// SPDX-License-Identifier: LGPL-2.0-or-later
//
// PocoNav: where you are, and how to drive somewhere else.
//
// Every other map program on this phone is a desktop application squeezed into
// a 6" screen. This one is built the other way round: for a phone clamped to a
// windscreen, in LANDSCAPE, read at a glance, with targets you can hit without
// aiming at them.
//
// This file is the interface and nothing else. Anything that needs to touch the
// system -- downloading a map, speaking a phrase, keeping the screen awake,
// starting the routing engine -- goes through `app`, the C++ backend exposed as
// a context property. See src/backend.h for why it exists.
//
// It was pure QML for most of its life, run straight from source by qmlscene.
// That stopped paying: QML cannot write a file or start a process, so every new
// feature arrived crippled and got propped up by a shell script polling the
// settings file. The README has the full account under "Why it stopped being
// pure QML".
//
// Strings are still Spanish rather than i18n(): the wiring for KLocalizedContext
// is not in place yet, and inventing half of it would be worse than none.
import QtCore
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtPositioning
import QtLocation
import QtSensors
import org.kde.kirigami as Kirigami

QQC2.ApplicationWindow {
	id: root

	visible: true
	// Only used when something runs this on a desktop; Plasma Mobile makes
	// every window fullscreen and ignores both. Landscape, because that is the
	// shape this is designed around.
	width: 1200
	height: 540
	title: "PocoNav"

	// The window background, declared. Without this the SYSTEM theme sets it, and
	// on this phone it is white: any gap a panel does not paint shows up
	// white, with text meant for a dark background on top. This is what made
	// the planner come out with invisible letters.
	color: root.p.fondo

	// "explorar" -> just the map. "vista" -> a route drawn, not started yet.
	// "conducir" -> the driving panel, and the screen held awake.
	property string modo: "explorar"
	readonly property bool apaisado: width > height

	// --- where the position comes from ---------------------------------------
	// From the GPS, or the simulator when it is on. EVERYTHING that needs to know
	// where you are goes through here and not through 'gps' directly: if every place
	// asked the GPS on its own, simulating would mean patching twenty spots and
	// forgetting three.
	readonly property bool simulando: simulador.corriendo

	readonly property var coord: simulando
		? simulador.donde : gps.position.coordinate
	readonly property real velocidad: simulando ? simulador.velocidad
		: (gps.position.speedValid ? gps.position.speed : -1)
	readonly property bool rumboValido: simulando || gps.position.directionValid
	readonly property real rumboFuente: simulando
		? simulador.rumbo : gps.position.direction

	readonly property bool hayPosicion: simulando
		|| (gps.position.latitudeValid && gps.position.longitudeValid)
	// While simulating there is no measurement error to show: it is set to zero so the
	// status pill does not say "network position" over a made-up car.
	readonly property int precision: simulando ? 0
		: (gps.position.horizontalAccuracyValid
			? Math.round(gps.position.horizontalAccuracy) : -1)
	// Anything this coarse did not come from a satellite. GeoClue falls back to
	// the network without saying so, and that fallback has been measured here
	// at 25 km -- see setup/ajustes/mapas. Guessing from the accuracy is the
	// only way to tell, because GeoClue does not report which source it used.
	readonly property bool porRed: precision > 500
	// 2,8 m/s is 10 km/h. MEASURED: parked, with the phone still on a table,
	// GeoClue reports speeds of a couple of m/s often enough that a walking
	// pace threshold turned the map to a random heading and -- because the
	// bearing is deliberately never reset -- left it there. Below this, the
	// reported course is noise.
	readonly property bool enMarcha: root.velocidad > 2.8

	// Whether the map sticks to you. Dragging it by hand means "leave it where
	// I put it"; the crosshair button hands control back.
	property bool seguir: true

	// Where you sit on the map while driving: horizontally centred in the map
	// column, and a little BELOW its middle, so most of the screen is the road
	// ahead of you rather than the road behind.
	readonly property real anclaY: root.apaisado ? 0.66 : 0.70

	// The only two margins of the floating interface. Before, each thing carried
	// its own -- 2.2 units here, 2.4 there, largeSpacing over yonder --
	// and the corners did not line up with each other. A single pair of numbers and everything
	// falls on the same grid.
	readonly property int borde: Math.round(Kirigami.Units.largeSpacing * 1.5)
	readonly property int hueco: Kirigami.Units.largeSpacing

	// The phone has no magnetometer and no accelerometer exposed today -- the
	// only IIO devices are the PMIC's ADCs -- so this stays false and the
	// button that uses it stays off. The day the sensor appears, it turns true
	// on its own and nothing else has to change.
	readonly property bool sensorDisponible: brujula.connectedToBackend
	readonly property bool orientarPorSensor: memoria.orientacion === "sensor"
		&& sensorDisponible

	// If the heading is being driven by something -- the compass, or the car's motion --
	// turning with your fingers does nothing: the binding puts it back in place on the
	// next frame. The gesture only makes sense when nobody is in charge.
	readonly property bool rumboLibre: !orientarPorSensor
		&& !(modo === "conducir" && enMarcha && rumboValido)
		// Not while choosing a route either: there north is fixed by the application and turning with
		// your fingers would only fight the binding that puts it back to zero.
		&& modo !== "planificar"

	// Every colour and radius in the application. See Theme.qml for why the
	// look is Google Maps' and why it does not follow the desktop theme.
	readonly property var p: Theme

	// --- day or night -------------------------------------------------------
	Sun {
		id: sol
		donde: root.hayPosicion ? root.coord : null
	}

	// In "auto", night when the sun has already set WHERE YOU ARE. Without
	// a position it cannot be known, and then it is not made up: it stays day,
	// which is the state the application always looks good in.
	readonly property bool esNoche: memoria.tema === "dark"
		|| (memoria.tema === "auto" && sol.sabemos && sol.esDeNoche)

	// THE TILE UNDERNEATH, and whether we have it downloaded.
	//
	// "There is a drawing map" is not enough: the drawing is downloaded in tiles of about
	// 300 km a side, and having Murcia's is not having Valencia's. Confusing
	// the two gives the worst possible screen, and it is not hypothetical -- it happened: with
	// the Murcia tile downloaded and the map opened where it was closed, in Valencia,
	// the 110 tiles it asked for answered 204 and the screen came out BLANK, without
	// a single line saying why.
	readonly property string cuadroAqui: {
		if (!coord)
			return ""
		const c = app.cuadrosDe(coord.latitude, coord.longitude, 0)
		return c.length ? c[0] : ""
	}
	readonly property bool dibujoAqui: cuadroAqui !== ""
		&& ruta.cuadrosDibujo.indexOf(cuadroAqui) >= 0

	// What it is drawn with. 'maplibre' ONLY where there is a downloaded tile; 'osm' everywhere
	// else, which at least draws while there is coverage.
	readonly property bool dibujoLocal: ruta.dibujoLocal && dibujoAqui

	// And the bad case: neither tile nor network. Here nothing can be drawn, and it has to be
	// SAID -- a silent blank map looks like the application is broken.
	readonly property bool mapaImposible: !dibujoAqui && !app.hayRed

	// THE TILES THE ROUTE CROSSES, and which of them are missing.
	//
	// Without this you could only download the tile UNDER THE PHONE, which is the
	// place you least need it: you are already there. What you need is
	// the map of where you are GOING, and that is only known when there is a route.
	//
	// The line is sampled instead of checking point by point: it is thousands of points
	// and a tile is 300 km a side, so one in every twenty does not skip
	// any -- and even so the endpoints are always added, which is where a
	// coarse sampling drops the last tile.
	readonly property var cuadrosRuta: {
		const p = ruta.puntos
        if (!p || p.length < 2)
			return []
		const vistos = {}
		const fuera = []
		function anota(c) {
			const lista = app.cuadrosDe(c.latitude, c.longitude, 0)
			if (!lista.length || vistos[lista[0]])
				return
			vistos[lista[0]] = true
			fuera.push(lista[0])
		}
		for (var i = 0; i < p.length; i += 20)
			anota(p[i])
		anota(p[p.length - 1])
		return fuera
	}
	// The same for the route being LOOKED AT in the planner, which has not
	// been adopted yet: there the line lives in the plan, not in 'ruta'.
	readonly property var cuadrosQueFaltanDelPlan: {
		const r = planificador.rutas
		const i = panelRutas.elegida
		if (!r || i < 0 || i >= r.length)
			return []
		// The rectangle Valhalla returns with the route. The planner stores the
		// trip undecoded, so there is no line to walk -- and for
		// tiles 300 km a side the rectangle gives the same result, with the advantage
		// that it skips none.
		const s = r[i].trip && r[i].trip.summary
		if (!s || s.min_lat === undefined)
			return []
		const todos = app.cuadrosDelRectangulo(s.min_lat, s.min_lon,
			s.max_lat, s.max_lon)
		const fuera = []
		for (var k = 0; k < todos.length; ++k)
			if (ruta.cuadrosDibujo.indexOf(todos[k]) < 0)
				fuera.push(todos[k])
		return fuera
	}

	readonly property var cuadrosQueFaltan: {
		const fuera = []
		for (var i = 0; i < cuadrosRuta.length; ++i)
			if (ruta.cuadrosDibujo.indexOf(cuadrosRuta[i]) < 0)
				fuera.push(cuadrosRuta[i])
		return fuera
	}

	// The window sets the singleton and the whole interface reads it at once.
	//
	// With a Binding and not a handler: the INITIAL value is needed as well as
	// the changes, and putting it in Component.onCompleted clashes with the one
	// already further down -- QML does not allow two handlers of the same signal on the
	// same object and the error it gives ("Property value set multiple times") does not
	// say which the other one is.
	Binding {
		target: Theme
		property: "noche"
		value: root.esNoche
	}

	// --- kilometres or miles -------------------------------------------------
	// In "auto" it is taken from the system language, which is where that
	// information lives: Qt knows en_US measures in miles and es_ES in kilometres. It is
	// more reliable than guessing it from the country of the position, because someone carrying
	// the phone in British English drives in miles even when travelling.
	readonly property bool millas: memoria.unidades === "millas"
		|| (memoria.unidades === "auto"
			&& Qt.locale().measurementSystem !== Locale.MetricSystem)

	// White circular buttons with a blue glyph, like the ones on the map
	// everybody already has. `azulado` fills the whole button instead, which is
	// how the follow button says it is on.
	//
	// Declared here and not next to the buttons: an inline component has to sit
	// at the top level of its file.
	component BotonMapa: QQC2.AbstractButton {
		id: bm
		property string icono: ""
		// For the buttons whose meaning is a word, not a picture -- "3D" says
		// it in two characters and no glyph would say it better.
		property string texto: ""
		property bool azulado: false
		property int lado: Kirigami.Units.gridUnit * 3.2

		implicitWidth: lado
		implicitHeight: lado

		background: Rectangle {
			radius: height / 2
			color: bm.azulado
				? (bm.pressed ? root.p.azulCasco : root.p.azul)
				: (bm.pressed ? "#e8eaed" : root.p.blanco)
			opacity: bm.enabled ? 1 : 0.5
		}

		contentItem: Item {
			Kirigami.Icon {
				anchors.centerIn: parent
				width: Math.round(parent.width * 0.62)
				height: width
				visible: bm.texto.length === 0
				source: bm.icono
				isMask: true
				color: bm.azulado ? root.p.blanco : root.p.azul
			}
			QQC2.Label {
				anchors.centerIn: parent
				visible: bm.texto.length > 0
				text: bm.texto
				font.bold: true
				font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.05
				color: bm.azulado ? root.p.blanco : root.p.azul
			}
		}
	}

	// Everything visible hangs off this one item. A window's own contentItem is
	// built in C++ and cannot be handed to grabToImage ("item has no QML
	// engine"), so having a QML-made root is what lets the application
	// photograph itself -- see Portraits.qml and `poconav --retratos`.
	readonly property alias lienzo: lienzo

	// GeoClue reports accuracy 0 here as often as it reports a real figure, and
	// 0 means "no estimate", not "perfect". Printing "±0 m" would be inventing
	// a number, so when there is none the app just does not print one.
	readonly property string margen: precision <= 0 ? ""
		: (precision < 1000 ? precision + " m"
			: (precision / 1000).toFixed(1) + " km")

	readonly property string estado: {
		if (gps.sourceError === PositionSource.AccessError)
			return qsTr("Location denied")
		if (gps.sourceError !== PositionSource.NoError || !gps.valid)
			return qsTr("No position source")
		if (!hayPosicion)
			return qsTr("Searching for GPS…")
		if (porRed)
			return qsTr("Network position · ±%1").arg(margen)
		return margen ? qsTr("GPS · ±%1").arg(margen) : qsTr("GPS fixed")
	}

	readonly property string detalle: {
		if (gps.sourceError === PositionSource.AccessError)
			return qsTr("turn it on in quick settings")
		if (gps.sourceError !== PositionSource.NoError || !gps.valid)
			return qsTr("did you apply the 'gps' setting?")
		if (!hayPosicion)
			return frio.running ? qsTr("from cold it takes ~40 s")
				: qsTr("indoors it may never fix")
		if (porRed)
			return qsTr("this is not GPS: it is an estimate")
		if (simulando)
			return "simulating the journey"
		return root.coord.latitude.toFixed(5) + ", "
			+ root.coord.longitude.toFixed(5)
	}

	// --- what the map remembers ------------------------------------------
	// Without this the map opens over a hardcoded default for the ~40 s a cold
	// fix takes, which reads as "broken" every single time. Reopening where you
	// closed it costs three numbers.
	//
	// Only what has to be REMEMBERED from one session to the next. What used to live here
	// so an outside script could read it -- the phrase to say, whether we are
	// navigating, whether there were home tiles -- no longer: that is asked of the backend
	// by calling it, which is what it exists for.
	Settings {
		id: memoria
		location: StandardPaths.writableLocation(StandardPaths.ConfigLocation)
			+ "/poconav.conf"
		property real lat: 40.4168
		property real lon: -3.7038
		property real zoom: 15
		// The route itself, so a crash or a reboot halfway to somewhere is not
		// the end of the journey. JSON, with the polyline still encoded.
		property string rutaGuardada: ""
		// Saved destinations, as JSON: [{nombre, lat, lon}].
		property string favoritos: "[]"
		property bool evitarPeajes: false
		property bool evitarAutopistas: false
		property bool evitarFerris: false
		property bool evitarTierra: false
		// "norte" or "sensor".
		property string orientacion: "norte"
		property bool tresD: false
		property bool voz: true
		// The last region written in the settings, so you do not have to
		// type it again when you come back.
		property string region: ""
		// "light", "dark" or "auto" (by the time of sunset where you are).
		property string tema: "auto"
		// "auto" (by the system language), "km" or "millas".
		property string unidades: "auto"
	}

	Voice {
		id: voz
		activa: memoria.voz
		// This used to write the phrase into the settings file and an outside
		// script read it every 0.3 s. Now it is told to the backend and that is it: the
		// phrase arrives whole, without filtering characters so it does not end up on a
		// command line, and without waiting for the next polling round.
		onHablar: (frase) => app.decir(frase)
		onCallar: app.callar()
	}

	Compass {
		id: brujula
		// Asking a sensor that is not there costs nothing, but asking one that
		// IS there costs battery, so it only runs when it is being used.
		active: root.orientarPorSensor
		// The more often the reading arrives, the less the animation has to make up
		// between one and the next. 20 Hz is more than enough and does not show in battery.
		dataRate: 20
		onReadingChanged: {
			if (reading)
				root.suavizarRumbo(reading.azimuth)
		}
	}

	// The sensor heading, filtered. A magnetometer shakes several degrees between
	// consecutive readings even when the phone does not move, and fed raw into the
	// map it looks exactly as it did: jerky.
	//
	// Exponential filter, not a moving average: it keeps no history, responds
	// instantly to a real turn and crushes the jitter. At 0.25 the map follows
	// the hand with no perceptible lag.
	property real rumboSuave: 0

	// THE LAST GOOD HEADING, held while driving.
	//
	// It is needed EVEN WITH A COMPASS, because the course over ground is only valid
	// above 10 km/h: without holding the last one, every stop returned the map to
	// north. You start the route stationary and the map faces north; you stop at a
	// traffic light and the map turns on its own. No navigator does that, and rightly so --
	// turning the map when the car has not turned is worse than leaving it still.
	//
	// WARNING FOR WHOEVER COMES NEXT: here I once wrote that this phone "has no
	// compass" because I looked at /sys/bus/iio and only saw two PMIC converters.
	// THAT IS FALSE. The sensors of this device do NOT hang off any SoC bus:
	// they go through the Snapdragon sensor core, and 'hexagonrpcd' exposes them --
	// udev labels them as 'ssc-accel', 'ssc-compass', 'ssc-light' and
	// 'ssc-proximity'. They are documented and working in
	// tasks/016-accelerometer-and-sensors.md.
	//
	// If 'sensorDisponible' comes out false, what to check is whether
	// 'hexagonrpcd-adsp-sensorspd' is running -- not whether the phone has the sensor.
	property real rumboRetenido: 0

	// The position, interpolated. The GPS gives one fix per second, and fed raw
	// that means jumps of several metres: the map slid with its animation
	// but the marker stuck to the data, so it jumped OVER the zonaMapa.item.
	// Now both come from here and move together.
	property var posSuave: QtPositioning.coordinate(0, 0)

	Behavior on posSuave {
		// LINEAR and the same duration as the GPS interval, on purpose.
		// With a smooth curve each segment slows at the end and starts at the beginning
		// of the next, and a second later slows again: that shows up as
		// jerks. Chained together, the only thing that joins seamlessly is a straight line.
		CoordinateAnimation {
			duration: gps.updateInterval
			easing.type: Easing.Linear
		}
	}

	onPosSuaveChanged: {
		if (!root.seguir || !root.hayPosicion)
			return
		if (root.modo === "conducir")
			zonaMapa.item.alignCoordinateToPoint(root.posSuave,
				Qt.point(zonaMapa.width / 2, zonaMapa.height * root.anclaY))
		else
			zonaMapa.item.center = root.posSuave
	}

	// When the compass is turned off, the map returns to north. Without this it stayed stuck
	// on the sensor's last heading, which is one of the most disorienting things
	// a map can do: you turn off rotation and it stays skewed, with nothing to
	// explain it. It does not apply while driving, where the course over ground is in charge.
	onOrientarPorSensorChanged: {
		if (!orientarPorSensor && modo !== "conducir")
			zonaMapa.item.bearing = 0
	}

	function suavizarRumbo(crudo) {
		// The short way round. Without this, going from 359 to 1 degree gives a jump of
		// 358 and the map does a full spin in place.
		var d = crudo - rumboSuave
		while (d > 180)
			d -= 360
		while (d < -180)
			d += 360
		// Dead zone: below half a degree it is noise, and chasing it makes
		// the map vibrate permanently.
		if (Math.abs(d) < 0.5)
			return
		rumboSuave = (rumboSuave + d * 0.25 + 360) % 360
	}

	// The screen is held awake WHILE DRIVING and only then: going off
	// halfway there leaves the phone useless, but never going off drains the
	// battery with the map forgotten in your pocket.
	onModoChanged: {
		app.mantenerPantalla(modo === "conducir")
		// North up to choose a route. Here too and not only when planning, in case
		// the map was rebuilt by a theme change and the saved camera brought back
		// the old heading.
		if (modo === "planificar" && zonaMapa.item)
			zonaMapa.item.bearing = 0
	}
	Component.onDestruction: app.mantenerPantalla(false)

	// Saved on a heartbeat rather than on close: this process gets killed by
	// SIGTERM often enough that onClosing cannot be trusted.
	//
	// And a heartbeat rather than a debounce, which is what this was: while
	// driving the centre moves every second, so a timer restarted on every move
	// NEVER elapsed and the map remembered nothing at all -- measured, the file
	// still held the factory default of Madrid after a whole journey.
	Timer {
		id: guardar
		interval: 5000
		running: true
		repeat: true
		onTriggered: {
			memoria.lat = zonaMapa.item.center.latitude
			memoria.lon = zonaMapa.item.center.longitude
			memoria.zoom = zonaMapa.item.zoomLevel
		}
	}

	// Only there to change the hint once waiting stops being normal.
	Timer {
		id: frio
		interval: 60000
		running: !root.hayPosicion
	}

	PositionSource {
		id: gps
		// The GNSS engine draws real power, and Plasma Mobile keeps this window
		// alive when you switch away from it: left at plain `true` the
		// satellites stay lit until the process dies. Cutting it the instant
		// focus is lost would be worse, because coming back would cost a fresh
		// search. Hence a minute of grace -- and none of that applies while
		// driving, which is what the first clause says.
		active: root.modo === "conducir"
			|| Qt.application.state === Qt.ApplicationActive || gracia.running
		updateInterval: 1000

		// While simulating, the GPS is not in charge: a real point would arrive every second and
		// would fight the made-up car, jumping between the two.
		onPositionChanged: if (!root.simulando) root.avanzar(position.coordinate)
	}

	// A single place where movement enters, whether from the GPS or the
	// simulator. This used to live inside the GPS handler and that is why simulating
	// would have meant duplicating it.
	function avanzar(donde) {
		if (!root.hayPosicion || !donde)
			return
		ruta.situar(donde)
		if (root.modo === "conducir")
			voz.seguir(ruta, root.velocidad > 0 ? root.velocidad : 0)
		// The rest is done by onPosSuaveChanged: here it only gives the destination to the
		// interpolation. The map and the marker both come from there, so they stay
		// together instead of each at its own pace.
		root.posSuave = donde
	}

	// --- the simulator ------------------------------------------------------
	Simulator {
		id: simulador
		ruta: ruta
		onDondeChanged: if (corriendo) root.avanzar(donde)
		onLlegado: root.terminar()
	}

	function simular() {
		if (!ruta.hay)
			return
		root.conducir()
		simulador.empezar()
	}

	Timer {
		id: gracia
		interval: 60000
		// Running from the start on purpose. Whether a freshly mapped window
		// reports itself as active depends on the compositor, and under
		// QT_QPA_PLATFORM=offscreen nothing ever does. Granting the first
		// minute unconditionally means the application cannot fail to look for
		// you just because nobody told it it was in front.
		running: true
	}

	Connections {
		target: Qt.application
		function onStateChanged() {
			if (Qt.application.state === Qt.ApplicationActive)
				gracia.stop()
			else
				gracia.restart()
		}
	}

	// The route options live here and we pass them to both: the
	// planner uses them to know WHAT each alternative breaks, and the route
	// to recalculate the same way if you go off it.
	Planner {
		id: planificador
		millas: root.millas
		evitarPeajes: memoria.evitarPeajes
		evitarAutopistas: memoria.evitarAutopistas
		evitarFerris: memoria.evitarFerris
		evitarTierra: memoria.evitarTierra
		hayLocal: ruta.hayLocal
		idioma: ruta.idioma

		// The first in the list previews itself. Showing the list with the
		// map empty would force you to touch something before seeing anything.
		onListo: {
			panelRutas.elegida = 0
			root.previsualizar(0)
		}
	}

	Route {
		id: ruta
		millas: root.millas
		evitarPeajes: memoria.evitarPeajes
		evitarAutopistas: memoria.evitarAutopistas

		onEstadoChanged: {
			// Saved the moment it exists, not when you set off: the useful
			// case is calculating it at home with WiFi and driving away.
			if (estado === "lista")
				memoria.rutaGuardada = paraGuardar()
			// Only when the route arrives on its own -- one restored at
			// startup. Coming from the planner the screen is already the list, and
			// jumping to the preview would close it mid-choice.
			if (estado === "lista" && root.modo === "explorar") {
				root.modo = "vista"
				// Following has to stop or the very next fix re-centres the
				// map on you and throws the framing away -- which is exactly
				// what happened: the far end of the route was off screen and
				// the destination flag with it.
				root.seguir = false
				root.encuadrarRuta()
			}
		}
	}

	function pedirRuta(destino, nombre) {
		if (!root.hayPosicion) {
			// It used to just `return`, so choosing a destination with no fix
			// did nothing at all and said nothing at all.
			ruta.fallar(qsTr("I do not know where you are yet; wait for the GPS"))
			return
		}
		// No longer ONE route is asked for: several are asked for and the driver decides. The
		// planning screen is the normal step between searching and driving.
		root.modo = "planificar"
		root.seguir = false
		planificador.planificar(root.coord, destino, nombre)
	}

	// --- what `--retratos` uses --------------------------------------------
	// These are the same doors the buttons use, not a separate path: if a
	// portrait comes out odd, the screen really is odd.
	function cerrarTodo() {
		buscador.visible = false
		panelAjustes.visible = false
		avisoFiltro.visible = false
	}
	function abrirBuscador() { buscador.abrir() }

	// Only for --retratos: the search box WITH RESULTS inside. It is the only
	// screen the portraits could not build, because it needs typing.
	function buscarEnRetrato(texto) {
		buscador.abrir()
		buscador.campo.text = texto
		buscador.buscar()
	}

	// Only for --retratos: with no filter set no route breaks anything, and
	// the warning dialog cannot be portrayed because it never comes to exist.
	function ponerFiltroPeajes(v) { memoria.evitarPeajes = v }

	// Only for --retratos: where the button column actually ends. The
	// portraits showed them cut off at the bottom and a number was needed, not
	// an impression.
	function medirBotonera() {
		return Math.round(botonera.y) + " height=" + Math.round(botonera.height)
			+ " end=" + Math.round(botonera.y + botonera.height)
			+ " map=" + Math.round(zonaMapa.item.y + zonaMapa.height)
	}
	function abrirAjustes() { panelAjustes.abrir() }

	function planificarDesde(origen, aDonde, nombre) {
		root.modo = "planificar"
		root.seguir = false
		// Always north up to choose. Comparing three routes with the map turned
		// to the car's last heading forces you to reorient before you
		// can read them; and on a map of the whole region, "up is north"
		// is the only thing that says anything.
		if (zonaMapa.item)
			zonaMapa.item.bearing = 0
		planificador.planificar(origen, aDonde, nombre)
	}

	function mostrarAviso() {
		// The first in the list that breaks something; if there is none, the last,
		// which serves just as well for seeing how the dialog looks.
		for (var i = 0; i < planificador.rutas.length; ++i) {
			if (planificador.rutas[i].aviso.length > 0) {
				root.arrancarRuta(planificador.rutas[i])
				return
			}
		}
	}

	// A route set and driving mode, with no GPS and no car.
	function conducirPrueba(origen, aDonde) {
		root.modo = "explorar"
		ruta.calcular(origen, aDonde, "Murcia")
		esperaConducir.restart()
	}

	readonly property Timer esperaConducir: Timer {
		interval: 3000
		// With the simulator running, not stopped: the portrait of the driving
		// screen with the car still came out with the "Off route" warning
		// and no speed, which is not what needs to be looked at.
		onTriggered: if (ruta.hay) root.simular()
	}

	// Draws on the map the route being looked at in the list, without starting it.
	// Route.adoptar() is used and not a separate line so the preview
	// is EXACTLY what will be driven -- same line, same maneuvers.
	function previsualizar(indice) {
		if (!planificador.hay || indice < 0 || indice >= planificador.rutas.length)
			return
		ruta.adoptar(planificador.rutas[indice].trip,
			planificador.destino, planificador.nombreDestino)
		root.encuadrarRuta()
	}

	// Start the chosen one. If it breaks something you asked to avoid, it asks first.
	function arrancarRuta(entrada) {
		if (!entrada)
			return
		if (entrada.aviso.length > 0) {
			// The time of the best one that DOES comply, so the question says
			// how much you gain by breaking the filter instead of just that it breaks.
			var mejor = 0
			for (var i = 0; i < planificador.rutas.length; ++i) {
				if (planificador.rutas[i].cumple) {
					mejor = planificador.rutas[i].minutos
					break
				}
			}
			avisoFiltro.preguntar(entrada, mejor)
			return
		}
		root.aceptarRuta(entrada)
	}

	function aceptarRuta(entrada) {
		ruta.adoptar(entrada.trip, planificador.destino,
			planificador.nombreDestino)
		root.conducir()
	}

	// If the home server is alive it decides where the routes come from AND WHAT
	// THE MAP IS DRAWN WITH, so it is asked -- never assumed.
	//
	// ALWAYS, in any mode. It was limited to "while there is no route", with
	// the argument that mid-journey the answer changes nothing. It stopped
	// being true the day the answer began to also choose the map's
	// connector, and the bug was invisible: the application starts up DRIVING when
	// there is a saved route less than a day old, so the poll never ran
	// EVER on that startup and the map was fetched over the internet with the tiles on
	// disk. With the phone out of coverage, that is a blank map.
	//
	// It costs nothing: it is one request to 127.0.0.1 once a minute.
	Timer {
		// FAST UNTIL IT ANSWERS, and then once a minute.
		//
		// The home server is started by the application itself and takes a few
		// seconds to load its tile index, so the first poll --
		// which fires at the same time as the window -- always finds it down. With
		// a single one-minute interval, that initial failure doomed the first
		// whole minute: routes over the network with the maps right there, and the map
		// drawn over the internet with the tiles on disk.
		//
		// Measured: the application started, the server came up a few
		// seconds later, and the log kept saying QGeoTileFetcherOsm.
		interval: ruta.sondeoContestado ? 60000 : 3000
		running: true
		triggeredOnStart: true
		repeat: true
		onTriggered: ruta.sondearLocal()
	}

	Component.onCompleted: {
		// A route left over from a journey that was interrupted. Restored into
		// the preview, never straight into driving: resuming has to be a
		// decision, not something that happens to you when you open the app.
		// Straight into driving, not into the preview: if you closed the app
		// with a route running, opening it again means you are still going
		// there. A day is the cut-off -- longer than that and it is yesterday's
		// journey, not this one.
		if (ruta.restaurar(memoria.rutaGuardada, 24))
			Qt.callLater(root.conducir)
	}

	function encuadrarRuta() {
		// The array, not ruta.hay. MEASURED: called straight from
		// onEstadoChanged, `hay` has not been re-evaluated yet -- QML gives no
		// order between a binding and a signal handler that depend on the same
		// property -- so this returned early every single time and the framing
		// silently never happened.
		if (!ruta.puntos || ruta.puntos.length < 2)
			return
		var norte = -90, sur = 90, este = -180, oeste = 180
		for (var i = 0; i < ruta.puntos.length; ++i) {
			const p = ruta.puntos[i]
			norte = Math.max(norte, p.latitude)
			sur = Math.min(sur, p.latitude)
			este = Math.max(este, p.longitude)
			oeste = Math.min(oeste, p.longitude)
		}
		// A margin, or the route touches the edges and both ends are
		// unreadable.
		const mLat = Math.max(0.002, (norte - sur) * 0.15)
		const mLon = Math.max(0.002, (este - oeste) * 0.15)
		// visibleRegion fits the whole Map item, and the summary bar sits on
		// top of its lower edge. Without this the last stretch of the route
		// hides behind the bar.
		const tapado = (norte - sur + mLat * 2) * (previa.height
			+ Kirigami.Units.largeSpacing * 2) / Math.max(1, zonaMapa.height)
		zonaMapa.item.bearing = 0
		zonaMapa.item.visibleRegion = QtPositioning.rectangle(
			QtPositioning.coordinate(norte + mLat, oeste - mLon),
			QtPositioning.coordinate(sur - mLat - tapado, este + mLon))
	}

	// Every good heading is noted so it can be held when stopping.
	onRumboFuenteChanged: if (rumboValido && enMarcha) rumboRetenido = rumboFuente

	function conducir() {
		voz.reiniciar()
		// On entering driving, the driving posture: camera tilted and map
		// oriented. It is not decoration -- in 3D you see much more road
		// ahead at the same zoom, and with the map turned you do not have to translate
		// mentally "left on the map" to "left through the windscreen".
		//
		// They stay set on exit, on purpose: if you like them while driving, you
		// like them. They are turned off with their own buttons.
		memoria.tresD = true
		if (root.sensorDisponible)
			memoria.orientacion = "sensor"
		root.modo = "conducir"
		root.seguir = true
		zonaMapa.item.zoomLevel = 17
		if (root.hayPosicion)
			zonaMapa.item.alignCoordinateToPoint(root.coord,
				Qt.point(zonaMapa.width / 2, zonaMapa.height * root.anclaY))
	}

	// --- back to the route ------------------------------------------------
	// It does not recalculate at the first metre off: a GPS with poor accuracy drifts off
	// and back on its own, and recalculating for that sends you elsewhere for no reason.
	// Eight seconds off in a row is a turn actually taken.
	//
	// And with a handbrake: 25 s between recalculations. Without that, a badly
	// mapped stretch leaves the application requesting routes in a loop from a public
	// server, which is the way to get yourself blocked.
	property real _ultimoRecalculo: 0

	// --- you have arrived -------------------------------------------------
	// Without this the route NEVER ended: you stayed in driving mode with
	// the screen held on and the GPS active until you closed the
	// application by hand, that is until you ran out of battery in the
	// car park.
	Connections {
		target: ruta
		function onLlegadoChanged() {
			if (ruta.llegado && root.modo === "conducir") {
				voz.decir("You have arrived at your destination")
				llegada.start()
			}
		}
	}

	Timer {
		id: llegada
		// Just enough to finish saying it before everything shuts off.
		interval: 3500
		onTriggered: root.terminar()
	}

	Timer {
		interval: 8000
		repeat: true
		running: root.modo === "conducir" && ruta.fueraDeRuta && root.hayPosicion
		onTriggered: {
			const ahora = Date.now()
			if (ahora - root._ultimoRecalculo < 25000)
				return
			root._ultimoRecalculo = ahora
			voz.decir("Recalculating")
			voz.reiniciar()
			ruta.recalcular(root.coord)
		}
	}

	function terminar() {
		// FIRST be quiet, then the rest. When cancelling a route the phrase already
		// sent to piper keeps playing: you have left the journey and the phone
		// tells you "turn left" with no route to refer to.
		voz.silenciar()
		ruta.limpiar()
		memoria.rutaGuardada = ""
		// It undoes what conducir() set: the camera returns to flat and the
		// map to north. The tilted view is for looking ahead of the
		// car; stopped over the map it only distorts and hides what is up top.
		memoria.tresD = false
		root.modo = "explorar"
		zonaMapa.item.bearing = 0
	}

	Item {
		id: lienzo

		anchors.fill: parent

		// --- the driving panel ----------------------------------------------
		// It takes its space FROM the map instead of floating over it. At a
		// glance a hard edge is easier to ignore than a translucent card, and
		// nothing important ends up hidden underneath.
		DrivingPanel {
			id: panelConducir

			millas: root.millas
			visible: root.modo === "conducir"
			ruta: ruta
			apaisado: root.apaisado
			velocidad: root.velocidad
			limite: ruta.limite
			onSalir: root.terminar()

			// Plain geometry, no anchors. MEASURED: an anchor whose binding
			// evaluates to `undefined` is NOT cleared -- once
			// `anchors.bottom` had been set while the window was landscape,
			// rotating to portrait left it anchored, the panel stayed
			// full-height and the map was squeezed to nothing (540x0).
			x: 0
			y: 0
			width: root.apaisado
				? Math.min(parent.width * 0.42, Kirigami.Units.gridUnit * 24)
				: parent.width
			// In portrait the dark strip eats a fixed 4,6 grid units of this, so
			// 10 left the blue card too cramped to breathe. And with lanes an extra
			// row is needed: the strip is a fixed height and the row came out
			// cut off at the bottom.
			height: root.apaisado ? parent.height
				: Kirigami.Units.gridUnit * (panelConducir.conCarriles ? 15 : 12)
		}

		// The list of routes to choose from. Landscape on the left, like Waze;
		// portrait, the top half.
		//
		// No anchors, like the driving panel and for the same reason: an
		// anchor whose binding evaluates to 'undefined' is NOT cleared, and rotating the phone
		// left it stuck to the edge of the previous orientation.
		// THE WARNING THAT THERE IS NO MAP HERE.
		//
		// Without this, running out of coverage outside a downloaded tile leaves the
		// screen BLANK and silent, which looks like the application is broken. It really
		// happened, and the user had to point it out because I did not check it.
		//
		// It sits over the map and does NOT cover anything useful: a narrow band at the top,
		// the width of the text, and it disappears as soon as there is something to draw with.
		Rectangle {
			visible: root.mapaImposible
			z: 50
			x: Math.round((zonaMapa.width - width) / 2) + zonaMapa.x
			y: zonaMapa.y + Kirigami.Units.gridUnit
			width: Math.min(zonaMapa.width - Kirigami.Units.gridUnit * 2,
				textoSinMapa.implicitWidth + Kirigami.Units.gridUnit * 2)
			height: textoSinMapa.implicitHeight + Kirigami.Units.gridUnit
			radius: height / 2
			color: root.p.fondoAlto
			border.color: root.p.ambar
			border.width: 1

			QQC2.Label {
				id: textoSinMapa
				anchors.centerIn: parent
				width: parent.width - Kirigami.Units.gridUnit * 1.5
				horizontalAlignment: Text.AlignHCenter
				wrapMode: Text.WordWrap
				color: root.p.tinta
				font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.95
				// It says WHAT is happening and WHAT to do. "No connection" alone is no use:
				// the map of this area can be downloaded, and this is where it is downloaded.
				text: qsTr("No connection and no map of this area.\nDownload it in Settings › Maps.")
			}
		}

		RoutesPanel {
			id: panelRutas

			millas: root.millas
			visible: root.modo === "planificar"
			plan: planificador

			// The tiles missing for the route being looked at. They are
			// computed here and not in the panel because it is the window that talks
			// to the backend.
			faltanCuadros: root.cuadrosQueFaltanDelPlan
			puedeBajar: app.hayRed && !app.trabajando
			onBajarMapaRuta: app.bajarDibujoCuadros(
				panelAjustes.region || "europe/spain",
				root.cuadrosQueFaltanDelPlan)

			x: 0
			y: 0
			width: root.apaisado
				? Math.min(parent.width * 0.42, Kirigami.Units.gridUnit * 26)
				: parent.width
			height: root.apaisado ? parent.height
				: Math.round(parent.height * 0.5)

			onElegidaChanged: root.previsualizar(elegida)
			onEmpezar: (entrada) => root.arrancarRuta(entrada)
			onSimular: (entrada) => {
				ruta.adoptar(entrada.trip, planificador.destino,
					planificador.nombreDestino)
				root.simular()
			}
			onCerrar: root.terminar()
		}

		// THE MAP GOES INSIDE A LOADER, and it is not a structural whim.
		//
		// The tile server is a parameter of Qt's connector and is
		// FIXED when the map is created. Verified two ways: binding it to the
		// theme changes the panels and changes the attribution, but the tiles do NOT;
		// and clearing the whole cache, neither. To go from a light map to a dark
		// map there is no choice but to recreate the map.
		//
		// The Loader keeps the GEOMETRY and the map fills it. This way the
		// buttons and panels still have something to anchor to while the map
		// is rebuilt -- and besides, anchoring to a Loader's child would be illegal: QML
		// only allows anchoring to a parent or a sibling.
		Loader {
			id: zonaMapa

			x: root.apaisado
				? (panelConducir.visible ? panelConducir.width
					: (panelRutas.visible ? panelRutas.width : 0))
				: 0
			y: root.apaisado ? 0
				: (panelConducir.visible ? panelConducir.height
					: (panelRutas.visible ? panelRutas.height : 0))
			width: parent.width - x
			height: parent.height - y

			sourceComponent: plantillaMapa

			// The camera is saved before throwing away the old map and handed back
			// to the new one. Without this, nightfall while driving would leave the map looking
			// at the middle of nowhere, with the car off screen.
			property var camara: null

			// Rebuild the map keeping where it was looking. TWO changes ask for it and for
			// the same reason: both the theme and the connector are fixed when the
			// Plugin is created and cannot be changed afterwards.
			function rehacer() {
				if (item) {
					camara = {
						centro: item.center,
						zoom: item.zoomLevel,
						rumbo: item.bearing,
						inclinacion: item.tilt
					}
				}
				active = false
				active = true
			}

			Connections {
				target: root
				// When the first map tile is downloaded it switches from 'osm' to
				// 'maplibre' on the fly, without closing the application.
				function onDibujoLocalChanged() { zonaMapa.rehacer() }
				function onEsNocheChanged() { zonaMapa.rehacer() }
			}

			onLoaded: {
				// WHAT it is drawing with. It is the only way to know from
				// outside: 'osm' announces itself when its tile downloader starts and
				// 'maplibre' says nothing, so without this line "nothing shows
				// in the log" was at once the symptom of success and of
				// failure.
				console.log("poconav: map with connector",
					item && item.plugin ? item.plugin.name : "none",
					"| types:", item ? item.supportedMapTypes.length : 0,
					"| active:", item && item.activeMapType
						? item.activeMapType.name : "none")
				if (!camara)
					return
				item.center = camara.centro
				item.zoomLevel = camara.zoom
				item.bearing = camara.rumbo
				item.tilt = camara.inclinacion
			}
		}

		// The map proper, in here so it can be rebuilt.
		Component {
			id: plantillaMapa

			Map {
				id: mapa

				// Whatever the panel leaves. Same reason as above: computed, not
				// anchored, so switching orientation cannot leave a stale edge
				// behind.
				anchors.fill: parent

				// THE CONNECTOR GOES IN HERE, with the map, and not outside.
				//
				// Rebuilding only the map was NOT enough: the tile server is
				// kept by the connector, and being outside the component it survived
				// the theme change. Verified: the map was recreated and the
				// tiles were still the light ones.
				plugin: Plugin {
					id: osm
					// THE CONNECTOR DEPENDS ON WHETHER THERE IS A MAP ON THE PHONE.
					//
					// 'osm' draws images fetched from the internet: it is what you see
					// while nothing has been downloaded, and out of coverage only
					// what was in its cache remains -- measured, 9 MB.
					//
					// 'maplibre' draws from the vector tiles that
					// our own server serves, so it works the same with
					// and without network. It is chosen as soon as there is a downloaded tile.
					//
					// The change forces the whole map to be rebuilt, and it already does: the
					// map lives in a Loader that is recreated on a theme change, and
					// this hooks into the same mechanism.
					name: root.dibujoLocal ? "maplibre" : "osm"

					// We ask our server for the style, which reads it from
					// disk and rewrites its URLs to point at itself. It carries
					// the theme inside: there is a light one and a dark one, and they are different
					// files, not the same one with other colours.
					PluginParameter {
						name: "maplibre.map.styles"
						value: "http://127.0.0.1:8554/mapa/estilo?tema="
							+ (root.esNoche ? "dark" : "light")
					}

				// WE DESCRIBE THE PROVIDER OURSELVES, in our own JSON.
				//
				// 'osm.mapping.custom.host' does NOT work: it is ignored. Measured
				// by pointing it at 127.0.0.1:1 -- where there is nothing -- with the cache
				// cleared, and the map kept drawing just the same with the
				// OpenStreetMap tiles. If it were used, the screen would have gone
				// grey. Before that, each ruled out with its own measurement: the
				// cache, recreating the map, recreating the connector and choosing the
				// "custom" type.
				//
				// What the connector DOES respect is its provider
				// repository: it requests '<address>/street' and expects a JSON with the
				// tile URL template. It is given one of ours via
				// 'file://', so there is no need to bring up any server or
				// depend on maps-redirect.qt.io -- which is the other reason
				// the whole repository used to be disabled.
				//
				// There are two folders, 'light' and 'dark'. Since this too is
				// fixed when the connector is created, the map lives in a Loader that
				// rebuilds it on a theme change.
				PluginParameter {
					name: "osm.mapping.providersrepository.address"
					value: "file:///usr/share/poconav/providers/"
						+ (root.esNoche ? "dark" : "light")
				}

				// THE TILES ARE THE ONLY PIECE THAT CANNOT GO WITHOUT NETWORK, and it is worth
				// saying why instead of leaving it as an unexplained shortcoming.
				//
				// Routes and searches do go without network: the data is downloaded and
				// resolved here. With the map drawing the same cannot be done,
				// because it would need a rasterizer -- mapnik or libosmscout -- and Alpine
				// packages none for this device. Verified with 'ldd' on the
				// only candidate there was: it links not a single one.
				//
				// What can be done is not requesting again what has already been seen. A gigabyte of
				// disk cache more than covers the roads of a whole region at
				// the zoom levels one drives at, so a journey already
				// made once draws without coverage. By default Qt stores much
				// less and throws it away quickly.
				PluginParameter {
					name: "osm.mapping.cache.disk.size"
					value: 1073741824
				}
				PluginParameter {
					name: "osm.mapping.cache.disk.cost_strategy"
					value: "bytesize"
				}
				// The OSM tile policy requires an identifiable User-Agent, and the
				// generic Qt one gets rate-limited.
				PluginParameter {
					name: "osm.useragent"
					value: "PocoNav/1.0 (postmarketOS; personal use)"
				}
				// MEASURED: with the default (two neighbouring zoom levels prefetched)
				// a single pan asks tile.openstreetmap.org for hundreds of tiles at
				// once over one HTTP/2 connection, and the server answers
				// ENHANCE_YOUR_CALM -- "excessive load detected" -- and drops the lot.
				// The map then stays grey. Fetching only what is on screen keeps us
				// inside the tile usage policy, which is a condition of using the
				// public servers at all, not a performance tweak.
				PluginParameter {
					name: "osm.mapping.prefetching_style"
					value: "NoPrefetching"
				}
				}
				minimumZoomLevel: 3
				maximumZoomLevel: 19
				// Qt's own attribution widget is empty for a custom tile host: it
				// draws a blank white band across the bottom of the map and no
				// text at all. Since attribution is a condition of using the OSM
				// tiles, it is drawn by hand below instead.
				copyrightsVisible: false

				center: QtPositioning.coordinate(memoria.lat, memoria.lon)
				zoomLevel: memoria.zoom

				// Following ALREADY comes interpolated from 'posSuave', so here
				// it is not smoothed again: chaining two animations over the same
				// movement only adds lag and brings back the jerk just
				// removed. This is left only for deliberate jumps -- the
				// centre button -- and never while you drag, or every gesture would fight
				// an animation.
				Behavior on center {
					enabled: !root.seguir && !arrastre.active
					CoordinateAnimation {
						duration: 300
						easing.type: Easing.InOutQuad
					}
				}

				// Heading up while driving, north up the rest of the time. Turning
				// the map is the difference between reading a junction and
				// decoding it.
				// Three sources, in order of how much they can be trusted while
				// moving: the course over ground, then the compass, then north.
				// WHILE DRIVING, the course over ground -- and the last good one
				// while stopped, instead of returning to north.
				Binding {
					target: mapa
					property: "bearing"
					value: (root.enMarcha && root.rumboValido)
						? root.rumboFuente : root.rumboRetenido
					when: root.modo === "conducir" && root.seguir
					restoreMode: Binding.RestoreNone
				}

				Binding {
					target: mapa
					property: "bearing"
					value: root.rumboSuave
					when: root.orientarPorSensor
						&& root.modo !== "conducir"
						&& root.modo !== "planificar"
					restoreMode: Binding.RestoreNone
				}

				// NORTH UP WHILE CHOOSING A ROUTE, and BOUND, not set once.
				//
				// Setting it on entry is not enough: the compass has its own binding and
				// the two-finger gesture also turns, so the map drifted off as
				// soon as you touched anything. Comparing three routes with the map turned
				// forces you to reorient before you can read them, and on a map of
				// the whole region "up is north" is the only thing that orients you.
				Binding {
					target: mapa
					property: "bearing"
					value: 0
					when: root.modo === "planificar"
					restoreMode: Binding.RestoreNone
				}

				// 3D is just the camera leaning over. 50 degrees is as far as it
				// can go before the horizon eats half the screen and the streets
				// near the top become unreadable.
				tilt: memoria.tresD ? 50 : 0

				Behavior on tilt {
					NumberAnimation {
						duration: 400
						easing.type: Easing.InOutQuad
					}
				}

				// Before it only animated while driving, and that is why the compass on the initial
				// screen was jerky: the sensor value came in raw and the map
				// teleported from one reading to the next.
				//
				// Two durations because they are two different things: the course over
				// ground changes slowly and appreciates half a second; the hand turning
				// the phone wants an immediate response, and 160 ms is just enough for
				// the eye to read it as movement and not as a jump.
				Behavior on bearing {
					// Almost always: it also has to animate the return to north
					// when the compass is turned OFF, and at that instant
					// orientarPorSensor is already false.
					//
					// But NOT while you turn with your fingers. There each delta of the
					// gesture would start its own animation and the map would feel
					// rubbery, chasing the hand instead of following it.
					enabled: !pellizco.active
					RotationAnimation {
						duration: (root.orientarPorSensor && root.modo !== "conducir")
							? 160 : 500
						direction: RotationAnimation.Shortest
						easing.type: Easing.OutQuad
					}
				}

				// --- the route ------------------------------------------------
				// Two lines, not one: a dark casing under a bright core. A single
				// coloured line vanishes over a motorway of the same width, over
				// the sea, and over a park.
				MapPolyline {
					visible: ruta.hay
					path: ruta.puntos
					line.width: 14
					line.color: root.p.azulCasco
				}

				MapPolyline {
					visible: ruta.hay
					path: ruta.puntos
					line.width: 9
					line.color: root.p.azulClaro
				}

				MapQuickItem {
					visible: ruta.destino !== null
					coordinate: ruta.destino ? ruta.destino
						: QtPositioning.coordinate(0, 0)
					anchorPoint.x: bandera.width / 2
					anchorPoint.y: bandera.height
					sourceItem: Kirigami.Icon {
						id: bandera
						source: "flag-red"
						width: Kirigami.Units.iconSizes.large
						height: width
					}
				}

				// How wrong the dot may be. Declared before the dot so it sits
				// underneath it. Hidden while driving: there it is just clutter
				// around the only thing you care about.
				MapCircle {
					visible: root.hayPosicion && root.precision > 0 && !root.porRed
						&& root.modo !== "conducir"
					center: root.posSuave
					radius: root.precision
					color: Qt.rgba(0.26, 0.52, 0.96, 0.16)
					border.color: Qt.rgba(0.26, 0.52, 0.96, 0.40)
					border.width: 1
				}

				MapQuickItem {
					visible: root.hayPosicion
					coordinate: root.posSuave
					anchorPoint.x: yo.width / 2
					anchorPoint.y: yo.height / 2
					sourceItem: Item {
						id: yo
						width: Kirigami.Units.gridUnit * 1.9
						height: width

						// Standing still it is a dot; moving it is the blue
						// arrowhead with a white outline that everyone recognises
						// from a phone on a dashboard. With the map itself rotated,
						// the arrow has to be corrected by the map bearing or it
						// lies about the direction.
						Rectangle {
							anchors.centerIn: parent
							visible: !root.enMarcha
							width: parent.width * 0.62
							height: width
							radius: width / 2
							// Blue when it is the GPS, amber when it is the network
							// guessing: the colour is the warning, not a footnote.
							color: root.porRed ? root.p.ambar : root.p.azulClaro
							border.color: root.p.blanco
							border.width: Math.max(2, width / 6)
						}

						Canvas {
							id: puntaYo
							anchors.fill: parent
							visible: root.enMarcha
							rotation: (root.rumboValido ? root.rumboFuente : 0)
								- mapa.bearing
							onPaint: {
								const ctx = getContext("2d")
								ctx.reset()
								const w = width, h = height
								ctx.beginPath()
								ctx.moveTo(w * 0.50, h * 0.08)
								ctx.lineTo(w * 0.90, h * 0.92)
								ctx.lineTo(w * 0.50, h * 0.70)
								ctx.lineTo(w * 0.10, h * 0.92)
								ctx.closePath()
								ctx.fillStyle = root.porRed ? root.p.ambar : root.p.azulClaro
								ctx.strokeStyle = root.p.blanco
								ctx.lineWidth = w * 0.10
								ctx.lineJoin = "round"
								ctx.fill()
								ctx.stroke()
							}
							// A Canvas does not repaint because a colour it read
							// changed, so the one colour that can change is
							// watched by hand.
							property bool aviso: root.porRed
							onAvisoChanged: requestPaint()
							Component.onCompleted: requestPaint()
						}
					}
				}

				PinchHandler {
					id: pellizco
					target: null
					property var anclaje
					grabPermissions: PointerHandler.TakeOverForbidden
					onActiveChanged: {
						if (active)
							anclaje = mapa.toCoordinate(pellizco.centroid.position,
								false)
					}
					onScaleChanged: (delta) => {
						mapa.zoomLevel += Math.log2(delta)
						mapa.alignCoordinateToPoint(anclaje,
							pellizco.centroid.position)
					}

					// Turn the map with two fingers, like on any map.
					// Only when the heading is free: with the compass on or with
					// the car moving there is a binding in charge, and the gesture
					// undoes itself on the next frame.
					//
					// The rotation is anchored to the point between the fingers, like the zoom:
					// this way the map turns around what you are looking at and not
					// around the centre of the screen.
					onRotationChanged: (delta) => {
						if (!root.rumboLibre)
							return
						mapa.bearing -= delta
						mapa.alignCoordinateToPoint(anclaje,
							pellizco.centroid.position)
					}
				}

				DragHandler {
					id: arrastre
					target: null
					onTranslationChanged: (delta) => mapa.pan(-delta.x, -delta.y)
					onActiveChanged: {
						if (active)
							root.seguir = false
					}
				}

				// Hold anywhere to route there: the fastest way to set a
				// destination you can see but cannot name. Disabled while driving,
				// where a long press is far more likely to be a hand steadying the
				// phone than a decision.
				TapHandler {
					enabled: root.modo !== "conducir"
					longPressThreshold: 0.6
					onLongPressed: root.pedirRuta(mapa.toCoordinate(point.position),
						"point on the map")
				}

				// Costs one line and makes the whole thing usable on a desktop,
				// which is where it gets debugged.
				WheelHandler {
					property: "zoomLevel"
					rotationScale: 1 / 120
				}
			}
		}

		// --- what is actually going on ---------------------------------------
		// The complaint that started this program: a map draws a dot and never
		// says whether that dot is a satellite fix, a WiFi guess or your IP
		// address. Here it always says, and it says it in metres. While driving
		// it says nothing, because there the screen belongs to the next turn.
		Rectangle {
			id: aviso

			// ONLY when there is bad news: no fix, network position, or
			// location denied. With a good GPS it says nothing -- that
			// everything is fine is not news, and a permanent sign in the middle
			// of the map ends up being noise you stop reading.
			visible: root.modo !== "conducir"
				&& (!root.hayPosicion || root.porRed
					|| gps.sourceError !== PositionSource.NoError)
			// Top right, not centred: in the centre it covered exactly what
			// you are looking at, and in the preview it ate the destination
			// flag.
			anchors.right: zonaMapa.right
			anchors.top: zonaMapa.top
			anchors.rightMargin: root.borde
			// Plasma Mobile floats its status bar over the top of every window.
			anchors.topMargin: Kirigami.Units.gridUnit * 2
			width: Math.min(zonaMapa.width - root.borde * 2,
				texto.implicitWidth + Kirigami.Units.gridUnit * 2)
			height: texto.implicitHeight + root.borde
			radius: height / 2
			color: root.p.fondo

			ColumnLayout {
				id: texto
				anchors.centerIn: parent
				spacing: 0

				QQC2.Label {
					Layout.alignment: Qt.AlignHCenter
					text: root.estado
					font.bold: true
					color: root.porRed ? root.p.ambar : root.p.tinta
				}

				QQC2.Label {
					Layout.alignment: Qt.AlignHCenter
					visible: text.length > 0
					text: root.detalle
					font.pointSize: Kirigami.Theme.smallFont.pointSize
					color: root.p.tintaSuave
				}
			}
		}

		// --- asking for a route ----------------------------------------------
		// The white search pill, straight off the phone everyone already has.
		QQC2.AbstractButton {
			id: botonBuscar

			visible: root.modo === "explorar"
			anchors.left: zonaMapa.left
			anchors.bottom: zonaMapa.bottom
			anchors.leftMargin: root.borde
			anchors.bottomMargin: root.borde + Kirigami.Units.gridUnit
			height: Kirigami.Units.gridUnit * 3.4
			width: Math.min(zonaMapa.width * 0.6, Kirigami.Units.gridUnit * 20)
			enabled: ruta.estado !== "pidiendo"
			onClicked: buscador.abrir()

			background: Rectangle {
				radius: height / 2
				color: botonBuscar.pressed ? "#e8eaed" : root.p.blanco
			}

			contentItem: RowLayout {
				spacing: Kirigami.Units.largeSpacing

				Kirigami.Icon {
					Layout.leftMargin: Kirigami.Units.largeSpacing
					Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
					Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
					source: "search"
					isMask: true
					color: root.p.tintaSuave
				}

				QQC2.Label {
					Layout.fillWidth: true
					text: ruta.estado === "pidiendo" ? qsTr("Calculating…") : qsTr("Where to?")
					color: root.p.tintaOscura
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.2
					elide: Text.ElideRight
				}
			}
		}

		// A route that fails has to say so where you are already looking, not
		// in a log nobody is going to read from a car.
		Rectangle {
			visible: ruta.estado === "error"
			anchors.centerIn: zonaMapa
			width: Math.min(zonaMapa.width * 0.8, falloTexto.implicitWidth
				+ Kirigami.Units.gridUnit * 3)
			height: falloTexto.implicitHeight + Kirigami.Units.gridUnit * 2
			radius: root.p.radio
			color: root.p.fondo

			QQC2.Label {
				id: falloTexto
				anchors.centerIn: parent
				width: parent.width - Kirigami.Units.gridUnit * 2
				text: qsTr("No route: %1").arg(ruta.fallo)
				color: root.p.ambar
				horizontalAlignment: Text.AlignHCenter
				wrapMode: Text.WordWrap
			}

			TapHandler { onTapped: ruta.limpiar() }
		}

		// THE MAP OF WHERE YOU ARE GOING, offered where the journey is decided.
		//
		// Until now you could only download the tile UNDER THE PHONE, which is
		// the one you least need: you are already there. What you need before
		// setting off is the one for the places you will pass through, and that is only known
		// with the route calculated -- that is why this is the place and not the settings.
		//
		// It only appears if one really is missing. A button that is almost always there
		// and almost never needed ends up pressed without being read.
		Rectangle {
			id: bajarRuta
			visible: root.modo === "vista" && root.cuadrosQueFaltan.length > 0
				&& !app.trabajando && app.hayRed
			anchors.left: previa.left
			anchors.right: previa.right
			anchors.bottom: previa.top
			anchors.bottomMargin: Kirigami.Units.smallSpacing
			height: Kirigami.Units.gridUnit * 3
            radius: root.p.radioGrande
			color: pulsar.pressed ? root.p.fondoAlto : root.p.fondo
			border.color: root.p.ambar
			border.width: 1

			TapHandler {
				id: pulsar
				gesturePolicy: TapHandler.DragThreshold
				onTapped: app.bajarDibujoCuadros(panelAjustes.region || "europe/spain",
					root.cuadrosQueFaltan)
			}

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: Kirigami.Units.largeSpacing
				anchors.rightMargin: Kirigami.Units.largeSpacing
				spacing: Kirigami.Units.largeSpacing

				Kirigami.Icon {
					source: "download"
					isMask: true
					color: root.p.ambar
					Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
					Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
				}
				QQC2.Label {
					Layout.fillWidth: true
					color: root.p.tinta
					elide: Text.ElideRight
					// THE SIZE IS STATED, not hidden. It is about 130 MB per
					// tile -- measured: 113 MB for Valencia, 112 for Murcia
					// -- and that is decided very differently on wifi than on data.
					//
					// It says "about" because it is an estimate per tile and not
					// a query to the server: asking it the exact size of
					// each would be several requests before a button could be
					// drawn, and the order of magnitude is enough to decide.
					text: root.cuadrosQueFaltan.length === 1
						? qsTr("Download the map for this route · about 130 MB")
						: qsTr("Download the map for this route · %1 areas, about %2 MB")
							.arg(root.cuadrosQueFaltan.length)
							.arg(root.cuadrosQueFaltan.length * 130)
				}
			}
		}

		// --- the route, before committing to it ------------------------------
		Rectangle {
			id: previa

			visible: root.modo === "vista"
			anchors.left: zonaMapa.left
			anchors.right: zonaMapa.right
			anchors.bottom: zonaMapa.bottom
			anchors.margins: root.borde
			height: Kirigami.Units.gridUnit * 5.4
			radius: root.p.radioGrande
			color: root.p.fondo

			RowLayout {
				anchors.fill: parent
				anchors.margins: Kirigami.Units.largeSpacing
				spacing: Kirigami.Units.largeSpacing

				ColumnLayout {
					Layout.fillWidth: true
					Layout.leftMargin: Kirigami.Units.smallSpacing
					spacing: 0

					// Time in green and first: it is the number you decide with.
					QQC2.Label {
						Layout.fillWidth: true
						text: panelConducir.duracion(ruta.segundosTotal)
						color: root.p.verde
						font.bold: true
						font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.8
					}

					QQC2.Label {
						Layout.fillWidth: true
						text: panelConducir.distancia(ruta.metrosTotal)
							+ (ruta.nombreDestino ? "  ·  " + ruta.nombreDestino : "")
						color: root.p.tintaSuave
						elide: Text.ElideRight
					}
				}

				// The place you long-pressed on the map has no name and no
				// other way of being kept, and that is exactly the kind of
				// place worth keeping.
				QQC2.AbstractButton {
					id: botonGuardar
					Layout.preferredHeight: Kirigami.Units.gridUnit * 3.4
					Layout.preferredWidth: Kirigami.Units.gridUnit * 3.4
					enabled: ruta.destino !== null
					onClicked: buscador.guardar(ruta.nombreDestino || "destination",
						ruta.destino.latitude, ruta.destino.longitude)
					background: Rectangle {
						radius: height / 2
						color: botonGuardar.pressed ? root.p.tintaSuave : root.p.fondoAlto
					}
					contentItem: Kirigami.Icon {
						source: "bookmark-new"
						isMask: true
						color: root.p.tinta
					}
				}

				QQC2.AbstractButton {
					id: botonQuitar
					Layout.preferredHeight: Kirigami.Units.gridUnit * 3.4
					Layout.preferredWidth: Kirigami.Units.gridUnit * 3.4
					onClicked: root.terminar()
					background: Rectangle {
						radius: height / 2
						color: botonQuitar.pressed ? root.p.tintaSuave : root.p.fondoAlto
					}
					contentItem: Kirigami.Icon {
						source: "dialog-close"
						isMask: true
						color: root.p.tinta
					}
				}

				// The blue pill: the one thing on this bar you are meant to
				// press, so it is the only coloured thing on it.
				QQC2.AbstractButton {
					id: botonEmpezar
					Layout.preferredHeight: Kirigami.Units.gridUnit * 3.4
					Layout.preferredWidth: Kirigami.Units.gridUnit * 8.5
					onClicked: root.conducir()

					background: Rectangle {
						radius: height / 2
						color: botonEmpezar.pressed ? root.p.azulCasco : root.p.azul
					}

					contentItem: RowLayout {
						spacing: Kirigami.Units.smallSpacing
						Item { Layout.fillWidth: true }
						Kirigami.Icon {
							Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
							Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
							source: "gps"
							isMask: true
							color: root.p.blanco
						}
						QQC2.Label {
							text: qsTr("Start")
							color: root.p.blanco
							font.bold: true
							font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.15
						}
						Item { Layout.fillWidth: true }
					}
				}
			}
		}

		// Using the public OSM tiles obliges us to credit them. Small, but
		// legible and never covered by anything -- which is why it climbs above
		// the preview bar instead of hiding behind it. Attribution is a
		// condition of the licence, not a decoration to drop when it is in the
		// way.
		QQC2.Label {
			anchors.left: zonaMapa.left
			anchors.bottom: root.modo === "vista" ? previa.top : zonaMapa.bottom
			anchors.leftMargin: root.borde
			anchors.bottomMargin: Kirigami.Units.smallSpacing
			// CARTO asks for its credit in addition to OSM's when its tiles are used.
			// It is a condition of use, not a courtesy.
			text: root.esNoche ? "© OpenStreetMap © CARTO" : "© OpenStreetMap"
			font.pointSize: Kirigami.Theme.smallFont.pointSize
			color: root.p.blanco
			opacity: 0.9
			background: Rectangle {
				color: root.p.fondo
				opacity: 0.7
				radius: 4
			}
			leftPadding: 4
			rightPadding: 4
		}

		// --- the controls -----------------------------------------------------
		ColumnLayout {
			id: botonera
			anchors.right: zonaMapa.right
			anchors.bottom: zonaMapa.bottom
			anchors.rightMargin: root.borde
			// Clear of the search pill, the attribution and the gesture bar.
			anchors.bottomMargin: root.modo === "vista"
				? previa.height + root.borde * 2 : root.borde
			// A fat finger and a bump: packed together you miss them.
			spacing: root.hueco

			// While driving these step back a little -- but only a little: at
			// 0.55 the blue of the follow button washed out to nothing and it
			// stopped reading as a button at all.
			opacity: root.modo === "conducir" ? 0.85 : 1

			// North up, or the map turning with the phone. Only on the
			// initial screen: while driving the course over ground is in charge.
			// The only voice control, and within reach while driving too: silencing it
			// is exactly what you want to be able to do without thinking.
			BotonMapa {
				icono: memoria.voz ? "audio-volume-high" : "audio-volume-muted"
				azulado: memoria.voz
				onClicked: {
					memoria.voz = !memoria.voz
					// When silencing it, SILENCE it: stopping sending phrases does not stop the
					// one already out, and pressing the speaker to shut it up and have it
					// keep talking is exactly the opposite of what you are asking for.
					if (!memoria.voz)
						voz.silenciar()
				}
			}

			BotonMapa {
				visible: root.modo === "explorar"
				icono: "compass"
				azulado: root.orientarPorSensor
				// Off, and visibly off, until the phone actually has the
				// sensor. A toggle that silently does nothing is worse than
				// one that admits it cannot.
				enabled: root.sensorDisponible
				onClicked: memoria.orientacion =
					(memoria.orientacion === "sensor" ? "norte" : "sensor")
			}

			BotonMapa {
				visible: root.modo === "explorar"
				texto: memoria.tresD ? "2D" : "3D"
				azulado: memoria.tresD
				onClicked: memoria.tresD = !memoria.tresD
			}

			// Only on the initial screen: choosing a voice or downloading a region is not
			// something you do with the car moving, and an extra button there
			// is a button pressed by accident.
			BotonMapa {
				visible: root.modo === "explorar"
				icono: "configure"
				onClicked: panelAjustes.abrir()
			}

			BotonMapa {
				// Hidden in landscape: there is only 540 px of height there and six
				// stacked buttons eat the whole side. The pinch
				// does the same, and while driving the zoom sets itself.
				visible: root.modo !== "conducir" && !root.apaisado
				icono: "zoom-in"
				onClicked: zonaMapa.item.zoomLevel = Math.min(zonaMapa.item.maximumZoomLevel,
					Math.round(zonaMapa.item.zoomLevel) + 1)
			}

			BotonMapa {
				visible: root.modo !== "conducir" && !root.apaisado
				icono: "zoom-out"
				onClicked: zonaMapa.item.zoomLevel = Math.max(zonaMapa.item.minimumZoomLevel,
					Math.round(zonaMapa.item.zoomLevel) - 1)
			}

			BotonMapa {
				// Filled blue while the map is glued to you, white while it is
				// not, so the mode is readable without reading anything.
				icono: root.seguir ? "gps" : "crosshairs"
				azulado: root.seguir
				enabled: root.hayPosicion
				// The one control that still has to be easy to hit while
				// driving, so it is the biggest.
				lado: Kirigami.Units.gridUnit * 4
				onClicked: {
					root.seguir = true
					if (root.modo === "conducir") {
						zonaMapa.item.zoomLevel = 17
						zonaMapa.item.alignCoordinateToPoint(root.coord,
							Qt.point(zonaMapa.width / 2, zonaMapa.height * root.anclaY))
					} else {
						zonaMapa.item.center = root.coord
						if (zonaMapa.item.zoomLevel < 15)
							zonaMapa.item.zoomLevel = 16
					}
				}
			}
		}

		DestinationSearch {
			id: buscador
			millas: root.millas
			cerca: root.hayPosicion ? root.coord : null
			hayLocal: ruta.hayLocal
			favoritosJson: memoria.favoritos
			evitarPeajes: memoria.evitarPeajes
			evitarAutopistas: memoria.evitarAutopistas
			onElegido: (coordenada, nombre) => root.pedirRuta(coordenada, nombre)
			onFavoritosCambiados: (json) => memoria.favoritos = json
			onAlternarPeajes: memoria.evitarPeajes = !memoria.evitarPeajes
			onAlternarAutopistas: memoria.evitarAutopistas = !memoria.evitarAutopistas
			evitarFerris: memoria.evitarFerris
			evitarTierra: memoria.evitarTierra
			onAlternarFerris: memoria.evitarFerris = !memoria.evitarFerris
			onAlternarTierra: memoria.evitarTierra = !memoria.evitarTierra
		}

		// Only exists with --retratos. Without that option, it is not even created.
		Loader {
			active: retratosEn !== ""
			sourceComponent: Portraits {
				ventana: root
				carpeta: retratosEn
				Component.onCompleted: arrancar()
			}
		}

		FilterWarning {
			id: avisoFiltro
			onAceptado: (entrada) => root.aceptarRuta(entrada)
			// Cancel does nothing else: it stays in the list, with the route
			// being looked at still drawn on the zonaMapa.item.
			onCancelado: {}
		}

		Settings {
			id: panelAjustes
			region: memoria.region
			onRegionChanged: memoria.region = region
			tema: memoria.tema
			unidades: memoria.unidades
			esNoche: root.esNoche
			millas: root.millas
			// Where the phone is, so the settings can download the map of
			// AROUND HERE -- a 132 MB tile -- instead of the whole region, which
			// in Spain is 1.9 GB. Without a position they are 0 and it falls back to the
			// previous behaviour.
			miLat: root.coord ? root.coord.latitude : 0
			miLon: root.coord ? root.coord.longitude : 0
			onPonerTema: (cual) => memoria.tema = cual
			onPonerUnidades: (cual) => memoria.unidades = cual
		}

		// When a download finishes it has to ask again: a freshly
		// downloaded region makes routing local, and without this it would keep requesting it
		// over the network until the next startup.
		Connections {
			target: app
			function onTerminado(ok, mensaje) {
				if (ok)
					ruta.sondearLocal()
			}
		}
	}
}
