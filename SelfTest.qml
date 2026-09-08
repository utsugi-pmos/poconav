// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The self-test: `poconav --probar`.
//
// WHY IT EXISTS
// --------------
// Because I used to compute a route with Python against the server, saw "9.23 km" and took
// the piece for good. But the application does NOT ask the way I asked: it asks via
// `GET ?json=...`, which is Valhalla's documented form, and my server only
// understood POST. Result: 404 on every route.
//
// And worse: since the poll said the home server was ready, the
// application did not fall back to the network. A mistake of mine in the local server left the
// application with no routes by ANY path, and I did not see it because I tested the piece
// instead of the path.
//
// This loads the SAME Route.qml the application uses, against the SAME backend,
// and requests real routes. If the path breaks, it breaks here.
//
// It exits with a non-zero code if something fails, so it can be chained.
import QtQuick
import QtPositioning
import QtLocation
import QtSensors

Item {
	id: prueba

	// --- 0. who can DRAW the map --------------------------------------------
	//
	// It is checked before anything else because it conditions everything else. The 'osm' connector
	// only draws images fetched from the network: out of coverage, the map is left with
	// the cache of what was already visited -- measured on the phone, 9 MB, while the
	// routing data took 2.2 GB. That is: routes yes, map no.
	//
	// 'maplibre' draws from vector tiles, which CAN be held
	// on disk. Its appearing here is the condition for being able to have a map without
	// coverage; its not appearing is a fact, not a failure, because today the
	// application still works with 'osm'.
	// --- 0b. the COMPASS ----------------------------------------------------
	//
	// It decides whether the map can orient itself while stopped. Without it there is only
	// the course over ground, and that is no good below 10 km/h: you start the route
	// stationary and the map faces north.
	//
	// It is checked here because finding it out by hand is a minefield. I even
	// wrote in the code that this phone HAS NO compass, and I got it wrong TWICE
	// in a row when checking it: the sensors do not hang off any SoC bus
	// -- they go through the Snapdragon sensor core, via hexagonrpcd -- and on
	// the D-Bus bus the compass lives in ANOTHER interface, so a 'busctl
	// introspect' of the main object does not show it. 'monitor-sensor' does.
	Component {
		id: plantillaBrujula
		Compass { active: true }
	}

	function probarBrujula() {
		const b = plantillaBrujula.createObject(prueba)
		const hay = b.connectedToBackend
		b.destroy()
		if (hay)
			prueba.bien("compass available (the map orients while stopped)")
		else
			console.log("  info  no compass: the map will only orient while moving."
				+ " Check 'systemctl is-active hexagonrpcd-adsp-sensorspd'")
	}

	function probarConectores() {
		const hay = plantillaConectores.createObject(prueba)
		const lista = hay.availableServiceProviders
		hay.destroy()
		console.log("  info  map connectors: " + lista.join(", "))
		if (lista.indexOf("maplibre") >= 0)
			prueba.bien("maplibre available (offline map possible)")
		else
			console.log("  info  no 'maplibre': the map will still need network")
	}

	Component {
		id: plantillaConectores
		Plugin { name: "osm" }
	}

	// Bolnuevo -> Mazarron. Inside the region downloaded in the tests,
	// and with a roundabout, which is where the differences between routers show most.
	readonly property var desde: QtPositioning.coordinate(37.5875, -1.2531)
	readonly property var hasta: QtPositioning.coordinate(37.6257, -1.2107)

	property int fallos: 0
	property int pendientes: 0

	function bien(que) { console.log("  ok    " + que) }
	function mal(que, porque) {
		console.log("  FAIL  " + que + ": " + porque)
		prueba.fallos += 1
	}

	// --- 1. the backend is there ------------------------------------------
	function probarBackend() {
		console.log("backend:")
		if (typeof app === "undefined" || app === null) {
			mal("app exposed to QML", "it is null -- QML cannot talk to the backend")
			return
		}
		bien("app exposed to QML")
		bien("data in " + app.rutaDatos())
		console.log("  info  maps: " + (app.mapas.length ? app.mapas.join(", ") : "none"))
		console.log("  info  voices: " + (app.voces.length ? app.voces.join(", ") : "none"))
	}

	// --- 2. the own routing server ----------------------------------------
	//
	// We wait for it to come up. The backend starts it on construction and it takes a few
	// seconds to bind to the port; asking it on the first frame is
	// asking it before it exists. The test gave "status 0" and then went on
	// against the public server, that is it tested half without saying so.
	property int _intentos: 0

	function probarServidor(cuando) {
		const x = new XMLHttpRequest()
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			if (x.status === 0 && prueba._intentos < 20) {
				// 20 attempts of 1 s. More than enough to start, and if it
				// really is not there, it ends up being said.
				prueba._intentos += 1
				const t = Qt.createQmlObject(
					'import QtQuick; Timer { interval: 1000; running: true }', prueba)
				t.triggered.connect(function () {
					t.destroy()
					prueba.probarServidor(cuando)
				})
				return
			}
			prueba._mirarServidor(x, cuando)
		}
		x.open("GET", "http://127.0.0.1:8554/status")
		x.send()
	}

	function _mirarServidor(x, cuando) {
		if (x.status !== 200) {
			prueba.mal("the own server answers",
				"status " + x.status + " after " + prueba._intentos + " s")
			cuando(false)
			return
		}
		try {
			const r = JSON.parse(x.responseText)
			if (r.listo) {
				prueba.bien("the own server can route")
				console.log("  info  tiles: " + r.teselas)
			} else {
				console.log("  info  no downloaded maps (" + r.motivo + ")")
			}
			cuando(r.listo === true)
		} catch (e) {
			prueba.mal("the own server answers JSON", e)
			cuando(false)
		}
	}

	// --- 3. a route, the way the application asks for it -------------------
	// Route.qml is used as is, without copying its code: if one day the way it asks for
	// routes changes, this test changes with it.
	Component {
		id: plantillaRuta
		Route {}
	}

	function probarRuta(enCasa, cuando) {
		const r = plantillaRuta.createObject(prueba)
		r.hayLocal = enCasa
		const etiqueta = enCasa ? "route on the phone" : "route over the internet"

		// 45 s: the public server from this phone has taken 20 s at times,
		// and a false negative from haste would cost more than waiting.
		const reloj = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 45000; running: true }', prueba)

		function acabar(ok, porque) {
			reloj.stop()
			reloj.destroy()
			r.destroy()
			if (ok)
				prueba.bien(etiqueta)
			else
				prueba.mal(etiqueta, porque)
			cuando()
		}

		reloj.triggered.connect(function () { acabar(false, "did not answer in 45 s") })

		r.estadoChanged.connect(function () {
			if (r.estado === "lista") {
				// It answering is not enough: it has to bring a DRIVABLE route.
				// A 200 with zero points is a silent failure.
				if (r.puntos.length < 2) {
					acabar(false, "answered with no line")
					return
				}
				const km = (r.metrosTotal / 1000).toFixed(2)
				console.log("  info  " + etiqueta + ": " + km + " km, "
					+ r.maniobras.length + " maneuvers")
				if (r.maniobras.length)
					console.log("  info  first: " + r.maniobras[0].texto)
				acabar(true, "")
			} else if (r.estado === "error") {
				acabar(false, r.fallo)
			}
		})

		r.calcular(prueba.desde, prueba.hasta, "prueba")
	}

	// --- 4. plan: several routes, and knowing which breaks a rule ----------
	Component {
		id: plantillaPlan
		Planner {}
	}

	// Cartagena -> Vera. Chosen on purpose: via the AP-7 there is a toll and inland
	// there is not, so with "avoid tolls" on there MUST be more than one option and
	// the toll one has to end up marked. If the planner stopped
	// distinguishing them, this test falls over.
	readonly property var pDesde: QtPositioning.coordinate(37.6155, -0.9875)
	readonly property var pHasta: QtPositioning.coordinate(37.2410, -1.8630)

	function probarPlan(enCasa, cuando) {
		const pl = plantillaPlan.createObject(prueba)
		pl.hayLocal = enCasa
        // With the filter on: it is the only thing that makes the test interesting.
		pl.evitarPeajes = true

		const reloj = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 90000; running: true }', prueba)

		function acabar(ok, porque) {
			reloj.stop(); reloj.destroy(); pl.destroy()
			if (ok) prueba.bien("plan (avoiding tolls)")
			else prueba.mal("plan (avoiding tolls)", porque)
			cuando()
		}
		reloj.triggered.connect(function () { acabar(false, "did not answer in 90 s") })

		pl.estadoChanged.connect(function () {
			if (pl.estado === "error") { acabar(false, pl.fallo); return }
			if (pl.estado !== "listo")
				return

			if (pl.rutas.length < 2) {
				acabar(false, "only returned " + pl.rutas.length + " route(s); "
					+ "with toll and without toll there should be several")
				return
			}
			for (var i = 0; i < pl.rutas.length; ++i) {
				const r = pl.rutas[i]
				console.log("  info  #" + i + "  " + (r.metros / 1000).toFixed(1)
					+ " km, " + r.minutos + " min, "
					+ (r.cumple ? "complies" : "breaks: " + r.aviso.join("+"))
					+ (r.resumen ? "  " + r.resumen : ""))
			}
			// What is really being checked:
			if (!pl.rutas[0].cumple) {
				acabar(false, "the first does NOT respect the filter")
				return
			}
			// Sorted by time among the ones that comply.
			for (var j = 1; j < pl.rutas.length; ++j) {
				if (pl.rutas[j].cumple && !pl.rutas[j - 1].cumple) {
					acabar(false, "one that complies comes after one that does not")
					return
				}
			}
			var conAviso = 0
			for (var k = 0; k < pl.rutas.length; ++k)
				if (!pl.rutas[k].cumple) conAviso += 1
			if (conAviso === 0) {
				acabar(false, "no toll alternative; there should be one")
				return
			}
			// And that the chosen one can really be driven.
			const r2 = plantillaRuta.createObject(prueba)
			r2.adoptar(pl.rutas[0].trip, prueba.pHasta, "prueba")
			const vale = r2.puntos.length > 1 && r2.maniobras.length > 0
			r2.destroy()
			if (!vale) {
				acabar(false, "adoptar() did not leave a usable route")
				return
			}
			prueba.bien("adopt the chosen route")
			acabar(true, "")
		})

		pl.planificar(prueba.pDesde, prueba.pHasta, "Vera")
	}

	// --- 4b. a destination OUTSIDE the downloaded maps ---------------------
	//
	// The rule is "no coverage whenever possible, network when there is no other
	// thing". The first half is checked by the tests above. This one checks
	// the SECOND, which nobody was looking at -- and that is why it was broken: the
	// planner gave up as soon as the home server answered badly, so
	// with the maps in place it NEVER used the internet, not even as the only path.
	//
	// Murcia -> Paris with Spain and Andorra downloaded: the home server
	// responds 400 "No suitable edges near location" in 15 ms.
	//
	// The expected result DEPENDS on whether there is network, and both answers are
	// correct -- what is not acceptable is hanging or lying:
	//   with network  a route must come out, and it must have been given by the internet
	//   no network    it must say it cannot, not keep thinking
	readonly property var fueraDesde: QtPositioning.coordinate(37.9922, -1.1307)
	readonly property var fueraHasta: QtPositioning.coordinate(48.8566, 2.3522)

	function probarFueraDeRegion(hayRed, cuando) {
		const pl = plantillaPlan.createObject(prueba)
		pl.hayLocal = true          // on purpose: it is asked at home first

		const reloj = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 90000; running: true }', prueba)

		function acabar(ok, porque) {
			reloj.stop(); reloj.destroy(); pl.destroy()
			if (ok) prueba.bien("destination outside the maps ("
				+ (hayRed ? "resolved over network" : "rejected with no network") + ")")
			else prueba.mal("destination outside the maps", porque)
			cuando()
		}
		// Hanging is the failure that matters: the driver can be told there is no
		// route, but cannot be left staring at a spinner forever.
		reloj.triggered.connect(function () {
			acabar(false, "did not answer in 90 s -- neither route nor error")
		})

		pl.estadoChanged.connect(function () {
			if (pl.estado === "error") {
				acabar(!hayRed, hayRed
					? "there is network and still no route was found: " + pl.fallo
					: "")
				return
			}
			if (pl.estado !== "listo")
				return
			if (!hayRed) {
				acabar(false, "no network and still it returned a route; impossible")
				return
			}
			console.log("  info  over network: " + (pl.rutas[0].metros / 1000).toFixed(0)
				+ " km, " + pl.rutas[0].minutos + " min")
			acabar(pl.rutas.length > 0, "it returned no route")
		})

		pl.planificar(prueba.fueraDesde, prueba.fueraHasta, "París")
	}

	// --- 5. DRIVE the whole route, as if driving it -----------------------
	//
	// This is what none of the previous tests touched: that a route being
	// COMPUTED well says nothing about it being GUIDED well. What is checked here is
	// the whole chain -- position -> situar() -> current maneuver -> phrase --
	// walking the line point by point, with no car and no GPS.
	//
	// Each maneuver change is logged with the kilometre it happens at, and each
	// phrase the voice would have said. This way you see at a glance whether the
	// instructions come out in order, whether any is skipped, and whether the warning has
	// the right lead time.
	Component {
		id: plantillaVoz
		Voice {}
	}

	function probarRecorrido(enCasa, cuando) {
		const r = plantillaRuta.createObject(prueba)
		r.hayLocal = enCasa
		const v = plantillaVoz.createObject(prueba)
		v.activa = true

		const dichas = []
		v.hablar.connect(function (frase) { dichas.push(frase) })

		const reloj = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 60000; running: true }', prueba)

		function acabar(ok, porque) {
			reloj.stop(); reloj.destroy(); r.destroy(); v.destroy()
			if (ok) prueba.bien("drive Bolnuevo -> Murcia")
			else prueba.mal("drive Bolnuevo -> Murcia", porque)
			cuando()
		}
		reloj.triggered.connect(function () { acabar(false, "the route did not arrive") })

		r.estadoChanged.connect(function () {
			if (r.estado === "error") { acabar(false, r.fallo); return }
			if (r.estado !== "lista")
				return

			console.log("  info  " + (r.metrosTotal / 1000).toFixed(1) + " km, "
				+ r.maniobras.length + " maneuvers, " + r.puntos.length + " points")

			// It advances along the line skipping points: walking the thousands of
			// points of a 70 km route one by one would take longer than
			// driving it. One in every five is plenty so that no
			// maneuver goes unnoticed.
			var ultimaManiobra = -1
			var avisos = 0
			var desorden = 0
			for (var i = 0; i < r.puntos.length; i += 5) {
				r.situar(r.puntos[i])
				// 90 km/h: the speed decides how far ahead the voice
				// warns, so it has to be given a road one.
				v.seguir(r, 25)

				if (r.maniobra !== ultimaManiobra) {
					// The maneuvers have to go FORWARD. If the
					// locator jumps backwards, the guidance goes haywire.
					if (r.maniobra < ultimaManiobra)
						desorden += 1
					ultimaManiobra = r.maniobra
					const km = (r.acumulado[i] / 1000).toFixed(1)
					const m = r.maniobras[r.maniobra]
					if (m && avisos < 12) {
						console.log("        " + km + " km  " + m.texto
							+ (m.calle ? "  [" + m.calle + "]" : ""))
						avisos += 1
					}
				}
			}

			// The last point ALWAYS, even if the five-by-five jump
			// skips past it: it is where arrival is declared, and stopping two
			// points from the end left the test saying an instruction was
			// missing when what was missing was reaching the destination.
			r.situar(r.puntos[r.puntos.length - 1])
			v.seguir(r, 5)
			if (r.maniobra > ultimaManiobra)
				ultimaManiobra = r.maniobra

			console.log("  info  phrases said: " + dichas.length)
			for (var j = 0; j < Math.min(dichas.length, 8); ++j)
				console.log("        \"" + dichas[j] + "\"")

			if (desorden > 0) {
				acabar(false, "the maneuver went backwards " + desorden + " times")
				return
			}
			// What really matters is not having passed through all the
			// maneuvers, but that the application knows you have ARRIVED: it is what
			// closes navigation and deletes the saved route.
			if (!r.llegado) {
				acabar(false, "drove the whole route and did not accept arrival"
					+ " (" + Math.round(r.metrosRestantes) + " m left)")
				return
			}
			// And that half the route was not skipped along the way.
			if (ultimaManiobra < r.maniobras.length - 2) {
				acabar(false, "ended at maneuver " + ultimaManiobra
					+ " of " + (r.maniobras.length - 1) + ": it dropped instructions")
				return
			}
			if (dichas.length === 0) {
				acabar(false, "it did not say a single phrase in the whole journey")
				return
			}
			acabar(true, "")
		})

		// Bolnuevo -> Murcia, which is the journey it was asked to check.
		r.calcular(prueba.desde, QtPositioning.coordinate(37.9917, -1.1305), "Murcia")
	}

	// --- 6. typing letter by letter: the debounce ------------------------
	//
	// "cartagena" is typed at 120 ms per letter -- faster than the 800 ms
	// clock -- and it is checked that a search does NOT go out per key, but ONE when
	// it stops. Nine keystrokes must give a single query.
	Component {
		id: plantillaBuscador
		DestinationSearch {}
	}

	function probarEscritura(cuando) {
		const b = plantillaBuscador.createObject(prueba)
		b.hayLocal = true


		const palabra = "cartagena"
		var i = 0
		const tecla = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 120; repeat: true; running: true }',
			prueba)
		tecla.triggered.connect(function () {
			i += 1
			b.campo.text = palabra.substring(0, i)
			if (i >= palabra.length)
				tecla.stop()
		})

		// Time to type, plus the debounce, plus the query.
		const fin = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 4000; running: true }', prueba)
		fin.triggered.connect(function () {
			const cuantos = b.resultados.count
			const primero = cuantos > 0 ? b.resultados.get(0).nombre : ""
			// The QUERIES fired, not the rows inserted: counting rows gave
			// twelve for a single search and made the test fail for no reason.
			const consultas = b.consultas
			tecla.destroy(); fin.destroy(); b.destroy()

			console.log("  info  9 keys -> " + consultas + " query(ies), "
				+ cuantos + " results, 1st: " + primero)
			if (consultas === 0) {
				prueba.mal("search as you type", "it searched nothing on stopping")
			} else if (consultas > 2) {
				prueba.mal("search as you type",
					"fired " + consultas + " queries for nine keys: no debounce")
			} else if (primero.toLowerCase().indexOf("cartagena") < 0) {
				prueba.mal("search as you type",
					"the first was '" + primero + "'")
			} else {
				prueba.bien("search as you type ("
					+ consultas + " query for 9 keys)")
			}
			cuando()
		})
	}

	// --- 7. search by name ------------------------------------------------
	// --- 9. the map DRAWING path, except the actual painting --------------
	//
	// Checks everything needed for the map to be drawn out of coverage:
	// that the position translates to the right tile, that the server says there
	// is something to draw with, that the style comes out with its URLs pointing at it, and that
	// a specific tile is actually served.
	//
	// The only thing it CANNOT check is that it paints. MapLibre only requests
	// tiles while drawing, and drawing needs a visible window -- with the
	// screen locked it requests not one. That has to be checked with the phone
	// in front; here everything else is covered, which is where the failures were.
	function probarDibujo(cuando) {
		// From the position to the tile. Bolnuevo falls in 7-63-49, which is one of the
		// 23 the catalog publishes for Spain -- verified against its list.
		const cuadros = app.cuadrosDe(37.5875, -1.2531, 0)
		if (cuadros.length !== 1 || cuadros[0] !== "7-63-49") {
			prueba.mal("position -> map tile",
				"expected 7-63-49 and got " + JSON.stringify(cuadros))
		} else {
			prueba.bien("position -> map tile (7-63-49)")
		}
		// THE RECTANGLE OF A ROUTE -> the tiles needed to see it.
		//
		// It is what decides whether the "download the map for this route" button appears, and
		// getting it wrong here gives no error: either it does not appear when needed, or it downloads
		// half the country. Valencia -> Murcia has to be exactly two.
		const deRuta = app.cuadrosDelRectangulo(37.99, -1.13, 39.50, -0.36)
		if (deRuta.length !== 2 || deRuta.indexOf("7-63-48") < 0
			|| deRuta.indexOf("7-63-49") < 0) {
			prueba.mal("route rectangle -> tiles",
				"expected 7-63-48 and 7-63-49; got " + JSON.stringify(deRuta))
		} else {
			prueba.bien("route rectangle -> tiles (Valencia-Murcia, 2)")
		}

		// And the ring: nine around, no duplicates.
		const nueve = app.cuadrosDe(37.5875, -1.2531, 1)
		const distintos = {}
		for (var i = 0; i < nueve.length; ++i)
			distintos[nueve[i]] = true
		if (nueve.length !== 9 || Object.keys(distintos).length !== 9)
			prueba.mal("tile ring", nueve.length + " tiles, "
				+ Object.keys(distintos).length + " distinct")
		else
			prueba.bien("tile ring (9 around)")

		const base = "http://127.0.0.1:8554"
		const e = new XMLHttpRequest()
		e.onreadystatechange = function () {
			if (e.readyState !== XMLHttpRequest.DONE)
				return
			if (e.status !== 200) {
				prueba.mal("map style", "the server responded " + e.status)
				cuando()
				return
			}
			var d = null
			try {
				d = JSON.parse(e.responseText)
			} catch (err) {
				prueba.mal("map style", "could not understand the response")
				cuando()
				return
			}
			const fuentes = Object.keys(d.sources || {})
			const url = fuentes.length ? d.sources[fuentes[0]].tiles[0] : ""
			console.log("  info  style: " + (d.layers || []).length
				+ " layers, tiles at " + url)
			// That it points HERE and not at the server of whoever wrote the style: the
			// original file carries 'HOSTNAMEPORT' unresolved, and if the
			// rewrite failed the map would come out blank without saying why.
			if (url.indexOf(base) !== 0) {
				prueba.mal("map style",
					"the tiles do not point at the own server: " + url)
				cuando()
				return
			}
			prueba.bien("map style points at the own server")

			// THE ZOOM RANGE IT DECLARES, which is what the planner left
			// blank. The catalog files say "minzoom 0" and only
			// carry from 7 to 14; if the style repeats that lie, MapLibre requests
			// a zoom 5 when zooming out, it does not exist, and it DRAWS NOTHING -- instead of
			// taking the level-7 one and scaling it.
			//
			// The symptom was baffling: while driving the map showed and in the
			// planner it came out blank. The difference is the zoom.
			const f = d.sources[fuentes[0]]
			console.log("  info  map zoom: " + f.minzoom + " to " + f.maxzoom)
			if (f.minzoom === undefined || f.maxzoom === undefined)
				prueba.mal("map zoom range", "the style does not declare it")
			else if (f.minzoom > 7)
				prueba.mal("map zoom range",
					"starts at " + f.minzoom + "; zooming out there will be no map")
			else
				prueba.bien("map zoom range (" + f.minzoom
					+ " to " + f.maxzoom + ")")

			// THE THREE PIECES IN A CHAIN, not in parallel: if the first fails,
			// the next would fail for the same reason and give three warnings for
			// a single problem.
			//
			// And the fonts matter as much as the tiles: without them
			// the map comes out with all its streets and WITHOUT A SINGLE LABEL. It gives no
			// error -- it draws, and stays silent -- so you see the shape of the junction and not
			// what the exit is called.
			function pedirGlifo() {
				const g = new XMLHttpRequest()
				g.onreadystatechange = function () {
					if (g.readyState !== XMLHttpRequest.DONE)
						return
					if (g.status === 200)
						prueba.bien("map fonts served")
					else if (g.status === 404)
						prueba.mal("map fonts",
							"404: they are not downloaded; the map would come out with no labels")
					else
						prueba.mal("map fonts",
							"responded " + g.status)
					cuando()
				}
				// The whole STACK separated by commas, which is how
				// MapLibre asks for it: its preference list. The database stores one row
				// per individual font, so if the server did not know how to
				// split it, there would be no labels and nothing would say so.
				g.open("GET", base + "/mapa/glifos/"
					+ encodeURIComponent("Open Sans Bold,Arial Unicode MS Bold")
					+ "/0-255.pbf")
				g.send()
			}

			// A real tile, Bolnuevo's at zoom 14.
			const t = new XMLHttpRequest()
			t.onreadystatechange = function () {
				if (t.readyState !== XMLHttpRequest.DONE)
					return
				// 200 with data means having a map; 204 is "there is nothing here to
				// paint", which for the sea is correct and for Bolnuevo is not.
				if (t.status === 200)
					prueba.bien("map tile served from the phone")
				else if (t.status === 204)
					prueba.mal("map tile",
						"204: no downloaded tile for Bolnuevo")
				else
					prueba.mal("map tile", "responded " + t.status)
				pedirGlifo()
			}
			t.open("GET", base + "/mapa/14/8134/6343.pbf")
			t.send()
		}
		e.open("GET", base + "/mapa/estilo?tema=light")
		e.send()
	}

	function probarBusqueda(cuando) {
		const x = new XMLHttpRequest()
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			if (x.status !== 200) {
				console.log("  info  search on the phone not available ("
					+ x.status + ")")
				cuando()
				return
			}
			try {
				const lista = JSON.parse(x.responseText).resultados || []
				if (!lista.length)
					prueba.mal("search without network", "it found nothing")
				else if (lista[0].nombre.toLowerCase().indexOf("mazarr") < 0)
					prueba.mal("search without network",
						"the first was '" + lista[0].nombre + "'")
				else
					prueba.bien("search without network (" + lista[0].nombre + ")")
			} catch (e) {
				prueba.mal("search without network", e)
			}
			cuando()
		}
		x.open("POST", "http://127.0.0.1:8554/search")
		x.setRequestHeader("Content-Type", "application/json")
		x.send(JSON.stringify({ q: "puerto de mazarron", limite: 3,
			cerca: { lat: 37.5875, lon: -1.2531 } }))
	}

	Component.onCompleted: {
		console.log("== PocoNav self-test ==")
		probarBackend()
		probarConectores()
		probarBrujula()
		console.log("  info  network: " + (app.hayRed ? "yes" : "no"))
		console.log("routes:")

		// Chained and not in parallel: two requests at once against the same
		// server confuse the diagnosis when one fails.
		probarServidor(function (hayLocal) {
			function siguiente() {
				// If there is network it is not asked separately: it is deduced from whether the internet
				// route came out. Asking it with a ping would be a second
				// measurement that may not match the one that really matters --
				// that the public server answers.
				const antes = prueba.fallos
				probarRuta(false, function () {
				  const hayRed = prueba.fallos === antes
				  probarFueraDeRegion(hayRed, function () {
				   probarPlan(hayLocal, function () {
				    probarRecorrido(hayLocal, function () {
				     probarEscritura(function () {
					probarDibujo(function () {
					probarBusqueda(function () {
						console.log(prueba.fallos === 0
							? "== all correct =="
							: "== " + prueba.fallos + " FAILURE(S) ==")
						Qt.exit(prueba.fallos === 0 ? 0 : 1)
					})
					})
				     })
				    })
				   })
				  })
				})
			}
			if (hayLocal)
				probarRuta(true, siguiente)
			else
				siguiente()
		})
	}
}
