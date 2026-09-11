// SPDX-License-Identifier: LGPL-2.0-or-later
//
// Several routes between two points, so you can choose.
//
// THE IDEA. A navigator that gives only ONE route forces you to accept its rules. If
// you asked to avoid tolls, it takes you through villages twenty minutes longer and does not tell you
// there was a motorway right next to it. Measured, Cartagena -> Vera:
//
//   with toll   110.8 km   69 min
//   no toll     140.8 km   88 min
//
// Nineteen minutes is a decision, and the decision is the driver's. So
// both are shown, with the compliant one first and the other marked.
//
// HOW THEY ARE OBTAINED. Valhalla returns alternatives with `alternates`, but they all
// respect the same preferences: asking for "no tolls" you will never see the toll
// one. TWO requests are needed:
//
//   A  with your filters on         -> the ones that comply
//   B  with your filters relaxed    -> the ones that exist, compliant or not
//
// B is only requested if some filter is active; with no filters there is nothing to
// break and it would be spending double for nothing.
//
// HOW WE KNOW WHAT IT BREAKS. Valhalla's summary carries `has_toll`,
// `has_highway` and `has_ferry` -- verified by reading the keys it returns, not
// assumed. Surface carries NONE: there is no way to ask a route
// whether it goes over dirt without requesting the attributes of each segment, which is another request
// per route.
//
// It is deduced: a route that ONLY appears when the filters are relaxed breaks one
// by construction. If no flag explains it and the dirt filter was
// on, it is that one. It costs not one extra request.
import QtQuick
import QtPositioning

