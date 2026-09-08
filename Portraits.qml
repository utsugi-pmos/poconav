// SPDX-License-Identifier: LGPL-2.0-or-later
//
// `poconav --retratos <folder>`: the application photographs itself.
//
// WHY, instead of a normal screenshot
// -------------------------------------------------
// Because the compositor's capture depends on the phone being in front, with the
// screen on and the session unlocked. With the session locked KWin
// returns a BLANK image on purpose, which is exactly what
// was happening to me: 10 kB captures, all identical, without a single clue.
//
// This needs none of that. It starts with QT_QPA_PLATFORM=offscreen, is
// painted in memory and saved with grabToImage. No screen is needed, nor for
// anyone to unlock, nor even for the phone to be at hand.
//
// And above all: it can portray screens that are hard to reproduce by hand --
// driving a specific route, with the route panel open, in both
// orientations -- and always the same ones, which is what is needed to compare
// a margin change with what came before.
//
// THE CANVAS. `root.lienzo` is photographed and not the window: the contentItem of a
// window is built by C++ and grabToImage rejects it with "item has no QML
// engine". That is why everything visible hangs off an Item made in QML.
import QtQuick
import QtPositioning

QtObject {
	id: retratos

	property var ventana: null
	property string carpeta: ""

	property int _paso: 0
	property var _cola: []

	// A place with a roundabout and a motorway exit nearby, so the
	// maneuvers portrayed are the interesting ones.
	readonly property var desde: QtPositioning.coordinate(37.5875, -1.2531)
	readonly property var hasta: QtPositioning.coordinate(37.9917, -1.1305)
	// Cartagena -> Vera takes the AP-7 with a toll; Bolnuevo -> Murcia has
	// none, so with that one there would be nothing to warn about.
	readonly property var peajeDesde: QtPositioning.coordinate(37.6155, -0.9875)
	readonly property var peajeHasta: QtPositioning.coordinate(37.2410, -1.8630)

	function arrancar() {
		// Each entry: the file name, whether it is landscape, and what to prepare.
		_cola = [
			{ f: "01-inicio-apaisado",      ancho: 1200, alto: 540,  prep: "explorar" },
			{ f: "02-inicio-vertical",      ancho: 540,  alto: 1200, prep: "explorar" },
			{ f: "03-buscar-apaisado",      ancho: 1200, alto: 540,  prep: "buscar" },
			{ f: "04-buscar-vertical",      ancho: 540,  alto: 1200, prep: "buscar" },
			{ f: "04b-resultados-vertical", ancho: 540,  alto: 1200, prep: "resultados" },
			{ f: "05-ajustes-apaisado",     ancho: 1200, alto: 540,  prep: "ajustes" },
			{ f: "06-ajustes-vertical",     ancho: 540,  alto: 1200, prep: "ajustes" },
			{ f: "07-rutas-apaisado",       ancho: 1200, alto: 540,  prep: "rutas" },
			{ f: "08-rutas-vertical",       ancho: 540,  alto: 1200, prep: "rutas" },
			// THE OVERFLOWED LIST, which is the scroll indicator case.
			//
			// With three routes and a normal screen, the whole list fits and the
			// indicator does not show -- correct, but then there is no way to
			// check that it shows when it should. This screen is deliberately
			// SHORT to force the overflow with the same three routes.
			//
			// It is not a made-up size: 540x400 is what is left in landscape
			// with the keyboard open, which is a real situation.
			{ f: "08b-rutas-desbordada",    ancho: 540,  alto: 400,  prep: "rutas" },
			{ f: "09-aviso-apaisado",       ancho: 1200, alto: 540,  prep: "aviso" },
			{ f: "10-conducir-apaisado",    ancho: 1200, alto: 540,  prep: "conducir" },
			{ f: "11-conducir-vertical",    ancho: 540,  alto: 1200, prep: "conducir" }
		]
		_paso = 0
		_siguiente()
	}

	function _siguiente() {
		if (_paso >= _cola.length) {
			console.log("retratos: " + _cola.length + " in " + carpeta)
			Qt.exit(0)
			return
		}
		const e = _cola[_paso]
		ventana.width = e.ancho
		ventana.height = e.alto
		// The state is set again right before firing, not only here: on
		// opening, the application restores the last route on its own and starts
		// driving, and that clobbered the first portrait -- the driving screen
		// came out where the initial one should have.
		retratos._preparar(e.prep)
		// Two waits: one for the layout to be redone after changing the size
		// and another for whatever was requested over the network to arrive. Without the first
		// portraits come out with the previous orientation half-applied.
		esperaCorta.restart()
	}

	readonly property Timer esperaCorta: Timer {
		interval: 700
		onTriggered: esperaLarga.restart()
	}

	readonly property Timer esperaLarga: Timer {
		interval: 2500
		onTriggered: retratos._disparar()
	}

	function _preparar(que) {
		const v = ventana
		if (que === "explorar") {
			v.cerrarTodo()
			v.modo = "explorar"
		} else if (que === "buscar") {
			v.cerrarTodo()
			v.modo = "explorar"
			v.abrirBuscador()
		} else if (que === "resultados") {
			v.cerrarTodo()
			v.modo = "explorar"
			v.buscarEnRetrato("cartagena")
			esperaLarga.interval = 4000
		} else if (que === "ajustes") {
			v.cerrarTodo()
			v.modo = "explorar"
			v.abrirAjustes()
		} else if (que === "rutas" || que === "aviso") {
			v.cerrarTodo()
			// With the toll filter on for the warning: it is the only way
			// for there to be a route that breaks a rule and the dialog to exist.
			v.ponerFiltroPeajes(que === "aviso")
			if (que === "aviso")
				v.planificarDesde(peajeDesde, peajeHasta, "Vera")
			else
				v.planificarDesde(desde, hasta, "Murcia")
			if (que === "aviso")
				esperaLarga.interval = 9000   // two requests, and over the network they are slow
		} else if (que === "conducir") {
			v.cerrarTodo()
			v.conducirPrueba(desde, hasta)
			// More wait: the route has to be computed, the car started and let
			// to travel a stretch so the photo has speed and a real
			// maneuver ahead.
			esperaLarga.interval = 12000
		}
	}

	function _disparar() {
		const e = _cola[_paso]
		if (e.prep === "explorar" || e.prep === "buscar" || e.prep === "ajustes")
			retratos._preparar(e.prep)
		if (e.prep === "aviso")
			ventana.mostrarAviso()

		// A frame is left so that whatever was just requested is drawn before
		// the photo.
		Qt.callLater(function () {
			ventana.lienzo.grabToImage(function (r) {
				r.saveToFile(retratos.carpeta + "/" + e.f + ".png")
				// What has actually been painted is measured, not what was requested:
				// with the 'offscreen' platform the size change is not
				// immediate and a portrait with the previous size misleads.
				console.log("  " + e.f + ".png  requested " + e.ancho + "x" + e.alto
					+ "  canvas " + ventana.lienzo.width + "x" + ventana.lienzo.height
					+ "  mode " + ventana.modo
					+ "  buttons y=" + ventana.medirBotonera())
				retratos._paso += 1
				esperaLarga.interval = 2500
				retratos._siguiente()
			})
		})
	}
}
