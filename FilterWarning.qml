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
	id: aviso

	readonly property var p: Theme

	property var entrada: null
	property int minutosMejor: 0     // the best one that DOES comply, for comparison

	signal aceptado(var entrada)
	signal cancelado()

	visible: false
	anchors.fill: parent

	function preguntar(cual, minutosDeLaQueCumple) {
		entrada = cual
		minutosMejor = minutosDeLaQueCumple || 0
		visible = true
	}

	function _lista() {
		if (!entrada)
			return ""
		const nombres = {
			peaje: qsTr("toll"), autopista: qsTr("motorway"),
			ferri: qsTr("ferry"), tierra: qsTr("unpaved sections")
		}
		const fuera = []
		for (var i = 0; i < entrada.aviso.length; ++i)
			fuera.push(nombres[entrada.aviso[i]] || entrada.aviso[i])
		if (fuera.length === 1)
			return fuera[0]
		return qsTr("%1 and %2").arg(fuera.slice(0, -1).join(", "))
			.arg(fuera[fuera.length - 1])
	}

	// What you gain by breaking the filter. It is the fact that turns the question
	// into a decision: without it, "has a toll" does not say whether it is worth it.
	function _gana() {
		if (!entrada || minutosMejor <= 0)
			return ""
		const d = minutosMejor - entrada.minutos
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
		height: cuerpo.implicitHeight + Kirigami.Units.largeSpacing * 3
		radius: aviso.p.radioGrande
		color: aviso.p.fondo

		ColumnLayout {
			id: cuerpo
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
					color: aviso.p.ambar
					QQC2.Label {
						anchors.centerIn: parent
						text: "!"
						font.bold: true
						font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.4
						color: aviso.p.tintaOscura
					}
				}

				QQC2.Label {
					Layout.fillWidth: true
					text: qsTr("This route includes %1").arg(aviso._lista())
					color: aviso.p.tinta
					font.bold: true
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.15
					wrapMode: Text.WordWrap
				}
			}

			QQC2.Label {
				Layout.fillWidth: true
				text: qsTr("You asked to avoid it. %1").arg(aviso._gana())
				color: aviso.p.tintaSuave
				wrapMode: Text.WordWrap
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: Kirigami.Units.largeSpacing

				QQC2.AbstractButton {
					id: cancelar
					Layout.fillWidth: true
					Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
					onClicked: { aviso.visible = false; aviso.cancelado() }
					background: Rectangle {
						radius: height / 2
						// This is the highlighted one: going back to the list is
						// what the driver had already asked for.
						color: cancelar.pressed ? aviso.p.azulCasco : aviso.p.azul
					}
					contentItem: QQC2.Label {
						text: qsTr("Choose another")
						color: aviso.p.blanco
						font.bold: true
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}

				QQC2.AbstractButton {
					id: seguir
					Layout.fillWidth: true
					Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
					onClicked: {
						aviso.visible = false
						aviso.aceptado(aviso.entrada)
					}
					background: Rectangle {
						radius: height / 2
						color: seguir.pressed ? aviso.p.fondoAlto : "transparent"
						border.width: 1
						border.color: aviso.p.tintaSuave
					}
					contentItem: QQC2.Label {
						text: qsTr("Continue anyway")
						color: aviso.p.tinta
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}
			}
		}
	}
}
