// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The lane strip: which lanes take you where you are going.
//
// One cell per lane, left to right as you see them through the windscreen.
// A lane that serves your maneuver is drawn solid; the rest are faded, not
// hidden -- you need to see that there are four lanes and that yours is the
// second, and a strip with the useless ones removed would count wrong.
//
// The data is OSRM's `intersections[].lanes`, because Valhalla does not provide
// any (measured -- see Route.qml). Each lane carries the directions it allows,
// so a single cell can show "straight or right".
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
	id: tira

	// [{ sirve: bool, hacia: ["straight", "right", ...] }]
	property var carriles: []
	property color tinta: "#ffffff"

	visible: carriles && carriles.length > 0
	implicitHeight: Kirigami.Units.gridUnit * 2.6

	// OSRM's words for a direction, turned into an angle. 0 is straight on,
	// positive turns right.
	function _angulo(indicacion) {
		switch (indicacion) {
		case "sharp left": return -135
		case "left": return -90
		case "slight left": return -40
		case "slight right": return 40
		case "right": return 90
		case "sharp right": return 135
		case "uturn": return 180
		default: return 0            // "straight", "none", and whatever it does not know
		}
	}

	RowLayout {
		anchors.centerIn: parent
		height: parent.height
		spacing: Kirigami.Units.smallSpacing

		Repeater {
			model: tira.carriles

			Rectangle {
				id: celda
				Layout.preferredWidth: Kirigami.Units.gridUnit * 2.2
				Layout.preferredHeight: tira.height
				radius: Kirigami.Units.smallSpacing
				// A lane that is no use to you still has to be countable, so it
				// keeps its box and loses its brightness.
				color: modelData.sirve ? Qt.rgba(1, 1, 1, 0.18) : "transparent"
				border.width: 1
				border.color: Qt.rgba(1, 1, 1, modelData.sirve ? 0.55 : 0.18)

				Canvas {
					anchors.fill: parent
					anchors.margins: Kirigami.Units.smallSpacing
					opacity: modelData.sirve ? 1 : 0.35

					onPaint: {
						const ctx = getContext("2d")
						ctx.reset()
						const w = width, h = height
						const lado = Math.min(w, h)
						ctx.strokeStyle = tira.tinta
						ctx.fillStyle = tira.tinta
						ctx.lineWidth = Math.max(2, lado * 0.13)
						ctx.lineCap = "round"
						ctx.lineJoin = "round"

						const hacia = modelData.hacia && modelData.hacia.length
							? modelData.hacia : ["straight"]

						for (var i = 0; i < hacia.length; ++i) {
							const a = tira._angulo(hacia[i]) * Math.PI / 180
							const cx = w / 2, base = h * 0.92
							const codo = h * 0.5
							const largo = lado * 0.34
							const ex = cx + Math.sin(a) * largo
							const ey = codo - Math.cos(a) * largo

							ctx.beginPath()
							ctx.moveTo(cx, base)
							ctx.lineTo(cx, codo)
							ctx.lineTo(ex, ey)
							ctx.stroke()

							// The head, pointing where the lane goes.
							const p = lado * 0.17
							const dx = Math.sin(a), dy = -Math.cos(a)
							ctx.beginPath()
							ctx.moveTo(ex + dx * p, ey + dy * p)
							ctx.lineTo(ex - dx * p * 0.3 - dy * p * 0.8,
								ey - dy * p * 0.3 + dx * p * 0.8)
							ctx.lineTo(ex - dx * p * 0.3 + dy * p * 0.8,
								ey - dy * p * 0.3 - dx * p * 0.8)
							ctx.closePath()
							ctx.fill()
						}
					}

					// A Canvas does not repaint just because the model behind it
					// changed, so the change is watched by hand.
					property var datos: modelData
					onDatosChanged: requestPaint()
					Component.onCompleted: requestPaint()
				}
			}
		}
	}
}
