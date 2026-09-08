// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The list of routes to choose from, next to the map.
//
// Landscape goes on the left and the map on the right; portrait, on top with the map
// below. Whoever places us lays it out, not us: here we only fill the
// gap we are given.
//
// WHAT IS SHOWN OF EACH ROUTE, and why that order of importance:
//
//   the time     large, because it is what you really compare
//   the km       below, smaller
//   which way    "via A-7 and RM-2" -- without this, four rows differing
//                by two minutes are indistinguishable
//   the warning  if it breaks something you asked to avoid, with its word
//
// The warning carries a WORD and not just a picture. A toll icon you have to
// learn; "toll" in amber you do not have to learn, and this is read with the
// car stopped but in a hurry.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
	id: panel

	readonly property var p: Theme

	// The side margin for EVERYTHING in this panel: the title, the rows and the
	// buttons fall in the same column. largeSpacing alone fell short and
	// the route text came out flush to the edge of its own row.
	readonly property int margen: Math.round(Kirigami.Units.gridUnit * 1.1)

	// THE PANEL PAINTS ITS OWN BACKGROUND, and this is not decoration.
	//
	// It did not paint it: it relied on whatever was behind. In the portraits, which
	// are made with no graphical session, black was behind and everything looked fine. On the
	// real phone the WINDOW background is behind, which undeclared takes
	// the system one -- white. Result: white title on white, white minutes
	// on white and the Simulate and Cancel buttons invisible.
	//
	// That is why there was no way to reproduce it looking at my screenshots: we were not
	// seeing the same screen.
	Rectangle {
		anchors.fill: parent
		color: panel.p.fondo
	}

	// The planner that feeds us.
	property var plan: null
	// Which one is selected, to draw it on the map.
	property int elegida: 0

	signal empezar(var entrada)
	signal simular(var entrada)
	signal cerrar()

	// Tapping a row ONLY previews it on the map. The warning that it breaks a
	// filter comes up on pressing Start, not before: if it popped on every tap, it would be
	// impossible to compare two routes without fighting a dialog.
	function elegir(i) {
		panel.elegida = i
	}

	function _tiempo(min) {
		if (min < 60)
			return qsTr("%1 min").arg(min)
		const h = Math.floor(min / 60)
		const m = min % 60
		return m === 0 ? qsTr("%1 h").arg(h) : qsTr("%1 h %2").arg(h).arg(m)
	}

	// --- distances, in whatever the driver uses ----------------------------
	// Internally EVERYTHING is metres; here and only here it is turned into what is read.
	//
	// In miles FEET are used below 0.1 mile and not yards: it is what
	// navigators in the US say and what people expect to hear. The cut-off
	// is at 528 feet, which is half a mile divided by five -- round in their
	// system, ugly in ours, and that is why dividing by a thousand does not work.
	property bool millas: false

	// The map tiles the chosen route is missing, and whether they can be downloaded.
	// The window computes them, which is what talks to the backend.
	property var faltanCuadros: []
	property bool puedeBajar: false
	signal bajarMapaRuta()

	function _dist(m) {
		if (millas) {
			const mi = m / 1609.344
			if (mi < 0.1)
				return Math.round(m * 3.28084 / 10) * 10 + " ft"
			return mi.toFixed(mi < 10 ? 1 : 0).replace(".", ",") + " mi"
		}
		if (m < 1000)
			// Rounded to 10 m: the last digit changes faster than
			// anyone can read it and makes the number look broken.
			return Math.round(m / 10) * 10 + " m"
		return (m / 1000).toFixed(m < 10000 ? 1 : 0).replace(".", ",") + " km"
	}

	function _distancia(metros) { return _dist(metros) }

	function _palabra(clave) {
		if (clave === "peaje") return qsTr("toll")
		if (clave === "autopista") return qsTr("motorway")
		if (clave === "ferri") return qsTr("ferry")
		if (clave === "tierra") return qsTr("unpaved")
		return clave
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.leftMargin: panel.margen
		anchors.rightMargin: panel.margen
		anchors.topMargin: Kirigami.Units.largeSpacing
		anchors.bottomMargin: Kirigami.Units.largeSpacing
		spacing: Kirigami.Units.smallSpacing

		RowLayout {
			Layout.fillWidth: true
			spacing: Kirigami.Units.smallSpacing

			QQC2.Label {
				Layout.fillWidth: true
				text: panel.plan && panel.plan.nombreDestino
					? panel.plan.nombreDestino : qsTr("Routes")
				color: panel.p.tinta
				font.bold: true
				font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.2
				elide: Text.ElideRight
			}

			QQC2.AbstractButton {
				id: cerrarBoton
				Layout.preferredWidth: Kirigami.Units.gridUnit * 2.6
				Layout.preferredHeight: Kirigami.Units.gridUnit * 2.6
				onClicked: panel.cerrar()
				background: Rectangle {
					radius: height / 2
					color: cerrarBoton.pressed ? panel.p.tintaSuave : panel.p.fondoAlto
				}
				// With its circle and at size: the bare cross on a dark background
				// did not read as a button.
				contentItem: Item {
					Kirigami.Icon {
						anchors.centerIn: parent
						width: Kirigami.Units.iconSizes.smallMedium
						height: width
						source: "dialog-close"
						isMask: true
						color: panel.p.tinta
					}
				}
			}
		}

		// While it computes. They are TWO requests and over the network they can be slow, so
		// staying silent would leave the screen as if nothing had happened.
		QQC2.Label {
			Layout.fillWidth: true
			visible: panel.plan && panel.plan.estado === "pidiendo"
			text: qsTr("Searching routes…")
			color: panel.p.tintaSuave
		}

		QQC2.Label {
			Layout.fillWidth: true
			visible: panel.plan && panel.plan.estado === "error"
			text: panel.plan ? panel.plan.fallo : ""
			color: panel.p.ambar
			wrapMode: Text.WordWrap
		}

		ListView {
			id: lista
			Layout.fillWidth: true
			// Whatever the rows take, capped. With 'fillHeight' the list
			// stretched to the bottom and left a huge gap between the last route
			// and the buttons -- especially in portrait, where there are only three rows
			// for half a screen.
			Layout.preferredHeight: Math.min(contentHeight,
				parent.height - Kirigami.Units.gridUnit * 9)
			Layout.maximumHeight: parent.height - Kirigami.Units.gridUnit * 9
			clip: true
			spacing: Kirigami.Units.smallSpacing
			model: panel.plan && panel.plan.estado === "listo" ? panel.plan.rutas : []

			// IT IS VISIBLE THAT THERE IS MORE BELOW, and both signals are needed.
			//
			// With four routes the list is cut off at the bottom edge and there is no
			// way to know it can be dragged: the last visible row
			// looks like the last one there is. And this is read while choosing a journey, which
			// is exactly when you are not going to start trying out gestures.
			//
			// The bar alone is not enough -- it is thin and on a phone barely looked at -- and
			// the gradient alone does not say HOW MUCH is left either. Together: the gradient
			// draws the eye and the bar gives the proportion.
			//
			// Both appear ONLY if there is something to scroll: a fixed bar on
			// a list of three routes would be permanent noise for a case that does
			// not happen.
			readonly property bool hayMas: contentHeight > height + 1

			QQC2.ScrollBar.vertical: QQC2.ScrollBar {
				policy: lista.hayMas ? QQC2.ScrollBar.AlwaysOn
					: QQC2.ScrollBar.AlwaysOff
				width: Kirigami.Units.smallSpacing
				// Always visible while needed, not only when dragging: the
				// indicator that appears when you are already scrolling arrives late
				// -- it reports what you have just discovered on your own.
				contentItem: Rectangle {
					radius: width / 2
					color: panel.p.tintaSuave
					opacity: 0.7
				}
			}

			delegate: QQC2.AbstractButton {
				id: fila
				required property int index
				required property var modelData

				width: ListView.view.width
				height: Kirigami.Units.gridUnit * 4.6
				onClicked: panel.elegir(fila.index)

				readonly property bool puesta: panel.elegida === fila.index
				readonly property bool rompe: modelData.aviso.length > 0

				background: Rectangle {
					radius: panel.p.radio
					// The chosen one in blue, like the line drawn on the map:
					// both things have to say "this one" without reading anything.
					color: fila.puesta ? panel.p.azul
						: (fila.pressed ? panel.p.fondoAlto : "transparent")
					border.width: fila.puesta ? 0 : 1
					border.color: panel.p.fondoAlto
				}

				contentItem: RowLayout {
					spacing: Kirigami.Units.largeSpacing

					ColumnLayout {
						Layout.fillWidth: true
						// Indented inside the row. Without this the "47 min" started
						// right at the edge of the blue rectangle, with no air, and
						// read as cropped text instead of as a card.
						Layout.leftMargin: Kirigami.Units.largeSpacing
						spacing: 0

						RowLayout {
							spacing: Kirigami.Units.smallSpacing
							QQC2.Label {
								text: panel._tiempo(fila.modelData.minutos)
								color: fila.puesta ? panel.p.blanco : panel.p.tinta
								font.bold: true
								font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.35
							}
							// The first one that complies is the recommended one, and it is said.
							// Without this, "why it is on top" is a guessing game.
							Rectangle {
								visible: fila.index === 0 && !fila.rompe
								radius: height / 2
								color: fila.puesta ? panel.p.blanco : panel.p.verde
								implicitWidth: mejor.implicitWidth
									+ Kirigami.Units.largeSpacing
								implicitHeight: mejor.implicitHeight
									+ Kirigami.Units.smallSpacing
								QQC2.Label {
									id: mejor
									anchors.centerIn: parent
									text: qsTr("best")
									font.bold: true
									font.pointSize: Kirigami.Theme.smallFont.pointSize
									color: fila.puesta ? panel.p.azul : panel.p.blanco
								}
							}
						}

						QQC2.Label {
							Layout.fillWidth: true
							text: panel._distancia(fila.modelData.metros)
								+ (fila.modelData.resumen
									? "  ·  " + fila.modelData.resumen : "")
							color: fila.puesta ? panel.p.blanco : panel.p.tintaSuave
							elide: Text.ElideRight
							opacity: fila.puesta ? 0.9 : 1
						}
					}

					// What it breaks. In amber and with the word written out.
					RowLayout {
						Layout.rightMargin: Kirigami.Units.largeSpacing
						spacing: Kirigami.Units.smallSpacing
						Repeater {
							model: fila.modelData.aviso
							delegate: Rectangle {
								required property string modelData
								radius: height / 2
								color: panel.p.ambar
								implicitWidth: aviso.implicitWidth
									+ Kirigami.Units.largeSpacing
								implicitHeight: aviso.implicitHeight
									+ Kirigami.Units.smallSpacing
								RowLayout {
									id: aviso
									anchors.centerIn: parent
									spacing: 2
									QQC2.Label {
										text: "!"
										font.bold: true
										color: panel.p.tintaOscura
									}
									QQC2.Label {
										text: panel._palabra(modelData)
										font.bold: true
										font.pointSize: Kirigami.Theme.smallFont.pointSize
										color: panel.p.tintaOscura
									}
								}
							}
						}
					}
				}
			}
		}

		// THE EDGE GRADIENT, stuck to the list and above it.
		//
		// It is drawn as a sibling and not inside the ListView because inside it would
		// scroll with the content, which is exactly the opposite of what
		// it must do: it stays still at the edge saying "this continues".
		//
		// And it disappears at the end, so it does not look like there is always
		// something more left.
		Item {
			Layout.fillWidth: true
			Layout.preferredHeight: 0
			z: 5
			Rectangle {
				y: -Kirigami.Units.gridUnit * 1.6
				width: parent.width
				height: Kirigami.Units.gridUnit * 1.6
                visible: lista.hayMas && !lista.atYEnd
				gradient: Gradient {
					GradientStop { position: 0.0; color: "transparent" }
					GradientStop { position: 1.0; color: panel.p.fondo }
				}
			}
		}

		// The leftover gap goes here: this way the routes stay packed at the top and the
		// buttons at the bottom, instead of the list stretched through the middle.
		Item { Layout.fillWidth: true; Layout.fillHeight: true }

		// THE MAP OF WHERE YOU ARE GOING, offered where the journey is chosen.
		//
		// This is the place, not the settings: there you only know where you ARE, and
		// the map of where you are is the one least needed -- you have already arrived.
		// Here there is already a route, so you know where you will pass through.
		//
		// It only appears if one really is missing and there is something to download it with. A button
		// that is almost always there and almost never needed gets pressed without being read.
		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: Kirigami.Units.gridUnit * 2.8
			Layout.bottomMargin: Kirigami.Units.smallSpacing
			visible: panel.faltanCuadros.length > 0 && panel.puedeBajar
			radius: height / 2
			color: bajar.pressed ? panel.p.fondoAlto : "transparent"
			border.color: panel.p.ambar
			border.width: 1

			TapHandler {
				id: bajar
				gesturePolicy: TapHandler.DragThreshold
				onTapped: panel.bajarMapaRuta()
			}

			QQC2.Label {
				anchors.centerIn: parent
				width: parent.width - Kirigami.Units.gridUnit
				horizontalAlignment: Text.AlignHCenter
				elide: Text.ElideRight
				color: panel.p.tinta
				font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.95
				// THE SIZE IS STATED, not hidden: it is about 130 MB per area
				// -- measured, 113 and 112 for the two that are downloaded -- and that is
				// decided very differently on wifi than on data.
				text: panel.faltanCuadros.length === 1
					? qsTr("Download the map for this route · about 130 MB")
					: qsTr("Download the map for this route · %1 areas, about %2 MB")
						.arg(panel.faltanCuadros.length)
						.arg(panel.faltanCuadros.length * 130)
			}
		}

		// At the bottom, which is where the thumb reaches. Cancel alongside and NOT just the
		// little cross in the corner: a small X right at the top is the
		// hardest spot to hit on the screen, and getting back to the map has to be
		// as easy as starting.
		RowLayout {
			Layout.fillWidth: true
			spacing: Kirigami.Units.smallSpacing

		// SIMULATE: drives the route with a pretend car, at the speed
		// each stretch allows. It is the only way to see how the
		// application behaves in motion without getting in the car -- with the phone on the table,
		// the GPS always gives the same point and that half cannot be looked at.
		QQC2.AbstractButton {
			id: simularBoton
			Layout.preferredWidth: Kirigami.Units.gridUnit * 6
			Layout.preferredHeight: Kirigami.Units.gridUnit * 3.4
			enabled: panel.plan && panel.plan.estado === "listo"
				&& panel.plan.rutas.length > 0
			onClicked: panel.simular(panel.plan.rutas[panel.elegida])
			background: Rectangle {
				radius: height / 2
				color: simularBoton.pressed ? panel.p.fondoAlto : "transparent"
				border.width: 1
				border.color: panel.p.tintaSuave
			}
			contentItem: QQC2.Label {
				text: qsTr("Simulate")
				color: panel.p.tinta
				horizontalAlignment: Text.AlignHCenter
				verticalAlignment: Text.AlignVCenter
			}
		}

		QQC2.AbstractButton {
			id: cancelarBoton
			Layout.preferredWidth: Kirigami.Units.gridUnit * 6
			Layout.preferredHeight: Kirigami.Units.gridUnit * 3.4
			onClicked: panel.cerrar()
			background: Rectangle {
				radius: height / 2
				color: cancelarBoton.pressed ? panel.p.fondoAlto : "transparent"
				border.width: 1
				border.color: panel.p.tintaSuave
			}
			contentItem: QQC2.Label {
				text: qsTr("Cancel")
				color: panel.p.tinta
				horizontalAlignment: Text.AlignHCenter
				verticalAlignment: Text.AlignVCenter
			}
		}

		QQC2.AbstractButton {
			id: empezarBoton
			Layout.fillWidth: true
			Layout.preferredHeight: Kirigami.Units.gridUnit * 3.4
			enabled: panel.plan && panel.plan.estado === "listo"
				&& panel.plan.rutas.length > 0
			onClicked: panel.empezar(panel.plan.rutas[panel.elegida])
			background: Rectangle {
				radius: height / 2
				color: empezarBoton.enabled
					? (empezarBoton.pressed ? panel.p.azulCasco : panel.p.azul)
					: panel.p.fondoAlto
			}
			contentItem: QQC2.Label {
				text: qsTr("Start")
				color: panel.p.blanco
				font.bold: true
				font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.15
				horizontalAlignment: Text.AlignHCenter
				verticalAlignment: Text.AlignVCenter
			}
		}
		}
	}
}
