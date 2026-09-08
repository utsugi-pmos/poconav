// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The turn arrow, drawn rather than borrowed.
//
// Breeze has no maneuver arrows. Everything that looked like a candidate --
// arrow-up, go-up, draw-arrow-up, arrow-up-double -- is a thin chevron, and a
// chevron rotated 90 degrees reads as a bracket, not as "turn left". Rendered
// side by side at 96 px they were all unusable; that is why this file exists.
//
// A Canvas and not QtQuick.Shapes: no extra import to depend on, and repainting
// only happens when the maneuver changes, which is a few times per journey.
import QtQuick

Canvas {
	id: flecha

	// 0 is straight on, positive turns right, negative left, 180 is a U-turn.
	property real giro: 0
	property bool rotonda: false
	property bool destino: false
	// Which exit off the roundabout. 0 means Valhalla did not say.
	property int salida: 0
	property color tinta: "white"

	onGiroChanged: requestPaint()
	onRotondaChanged: requestPaint()
	onDestinoChanged: requestPaint()
	onSalidaChanged: requestPaint()
	onTintaChanged: requestPaint()
	onWidthChanged: requestPaint()
	onHeightChanged: requestPaint()

	function _punta(ctx, x, y, angulo, tam) {
		// Filled triangle pointing along `angulo`, measured like a compass:
		// 0 is up, 90 is right.
		const a = angulo * Math.PI / 180
		const dx = Math.sin(a), dy = -Math.cos(a)
		// Perpendicular, for the two back corners.
		const px = -dy, py = dx
		ctx.beginPath()
		ctx.moveTo(x + dx * tam, y + dy * tam)
		ctx.lineTo(x - dx * tam * 0.35 + px * tam * 0.75,
			y - dy * tam * 0.35 + py * tam * 0.75)
		ctx.lineTo(x - dx * tam * 0.35 - px * tam * 0.75,
			y - dy * tam * 0.35 - py * tam * 0.75)
		ctx.closePath()
		ctx.fill()
	}

	onPaint: {
		const ctx = getContext("2d")
		ctx.reset()

		const w = width, h = height
		const lado = Math.min(w, h)
		const cx = w / 2
		const grosor = lado * 0.11
		const punta = lado * 0.15

		ctx.strokeStyle = tinta
		ctx.fillStyle = tinta
		ctx.lineWidth = grosor
		ctx.lineCap = "round"
		ctx.lineJoin = "round"

		if (destino) {
			// A ring with a dot in it. Not a flag: a flag has a side, and the
			// side would be a lie half the time.
			ctx.beginPath()
			ctx.arc(cx, h / 2, lado * 0.30, 0, Math.PI * 2)
			ctx.stroke()
			ctx.beginPath()
			ctx.arc(cx, h / 2, lado * 0.11, 0, Math.PI * 2)
			ctx.fill()
			return
		}

		if (rotonda) {
			// The ring you go round, the road you came in by, and the exit.
			//
			// The exit is drawn at a fixed angle, NOT at the real one: Valhalla
			// gives the exit NUMBER but not its bearing, and inventing an angle
			// would be worse than admitting there is none. What the driver
			// needs is the number, so the number goes in the middle of the
			// ring, where it is the biggest thing in the glyph.
			const r = lado * 0.30
			const cy = h * 0.44
			ctx.beginPath()
			ctx.arc(cx, cy, r, 0, Math.PI * 2)
			ctx.stroke()

			ctx.beginPath()
			ctx.moveTo(cx, h * 0.95)
			ctx.lineTo(cx, cy + r)
			ctx.stroke()

			const a = 55 * Math.PI / 180
			const sx = cx + Math.sin(a) * r, sy = cy - Math.cos(a) * r
			const ex = cx + Math.sin(a) * (r + lado * 0.20)
			const ey = cy - Math.cos(a) * (r + lado * 0.20)
			ctx.beginPath()
			ctx.moveTo(sx, sy)
			ctx.lineTo(ex, ey)
			ctx.stroke()
			_punta(ctx, ex, ey, 55, punta)

			if (salida > 0) {
				ctx.font = "bold " + Math.round(lado * 0.34) + "px sans-serif"
				ctx.textAlign = "center"
				ctx.textBaseline = "middle"
				ctx.fillText(String(salida), cx, cy)
			}
			return
		}

		if (Math.abs(giro) >= 175) {
			// A U-turn drawn as two segments would fold back over its own
			// stem and be unreadable, so it gets a real half circle.
			const r = lado * 0.20
			const cy = h * 0.42
			ctx.beginPath()
			ctx.moveTo(cx - r, h * 0.95)
			ctx.lineTo(cx - r, cy)
			ctx.arc(cx, cy, r, Math.PI, 0, false)
			ctx.lineTo(cx + r, h * 0.72)
			ctx.stroke()
			_punta(ctx, cx + r, h * 0.72 + punta * 0.2, 180, punta)
			return
		}

		// Everything else: a stem, one rounded corner, and a head. Two straight
		// segments read better at a glance than a curve, and the round join
		// keeps it from looking like a diagram.
		// A sharp turn doubles back, so its head lands next to its own stem.
		// Raising the elbow and shortening the blade buys the clearance that
		// keeps the two from touching.
		const cerrada = Math.abs(giro) > 100
		const codo = h * (cerrada ? 0.42 : 0.52)
		const largo = lado * (cerrada ? 0.30 : 0.34)
		const a = giro * Math.PI / 180
		const ex = cx + Math.sin(a) * largo
		const ey = codo - Math.cos(a) * largo

		ctx.beginPath()
		ctx.moveTo(cx, h * 0.95)
		ctx.lineTo(cx, codo)
		ctx.lineTo(ex, ey)
		ctx.stroke()
		_punta(ctx, ex, ey, giro, punta)
	}
}
