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
// already carries the legal limit point by point (ruta.limite, from
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

	property var ruta: null
	property bool corriendo: false

	// Where the car is and which way it looks. It is what the application uses
	// instead of the GPS while this is running.
	property var donde: QtPositioning.coordinate(0, 0)
	property real rumbo: 0
	property real velocidad: 0        // m/s, as the GPS gives it

	// How many times faster than reality. At 1 the trip takes as long as it takes,
	// which is what is needed to judge whether a warning arrives on time: sped up,
	// everything seems to arrive late even when it is not true.
	property real prisa: 1

	// How far has been travelled, in metres from the start.
	property real avance: 0

	signal llegado()

	// If the route does not state the limit, 50: it is what applies in the place
	// where most doubt fits, which is inside a village.
	readonly property int limitePorDefecto: 50

	function empezar() {
		if (!ruta || !ruta.hay)
			return
		avance = 0
		velocidad = 0
		_colocar()
		corriendo = true
	}

	function parar() {
		corriendo = false
		velocidad = 0
	}

	readonly property Timer reloj: Timer {
		// At 60 ms the simulator itself IS the smoothing: it delivers interpolated
		// positions more often than the eye can tell apart. At 200 ms it looked
		// jerky because each step fired a 200 ms animation that the next one cut
		// off halfway.
		interval: 60
		repeat: true
		running: sim.corriendo
		onTriggered: sim._paso(0.06)
	}

	function _paso(segundos) {
		if (!ruta || !ruta.hay) {
			parar()
			return
		}

		// The limit of the stretch where the car is NOW. It accelerates and brakes
		// gradually -- 2 m/s2, which is a normal car -- instead of changing all at
		// once: a jump from 120 to 50 in one frame would make the voice warn as if
		// it had braked hard.
		const legal = (ruta.limite > 0 ? ruta.limite : limitePorDefecto) / 3.6
        const dv = 2.0 * segundos
		if (velocidad < legal)
			velocidad = Math.min(legal, velocidad + dv)
		else
			velocidad = Math.max(legal, velocidad - dv)

		avance += velocidad * segundos * prisa

		const total = ruta.acumulado[ruta.acumulado.length - 1]
		if (avance >= total) {
			avance = total
			_colocar()
			parar()
			llegado()
			return
		}
		_colocar()
	}

	// Places the car `avance` metres from the start, interpolating between the two
	// points around it.
	function _colocar() {
		const acum = ruta.acumulado
		const pts = ruta.puntos
		if (!acum || acum.length < 2)
			return

		// Search from where we were, not from the start: this runs five times per
		// second over routes of thousands of points.
		var i = _ultimo
		while (i < acum.length - 1 && acum[i + 1] < avance)
			i += 1
		_ultimo = i

		const a = pts[i]
		const b = pts[Math.min(i + 1, pts.length - 1)]
		const tramo = acum[Math.min(i + 1, acum.length - 1)] - acum[i]
		const t = tramo > 0 ? (avance - acum[i]) / tramo : 0

		donde = QtPositioning.coordinate(
			a.latitude + (b.latitude - a.latitude) * t,
			a.longitude + (b.longitude - a.longitude) * t)

		// The heading, looking a little further ahead than the next point: between
		// two very close points the angle dances, and the map would lurch.
		const lejos = pts[Math.min(i + 6, pts.length - 1)]
		if (lejos !== a)
			rumbo = a.azimuthTo(lejos)
	}

	property int _ultimo: 0
	onCorriendoChanged: if (corriendo) _ultimo = 0
}