QtObject {
	id: plan

	// What the user asked to avoid.
	property bool avoidTolls: false
	property bool avoidMotorways: false
	property bool avoidFerries: false
	property bool avoidUnpaved: false

	property var origin: null
	property var destination: null
	property string destinationName: ""

	// "", "requesting", "ready", "error"
	property string status: ""
	property string failure: ""

	// How many are shown. Four fit on screen without scrolling, and scrolling
	// a list with the car moving is not something you can ask for.
	readonly property int maxRoutes: 4

	// Cada entry: { trip, minutes, meters, toll, motorway, ferry, unpaved,
	//                 complies, warning, summary }
	property var routes: []
	readonly property bool exists: status === "ready" && routes.length > 0

	readonly property bool hasFilters: avoidTolls || avoidMotorways
		|| avoidFerries || avoidUnpaved

	signal ready()

	// --- request ------------------------------------------------------------

	property var _server: null   // set by whoever uses us: the effective Route.server
	property string localServer: "http://127.0.0.1:8554"
	property string publicServer: "https://valhalla1.openstreetmap.de/route"
	property bool hasLocal: false
	// The same order as in Route.qml, and for the same reasons: the internet is in charge
	// while there is any because it sees this week's closures, and the phone answers
	// when there is none. See the long comment there.
	property bool hasNetwork: app.hasNetwork
	readonly property bool _outsideFirst: hasNetwork || !hasLocal
	readonly property string userAgent: "PocoNav/1.0 (postmarketOS; personal use)"
	property string language: "es-ES"
	// Same treatment as in Route: it is requested in the driver's units and
	// converted to metres on the way in.
	property bool miles: false
	readonly property real _toMeters: miles ? 1609.344 : 1000

	property var _a: null
	property var _b: null
	property var _rawA: null
	property var _rawB: null

	function planRoutes(begin, dest, name) {
		if (!begin || !dest)
			return
		cancel()

		origin = begin
		destination = dest
		destinationName = name || ""
		status = "requesting"
		failure = ""
		routes = []
		_rawA = null
		_rawB = null

		// With the user's filters.
		_a = _request(_query(true), function (r) {
			plan._rawA = r
			plan._maybeFinish()
		}, function (why) {
			// If the compliant one fails, there is nothing to show even if the other
			// arrives: it would be offering only routes the user does not want.
			//
			// The reason is written BEFORE the state, and not the other way round: whoever
			// listens to statusChanged runs at once, and if the state changes
			// first it reads a still-empty reason. The self-test said
			// literally "FAIL plan: " with nothing after it.
			plan.failure = why
			plan.status = "error"
		})

		if (hasFilters) {
			_b = _request(_query(false), function (r) {
				plan._rawB = r
				plan._maybeFinish()
			}, function () {
				// The alternatives that break rules are a bonus. Their failing must
				// not cost the good route.
				plan._rawB = { trip: null }
				plan._maybeFinish()
			})
		}
	}

	// Cancellation goes through the LIST of live requests and not through _a/_b, because the
	// network retry creates a new request: keeping only the first,
	// changing destination while the retry was in flight let a response
	// from the previous trip arrive and be drawn as if it were the new one's.
	property var _inFlight: []

	function cancel() {
		for (var i = 0; i < _inFlight.length; ++i)
			_inFlight[i].abort()
		_inFlight = []
		_a = null
		_b = null
	}

	function _query(withFilters) {
		// 0 is not "forbidden" but "only if there is no other way". A hard
		// ban can answer that there is no route, and whoever asked to avoid tolls
		// still wants to arrive.
		const c = withFilters
		return {
			locations: [
				{ lat: origin.latitude, lon: origin.longitude },
				{ lat: destination.latitude, lon: destination.longitude }
			],
			costing: "auto",
			// Three alternatives per request. With the two requests up to
			// six come out, and from there they are trimmed to the four best.
			alternates: 3,
			costing_options: {
				auto: {
					use_tolls: (c && avoidTolls) ? 0.0 : 0.5,
					use_highways: (c && avoidMotorways) ? 0.0 : 0.5,
					use_ferry: (c && avoidFerries) ? 0.0 : 0.5,
					use_tracks: (c && avoidUnpaved) ? 0.0 : 0.5
				}
			},
			directions_options: { language: language, units: miles ? "miles" : "kilometers" }
		}
	}

	// `atHome` says who it is asked of, and it is separated from the rest so it can
	// RETRY over the network without rebuilding the query -- like in Route.qml.
	//
	// Without that retry the planner gave up as soon as the home server
	// said no, and saying no is normal outside the downloaded regions:
	// asking Murcia -> Paris with only Spain and Andorra gives a 400 in 15 ms.
	// The rule is "no coverage whenever possible, network when there is no other
	// thing", and without this the second half did not exist: with the maps in place, the
	// planner NEVER used the internet, not even when it was the only way.
	//
	// Measured on the phone, with Spain and Andorra downloaded:
	//   Murcia -> Andorra   1443 ms on the phone   (663 km, crosses two regions)
	//   Murcia -> Paris       15 ms   400 "No suitable edges near location"
	// The second is the one now re-requested over the network.
	function _request(query, onOk, onFail, atHome, alreadyRetried) {
		if (atHome === undefined)
			atHome = !_outsideFirst
		const x = new XMLHttpRequest()
		const url = (atHome ? localServer + "/route" : publicServer)
			+ "?json=" + encodeURIComponent(JSON.stringify(query))
		// Like in Route.qml: if the first cannot, the other is tried
		// ONCE, and only if the other exists.
		const hasOther = atHome ? true : hasLocal
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			if (x.status !== 200) {
				if (hasOther && !alreadyRetried) {
					// The flags are NOT touched: this trip leaves the downloaded
					// maps or this server is down now, but the next one
					// may be inside. Turning them off here would send
					// all the remaining routes of the session the same way.
					plan._request(query, onOk, onFail, !atHome, true)
					return
				}
				onFail(x.status === 0 ? qsTr("no connection to the routing server")
					: qsTr("the routing server responded %1").arg(x.status))
				return
			}
			try {
				onOk(JSON.parse(x.responseText))
			} catch (e) {
				// A 200 with garbage inside counts as a failure: the other
				// is tried just as with an error code.
				if (hasOther && !alreadyRetried) {
					plan._request(query, onOk, onFail, !atHome, true)
					return
				}
				onFail(qsTr("I could not understand the server response"))
			}
		}
		x.open("GET", url)
		x.setRequestHeader("User-Agent", userAgent)
		x.send()
		_inFlight.push(x)
		return x
	}

	// --- merge and sort -----------------------------------------------------

	function _maybeFinish() {
		if (status !== "requesting")
			return
		if (!_rawA || (hasFilters && !_rawB))
			return
		_assemble()
	}

	// Pulls the list of trips out of a response: the main one and its alternatives.
	function _trips(response) {
		if (!response || !response.trip)
			return []
		const out = [response.trip]
		const alt = response.alternates || []
		for (var i = 0; i < alt.length; ++i)
			if (alt[i].trip)
				out.push(alt[i].trip)
		return out
	}

	// Two routes are "the same" if they match in distance and time when rounded.
	// The two requests almost always return some duplicate, and showing the
	// same route twice with different labels would be absurd.
	function _key(t) {
		return Math.round(t.summary.length * 10) + "/" + Math.round(t.summary.time)
	}

	function _assemble() {
		const seen = {}
		const items = []

		function add(t, fromCompliant) {
			const k = _key(t)
			if (seen[k])
				return
			seen[k] = true

			const s = t.summary
			const toll = s.has_toll === true
			const motorway = s.has_highway === true
			const ferry = s.has_ferry === true

			// What it breaks, of what the user asked to avoid.
			const broken = []
			if (avoidTolls && toll) broken.push("toll")
			if (avoidMotorways && motorway) broken.push("motorway")
			if (avoidFerries && ferry) broken.push("ferry")

			// Dirt by elimination: it comes from the relaxed group and no flag
			// explains it, so the filter it breaks can only be that one.
			const unpaved = !fromCompliant && avoidUnpaved && broken.length === 0
			if (unpaved) broken.push("unpaved")

			items.push({
				trip: t,
				minutes: Math.round(s.time / 60),
				meters: s.length * _toMeters,
				toll: toll,
				motorway: motorway,
				ferry: ferry,
				unpaved: unpaved,
				complies: fromCompliant && broken.length === 0,
				warning: broken,
				summary: _viaWhich(t)
			})
		}

		const compliant = _trips(_rawA)
		for (var i = 0; i < compliant.length; ++i)
			add(compliant[i], true)
		const others = _trips(_rawB)
		for (var j = 0; j < others.length; ++j)
			add(others[j], false)

		// First the ones that respect your criteria, and within each group the one that
		// gets you there soonest. A toll one never comes on top if you asked to avoid them.
		items.sort(function (a, b) {
			if (a.complies !== b.complies)
				return a.complies ? -1 : 1
			return a.minutes - b.minutes
		})

		routes = items.slice(0, maxRoutes)
		status = "ready"
		ready()
	}

	// "via A-30 and RM-2": the named roads you spend the most time on. Without
	// this, four rows that differ by only two minutes are
	// indistinguishable.
	function _viaWhich(t) {
		const byRoad = {}
		const legs = t.legs || []
		for (var i = 0; i < legs.length; ++i) {
			const ms = legs[i].maneuvers || []
			for (var j = 0; j < ms.length; ++j) {
				const names = ms[j].street_names
				if (!names || !names.length)
					continue
				const v = String(names[0])
				byRoad[v] = (byRoad[v] || 0) + (ms[j].time || 0)
			}
		}
		const order = Object.keys(byRoad).sort(function (a, b) {
			return byRoad[b] - byRoad[a]
		})
		if (!order.length)
			return ""
		return qsTr("via %1").arg(order.slice(0, 2).join(qsTr(" and ")))
	}
}
