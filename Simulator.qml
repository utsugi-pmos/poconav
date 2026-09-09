// SPDX-License-Identifier: LGPL-2.0-or-later
//
// A pretend car running along the route, to see how the application behaves
// without going out to drive.
//
// WHY IT IS NEEDED. Everything that happens while driving -- the maneuver
// advancing on time, the voice warning with just the right lead, the map turning
// and following the car, the lanes appearing where they should -- can ONLY be
// judged in motion. And with the phone on the table the GPS always gives the same
// point, so that half of the application could not be looked at.
//
// AT WHAT SPEED. At the one each stretch allows, not a fixed one: the route
// already carries the legal limit point by point (route.limit, from
// trace_attributes), so the car accelerates on the motorway and brakes on
// entering the village. A simulator at a constant 50 km/h would pass as good
// warnings that on the motorway arrive late.
//
// It moves by INTERPOLATION between the points of the line, not jumping from one
// to another: the points are at very uneven distances -- close together on
// roundabouts, far apart on the straight -- and jumping between them would give
// jerks and false speeds.
import QtQuick
import QtPositioning

QtObject {
	id: sim

	property var route: null
	property bool running: false

	// Where the car is and which way it looks. It is what the application uses
	// instead of the GPS while this is running.
	property var where: QtPositioning.coordinate(0, 0)
	property real heading: 0
	property real speed: 0        // m/s, as the GPS gives it

	// How many times faster than reality. At 1 the trip takes as long as it takes,
	// which is what is needed to judge whether a warning arrives on time: sped up,
	// everything seems to arrive late even when it is not true.
	property real haste: 1

	// How far has been travelled, in metres from the start.
	property real advance: 0

	signal arrived()

	// If the route does not state the limit, 50: it is what applies in the place
	// where most doubt fits, which is inside a village.
	readonly property int defaultLimit: 50

	function start() {
		if (!route || !route.exists)
			return
		advance = 0
		speed = 0
		_place()
		running = true
	}

	function stop() {
		running = false
		speed = 0
	}

	readonly property Timer clock: Timer {
		// At 60 ms the simulator itself IS the smoothing: it delivers interpolated
		// positions more often than the eye can tell apart. At 200 ms it looked
		// jerky because each step fired a 200 ms animation that the next one cut
		// off halfway.
		interval: 60
		repeat: true
		running: sim.running
		onTriggered: sim._step(0.06)
	}

	function _step(seconds) {
		if (!route || !route.exists) {
			stop()
			return
		}

		// The limit of the stretch where the car is NOW. It accelerates and brakes
		// gradually -- 2 m/s2, which is a normal car -- instead of changing all at
		// once: a jump from 120 to 50 in one frame would make the voice warn as if
		// it had braked hard.
		const legal = (route.limit > 0 ? route.limit : defaultLimit) / 3.6
        const dv = 2.0 * seconds
		if (speed < legal)
			speed = Math.min(legal, speed + dv)
		else
			speed = Math.max(legal, speed - dv)

		advance += speed * seconds * haste

		const total = route.cumulative[route.cumulative.length - 1]
		if (advance >= total) {
			advance = total
			_place()
			stop()
			arrived()
			return
		}
		_place()
	}

	// Places the car `advance` metres from the start, interpolating between the two
	// points around it.
	function _place() {
		const accum = route.cumulative
		const pts = route.points
		if (!accum || accum.length < 2)
			return

		// Search from where we were, not from the start: this runs five times per
		// second over routes of thousands of points.
		var i = _last
		while (i < accum.length - 1 && accum[i + 1] < advance)
			i += 1
		_last = i

		const a = pts[i]
		const b = pts[Math.min(i + 1, pts.length - 1)]
		const segment = accum[Math.min(i + 1, accum.length - 1)] - accum[i]
		const t = segment > 0 ? (advance - accum[i]) / segment : 0

		where = QtPositioning.coordinate(
			a.latitude + (b.latitude - a.latitude) * t,
			a.longitude + (b.longitude - a.longitude) * t)

		// The heading, looking a little further ahead than the next point: between
		// two very close points the angle dances, and the map would lurch.
		const far = pts[Math.min(i + 6, pts.length - 1)]
		if (far !== a)
			heading = a.azimuthTo(far)
	}

	property int _last: 0
	onRunningChanged: if (running) _last = 0
}
