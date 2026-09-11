// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The route: asking for one, understanding the answer, and knowing where along
// it you are.
//
// WHY VALHALLA AND NOT QtLocation's RouteModel. Qt's own routing speaks OSRM,
// and it works -- same road, same length. But Qt writes the turns itself, in
// English, and it loses things the driver needs. Measured on the same pair of
// points, Bolnuevo to Mazarron:
//
//   Qt/OSRM   "Enter the roundabout and take the second exit"
//             "exit roundabout to/onto  "        <- name missing, two steps
//                                                   for one roundabout
//   Valhalla  "Haga la roundabout y tome la exitNumber 3.º toward RM-D6."
//
// The server does the wording, so the language is a request parameter and the
// exit number is in it. Qt's parser cannot be made to do either.
//
// The price is that the HTTP call, the polyline and the progress along it are
// ours. That is what this file is.
import QtQuick
import QtPositioning

QtObject {
	id: route

	// --- the answer -------------------------------------------------------
	property var points: []          // coordinates, for the line on the map
	property var maneuvers: []       // {kind, text, street, meters, seconds, startIndex}
	property real totalMeters: 0
	property real totalSeconds: 0
	property var destination: null       // coordinate asked for
	property string destinationName: ""
	// The polyline exactly as the server sent it. Kept because saving a route
	// to disk as thousands of lat/lon pairs is hundreds of kilobytes of JSON,
	// and this same string is a couple of hundred bytes per kilometre.
	property string shape: ""

	// "", "requesting", "items", "error"
	property string status: ""
	property string failure: ""
	readonly property bool exists: status === "items" && points.length > 1

	// --- where you are on it ----------------------------------------------
	property int index: 0           // nearest shape point
	property real deviation: 0          // metres from the line
	property int maneuver: 0         // which instruction is current
	property real metersToManeuver: 0
	property real metersLeft: 0
	property real secondsLeft: 0
	// 60 m is wide enough for GPS noise and a dual carriageway, narrow enough
	// that a wrong turn shows up within a block.
	readonly property bool offRoute: exists && deviation > 60

	// You have arrived. `index > 0` is not redundant: without it, a twenty-metre route would
	// be declared finished before the car even starts.
	readonly property bool arrived: exists && index > 0 && metersLeft < 25

	// The legal limit at the point where you are, in km/h. 0 = unknown, which is
	// different from "none", and that is why nothing is drawn instead of a zero.
	property var _limitPerPoint: []
	readonly property int limit: (_limitPerPoint.length > index)
		? (_limitPerPoint[index] || 0) : 0

	// Cumulative distance along `points`, so "how far to the next turn" is a
	// subtraction instead of a walk over the whole line every second.
	property var cumulative: []

	// The public Valhalla of FOSSGIS. Same project that serves the tiles, no
	// account, no key. Light use with an honest User-Agent is what its terms
	// ask for, which is exactly what a phone doing one route at a time is.
	readonly property string publicServer: "https://valhalla1.openstreetmap.de/route"
	// The application's own routing server: its backend starts it when
	// it opens and it dies with it. It speaks Valhalla JSON because it IS Valhalla
	// -- the same engine as the public one, loaded in here -- so the same
	// request and the same reader work for both.
	//
	// 127.0.0.1 and NOT "localhost", on purpose. Anyone resolving "localhost" to ::1
	// first gets a "connection refused" that looks like the server is
	// down. It had me chasing a ghost a whole night: wget failed and
	// python worked against the SAME server, at the same time.
	readonly property string localServer: "http://127.0.0.1:8554"
	property bool hasLocal: false
	// Whether there is also something to DRAW with out of coverage. It is another flag, not the
	// same one: they download separately and you can have one without the other. The window
	// uses it to choose which connector draws the map.
	property bool localDrawing: false
	// THE TILES on disk, by name: ["7-63-49"].
	//
	// The list is needed, not just "there is or there is not". Having a drawing map and having
	// a map OF HERE are different things, and confusing them gives the worst possible
	// screen: blank and unexplained.
	property var drawingBoxes: []
	// Whether the home server has ever ANSWERED at all.
	//
	// Not the same as 'hasLocal': answering "I have no maps" is answering. It is
	// separate because it decides how often to ask again -- the server takes
	// a few seconds to load the tile index when the application starts, and
	// until it loads there is no one to ask.
	property bool probeAnswered: false

	// THE ORDER: internet first, and the phone when there is no internet.
	//
	// It was the other way round, with this argument written right here: "if there are
	// downloaded maps they are used ALWAYS, nobody wants the answer that on top of being
	// slower spends data". The argument is good for the spending and bad for
	// driving -- the public server sees this week's closures, roadworks and
	// reversed directions, and the phone's tiles are from the date they
	// were downloaded. On a map, "faster" is not worth a route that no longer exists.
	//
	// The local one is not a degraded mode: it resolves the same routes with the same
	// engine, and it is the only thing there is in a tunnel, in a village or abroad
	// with no data. That is why the fallback goes BOTH WAYS: the right one is
	// asked, and if it cannot the other is tried before telling the driver
	// there is no route.
	property bool hasNetwork: app.hasNetwork
	readonly property bool _outsideFirst: hasNetwork || !hasLocal
	readonly property string server: _outsideFirst
		? publicServer : localServer + "/route"
	readonly property string userAgent: "PocoNav/1.0 (postmarketOS; personal use)"

	// --- kilometres or miles -------------------------------------------------
	// Valhalla is asked in the driver's units, and not always in
	// kilometres converting afterwards, because the spoken phrases CARRY THE
	// UNIT INSIDE: "continue for half a mile" is written by the server, not
	// by us.
	//
	// The price is that its numbers also come in those units. Inside the
	// application EVERYTHING is metres and km/h, always, and the conversion happens here
	// on the way in. Mixing units internally is the sure way for a distance one day
	// to come out 1.6 times longer with nobody knowing why.
	property bool miles: false
	readonly property real _toMeters: miles ? 1609.344 : 1000
	readonly property real _toKmh: miles ? 1.609344 : 1
	readonly property string _units: miles ? "miles" : "kilometers"

	// The language of the instructions is set by the voice chosen in settings, not a separate
	// setting: having an English voice reading Spanish text -- or the
	// other way round -- serves no one, and it is two places to get it wrong.
	//
	// The voice name is "es_ES-davefx-medium" and Valhalla wants "es-ES", so
	// it is trimmed at the first hyphen and the underscore is swapped. If there is no voice
	// set, Spanish: it is the language of the interface.
	readonly property string language: {
		const v = app.activeVoice
		if (!v || v.length < 5)
			return "es-ES"
		return v.split("-")[0].replace("_", "-")
	}

	// Route preferences. Valhalla takes them as a 0..1 willingness, not as a
	// ban: 0 means "only if there is no other way", which is what a driver
	// actually wants -- a hard ban can leave you with no route at all.
	property bool avoidTolls: false
	property bool avoidMotorways: false

	// --- lane guidance, from a second router --------------------------------
	// MEASURED: Valhalla 3.8.3 returns no lane information at all -- three
	// routes, including the M-30 and Gran Via, 41 maneuvers, zero with `lanes`.
	// OSRM does return it, as intersections[].lanes with `valid` and
	// `indications`. So the text comes from Valhalla, in Spanish, and the lanes
	// come from OSRM.
	//
	// The two routers can disagree about which road to take. That is why lanes
	// are attached by PROXIMITY to a Valhalla maneuver and not by index: if the
	// routes diverge, nothing matches and no lanes are shown. Never guess a
	// lane -- a wrong arrow at a junction is worse than no arrow.
	readonly property string laneServer:
		"https://routing.openstreetmap.de/routed-car/route/v1/driving/"
	property var _laneRequest: null

	function _requestLanes(origin, dest) {
		if (_laneRequest)
			_laneRequest.abort()
		const x = new XMLHttpRequest()
		_laneRequest = x
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			// The route may have been destroyed while this was in flight -- the
			// lanes and the limits take longer than the route and arrive late. Without
			// this guard, the handler writes over an object that no longer
			// exists. The self-test uncovered it on its first run.
			if (!route)
				return
			route._laneRequest = null
			if (x.status !== 200)
				return
			try {
				route._matchLanes(JSON.parse(x.responseText))
			} catch (e) {
				// Lanes are a bonus. Losing them must never cost the route.
			}
		}
		x.open("GET", laneServer
			+ origin.longitude + "," + origin.latitude + ";"
			+ dest.longitude + "," + dest.latitude
			+ "?overview=false&steps=true&annotations=false")
		x.setRequestHeader("User-Agent", userAgent)
		x.send()
	}

	function _matchLanes(response) {
		if (!exists || !response.routes || !response.routes.length)
			return
		const steps = response.routes[0].legs[0].steps
		const copy = maneuvers.slice()
		var placed = 0

		for (var i = 0; i < steps.length; ++i) {
			const crossings = steps[i].intersections || []
			for (var j = 0; j < crossings.length; ++j) {
				const c = crossings[j]
				if (!c.lanes || !c.lanes.length || !c.location)
					continue
				const where = QtPositioning.coordinate(c.location[1], c.location[0])

				// The nearest maneuver, and only if it is really near. 30 m is
				// about one junction: further than that and the two routers are
				// talking about different places.
				var best = -1, bestD = 30
				for (var k = 0; k < copy.length; ++k) {
					const d = where.distanceTo(points[copy[k].startIndex])
					if (d < bestD) { bestD = d; best = k }
				}
				if (best < 0)
					continue

				const lanes = []
				for (var n = 0; n < c.lanes.length; ++n)
					lanes.push({
						serves: c.lanes[n].valid === true,
						toward: c.lanes[n].indications || []
					})
				copy[best] = Object.assign({}, copy[best], { lanes: lanes })
				++placed
			}
		}

		if (placed > 0)
			maneuvers = copy
	}

	// --- speed limits ------------------------------------------------------
	// Neither Valhalla nor OSRM give them in the route response -- verified: public
	// OSRM does not even accept 'annotations=maxspeed', and its 'speed' is the
	// computed one, not the legal one. But Valhalla's 'trace_attributes' DOES, and on top
	// it returns the shape indices, which are the same ones we already follow here.
	// Measured in Madrid: 135 of 154 segments with a limit.
	//
	// A single request per route, and by POST: the encoded shape of a long
	// route does not fit in a URL.
	property var _limitRequest: null

	function _requestLimits(encoded) {
		if (_limitRequest)
			_limitRequest.abort()
		const x = new XMLHttpRequest()
		_limitRequest = x
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			// The route may have been destroyed while this was in flight -- the
			// lanes and the limits take longer than the route and arrive late. Without
			// this guard, the handler writes over an object that no longer
			// exists. The self-test uncovered it on its first run.
			if (!route)
				return
			route._limitRequest = null
			if (x.status !== 200)
				return
			try {
				route._readLimits(JSON.parse(x.responseText))
			} catch (e) {
				// A bonus. Its failure must not cost the route.
			}
		}
		const body = JSON.stringify({
			encoded_polyline: encoded,
			costing: "auto",
			shape_match: "edge_walk",
			filters: {
				attributes: ["edge.speed_limit", "edge.begin_shape_index",
					"edge.end_shape_index"],
				action: "include"
			}
		})
		// To the same one as the route, and in the same order: the limits have to
		// come from the map that drew the path. Mixing them -- route from the internet,
		// limits from the phone -- is asking for a new stretch to come out with no limit or with
		// that of the road that was there before.
		x.open("POST", (_outsideFirst
			? "https://valhalla1.openstreetmap.de" : localServer)
			+ "/trace_attributes")
		x.setRequestHeader("User-Agent", userAgent)
		x.setRequestHeader("Content-Type", "application/json")
		x.send(body)
	}

	function _readLimits(response) {
		const edges = response.edges
		if (!edges || !edges.length || !points.length)
			return
		// A flat table by shape index: looking up the limit is then a single
		// access, and this is consulted once a second.
		const table = new Array(points.length)
		for (var i = 0; i < edges.length; ++i) {
			const e = edges[i]
			if (!e.speed_limit)
				continue
			const begin = e.begin_shape_index || 0
			const end = Math.min(points.length - 1, e.end_shape_index || begin)
			for (var j = begin; j <= end; ++j)
				// Always km/h. Asked in miles, Valhalla answers in mph.
				table[j] = Math.round(e.speed_limit * route._toKmh)
		}
		_limitPerPoint = table
	}

	property var _pending: null
	property var _probe: null

	// Asks our own server whether it can route. It answers
	// {"ready":true/false}, and the false matters as much as the true: the process
	// can be alive and not have maps yet, or have them half-downloaded.
	// Trusting that it answers would be accepting an incomplete region.
	//
	// It is local and fails fast when nobody is listening, so it can be
	// asked before every route at no cost.
	function probeLocal() {
		if (_probe)
			_probe.abort()
		const s = new XMLHttpRequest()
		_probe = s
		s.onreadystatechange = function () {
			if (s.readyState !== XMLHttpRequest.DONE)
				return
			route._probe = null
			if (s.status !== 200) {
				route.hasLocal = false
				route.localDrawing = false
				route.drawingBoxes = []
				return
			}
			route.probeAnswered = true
			try {
				const r = JSON.parse(s.responseText)
				// It is logged ONCE, on change, and not on every poll: it is the only
				// signal of why the map is drawn one way or another, and
				// without it the symptom is just "it comes over the internet".
				if (route.localDrawing !== (r.drawable === true))
					console.log("poconav: drawing local ->",
						r.drawable === true, "(" + (r.drawing_maps || 0) + " maps)")
				route.hasLocal = r.ready === true
				route.localDrawing = r.drawable === true
				route.drawingBoxes = r.boxes || []
			} catch (e) {
				route.hasLocal = false
				route.localDrawing = false
			}
		}
		try {
			s.open("GET", localServer + "/status")
			s.send()
		} catch (e) {
			route._probe = null
			route.hasLocal = false
			route.localDrawing = false
		}
	}

	// So that whoever asks for a route can report a refusal through the same
	// channel the server errors use, instead of failing in silence.
	function failWith(reason) {
		status = "error"
		failure = reason
	}

	function clear() {
		if (_pending) {
			_pending.abort()
			_pending = null
		}
		if (_laneRequest) {
			_laneRequest.abort()
			_laneRequest = null
		}
		if (_limitRequest) {
			_limitRequest.abort()
			_limitRequest = null
		}
		_limitPerPoint = []
		points = []
		maneuvers = []
		cumulative = []
		totalMeters = 0
		totalSeconds = 0
		destination = null
		destinationName = ""
		shape = ""
		status = ""
		failure = ""
		index = 0
		maneuver = 0
	}

	// The same route, from where you are now. Separated from compute() so that
	// it is clear in the code that calling it is NOT starting a new journey: the
	// destination and its name are not touched.
	function recompute(origin) {
		if (!destination)
			return
		compute(origin, destination, destinationName)
	}

	function compute(origin, dest, name) {
		if (!origin || !dest)
			return
		if (_pending)
			_pending.abort()

		destination = dest
		destinationName = name || ""
		status = "requesting"
		failure = ""

		const query = {
			locations: [
				{ lat: origin.latitude, lon: origin.longitude },
				{ lat: dest.latitude, lon: dest.longitude }
			],
			costing: "auto",
			costing_options: {
				auto: {
					// 0 is not "forbidden", it is "only if there is no other
					// way". A hard ban can answer with no route at all, and a
					// driver who asked to dodge tolls still wants to arrive.
					use_tolls: avoidTolls ? 0.0 : 0.5,
					use_highways: avoidMotorways ? 0.0 : 0.5
				}
			},
			directions_options: { language: route.language, units: route._units }
		}

		_requestRoute(query, !_outsideFirst)
	}

	// `atHome` says who it is asked of. Separated from compute() so it can
	// RETRY with the other one without rebuilding the query.
	//
	// That retry is not an ornament. Without it, any failure of the first one left
	// the application with no routes by ANY path: it was asked, answered wrong, and
	// that was that -- even though the other could have answered easily. A single mistake
	// of mine on the home server took down the internet ones too.
	//
	// It retries ONCE and in the opposite direction, never in a loop: the second
	// failure is a real no and it has to be said, not to keep trying while the
	// driver watches a spinner turn.
	function _requestRoute(query, atHome, alreadyRetried) {
		const destinationUrl = atHome ? localServer + "/route" : publicServer

		// It only makes sense to try the other if the other exists: with no downloaded maps
		// there is nothing at home to fall back on.
		const hasOther = atHome ? true : hasLocal

		const x = new XMLHttpRequest()
		_pending = x
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			route._pending = null

			function giveUp(why) {
				route.status = "error"
				route.failure = why
			}
			function tryTheOther() {
				// NEITHER 'hasLocal' nor 'hasNetwork' is touched here. This particular trip
				// leaves the maps, or this server is down right now;
				// turning off the flag would send ALL the remaining routes of the session
				// the same way, including the ones the other would resolve
				// better. The network state is told by NetworkManager, not by a 404.
				route._requestRoute(query, !atHome, true)
			}

			if (x.status !== 200) {
				if (hasOther && !alreadyRetried) { tryTheOther(); return }
				// status 0 is what an aborted or unreachable request looks
				// like, and "error 0" tells the driver nothing.
				giveUp(x.status === 0 ? qsTr("no connection to the routing server")
					: qsTr("the routing server responded %1").arg(x.status))
				return
			}
			try {
				_read(JSON.parse(x.responseText))
			} catch (e) {
				if (hasOther && !alreadyRetried) { tryTheOther(); return }
				giveUp(qsTr("I could not understand the server response"))
			}
		}
		x.open("GET", destinationUrl + "?json=" + encodeURIComponent(JSON.stringify(query)))
		x.setRequestHeader("User-Agent", userAgent)
		x.send()
	}

	// Pulls up to `howMany` texts from a list in Valhalla's 'sign' field and
	// joins them. Returns "" if there is none, which is what the interface looks at to
	// decide whether to draw the sign or not.
	function _fromSign(sign, items, howMany) {
		if (!sign || !sign[items] || !sign[items].length)
			return ""
		const exitNumber = []
		for (var i = 0; i < sign[items].length && i < howMany; ++i)
			exitNumber.push(String(sign[items][i].text).trim())
		return exitNumber.join(" · ")
	}

	// Adopts an ALREADY calculated route, without requesting it again.
	//
	// The planner uses it: it asked for several at once and the driver chooses
	// one. Requesting it from the server again would be waiting once more for something already
	// in memory -- and against the public server, one extra request each
	// time someone changes their mind between two options.
	//
	// From here on the route is indistinguishable from one requested via compute():
	// same line, same maneuvers, same lanes and limits.
	function adopt(trip, dest, name) {
		if (!trip)
			return
		if (_pending) {
			_pending.abort()
			_pending = null
		}
		destination = dest
		destinationName = name || ""
		failure = ""
		_read({ trip: trip })
	}

	function _read(response) {
		const trip = response.trip
		if (!trip || !trip.legs || trip.legs.length === 0) {
			status = "error"
			failure = qsTr("there is no road to there")
			return
		}

		const segment = trip.legs[0]
		const line = _decode(segment.shape)
		if (line.length < 2) {
			status = "error"
			failure = qsTr("the route came back empty")
			return
		}

		// Distances add up once, here, instead of on every position update.
		const accum = new Array(line.length)
		accum[0] = 0
		for (var i = 1; i < line.length; ++i)
			accum[i] = accum[i - 1] + line[i - 1].distanceTo(line[i])

		const steps = []
		for (var j = 0; j < segment.maneuvers.length; ++j) {
			const m = segment.maneuvers[j]
			steps.push({
				kind: m.type,
				text: m.instruction || "",
				// Valhalla hands the street names over separately, which is
				// what the big line on the driving panel wants: the whole
				// sentence is too long to read at 90 km/h.
				// Only the first two names. A dual carriageway carries up to five
				// synonyms -- "A-7 / E 15 / Autovia de la Mediterrania /
				// Autovia del Mediterraneo / ..." -- and together they filled two
				// lines of the card with the same road said in several
				// ways. Seen on screen.
				street: (m.street_names && m.street_names.length)
					? m.street_names.slice(0, 2).join(" / ") : "",
				meters: (m.length || 0) * route._toMeters,
				seconds: m.time || 0,
				startIndex: m.begin_shape_index || 0,
				// Valhalla writes the phrases to be spoken aloud SEPARATELY, and
				// they are not the same as the written one: the spoken one carries no
				// abbreviations or symbols, which sound terrible. The three are
				// kept because each has its moment.
				warning: m.verbal_transition_alert_instruction || "",
				spoken: m.verbal_pre_transition_instruction || m.instruction || "",
				afterwards: m.verbal_post_transition_instruction || "",
				// Which exit to take. Valhalla says it in the sentence too,
				// but a driver reads a number long before a sentence.
				exitNumber: m.roundabout_exit_count || 0,
				// The motorway exits, from the 'sign' field, which Valhalla
				// returns SEPARATELY and with the pieces split apart. Measured on the A-3
				// leaving Madrid: 10 of 18 maneuvers carry it.
				//
				// It matters to have it loose because the number -- "15AB" -- is the
				// only thing the driver compares with the road's blue
				// sign, and inside the whole sentence it gets lost.
				exitNumber: _fromSign(m.sign, "exit_number_elements", 1),
				// Where it heads. The destination ("Valencia") is preferred over the
				// road number, which is what the sign puts in large type.
				toward: _fromSign(m.sign, "exit_toward_elements", 2)
					|| _fromSign(m.sign, "exit_branch_elements", 2)
			})
		}

		shape = segment.shape
		points = line
		cumulative = accum
		maneuvers = steps
		// The total comes from the LINE, not from summary.length, even though Valhalla
		// says so. They are two different measures of the same thing: the summary comes from the
		// graph edges and the line from the encoded polyline, and they do not match.
		//
		// Measured, Bolnuevo -> Murcia: 77.40 km per the summary and 77.31 per the
		// line. Since progress is measured over the line, those 91 metres of
		// difference were ALWAYS left to travel -- and since arrival requires
		// less than 25 m, the application never declared the journey finished. The
		// simulator found it by driving the whole route.
		//
		// The difference is 0.1 %, so for showing the kilometres it makes
		// no difference which is used; for knowing whether you have arrived, it does.
		totalMeters = accum.length ? accum[accum.length - 1] : 0
		totalSeconds = trip.summary.time || 0
		index = 0
		maneuver = 0
		metersLeft = totalMeters
		secondsLeft = totalSeconds
		metersToManeuver = steps.length > 1 ? accum[steps[1].startIndex] : totalMeters
		status = "items"

		// After the route is accepted, never before: if the second server
		// is slow or fails, the route is already on screen.
		if (destination)
			_requestLanes(line[0], destination)
		_requestLimits(segment.shape)
	}

	// --- surviving a power cut ---------------------------------------------
	// Once a route exists it needs no network at all: the shape and every
	// instruction are already here. What it does NOT survive is the process
	// dying -- and on a phone, in a car, that happens. So it goes to disk.
	function serialize() {
		// The arrays, not `exists`. Called from onStatusChanged, that binding has
		// not been re-evaluated yet and is still false -- the same trap that
		// silently killed frameRoute(), and it silently saved nothing here.
		if (!points || points.length < 2 || !destination || !shape)
			return ""
		return JSON.stringify({
			shape: shape,
			maneuvers: maneuvers,
			meters: totalMeters,
			seconds: totalSeconds,
			lat: destination.latitude,
			lon: destination.longitude,
			name: destinationName,
			when: Date.now()
		})
	}

	// Returns true if a route was rebuilt. `hours` is how stale is too stale:
	// a route from yesterday morning is not the one you are driving now, and
	// silently restoring it would be worse than restoring nothing.
	function restore(text, hours) {
		if (!text)
			return false
		var g
		try {
			g = JSON.parse(text)
		} catch (e) {
			return false
		}
		if (!g || !g.shape || !g.maneuvers || !g.maneuvers.length)
			return false
		if (hours > 0 && Date.now() - (g.when || 0) > hours * 3600 * 1000)
			return false

		const line = _decode(g.shape)
		if (line.length < 2)
			return false
		const accum = new Array(line.length)
		accum[0] = 0
		for (var i = 1; i < line.length; ++i)
			accum[i] = accum[i - 1] + line[i - 1].distanceTo(line[i])

		shape = g.shape
		points = line
		cumulative = accum
		maneuvers = g.maneuvers
		totalMeters = g.meters || 0
		totalSeconds = g.seconds || 0
		destination = QtPositioning.coordinate(g.lat, g.lon)
		destinationName = g.name || ""
		index = 0
		maneuver = 0
		metersLeft = totalMeters
		secondsLeft = totalSeconds
		metersToManeuver = maneuvers.length > 1
			? accum[maneuvers[1].startIndex] : totalMeters
		failure = ""
		status = "items"
		return true
	}

	// Google's polyline, at Valhalla's precision of six decimals.
	function _decode(s) {
		const exitNumber = []
		var i = 0, lat = 0, lon = 0
		while (i < s.length) {
			var b, shift = 0, r = 0
			do { b = s.charCodeAt(i++) - 63; r |= (b & 0x1f) << shift; shift += 5 } while (b >= 0x20)
			lat += (r & 1) ? ~(r >> 1) : (r >> 1)
			shift = 0; r = 0
			do { b = s.charCodeAt(i++) - 63; r |= (b & 0x1f) << shift; shift += 5 } while (b >= 0x20)
			lon += (r & 1) ? ~(r >> 1) : (r >> 1)
			exitNumber.push(QtPositioning.coordinate(lat / 1e6, lon / 1e6))
		}
		return exitNumber
	}

	// Where on the line you are. Called once per fix.
	function locate(where) {
		if (!exists || !where)
			return

		// A long route is thousands of points and this runs every second, so
		// the search starts as a window around where you were. It only falls
		// back to the whole line when that window has nothing plausible in it,
		// which is what happens when you leave the route or the app was in the
		// background while the car kept moving.
		var best = -1, bestD = Number.MAX_VALUE
		const begin = Math.max(0, index - 40)
		const end = Math.min(points.length, index + 400)
		for (var i = begin; i < end; ++i) {
			const d = where.distanceTo(points[i])
			if (d < bestD) { bestD = d; best = i }
		}
		if (bestD > 150) {
			for (var j = 0; j < points.length; ++j) {
				const d2 = where.distanceTo(points[j])
				if (d2 < bestD) { bestD = d2; best = j }
			}
		}
		if (best < 0)
			return

		index = best
		deviation = bestD

		// The current instruction is the last one already begun.
		var m = 0
		for (var k = 0; k < maneuvers.length; ++k) {
			if (maneuvers[k].startIndex <= best)
				m = k
			else
				break
		}
		maneuver = m

		const traveled = cumulative[best]
		metersLeft = Math.max(0, totalMeters - traveled)

		const next = m + 1 < maneuvers.length ? maneuvers[m + 1] : null
		metersToManeuver = next
			? Math.max(0, cumulative[next.startIndex] - traveled) : metersLeft

		// Time left: whole maneuvers still ahead, plus the fraction of the one
		// being driven. Valhalla's own per-step times, not a speed guess.
		var seg = 0
		for (var n = m + 1; n < maneuvers.length; ++n)
			seg += maneuvers[n].seconds
		const current = maneuvers[m]
		if (current.meters > 1)
			seg += current.seconds * Math.min(1, metersToManeuver / current.meters)
		secondsLeft = seg
	}
}
