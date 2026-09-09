// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The self-test: `poconav --test`.
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
	id: selfTest

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
		id: compassTemplate
		Compass { active: true }
	}

	function testCompass() {
		const b = compassTemplate.createObject(selfTest)
		const exists = b.connectedToBackend
		b.destroy()
		if (exists)
			selfTest.pass("compass available (the map orients while stopped)")
		else
			console.log("  info  no compass: the map will only orient while moving."
				+ " Check 'systemctl is-active hexagonrpcd-adsp-sensorspd'")
	}

	function testConnectors() {
		const exists = connectorTemplate.createObject(selfTest)
		const items = exists.availableServiceProviders
		exists.destroy()
		console.log("  info  map connectors: " + items.join(", "))
		if (items.indexOf("maplibre") >= 0)
			selfTest.pass("maplibre available (offline map possible)")
		else
			console.log("  info  no 'maplibre': the map will still need network")
	}

	Component {
		id: connectorTemplate
		Plugin { name: "osm" }
	}

	// Bolnuevo -> Mazarron. Inside the region downloaded in the tests,
	// and with a roundabout, which is where the differences between routers show most.
	readonly property var begin: QtPositioning.coordinate(37.5875, -1.2531)
	readonly property var end: QtPositioning.coordinate(37.6257, -1.2107)

	property int failures: 0
	property int pending: 0

	function pass(what) { console.log("  ok    " + what) }
	function fail(what, why) {
		console.log("  FAIL  " + what + ": " + why)
		selfTest.failures += 1
	}

	// --- 1. the backend is there ------------------------------------------
	function testBackend() {
		console.log("backend:")
		if (typeof app === "undefined" || app === null) {
			fail("app exposed to QML", "it is null -- QML cannot talk to the backend")
			return
		}
		pass("app exposed to QML")
		pass("data in " + app.dataPath())
		console.log("  info  maps: " + (app.maps.length ? app.maps.join(", ") : "none"))
		console.log("  info  voices: " + (app.voices.length ? app.voices.join(", ") : "none"))
	}

	// --- 2. the own routing server ----------------------------------------
	//
	// We wait for it to come up. The backend starts it on construction and it takes a few
	// seconds to bind to the port; asking it on the first frame is
	// asking it before it exists. The test gave "status 0" and then went on
	// against the public server, that is it tested half without saying so.
	property int _attempts: 0

	function testServer(when) {
		const x = new XMLHttpRequest()
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			if (x.status === 0 && selfTest._attempts < 20) {
				// 20 attempts of 1 s. More than enough to start, and if it
				// really is not there, it ends up being said.
				selfTest._attempts += 1
				const t = Qt.createQmlObject(
					'import QtQuick; Timer { interval: 1000; running: true }', selfTest)
				t.triggered.connect(function () {
					t.destroy()
					selfTest.testServer(when)
				})
				return
			}
			selfTest._checkServer(x, when)
		}
		x.open("GET", "http://127.0.0.1:8554/status")
		x.send()
	}

	function _checkServer(x, when) {
		if (x.status !== 200) {
			selfTest.fail("the own server answers",
				"status " + x.status + " after " + selfTest._attempts + " s")
			when(false)
			return
		}
		try {
			const r = JSON.parse(x.responseText)
			if (r.ready) {
				selfTest.pass("the own server can route")
				console.log("  info  tiles: " + r.tiles)
			} else {
				console.log("  info  no downloaded maps (" + r.reason + ")")
			}
			when(r.ready === true)
		} catch (e) {
			selfTest.fail("the own server answers JSON", e)
			when(false)
		}
	}

	// --- 3. a route, the way the application asks for it -------------------
	// Route.qml is used as is, without copying its code: if one day the way it asks for
	// routes changes, this test changes with it.
	Component {
		id: routeTemplate
		Route {}
	}

	function testRoute(atHome, when) {
		const r = routeTemplate.createObject(selfTest)
		r.hasLocal = atHome
		const label = atHome ? "route on the phone" : "route over the internet"

		// 45 s: the public server from this phone has taken 20 s at times,
		// and a false negative from haste would cost more than waiting.
		const clock = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 45000; running: true }', selfTest)

		function finish(ok, why) {
			clock.stop()
			clock.destroy()
			r.destroy()
			if (ok)
				selfTest.pass(label)
			else
				selfTest.fail(label, why)
			when()
		}

		clock.triggered.connect(function () { finish(false, "did not answer in 45 s") })

		r.statusChanged.connect(function () {
			if (r.status === "items") {
				// It answering is not enough: it has to bring a DRIVABLE route.
				// A 200 with zero points is a silent failure.
				if (r.points.length < 2) {
					finish(false, "answered with no line")
					return
				}
				const km = (r.totalMeters / 1000).toFixed(2)
				console.log("  info  " + label + ": " + km + " km, "
					+ r.maneuvers.length + " maneuvers")
				if (r.maneuvers.length)
					console.log("  info  first: " + r.maneuvers[0].text)
				finish(true, "")
			} else if (r.status === "error") {
				finish(false, r.failure)
			}
		})

		r.compute(selfTest.begin, selfTest.end, "selfTest")
	}

	// --- 4. plan: several routes, and knowing which breaks a rule ----------
	Component {
		id: planTemplate
		Planner {}
	}

	// Cartagena -> Vera. Chosen on purpose: via the AP-7 there is a toll and inland
	// there is not, so with "avoid tolls" on there MUST be more than one option and
	// the toll one has to end up marked. If the planner stopped
	// distinguishing them, this test falls over.
	readonly property var pBegin: QtPositioning.coordinate(37.6155, -0.9875)
	readonly property var pEnd: QtPositioning.coordinate(37.2410, -1.8630)

	function testPlan(atHome, when) {
		const pl = planTemplate.createObject(selfTest)
		pl.hasLocal = atHome
        // With the filter on: it is the only thing that makes the test interesting.
		pl.avoidTolls = true

		const clock = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 90000; running: true }', selfTest)

		function finish(ok, why) {
			clock.stop(); clock.destroy(); pl.destroy()
			if (ok) selfTest.pass("plan (avoiding tolls)")
			else selfTest.fail("plan (avoiding tolls)", why)
			when()
		}
		clock.triggered.connect(function () { finish(false, "did not answer in 90 s") })

		pl.statusChanged.connect(function () {
			if (pl.status === "error") { finish(false, pl.failure); return }
			if (pl.status !== "ready")
				return

			if (pl.routes.length < 2) {
				finish(false, "only returned " + pl.routes.length + " route(s); "
					+ "with toll and without toll there should be several")
				return
			}
			for (var i = 0; i < pl.routes.length; ++i) {
				const r = pl.routes[i]
				console.log("  info  #" + i + "  " + (r.meters / 1000).toFixed(1)
					+ " km, " + r.minutes + " min, "
					+ (r.complies ? "complies" : "breaks: " + r.warning.join("+"))
					+ (r.summary ? "  " + r.summary : ""))
			}
			// What is really being checked:
			if (!pl.routes[0].complies) {
				finish(false, "the first does NOT respect the filter")
				return
			}
			// Sorted by time among the ones that comply.
			for (var j = 1; j < pl.routes.length; ++j) {
				if (pl.routes[j].complies && !pl.routes[j - 1].complies) {
					finish(false, "one that complies comes after one that does not")
					return
				}
			}
			var withWarning = 0
			for (var k = 0; k < pl.routes.length; ++k)
				if (!pl.routes[k].complies) withWarning += 1
			if (withWarning === 0) {
				finish(false, "no toll alternative; there should be one")
				return
			}
			// And that the chosen one can really be driven.
			const r2 = routeTemplate.createObject(selfTest)
			r2.adopt(pl.routes[0].trip, selfTest.pEnd, "selfTest")
			const usable = r2.points.length > 1 && r2.maneuvers.length > 0
			r2.destroy()
			if (!usable) {
				finish(false, "adopt() did not leave a usable route")
				return
			}
			selfTest.pass("adopt the chosen route")
			finish(true, "")
		})

		pl.planRoutes(selfTest.pBegin, selfTest.pEnd, "Vera")
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
	readonly property var outsideBegin: QtPositioning.coordinate(37.9922, -1.1307)
	readonly property var outsideEnd: QtPositioning.coordinate(48.8566, 2.3522)

	function testOutsideRegion(hasNetwork, when) {
		const pl = planTemplate.createObject(selfTest)
		pl.hasLocal = true          // on purpose: it is asked at home first

		const clock = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 90000; running: true }', selfTest)

		function finish(ok, why) {
			clock.stop(); clock.destroy(); pl.destroy()
			if (ok) selfTest.pass("destination outside the maps ("
				+ (hasNetwork ? "resolved over network" : "rejected with no network") + ")")
			else selfTest.fail("destination outside the maps", why)
			when()
		}
		// Hanging is the failure that matters: the driver can be told there is no
		// route, but cannot be left staring at a spinner forever.
		clock.triggered.connect(function () {
			finish(false, "did not answer in 90 s -- neither route nor error")
		})

		pl.statusChanged.connect(function () {
			if (pl.status === "error") {
				finish(!hasNetwork, hasNetwork
					? "there is network and still no route was found: " + pl.failure
					: "")
				return
			}
			if (pl.status !== "ready")
				return
			if (!hasNetwork) {
				finish(false, "no network and still it returned a route; impossible")
				return
			}
			console.log("  info  over network: " + (pl.routes[0].meters / 1000).toFixed(0)
				+ " km, " + pl.routes[0].minutes + " min")
			finish(pl.routes.length > 0, "it returned no route")
		})

		pl.planRoutes(selfTest.outsideBegin, selfTest.outsideEnd, "París")
	}

	// --- 5. DRIVE the whole route, as if driving it -----------------------
	//
	// This is what none of the previous tests touched: that a route being
	// COMPUTED well says nothing about it being GUIDED well. What is checked here is
	// the whole chain -- position -> locate() -> current maneuver -> phrase --
	// walking the line point by point, with no car and no GPS.
	//
	// Each maneuver change is logged with the kilometre it happens at, and each
	// phrase the voice would have said. This way you see at a glance whether the
	// instructions come out in order, whether any is skipped, and whether the warning has
	// the right lead time.
	Component {
		id: voiceTemplate
		Voice {}
	}

	function testDrive(atHome, when) {
		const r = routeTemplate.createObject(selfTest)
		r.hasLocal = atHome
		const v = voiceTemplate.createObject(selfTest)
		v.active = true

		const said = []
		v.speakOut.connect(function (phrase) { said.push(phrase) })

		const clock = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 60000; running: true }', selfTest)

		function finish(ok, why) {
			clock.stop(); clock.destroy(); r.destroy(); v.destroy()
			if (ok) selfTest.pass("drive Bolnuevo -> Murcia")
			else selfTest.fail("drive Bolnuevo -> Murcia", why)
			when()
		}
		clock.triggered.connect(function () { finish(false, "the route did not arrive") })

		r.statusChanged.connect(function () {
			if (r.status === "error") { finish(false, r.failure); return }
			if (r.status !== "items")
				return

			console.log("  info  " + (r.totalMeters / 1000).toFixed(1) + " km, "
				+ r.maneuvers.length + " maneuvers, " + r.points.length + " points")

			// It advances along the line skipping points: walking the thousands of
			// points of a 70 km route one by one would take longer than
			// driving it. One in every five is plenty so that no
			// maneuver goes unnoticed.
			var lastManeuver = -1
			var warnings = 0
			var outOfOrder = 0
			for (var i = 0; i < r.points.length; i += 5) {
				r.locate(r.points[i])
				// 90 km/h: the speed decides how far ahead the voice
				// warns, so it has to be given a road one.
				v.follow(r, 25)

				if (r.maneuver !== lastManeuver) {
					// The maneuvers have to go FORWARD. If the
					// locator jumps backwards, the guidance goes haywire.
					if (r.maneuver < lastManeuver)
						outOfOrder += 1
					lastManeuver = r.maneuver
					const km = (r.cumulative[i] / 1000).toFixed(1)
					const m = r.maneuvers[r.maneuver]
					if (m && warnings < 12) {
						console.log("        " + km + " km  " + m.text
							+ (m.street ? "  [" + m.street + "]" : ""))
						warnings += 1
					}
				}
			}

			// The last point ALWAYS, even if the five-by-five jump
			// skips past it: it is where arrival is declared, and stopping two
			// points from the end left the test saying an instruction was
			// missing when what was missing was reaching the destination.
			r.locate(r.points[r.points.length - 1])
			v.follow(r, 5)
			if (r.maneuver > lastManeuver)
				lastManeuver = r.maneuver

			console.log("  info  phrases said: " + said.length)
			for (var j = 0; j < Math.min(said.length, 8); ++j)
				console.log("        \"" + said[j] + "\"")

			if (outOfOrder > 0) {
				finish(false, "the maneuver went backwards " + outOfOrder + " times")
				return
			}
			// What really matters is not having passed through all the
			// maneuvers, but that the application knows you have ARRIVED: it is what
			// closes navigation and deletes the saved route.
			if (!r.arrived) {
				finish(false, "drove the whole route and did not accept arrival"
					+ " (" + Math.round(r.metersLeft) + " m left)")
				return
			}
			// And that half the route was not skipped along the way.
			if (lastManeuver < r.maneuvers.length - 2) {
				finish(false, "ended at maneuver " + lastManeuver
					+ " of " + (r.maneuvers.length - 1) + ": it dropped instructions")
				return
			}
			if (said.length === 0) {
				finish(false, "it did not say a single phrase in the whole journey")
				return
			}
			finish(true, "")
		})

		// Bolnuevo -> Murcia, which is the journey it was asked to check.
		r.compute(selfTest.begin, QtPositioning.coordinate(37.9917, -1.1305), "Murcia")
	}

	// --- 6. typing letter by letter: the debounce ------------------------
	//
	// "cartagena" is typed at 120 ms per letter -- faster than the 800 ms
	// clock -- and it is checked that a search does NOT go out per key, but ONE when
	// it stops. Nine keystrokes must give a single query.
	Component {
		id: finderTemplate
		DestinationSearch {}
	}

	function testTyping(when) {
		const b = finderTemplate.createObject(selfTest)
		b.hasLocal = true


		const word = "cartagena"
		var i = 0
		const keyTimer = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 120; repeat: true; running: true }',
			selfTest)
		keyTimer.triggered.connect(function () {
			i += 1
			b.field.text = word.substring(0, i)
			if (i >= word.length)
				keyTimer.stop()
		})

		// Time to type, plus the debounce, plus the query.
		const endTimer = Qt.createQmlObject(
			'import QtQuick; Timer { interval: 4000; running: true }', selfTest)
		endTimer.triggered.connect(function () {
			const howMany = b.results.count
			const first = howMany > 0 ? b.results.get(0).name : ""
			// The QUERIES fired, not the rows inserted: counting rows gave
			// twelve for a single search and made the test fail for no reason.
			const queries = b.queries
			keyTimer.destroy(); endTimer.destroy(); b.destroy()

			console.log("  info  9 keys -> " + queries + " query(ies), "
				+ howMany + " results, 1st: " + first)
			if (queries === 0) {
				selfTest.fail("search as you type", "it searched nothing on stopping")
			} else if (queries > 2) {
				selfTest.fail("search as you type",
					"fired " + queries + " queries for nine keys: no debounce")
			} else if (first.toLowerCase().indexOf("cartagena") < 0) {
				selfTest.fail("search as you type",
					"the first was '" + first + "'")
			} else {
				selfTest.pass("search as you type ("
					+ queries + " query for 9 keys)")
			}
			when()
		})
	}

	// --- 7. search by name ------------------------------------------------
	// --- 9. the map DRAWING path, except the current painting --------------
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
	function testDrawing(when) {
		// From the position to the tile. Bolnuevo falls in 7-63-49, which is one of the
		// 23 the catalog publishes for Spain -- verified against its list.
		const boxes = app.boxesAt(37.5875, -1.2531, 0)
		if (boxes.length !== 1 || boxes[0] !== "7-63-49") {
			selfTest.fail("position -> map tile",
				"expected 7-63-49 and got " + JSON.stringify(boxes))
		} else {
			selfTest.pass("position -> map tile (7-63-49)")
		}
		// THE RECTANGLE OF A ROUTE -> the tiles needed to see it.
		//
		// It is what decides whether the "download the map for this route" button appears, and
		// getting it wrong here gives no error: either it does not appear when needed, or it downloads
		// half the country. Valencia -> Murcia has to be exactly two.
		const fromRoute = app.boxesInRectangle(37.99, -1.13, 39.50, -0.36)
		if (fromRoute.length !== 2 || fromRoute.indexOf("7-63-48") < 0
			|| fromRoute.indexOf("7-63-49") < 0) {
			selfTest.fail("route rectangle -> tiles",
				"expected 7-63-48 and 7-63-49; got " + JSON.stringify(fromRoute))
		} else {
			selfTest.pass("route rectangle -> tiles (Valencia-Murcia, 2)")
		}

		// And the ring: nine around, no duplicates.
		const nine = app.boxesAt(37.5875, -1.2531, 1)
		const distinct = {}
		for (var i = 0; i < nine.length; ++i)
			distinct[nine[i]] = true
		if (nine.length !== 9 || Object.keys(distinct).length !== 9)
			selfTest.fail("tile ring", nine.length + " tiles, "
				+ Object.keys(distinct).length + " distinct")
		else
			selfTest.pass("tile ring (9 around)")

		const base = "http://127.0.0.1:8554"
		const e = new XMLHttpRequest()
		e.onreadystatechange = function () {
			if (e.readyState !== XMLHttpRequest.DONE)
				return
			if (e.status !== 200) {
				selfTest.fail("map style", "the server responded " + e.status)
				when()
				return
			}
			var d = null
			try {
				d = JSON.parse(e.responseText)
			} catch (err) {
				selfTest.fail("map style", "could not understand the response")
				when()
				return
			}
			const sourceNames = Object.keys(d.sources || {})
			const url = sourceNames.length ? d.sources[sourceNames[0]].tiles[0] : ""
			console.log("  info  style: " + (d.layers || []).length
				+ " layers, tiles at " + url)
			// That it points HERE and not at the server of whoever wrote the style: the
			// original file carries 'HOSTNAMEPORT' unresolved, and if the
			// rewrite failed the map would come out blank without saying why.
			if (url.indexOf(base) !== 0) {
				selfTest.fail("map style",
					"the tiles do not point at the own server: " + url)
				when()
				return
			}
			selfTest.pass("map style points at the own server")

			// THE ZOOM RANGE IT DECLARES, which is what the planner left
			// blank. The catalog files say "minzoom 0" and only
			// carry from 7 to 14; if the style repeats that lie, MapLibre requests
			// a zoom 5 when zooming out, it does not exist, and it DRAWS NOTHING -- instead of
			// taking the level-7 one and scaling it.
			//
			// The symptom was baffling: while driving the map showed and in the
			// planner it came out blank. The difference is the zoom.
			const f = d.sources[sourceNames[0]]
			console.log("  info  map zoom: " + f.minzoom + " to " + f.maxzoom)
			if (f.minzoom === undefined || f.maxzoom === undefined)
				selfTest.fail("map zoom range", "the style does not declare it")
			else if (f.minzoom > 7)
				selfTest.fail("map zoom range",
					"starts at " + f.minzoom + "; zooming out there will be no map")
			else
				selfTest.pass("map zoom range (" + f.minzoom
					+ " to " + f.maxzoom + ")")

			// THE THREE PIECES IN A CHAIN, not in parallel: if the first fails,
			// the next would fail for the same reason and give three warnings for
			// a single problem.
			//
			// And the fonts matter as much as the tiles: without them
			// the map comes out with all its streets and WITHOUT A SINGLE LABEL. It gives no
			// error -- it draws, and stays silent -- so you see the shape of the junction and not
			// what the exit is called.
			function requestGlyph() {
				const g = new XMLHttpRequest()
				g.onreadystatechange = function () {
					if (g.readyState !== XMLHttpRequest.DONE)
						return
					if (g.status === 200)
						selfTest.pass("map fonts served")
					else if (g.status === 404)
						selfTest.fail("map fonts",
							"404: they are not downloaded; the map would come out with no labels")
					else
						selfTest.fail("map fonts",
							"responded " + g.status)
					when()
				}
				// The whole STACK separated by commas, which is how
				// MapLibre asks for it: its preference list. The database stores one row
				// per individual font, so if the server did not know how to
				// split it, there would be no labels and nothing would say so.
				g.open("GET", base + "/map/glyphs/"
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
					selfTest.pass("map tile served from the phone")
				else if (t.status === 204)
					selfTest.fail("map tile",
						"204: no downloaded tile for Bolnuevo")
				else
					selfTest.fail("map tile", "responded " + t.status)
				requestGlyph()
			}
			t.open("GET", base + "/map/14/8134/6343.pbf")
			t.send()
		}
		e.open("GET", base + "/map/style?theme=light")
		e.send()
	}

	function testSearch(when) {
		const x = new XMLHttpRequest()
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			if (x.status !== 200) {
				console.log("  info  search on the phone not available ("
					+ x.status + ")")
				when()
				return
			}
			try {
				const items = JSON.parse(x.responseText).results || []
				if (!items.length)
					selfTest.fail("search without network", "it found nothing")
				else if (items[0].name.toLowerCase().indexOf("mazarr") < 0)
					selfTest.fail("search without network",
						"the first was '" + items[0].name + "'")
				else
					selfTest.pass("search without network (" + items[0].name + ")")
			} catch (e) {
				selfTest.fail("search without network", e)
			}
			when()
		}
		x.open("POST", "http://127.0.0.1:8554/search")
		x.setRequestHeader("Content-Type", "application/json")
		x.send(JSON.stringify({ q: "puerto de mazarron", limit: 3,
			near: { lat: 37.5875, lon: -1.2531 } }))
	}

	Component.onCompleted: {
		console.log("== PocoNav self-test ==")
		testBackend()
		testConnectors()
		testCompass()
		console.log("  info  network: " + (app.hasNetwork ? "yes" : "no"))
		console.log("routes:")

		// Chained and not in parallel: two requests at once against the same
		// server confuse the diagnosis when one fails.
		testServer(function (hasLocal) {
			function next() {
				// If there is network it is not asked separately: it is deduced from whether the internet
				// route came out. Asking it with a ping would be a second
				// measurement that may not match the one that really matters --
				// that the public server answers.
				const before = selfTest.failures
				testRoute(false, function () {
				  const hasNetwork = selfTest.failures === before
				  testOutsideRegion(hasNetwork, function () {
				   testPlan(hasLocal, function () {
				    testDrive(hasLocal, function () {
				     testTyping(function () {
					testDrawing(function () {
					testSearch(function () {
						console.log(selfTest.failures === 0
							? "== all correct =="
							: "== " + selfTest.failures + " FAILURE(S) ==")
						Qt.exit(selfTest.failures === 0 ? 0 : 1)
					})
					})
				     })
				    })
				   })
				  })
				})
			}
			if (hasLocal)
				testRoute(true, next)
			else
				next()
		})
	}
}
