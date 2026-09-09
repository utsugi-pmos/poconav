// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The panel you read at 90 km/h, shaped like the one drivers already know.
//
// Two blocks, always, in both orientations:
//
//   the BLUE card    what you are about to do -- arrow, metres, street
//   the DARK strip   what is left -- speed, distance, arrival, and Exit
//
// That split is Google Maps' driving mode, and it is copied deliberately: the
// blue block means "the instruction" to anyone who has ever used a phone in a
// car, before they read a single word of it. Colours live in Theme.qml.
//
// Everything here is sized for a glance, not for reading: the distance to the
// next turn is the biggest thing on the screen, the street name comes second,
// and the full sentence is last because nobody finishes it while driving.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
	id: panel

	property var route: null
	property bool landscape: true
	// Metres per second, negative when the GPS is not reporting it.
	property real speed: -1
	// The legal limit in km/h. 0 = unknown.
	property int limit: 0

	// What the speedometer reads, in the driver's unit. Internally speed always
	// arrives in m/s and the limit in km/h.
	readonly property int kmh: speed >= 0
		? Math.round(speed * (miles ? 2.23694 : 3.6)) : -1
	readonly property int shownLimit: miles
		? Math.round(limit / 1.609344) : limit
	readonly property string speedUnit: miles ? "mph" : "km/h"
	// Five of margin: speedometers read high and the GPS wavers, and a sign that
	// lights up on its own at 51 on a 50 road ends up being ignored.
	readonly property bool speeding: limit > 0 && kmh > limit + 5

	signal exit()

	readonly property var p: Theme

	readonly property var maneuver: (route && route.exists
		&& route.maneuver < route.maneuvers.length)
		? route.maneuvers[route.maneuver] : null
	// What you are about to do, not what you are doing: the panel must show the
	// NEXT instruction while you drive the current one.
	readonly property var next: (route && route.exists
		&& route.maneuver + 1 < route.maneuvers.length)
		? route.maneuvers[route.maneuver + 1] : null
	readonly property var shown: next ? next : maneuver

	// So that whoever lays us out knows there is one more row to fit. In portrait
	// the strip is a fixed height, and without this the lane strip spilled off
	// the bottom, cut in half.
	readonly property bool withLanes: !!(shown && shown.lanes
		&& shown.lanes.length > 0)

	// --- distances, in whatever the driver uses -----------------------------
	// Internally EVERYTHING is metres; here and only here it is turned into what
	// gets read.
	//
	// In miles, FEET are used below 0.1 mile and not yards: it is what navigators
	// say in the USA and what people expect to hear. The cut is at 528 feet,
	// which is half a mile divided by five -- round in their system, ugly in
	// ours, and that is why dividing by a thousand does not work.
	property bool miles: false

	function _dist(m) {
		if (miles) {
			const mi = m / 1609.344
			if (mi < 0.1)
				return Math.round(m * 3.28084 / 10) * 10 + " ft"
			return mi.toFixed(mi < 10 ? 1 : 0).replace(".", ",") + " mi"
		}
		if (m < 1000)
			// Rounded to 10 m: the last digit changes faster than anyone can
			// read it and makes the number look broken.
			return Math.round(m / 10) * 10 + " m"
		return (m / 1000).toFixed(m < 10000 ? 1 : 0).replace(".", ",") + " km"
	}

	function distance(m) { return _dist(m) }

	function duration(s) {
		const min = Math.round(s / 60)
		if (min < 60)
			return min + " min"
		const h = Math.floor(min / 60)
		return h + " h " + ("0" + (min - h * 60)).slice(-2)
	}

	function arrival(s) {
		const t = new Date(new Date().getTime() + s * 1000)
		return ("0" + t.getHours()).slice(-2) + ":" + ("0" + t.getMinutes()).slice(-2)
	}

	// Valhalla's maneuver types, turned into one angle. The numbers are its own
	// enum; the ones not named here are all "carry on".
	function angle(kind) {
		switch (kind) {
		case 9: case 18: case 20: case 23: case 2: case 5: case 37: return 45
		case 10: return 90
		case 11: return 135
		case 12: case 13: return 180
		case 14: return -135
		case 15: return -90
		case 16: case 19: case 21: case 24: case 3: case 6: case 38: return -45
		default: return 0
		}
	}

	function isDestination(kind) {
		return kind === 4 || kind === 5 || kind === 6
	}

	function isRoundabout(kind) {
		return kind === 26 || kind === 27
	}

	// --- the blue card ----------------------------------------------------
	Rectangle {
		id: card

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: summary.top
		color: panel.p.blue

		GridLayout {
			// Centred, not stuck to the top. With the elastic gap from before,
			// in landscape there were 200 px of empty blue below the instruction
			// and the card looked half done.
			//
			// But not fully centred either: in landscape the phone sits on the
			// dashboard and the gaze falls higher than the geometric centre of
			// the screen. It is raised by an eighth of the card's height, which
			// is enough to notice without leaving dead space below.
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			anchors.verticalCenterOffset: panel.landscape
				? -Math.round(parent.height / 8) : 0
			anchors.margins: Kirigami.Units.largeSpacing
			// Landscape stacks the arrow over the words; portrait lays them out
			// sideways so the card stays a band and does not eat the map.
			columns: panel.landscape ? 1 : 2
			rowSpacing: Kirigami.Units.smallSpacing
			columnSpacing: Kirigami.Units.largeSpacing

			ManeuverArrow {
				Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
				Layout.preferredWidth: panel.landscape
					? Math.min(panel.width * 0.42, Kirigami.Units.gridUnit * 7)
					: Math.min(card.height * 0.72, Kirigami.Units.gridUnit * 5)
				Layout.preferredHeight: Layout.preferredWidth
				visible: panel.shown !== null
				ink: panel.p.white
				turn: panel.shown ? panel.angle(panel.shown.kind) : 0
				roundabout: panel.shown ? panel.isRoundabout(panel.shown.kind) : false
				destination: panel.shown ? panel.isDestination(panel.shown.kind) : false
				exitNumber: panel.shown ? (panel.shown.exitNumber || 0) : 0
			}

			ColumnLayout {
				Layout.fillWidth: true
				Layout.alignment: Qt.AlignVCenter
				spacing: 0

				QQC2.Label {
					Layout.fillWidth: true
					horizontalAlignment: panel.landscape ? Text.AlignHCenter : Text.AlignLeft
					text: route && route.exists ? panel.distance(route.metersToManeuver) : ""
					color: panel.p.white
					font.bold: true
					// The single biggest thing on the screen, deliberately.
					font.pointSize: Kirigami.Theme.defaultFont.pointSize
						* (panel.landscape ? 3.0 : 2.2)
				}

				// The exit number, in its box. It is the only thing the driver
				// compares letter by letter with the road sign, so it stands on
				// its own and large instead of lost inside the sentence.
				Rectangle {
					Layout.alignment: panel.landscape ? Qt.AlignHCenter : Qt.AlignLeft
					Layout.preferredWidth: exitLabel.implicitWidth
						+ Kirigami.Units.largeSpacing * 2
					Layout.preferredHeight: exitLabel.implicitHeight
						+ Kirigami.Units.smallSpacing * 2
					Layout.topMargin: Kirigami.Units.smallSpacing
					Layout.bottomMargin: Kirigami.Units.smallSpacing
					visible: panel.shown && panel.shown.exitNumber
					radius: Kirigami.Units.smallSpacing
					color: panel.p.white

					QQC2.Label {
						id: exitLabel
						anchors.centerIn: parent
						text: "Exit " + (panel.shown ? panel.shown.exitNumber : "")
						color: panel.p.blue
						font.bold: true
						font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.4
					}
				}

				QQC2.Label {
					id: mainLine
					Layout.fillWidth: true
					horizontalAlignment: panel.landscape ? Text.AlignHCenter : Text.AlignLeft
					visible: text.length > 0
					// At an exit the DESTINATION rules, not the road name: at
					// "Exit 16" what you look for on the sign is "Alicante", not
					// the five names of the motorway. Away from an exit it is the
					// other way round.
					text: {
						if (!panel.shown)
							return ""
						if (panel.shown.exitNumber)
							return panel.shown.toward || panel.shown.street || ""
						return panel.shown.street || panel.shown.toward || ""
					}
					color: panel.p.white
					// Larger in landscape than in portrait: in landscape the card
					// takes a whole column and there is room, and it is the text
					// that must be read at a glance without looking away from the
					// road. In portrait the card is a narrow band and enlarging it
					// would only eat map.
					font.pointSize: Kirigami.Theme.defaultFont.pointSize
						* (panel.landscape ? 1.8 : 1.5)
					wrapMode: Text.WordWrap
					maximumLineCount: 2
					elide: Text.ElideRight
				}

				QQC2.Label {
					Layout.fillWidth: true
					Layout.topMargin: Kirigami.Units.smallSpacing
					horizontalAlignment: panel.landscape ? Text.AlignHCenter : Text.AlignLeft
					// Always in landscape; in portrait only when there is nothing
					// better to show. There are maneuvers with no street name and
					// no destination -- "Keep left at the fork" -- and without
					// this the band was left with an arrow and some metres, saying
					// nothing about what it was. Seen on screen.
					visible: text.length > 0
						&& (panel.landscape || mainLine.text.length === 0)
					text: panel.shown ? panel.shown.text : ""
					color: panel.p.white
					// The instruction itself -- "Turn left" -- larger and less
					// dimmed in landscape. It is the sentence that says WHAT to
					// do: the metres say when, but if the action is not read, the
					// number is useless. In portrait it is left as it was, where
					// the band is narrow.
					font.pointSize: Kirigami.Theme.defaultFont.pointSize
						* (panel.landscape ? 1.25 : 1.0)
					opacity: panel.landscape ? 0.92 : 0.75
					wrapMode: Text.WordWrap
					maximumLineCount: 3
					elide: Text.ElideRight
				}
			}

			// Which lanes take you where you are going. Only appears when both
			// routers agreed on this junction -- see Route.qml.
			Lanes {
				Layout.fillWidth: true
				Layout.columnSpan: panel.landscape ? 1 : 2
				Layout.topMargin: Kirigami.Units.smallSpacing
				lanes: panel.shown && panel.shown.lanes
					? panel.shown.lanes : []
				ink: panel.p.white
			}

			// Off route. Amber on blue, so it cannot be mistaken for part of
			// the instruction.
			Rectangle {
				Layout.fillWidth: true
				Layout.columnSpan: panel.landscape ? 1 : 2
				Layout.preferredHeight: Kirigami.Units.gridUnit * 2
				visible: route && route.offRoute
				radius: height / 2
				color: panel.p.amber

				QQC2.Label {
					anchors.centerIn: parent
					text: qsTr("Off route")
					color: panel.p.inkDark
					font.bold: true
				}
			}

		}
	}

	// --- the dark strip ---------------------------------------------------
	Rectangle {
		id: summary

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: Kirigami.Units.gridUnit * 4.6
		color: panel.p.surface

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: Kirigami.Units.largeSpacing * 1.5
			anchors.rightMargin: Kirigami.Units.largeSpacing
			spacing: Kirigami.Units.largeSpacing

			// Arrival time first and in green, exactly where a driver already
			// looks for it.
			ColumnLayout {
				spacing: 0
				QQC2.Label {
					text: route && route.exists ? panel.arrival(route.secondsLeft) : "—"
					color: panel.p.green
					font.bold: true
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.7
				}
				QQC2.Label {
					text: route && route.exists
						? panel.duration(route.secondsLeft) + " · "
							+ panel.distance(route.metersLeft) : ""
					color: panel.p.inkSoft
					font.pointSize: Kirigami.Theme.smallFont.pointSize
				}
			}

			Item { Layout.fillWidth: true }

			// The sign, round and with a red ring, like the one on the road. It
			// only appears where the limit is known: inventing one would be worse
			// than not showing it.
			Rectangle {
				Layout.preferredWidth: Kirigami.Units.gridUnit * 2.6
				Layout.preferredHeight: width
				Layout.alignment: Qt.AlignVCenter
				visible: panel.limit > 0
				radius: width / 2
				color: panel.p.white
				border.width: Math.round(width * 0.13)
				border.color: panel.p.red

				QQC2.Label {
					anchors.centerIn: parent
					text: panel.shownLimit
					color: panel.p.inkDark
					font.bold: true
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.25
				}
			}

			ColumnLayout {
				spacing: 0
				visible: panel.kmh >= 0
				QQC2.Label {
					Layout.alignment: Qt.AlignHCenter
					text: panel.kmh
					// Red when you go over: it is the only place on the panel
					// where the colour changes because of something you are doing
					// wrong.
					color: panel.speeding ? panel.p.red : panel.p.ink
					font.bold: true
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.7
				}
				QQC2.Label {
					Layout.alignment: Qt.AlignHCenter
					text: panel.speedUnit
					color: panel.p.inkSoft
					font.pointSize: Kirigami.Theme.smallFont.pointSize
				}
			}

			// Big, and the only button on this panel: nothing else here should
			// be reachable by accident while driving.
			QQC2.AbstractButton {
				id: exitButton
				Layout.preferredWidth: Kirigami.Units.gridUnit * 5.5
				Layout.preferredHeight: Kirigami.Units.gridUnit * 3
				onClicked: panel.exit()

				background: Rectangle {
					radius: height / 2
					color: exitButton.pressed ? panel.p.inkSoft : panel.p.surfaceHigh
				}

				contentItem: QQC2.Label {
					text: qsTr("Exit")
					color: panel.p.ink
					horizontalAlignment: Text.AlignHCenter
					verticalAlignment: Text.AlignVCenter
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.1
				}
			}
		}
	}
}
