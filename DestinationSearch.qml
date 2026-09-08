// SPDX-License-Identifier: LGPL-2.0-or-later
//
// Choosing where to go: by name, from your saved places, and with the two
// preferences that change the road you get.
//
// Nominatim is the OSM search. Its terms are strict and they are respected here
// on purpose: an identifiable User-Agent, and a query sent ONLY when you ask
// for it -- never as you type. Search-as-you-type against Nominatim is
// explicitly forbidden and would get the whole phone blocked, which is a
// terrible way to find out.
//
// The search needs the network. Saved places and holding a finger on the map do
// not, which is why this panel says so when there is no signal instead of just
// failing.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtPositioning
import org.kde.kirigami as Kirigami

Item {
	id: buscador

	// Bias results towards where you are, otherwise "farmacia" is a lottery
	// over the whole planet.
	property var cerca: null
	property int alto: Kirigami.Units.gridUnit * 3.5

	// Owned by the caller and handed back through the signals, so this panel
	// never has to know where preferences live.
	property string favoritosJson: "[]"
	property bool evitarPeajes: false
	property bool evitarAutopistas: false
	property bool evitarFerris: false
	property bool evitarTierra: false

	signal elegido(var coordenada, string nombre)
	signal favoritosCambiados(string json)
	signal alternarPeajes()
	signal alternarAutopistas()
	signal alternarFerris()
	signal alternarTierra()

	readonly property var p: Theme

	// If there are downloaded maps, the search runs on the phone. Whoever creates us decides it:
	// it is the same poll the routes already use, and there is no reason to do it
	// twice or for the two things to be able to disagree.
	property bool hayLocal: false

	// Reachable from outside so the field can be written to from the
	// self-test: checking the debounce requires actually typing.
	property alias campo: campo
	property alias resultados: resultados
	// How many queries have been fired. The self-test looks at it to check that
	// typing nine letters gives ONE search and not nine; counting inserted rows
	// is no good, because a single search inserts twelve.
	property int consultas: 0

	property string estado: ""   // "", "buscando", "listo", "error"
	property string fallo: ""
	property var _peticion: null

	readonly property bool sinRed: estado === "error" && fallo.indexOf("connection") >= 0

	visible: false
	anchors.fill: parent

	onFavoritosJsonChanged: _cargarFavoritos()
	Component.onCompleted: _cargarFavoritos()

	function abrir() {
		visible = true
		campo.forceActiveFocus()
		campo.selectAll()
	}

	function cerrar() {
		// Keyboard away WHENEVER you leave here, not only when pressing search.
		// It goes in 'cerrar' and not in every place that chooses a destination because
		// all the exits pass through here -- a result, a save, the cross --
		// and putting this in three places guarantees that one day it is missing from one.
		campo.focus = false
		Qt.inputMethod.hide()
		if (_peticion) {
			_peticion.abort()
			_peticion = null
		}
		visible = false
	}

	// --- saved places -----------------------------------------------------
	function _cargarFavoritos() {
		favoritos.clear()
		var lista
		try {
			lista = JSON.parse(favoritosJson)
		} catch (e) {
			return
		}
		if (!lista || !lista.length)
			return
		for (var i = 0; i < lista.length; ++i)
			favoritos.append({
				nombre: lista[i].nombre,
				lat: lista[i].lat,
				lon: lista[i].lon
			})
	}

	function _volcarFavoritos() {
		const salida = []
		for (var i = 0; i < favoritos.count; ++i) {
			const f = favoritos.get(i)
			salida.push({ nombre: f.nombre, lat: f.lat, lon: f.lon })
		}
		favoritosCambiados(JSON.stringify(salida))
	}

	function guardar(nombre, lat, lon) {
		// Same place twice is clutter, and "same" here means the same spot,
		// not the same spelling: Nominatim writes a name a dozen ways.
		for (var i = 0; i < favoritos.count; ++i) {
			const f = favoritos.get(i)
			if (Math.abs(f.lat - lat) < 1e-5 && Math.abs(f.lon - lon) < 1e-5)
				return
		}
		favoritos.append({ nombre: nombre, lat: lat, lon: lon })
		_volcarFavoritos()
	}

	function olvidar(indice) {
		favoritos.remove(indice)
		_volcarFavoritos()
	}

	// --- search as you type (0.8 s debounce) ---------------------------------
	//
	// It waits for text to stop arriving and then searches, instead of searching
	// on every key: typing "cartagena" is nine keystrokes and would be nine
	// searches to throw away eight.
	//
	// ONLY AGAINST THE PHONE, and it is not a technical limitation: Nominatim EXPRESSLY
	// FORBIDS search as you type -- "you must not implement such a
	// service on the client side using the API" --, and it is the condition under
	// which that server is used. Without downloaded maps, the search box stays as
	// it was: you type and you press.
	//
	// On the phone there is no such problem: the database is ours and a search takes
	// between 5 and 30 ms, measured over the whole of Spain.
	readonly property Timer antirrebote: Timer {
		interval: 800
		onTriggered: {
			const texto = campo.text.trim()
			if (texto.length >= 2 && buscador.hayLocal)
				buscador._buscarEnCasa(texto, false)
		}
	}

	function alEscribir() {
		if (!hayLocal)
			return
		// Emptying the field clears the list at once: leaving the results of what
		// has already been deleted is what makes a live search feel
		// sticky.
		if (campo.text.trim().length < 2) {
			antirrebote.stop()
			resultados.clear()
			estado = ""
			return
		}
		antirrebote.restart()
	}

	function buscar() {
		antirrebote.stop()
		// Keyboard away. It takes up half the screen and what you want to see right
		// after searching are the RESULTS, which are below.
		campo.focus = false
		Qt.inputMethod.hide()
		const texto = campo.text.trim()
		if (texto.length < 2)
			return
		if (_peticion)
			_peticion.abort()

		resultados.clear()
		estado = "buscando"
		fallo = ""

		// With downloaded maps the search runs on the phone, otherwise over the network. Same
		// rule as the routes: if it is at home, the home one is used.
		if (hayLocal)
			_buscarEnCasa(texto, true)
		else
			_buscarPorRed(texto)
	}

	// The application's own server, the same one that computes the routes. Its
	// database comes with the downloaded region.
	// 'permitirRed' distinguishes the two ways of getting here. Searching live it CANNOT
	// fall back to Nominatim even if the phone finds nothing: it would be
	// exactly what its policy forbids, one request for every pause while
	// typing. Pressing search, yes.
	function _buscarEnCasa(texto, permitirRed) {
		buscador.consultas += 1
		const cuerpo = { q: texto, limite: 12 }
		if (cerca)
			cuerpo.cerca = { lat: cerca.latitude, lon: cerca.longitude }

		const x = new XMLHttpRequest()
		_peticion = x
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			buscador._peticion = null
			// If the home server fails, the network is tried before giving
			// up: it may not have started yet, or the downloaded region
			// may not cover what is being searched for.
			if (x.status !== 200) {
				if (permitirRed)
					buscador._buscarPorRed(texto)
				else
					estado = "listo"
				return
			}
			try {
				const lista = JSON.parse(x.responseText).resultados || []
				// It is cleared HERE and not only in buscar(): when searching live, the
				// timer calls this function directly, and without this each pause
				// while typing would add another batch below the previous one.
				//
				// And it is cleared on RECEIVING, not on requesting: emptying the list while
				// the response arrives leaves it blank for a moment on every
				// pause, which is exactly the flicker that makes a live
				// search feel broken.
				resultados.clear()
				for (var i = 0; i < lista.length; ++i) {
					const r = lista[i]
					const c = QtPositioning.coordinate(r.lat, r.lon)
					resultados.append({
						nombre: r.nombre,
						// The type comes from OSM in English and with an underscore
						// ("place_town"). It is shown readable: it is the only thing that
						// distinguishes two places with the same name.
						detalle: buscador._legible(r.tipo),
						lat: c.latitude,
						lon: c.longitude,
						lejos: cerca ? cerca.distanceTo(c) : 0
					})
				}
				if (resultados.count === 0 && permitirRed) {
					// No results at home is NOT the same as not having
					// searched: it may be outside the downloaded region.
					buscador._buscarPorRed(texto)
					return
				}
				estado = "listo"
			} catch (e) {
				if (permitirRed)
					buscador._buscarPorRed(texto)
				else
					estado = "listo"
			}
		}
		x.open("POST", "http://127.0.0.1:8554/search")
		x.setRequestHeader("Content-Type", "application/json")
		x.send(JSON.stringify(cuerpo))
	}

	function _legible(tipo) {
		if (!tipo)
			return ""
		const t = tipo.split("_")
		const nombres = {
			"place": "town", "boundary": "municipality", "highway": "road",
			"natural": "natural feature", "amenity": "amenity", "tourism": "tourism",
			"shop": "shop", "leisure": "leisure", "building": "building",
			"aeroway": "airport", "railway": "railway", "landuse": "area",
			"healthcare": "healthcare", "aerialway": "cable car"
		}
		return nombres[t[0]] || t[0]
	}

	function _buscarPorRed(texto) {
		var url = "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=8"
			+ "&accept-language=es&q=" + encodeURIComponent(texto)
		if (cerca) {
			// A box around you, unbounded: it ranks what is near first without
			// hiding the rest.
			const d = 0.6
			url += "&viewbox=" + (cerca.longitude - d) + "," + (cerca.latitude + d)
				+ "," + (cerca.longitude + d) + "," + (cerca.latitude - d)
		}

		const x = new XMLHttpRequest()
		_peticion = x
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			buscador._peticion = null
			if (x.status !== 200) {
				estado = "error"
				fallo = x.status === 0 ? qsTr("no connection")
					: qsTr("the search server responded %1").arg(x.status)
				return
			}
			try {
				const lista = JSON.parse(x.responseText)
				for (var i = 0; i < lista.length; ++i) {
					const r = lista[i]
					const c = QtPositioning.coordinate(parseFloat(r.lat), parseFloat(r.lon))
					resultados.append({
						nombre: r.name && r.name.length ? r.name
							: r.display_name.split(",")[0],
						detalle: r.display_name,
						lat: c.latitude,
						lon: c.longitude,
						lejos: cerca ? cerca.distanceTo(c) : 0
					})
				}
				estado = "listo"
			} catch (e) {
				estado = "error"
				fallo = qsTr("I could not understand the search response")
			}
		}
		x.open("GET", url)
		x.setRequestHeader("User-Agent", "PocoNav/1.0 (postmarketOS; personal use)")
		x.send()
	}

	// --- distances, in whatever the driver uses ----------------------------
	// Internally EVERYTHING is metres; here and only here it is turned into what is read.
	//
	// In miles FEET are used below 0.1 mile and not yards: it is what
	// navigators in the US say and what people expect to hear. The cut-off
	// is at 528 feet, which is half a mile divided by five -- round in their
	// system, ugly in ours, and that is why dividing by a thousand does not work.
	property bool millas: false

	function _dist(m) {
		if (millas) {
			const mi = m / 1609.344
			if (mi < 0.1)
				return Math.round(m * 3.28084 / 10) * 10 + " ft"
			return mi.toFixed(mi < 10 ? 1 : 0).replace(".", ",") + " mi"
		}
		if (m < 1000)
			// Rounded to 10 m: the last digit changes faster than
			// anyone can read it and makes the number look broken.
			return Math.round(m / 10) * 10 + " m"
		return (m / 1000).toFixed(m < 10000 ? 1 : 0).replace(".", ",") + " km"
	}

	function _lejania(m) {
		return m <= 0 ? "" : "  ·  " + _dist(m)
	}

	ListModel { id: resultados }
	ListModel { id: favoritos }

	// Tapping outside closes. Also stops taps reaching the map underneath.
	MouseArea {
		anchors.fill: parent
		onClicked: buscador.cerrar()
	}

	Rectangle {
		anchors.fill: parent
		color: "#000000"
		opacity: 0.45
	}

	Rectangle {
		// Anchored to the top rather than centred: the virtual keyboard eats
		// the bottom half of a phone, and in landscape it eats more than half.
		anchors.top: parent.top
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.topMargin: Kirigami.Units.largeSpacing
		width: Math.min(parent.width - Kirigami.Units.largeSpacing * 2,
			Kirigami.Units.gridUnit * 36)
		height: Math.min(parent.height - Kirigami.Units.largeSpacing * 2,
			contenido.implicitHeight + Kirigami.Units.largeSpacing * 2)
		radius: buscador.p.radioGrande
		color: buscador.p.fondo

		// Swallows the taps that would otherwise close the sheet.
		MouseArea { anchors.fill: parent }

		ColumnLayout {
			id: contenido
			anchors.fill: parent
			anchors.margins: Kirigami.Units.largeSpacing
			spacing: Kirigami.Units.smallSpacing

			RowLayout {
				Layout.fillWidth: true
				spacing: Kirigami.Units.smallSpacing

				QQC2.TextField {
					id: campo
					Layout.fillWidth: true
					Layout.preferredHeight: buscador.alto
					placeholderText: qsTr("Where to?")
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.3
					inputMethodHints: Qt.ImhNoPredictiveText
					onAccepted: buscador.buscar()
					onTextChanged: buscador.alEscribir()
					color: buscador.p.tintaOscura
					placeholderTextColor: buscador.p.tintaSuave
					leftPadding: Kirigami.Units.largeSpacing * 1.5
					rightPadding: leftPadding
					background: Rectangle {
						radius: height / 2
						color: buscador.p.blanco
					}
				}

				QQC2.AbstractButton {
					id: botonLupa
					Layout.preferredWidth: buscador.alto
					Layout.preferredHeight: buscador.alto
					onClicked: buscador.buscar()
					background: Rectangle {
						radius: height / 2
						color: botonLupa.pressed ? buscador.p.azulCasco : buscador.p.azul
					}
					contentItem: Kirigami.Icon {
						source: "search"
						isMask: true
						color: buscador.p.blanco
					}
				}

				QQC2.AbstractButton {
					id: botonCerrar
					Layout.preferredWidth: buscador.alto
					Layout.preferredHeight: buscador.alto
					onClicked: buscador.cerrar()
					background: Rectangle {
						radius: height / 2
						color: botonCerrar.pressed ? buscador.p.tintaSuave : buscador.p.fondoAlto
					}
					contentItem: Kirigami.Icon {
						source: "dialog-close"
						isMask: true
						color: buscador.p.tinta
					}
				}
			}

			QQC2.Label {
				Layout.fillWidth: true
				visible: text.length > 0
				text: {
					if (buscador.estado === "buscando")
						return qsTr("Searching…")
					if (buscador.sinRed)
						return qsTr("No connection. Your saved places still work, and "
							+ "you can hold your finger on the map to set "
							+ "the destination there.")
					if (buscador.estado === "error")
						return buscador.fallo
					if (buscador.estado === "listo" && resultados.count === 0)
						return qsTr("No results")
					if (buscador.estado !== "listo" && favoritos.count === 0)
						return buscador.hayLocal
							? qsTr("Type: it searches on its own.")
							: qsTr("Type a place, a street or a town.")
					return ""
				}
				color: buscador.p.tintaSuave
				wrapMode: Text.WordWrap
				padding: Kirigami.Units.smallSpacing
			}

			// --- saved places, while there is nothing else to show ---------
			QQC2.Label {
				Layout.fillWidth: true
				visible: listaFavoritos.visible
				text: qsTr("Saved")
				font.bold: true
				color: buscador.p.tintaSuave
				padding: Kirigami.Units.smallSpacing
			}

			ListView {
				id: listaFavoritos
				Layout.fillWidth: true
				Layout.preferredHeight: Math.min(count * buscador.alto * 1.2,
					Kirigami.Units.gridUnit * 14)
				visible: count > 0 && resultados.count === 0
				clip: true
				model: favoritos
				spacing: 1

				delegate: QQC2.ItemDelegate {
					id: filaFav
					width: ListView.view.width
					height: buscador.alto * 1.2
					// Without this, Breeze paints the delegate white and the light
					// text on top is illegible over the dark sheet.
					background: Rectangle {
						radius: buscador.p.radio
						color: filaFav.pressed ? buscador.p.fondoAlto : "transparent"
					}
					onClicked: {
						buscador.elegido(QtPositioning.coordinate(model.lat, model.lon),
							model.nombre)
						buscador.cerrar()
					}

					contentItem: RowLayout {
						spacing: Kirigami.Units.smallSpacing
						QQC2.Label {
							Layout.fillWidth: true
							text: model.nombre + buscador._lejania(buscador.cerca
								? buscador.cerca.distanceTo(
									QtPositioning.coordinate(model.lat, model.lon)) : 0)
							font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.15
							color: buscador.p.tinta
							elide: Text.ElideRight
						}
						QQC2.AbstractButton {
							id: botonOlvidar
							Layout.preferredWidth: buscador.alto
							Layout.preferredHeight: buscador.alto
							onClicked: buscador.olvidar(model.index)
							background: Rectangle {
								radius: height / 2
								color: botonOlvidar.pressed ? buscador.p.fondoAlto : "transparent"
							}
							contentItem: Kirigami.Icon {
								source: "edit-delete"
								isMask: true
								color: buscador.p.tintaSuave
							}
						}
					}
				}
			}

			// --- what the search found -------------------------------------
			ListView {
				Layout.fillWidth: true
				Layout.preferredHeight: Math.min(count * buscador.alto * 1.5,
					Kirigami.Units.gridUnit * 20)
				visible: count > 0
				clip: true
				model: resultados
				spacing: 1

				delegate: QQC2.ItemDelegate {
					id: filaRes
					width: ListView.view.width
					height: buscador.alto * 1.5
					background: Rectangle {
						radius: buscador.p.radio
						color: filaRes.pressed ? buscador.p.fondoAlto : "transparent"
					}
					onClicked: {
						buscador.elegido(QtPositioning.coordinate(model.lat, model.lon),
							model.nombre)
						buscador.cerrar()
					}

					contentItem: RowLayout {
						spacing: Kirigami.Units.smallSpacing

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0
							QQC2.Label {
								Layout.fillWidth: true
								text: model.nombre + buscador._lejania(model.lejos)
								font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.15
								font.bold: true
								color: buscador.p.tinta
								elide: Text.ElideRight
							}
							QQC2.Label {
								Layout.fillWidth: true
								text: model.detalle
								font.pointSize: Kirigami.Theme.smallFont.pointSize
								color: buscador.p.tintaSuave
								elide: Text.ElideRight
							}
						}

						QQC2.AbstractButton {
							id: botonFav
							Layout.preferredWidth: buscador.alto
							Layout.preferredHeight: buscador.alto
							onClicked: buscador.guardar(model.nombre, model.lat, model.lon)
							background: Rectangle {
								radius: height / 2
								color: botonFav.pressed ? buscador.p.fondoAlto : "transparent"
							}
							contentItem: Kirigami.Icon {
								source: "bookmark-new"
								isMask: true
								color: buscador.p.tintaSuave
							}
						}
					}
				}
			}

			// --- how the route gets calculated -----------------------------
			// Here and not in a settings screen: these change the road
			// you will be given, so they go next to the destination.
			//
			// They FORBID nothing: the planner also shows the routes that
			// break them, marked, and asks before taking you down one. What they
			// decide is which comes first and which carries a warning.
			RowLayout {
				Layout.fillWidth: true
				Layout.topMargin: Kirigami.Units.smallSpacing
				spacing: Kirigami.Units.smallSpacing

				QQC2.AbstractButton {
					id: swPeajes
					Layout.fillWidth: true
					// Starting width ZERO so the split is in equal
					// parts. With only fillWidth each button keeps what
					// its text asks for, and "Avoid unpaved" is longer
					// than "Avoid ferries": the two rows did not line up.
					Layout.preferredWidth: 0
					Layout.preferredHeight: buscador.alto
					onClicked: buscador.alternarPeajes()
					background: Rectangle {
						radius: height / 2
						color: buscador.evitarPeajes ? buscador.p.azul : buscador.p.fondoAlto
					}
					contentItem: QQC2.Label {
						text: qsTr("Avoid tolls")
						color: buscador.p.tinta
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}

				QQC2.AbstractButton {
					id: swAutopistas
					Layout.fillWidth: true
					// Starting width ZERO so the split is in equal
					// parts. With only fillWidth each button keeps what
					// its text asks for, and "Avoid unpaved" is longer
					// than "Avoid ferries": the two rows did not line up.
					Layout.preferredWidth: 0
					Layout.preferredHeight: buscador.alto
					onClicked: buscador.alternarAutopistas()
					background: Rectangle {
						radius: height / 2
						color: buscador.evitarAutopistas ? buscador.p.azul : buscador.p.fondoAlto
					}
					contentItem: QQC2.Label {
						text: qsTr("Avoid motorways")
						color: buscador.p.tinta
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}
			}

			// Second row. These two are used far less -- a ferry only
			// appears when going to the islands or to Ceuta -- but when they appear,
			// finding out halfway is too late.
			RowLayout {
				Layout.fillWidth: true
				spacing: Kirigami.Units.smallSpacing

				QQC2.AbstractButton {
					id: swFerris
					Layout.fillWidth: true
					// Starting width ZERO so the split is in equal
					// parts. With only fillWidth each button keeps what
					// its text asks for, and "Avoid unpaved" is longer
					// than "Avoid ferries": the two rows did not line up.
					Layout.preferredWidth: 0
					Layout.preferredHeight: buscador.alto
					onClicked: buscador.alternarFerris()
					background: Rectangle {
						radius: height / 2
						color: buscador.evitarFerris ? buscador.p.azul : buscador.p.fondoAlto
					}
					contentItem: QQC2.Label {
						text: qsTr("Avoid ferries")
						color: buscador.p.tinta
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}

				QQC2.AbstractButton {
					id: swTierra
					Layout.fillWidth: true
					// Starting width ZERO so the split is in equal
					// parts. With only fillWidth each button keeps what
					// its text asks for, and "Avoid unpaved" is longer
					// than "Avoid ferries": the two rows did not line up.
					Layout.preferredWidth: 0
					Layout.preferredHeight: buscador.alto
					onClicked: buscador.alternarTierra()
					background: Rectangle {
						radius: height / 2
						color: buscador.evitarTierra ? buscador.p.azul : buscador.p.fondoAlto
					}
					contentItem: QQC2.Label {
						text: qsTr("Avoid unpaved")
						color: buscador.p.tinta
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}
			}

			QQC2.Label {
				Layout.fillWidth: true
				// With a margin: flush to the edge it looked like cut-off text, not a
				// credit.
				Layout.rightMargin: Kirigami.Units.smallSpacing
				Layout.topMargin: Kirigami.Units.smallSpacing
				text: qsTr("Search by OpenStreetMap (Nominatim)")
				font.pointSize: Kirigami.Theme.smallFont.pointSize
				color: buscador.p.tintaSuave
				opacity: 0.8
				horizontalAlignment: Text.AlignRight
			}
		}
	}
}
