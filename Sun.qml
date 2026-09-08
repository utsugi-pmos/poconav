// SPDX-License-Identifier: LGPL-2.0-or-later
//
// What time the sun sets here today.
//
// WHY NOT A FIXED TIME. It is the easy way -- "night from eight o'clock" -- and
// it is wrong almost all year. In Murcia the sun sets at 17:50 in December and at
// 21:30 in June: nearly four hours of difference. With a fixed threshold, either
// you drive half an hour in the dark with the white map blinding you, or it turns
// black on you in broad daylight.
//
// So it is calculated, from the position and the date. It is the Nautical Almanac
// algorithm, the same one the sunrise and sunset tables use; it is solved with
// arithmetic and without asking anyone for anything, which is exactly what is
// needed on a phone that may go without coverage.
//
// CIVIL TWILIGHT is used (sun 6 degrees below the horizon) and not the exact set:
// between one and the other there is a long half hour in which you already drive
// with lights and the white map is a nuisance. Asking people when "it is night"
// for driving gives twilight, not the instant the disc disappears.
import QtQuick
import QtPositioning

QtObject {
	id: sol

	// Where you are. Without a position no answer is possible, and it says so.
	property var donde: null
	// Recalculated when the day changes, not on every tick.
	property date cuando: new Date()

	readonly property bool sabemos: donde !== null
		&& donde.isValid !== false && !isNaN(_ocaso)

	// The only thing looked at from outside.
	readonly property bool esDeNoche: sabemos
		&& (_horaAhora < _alba || _horaAhora >= _ocaso)

	// Decimal UTC hours.
	readonly property real _alba: _calcular(true)
	readonly property real _ocaso: _calcular(false)
	readonly property real _horaAhora: cuando.getUTCHours()
		+ cuando.getUTCMinutes() / 60

	// A slow clock: night does not arrive all at once and checking it every minute
	// is overkill. Every five, it is not noticeable and does not wake the
	// processor for nothing.
	property Timer _reloj: Timer {
		interval: 300000
		repeat: true
		running: true
		onTriggered: sol.cuando = new Date()
	}

	// Returns the UTC time of civil dawn or dusk, or NaN if at this date and
	// latitude there is neither -- which really happens: inside the polar circle
	// there are days when the sun neither rises nor sets.
	function _calcular(esAlba) {
		if (!donde)
			return NaN

		const lat = donde.latitude
		const lon = donde.longitude
		const rad = Math.PI / 180

		// Day of the year.
		const inicio = new Date(Date.UTC(cuando.getUTCFullYear(), 0, 1))
		const hoy = new Date(Date.UTC(cuando.getUTCFullYear(),
			cuando.getUTCMonth(), cuando.getUTCDate()))
		const n = Math.floor((hoy - inicio) / 86400000) + 1

		// Approximate time of the event, in days.
		const t = n + ((esAlba ? 6 : 18) - lon / 15) / 24

		// Mean anomaly of the Sun, and its true longitude.
		const M = (0.9856 * t) - 3.289
		var L = M + (1.916 * Math.sin(M * rad)) + (0.020 * Math.sin(2 * M * rad))
			+ 282.634
		L = (L + 360) % 360

		// Right ascension, put in the same quadrant as L.
		var AR = Math.atan(0.91764 * Math.tan(L * rad)) / rad
		AR = (AR + 360) % 360
		AR = AR + (Math.floor(L / 90) - Math.floor(AR / 90)) * 90
		AR = AR / 15

		// Declination.
		const senoDec = 0.39782 * Math.sin(L * rad)
		const cosDec = Math.cos(Math.asin(senoDec))

		// The hour angle. -0.10453 is the cosine of 96 degrees: 90 of the horizon
		// plus the 6 of civil twilight.
		const cosH = (-0.10453 - senoDec * Math.sin(lat * rad))
			/ (cosDec * Math.cos(lat * rad))
		if (cosH > 1 || cosH < -1)
			return NaN            // neither rises nor sets: polar night or day

		var H = Math.acos(cosH) / rad
		if (esAlba)
			H = 360 - H
		H = H / 15

		// Local mean time, and from there to UTC.
		const T = H + AR - (0.06571 * t) - 6.622
		return ((T - lon / 15) % 24 + 24) % 24
	}
}
