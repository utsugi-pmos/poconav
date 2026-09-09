// SPDX-License-Identifier: LGPL-2.0-or-later
//
// "This route has a toll. Shall we continue?"
//
// It appears on STARTING a route that breaks something you asked to avoid, not on
// tapping it in the list. Tapping a row only paints it on the map, and if the
// warning fired on every tap you could not compare two routes without fighting a
// dialog.
//
// The continue button is NOT the highlighted one. Whoever asked to avoid tolls
// already said what they wanted; what is being offered is a change of mind, and
// that is accepted on purpose, not by inertia from hitting the usual big button.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
	id: warning

	readonly property var p: Theme

	property var entry: null
	property int bestMinutes: 0     // the best one that DOES comply, for comparison

	signal accepted(var entry)
	signal cancelled()

	visible: false
	anchors.fill: parent

	function ask(which, compliantMinutes) {
		entry = which
		bestMinutes = compliantMinutes || 0
		visible = true
	}

	function _broken() {
		if (!entry)
			return ""
		const names = {
			toll: qsTr("toll"), motorway: qsTr("motorway"),
			ferry: qsTr("ferry"), unpaved: qsTr("unpaved sections")
		}
		const out = []
		for (var i = 0; i < entry.warning.length; ++i)
			out.push(names[entry.warning[i]] || entry.warning[i])
		if (out.length === 1)
			return out[0]
		return qsTr("%1 and %2").arg(out.slice(0, -1).join(", "))
			.arg(out[out.length - 1])
	}

	// What you gain by breaking the filter. It is the fact that turns the question
	// into a decision: without it, "has a toll" does not say whether it is worth it.
	function _gain() {
		if (!entry || bestMinutes <= 0)
			return ""
		const d = bestMinutes - entry.minutes
		if (d <= 0)
			return ""
		return d < 60 ? qsTr("You arrive %1 min earlier.").arg(d)
			: qsTr("You arrive %1 h %2 earlier.").arg(Math.floor(d / 60)).arg(d % 60)
	}

	// It swallows taps outside so they do not reach the map below, but does NOT
	// close: a question with two ways out is answered, not dodged.
	MouseArea { anchors.fill: parent }

	Rectangle {
		anchors.fill: parent
		color: "#000000"
		opacity: 0.6
	}

	Rectangle {
		anchors.centerIn: parent
		width: Math.min(parent.width - Kirigami.Units.largeSpacing * 4,
			Kirigami.Units.gridUnit * 26)
		height: body.implicitHeight + Kirigami.Units.largeSpacing * 3
		radius: warning.p.cornerRadiusLarge
		color: warning.p.surface

		ColumnLayout {
			id: body
			anchors.fill: parent
			anchors.margins: Kirigami.Units.largeSpacing * 1.5
			spacing: Kirigami.Units.largeSpacing

			RowLayout {
				Layout.fillWidth: true
				spacing: Kirigami.Units.largeSpacing

				Rectangle {
					Layout.preferredWidth: Kirigami.Units.gridUnit * 2.4
					Layout.preferredHeight: Kirigami.Units.gridUnit * 2.4
					radius: width / 2
					color: warning.p.amber
					QQC2.Label {
						anchors.centerIn: parent
						text: "!"
						font.bold: true
						font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.4
						color: warning.p.inkDark
					}
				}

				QQC2.Label {
					Layout.fillWidth: true
					text: qsTr("This route includes %1").arg(warning._broken())
					color: warning.p.ink
					font.bold: true
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.15
					wrapMode: Text.WordWrap
				}
			}

			QQC2.Label {
				Layout.fillWidth: true
				text: qsTr("You asked to avoid it. %1").arg(warning._gain())
				color: warning.p.inkSoft
				wrapMode: Text.WordWrap
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: Kirigami.Units.largeSpacing

				QQC2.AbstractButton {
					id: cancel
					Layout.fillWidth: true
					Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
					onClicked: { warning.visible = false; warning.cancelled() }
					background: Rectangle {
						radius: height / 2
						// This is the highlighted one: going back to the list is
						// what the driver had already asked for.
						color: cancel.pressed ? warning.p.blueCasing : warning.p.blue
					}
					contentItem: QQC2.Label {
						text: qsTr("Choose another")
						color: warning.p.white
						font.bold: true
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}

				QQC2.AbstractButton {
					id: follow
					Layout.fillWidth: true
					Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
					onClicked: {
						warning.visible = false
						warning.accepted(warning.entry)
					}
					background: Rectangle {
						radius: height / 2
						color: follow.pressed ? warning.p.surfaceHigh : "transparent"
						border.width: 1
						border.color: warning.p.inkSoft
					}
					contentItem: QQC2.Label {
						text: qsTr("Continue anyway")
						color: warning.p.ink
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}
			}
		}
	}
}
