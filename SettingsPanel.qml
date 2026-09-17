// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The settings, full screen.
//
// It began as a floating dialog and that was wrong: in landscape there are 540 px of
// height, the content needed rather more, and the panel spilled off the bottom with the
// last text cut off mid-sentence. A box that does not fit is not a box, it is
// a crop.
//
// So it takes up the whole screen, like the settings of any phone:
//
//   a bar at the top with the back arrow and the title, always visible
//   sections with their heading
//   fixed-height rows: on the left what it is and what it costs, on the right the control
//   a thin line between rows, indented, instead of loose boxes
//
// The row height is NOT decorative: it is what lets you hit it with your finger
// without looking. And the support text goes BELOW each title, in grey, instead of in
// a paragraph at the end of the section -- this way each option is explained where you touch it.
//
// Everything touched here asks the backend directly -- 'app.downloadVoice',
// 'app.downloadMap' -- and the progress arrives through its properties. There is no file
// in between and nobody polling: the bar moves because a property changed.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
	id: settings

	readonly property var p: Theme

	// The region written last time, so you do not type it again.
	property alias region: regionField.text

	// WHERE THE PHONE IS, so the map "around here" can be downloaded.
	//
	// The drawing is split into zoom-7 tiles -- about 300 km a side, 132 MB
	// each -- and downloading the one underneath is what turns "the map of Spain"
	// into something that fits in a spell of wifi. Without a position you cannot choose
	// a tile and the whole region is downloaded, which is what there used to be.
	property real myLat: 0
	property real myLon: 0
	readonly property bool knowWhere: myLat !== 0 || myLon !== 0

	// A single side margin for EVERYTHING. Before, each block carried its own and the
	// texts did not fall in the same column.
	readonly property int margin: Math.round(Kirigami.Units.gridUnit * 1.2)
	readonly property int rowHeight: Math.round(Kirigami.Units.gridUnit * 3.6)

	// A single column for the WHOLE screen: the top bar, the download
	// bar and the rows. Centring only the body left the "Settings" title
	// stuck to the left edge and the rows a hand's width away, with nothing to
	// relate them. The width is what a settings line comfortably takes;
	// more than that, in landscape, separates the title from its control by half a screen.
	readonly property int usableWidth: Math.min(width, Kirigami.Units.gridUnit * 34)
	readonly property int indent: Math.round((width - usableWidth) / 2)

	visible: false
	anchors.fill: parent

	// The voices Piper offers. The whole repository catalog is NOT read on
	// purpose: there are several hundred, and choosing among eight is a decision --
	// among three hundred, a maze. The download path is deduced from the name.
	readonly property var voices: [
		{ id: "es_ES-davefx-medium",   name: "Dave",     language: "Spanish (Spain)" },
		{ id: "es_ES-sharvard-medium", name: "Sharvard", language: "Spanish (Spain)" },
		{ id: "es_MX-claude-high",     name: "Claude",   language: "Spanish (Mexico)" },
		{ id: "en_GB-alba-medium",     name: "Alba",     language: "English (UK)" },
		{ id: "en_US-amy-medium",      name: "Amy",      language: "English (US)" },
		{ id: "fr_FR-siwis-medium",    name: "Siwis",    language: "French" },
		{ id: "de_DE-thorsten-medium", name: "Thorsten", language: "German" },
		{ id: "pt_PT-tugao-medium",    name: "Tugão",    language: "Portuguese" }
	]

	// What is set and what is chosen. The settings store nothing:
	// the window stores it, which is what holds the memory.
	property string theme: "auto"
	property string units: "auto"
	property bool nightMode: false
	property bool miles: false
	signal setTheme(string which)
	signal setUnits(string which)

	function open() { visible = true }
	function close() { visible = false }

	// Opaque and full screen: nothing behind should distract, and this way
	// no veils or shadows are needed either.
	Rectangle {
		anchors.fill: parent
		color: settings.p.surface
	}

	// It swallows any tap that misses a row, so it does not reach the
	// map underneath.
	//
	// 'propagateComposedEvents' and without accepting the press: this way it stops the taps
	// but does NOT keep the drag, which is what the list scrolling
	// needs. Before it grabbed it and the settings screen would not
	// scroll depending on where you started the gesture.
	MouseArea {
		anchors.fill: parent
		propagateComposedEvents: true
		onPressed: (event) => event.accepted = false
	}

	// --- a menu row, which is what the screen is made of ----------------------
	// A ROW IS NOT A BUTTON, and that matters for being able to scroll the list.
	//
	// It was a QQC2.AbstractButton and the screen would not scroll when the
	// finger started on a row: the button grabs the press at once
	// and does not let go, so the Flickable never learns about the drag. The
	// Flickable's 'pressDelay' is not enough for that.
	//
	// With a TapHandler on 'DragThreshold' the opposite happens: the tap is NOT
	// accepted until the finger is lifted without having moved. If you move,
	// the scroll takes the gesture, which is exactly what you
	// expect from a list.
	component SettingRow: Item {
		id: f
		property string title: ""
		property string hint: ""
		property bool separator: true
		// 'enabled' is NOT declared: Item already has it, and redeclaring it
		// hides it. Qt warns about it ("overrides a member of the base object") and
		// the winner is not always the one you think.
		property Component rightItem: null
		signal clicked()

		readonly property bool pressed: tap.pressed

		Layout.fillWidth: true
		Layout.preferredHeight: settings.rowHeight

		TapHandler {
			id: tap
			enabled: f.enabled
			gesturePolicy: TapHandler.DragThreshold
			onTapped: f.clicked()
		}

		Rectangle {
			anchors.fill: parent
			color: f.pressed && f.enabled ? settings.p.surfaceHigh : "transparent"
			// The line goes at the bottom and indented to where the text starts, not from
			// edge to edge: this way it groups the rows instead of chopping up the screen.
			Rectangle {
				visible: f.separator
				anchors.bottom: parent.bottom
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.leftMargin: settings.margin
				height: 1
				color: settings.p.surfaceHigh
			}
		}

		RowLayout {
			anchors.fill: parent
			spacing: Kirigami.Units.largeSpacing

			ColumnLayout {
				Layout.fillWidth: true
				Layout.leftMargin: settings.margin
				spacing: 1

				// The two sizes are TIED to the interface size, not taken from
				// smallFont: on this phone smallFont comes out BIGGER than the
				// normal font, and the subtitle swallowed the title.
				QQC2.Label {
					Layout.fillWidth: true
					text: f.title
					color: f.enabled ? settings.p.ink : settings.p.inkSoft
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.05
					elide: Text.ElideRight
					wrapMode: Text.WordWrap
					maximumLineCount: 2
				}
				QQC2.Label {
					Layout.fillWidth: true
					visible: f.hint.length > 0
					text: f.hint
					color: settings.p.inkSoft
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.85
					elide: Text.ElideRight
				}
			}

			// A FIXED-width column for the control on the right: this way they all fall
			// aligned and the row reserves space for them even before they have a size.
			Item {
				Layout.preferredWidth: Kirigami.Units.gridUnit * 3
				Layout.fillHeight: true
				Layout.rightMargin: settings.margin

				Loader {
					anchors.centerIn: parent
					sourceComponent: f.rightItem
				}
			}
		}
	}

	// Three options in a row, segmented-switch style: to choose among
	// three short things, a list of three rows wastes half a screen and a dropdown
	// menu hides the options behind an extra tap.
	component Options: RowLayout {
		id: op
		property var keys: []
		property var labels: []
		property string selected: ""
		signal picked(string key)

		spacing: Kirigami.Units.smallSpacing

		Repeater {
			model: op.keys.length
			delegate: QQC2.AbstractButton {
				id: bo
				required property int index
				Layout.fillWidth: true
				Layout.preferredWidth: 0
				Layout.preferredHeight: Kirigami.Units.gridUnit * 2.6
				onClicked: op.picked(op.keys[bo.index])
				background: Rectangle {
					radius: height / 2
					color: op.selected === op.keys[bo.index] ? settings.p.blue
						: (bo.pressed ? settings.p.surfaceHigh : "transparent")
					border.width: op.selected === op.keys[bo.index] ? 0 : 1
					border.color: settings.p.surfaceHigh
				}
				contentItem: QQC2.Label {
					text: op.labels[bo.index]
					color: op.selected === op.keys[bo.index]
						? settings.p.white : settings.p.ink
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.95
					horizontalAlignment: Text.AlignHCenter
					verticalAlignment: Text.AlignVCenter
					elide: Text.ElideRight
				}
			}
		}
	}

	component SectionHeader: QQC2.Label {
		Layout.fillWidth: true
		Layout.preferredHeight: Kirigami.Units.gridUnit * 2.8
		leftPadding: settings.margin
		verticalAlignment: Text.AlignBottom
		bottomPadding: Kirigami.Units.smallSpacing
		color: settings.p.lightBlue
		font.bold: true
		font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.9
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 0

		// --- top bar, always visible -----------------------------------------
		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: Kirigami.Units.gridUnit * 3.6
			color: settings.p.surface

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: settings.indent + Kirigami.Units.smallSpacing
				anchors.rightMargin: settings.indent + settings.margin
				spacing: Kirigami.Units.smallSpacing

				// A back arrow, not a cross in the corner: on a full
				// screen what you expect is to go back.
				QQC2.AbstractButton {
					id: back
					Layout.preferredWidth: Kirigami.Units.gridUnit * 3
					Layout.preferredHeight: Kirigami.Units.gridUnit * 3
					onClicked: settings.close()
					background: Rectangle {
						radius: height / 2
						color: back.pressed ? settings.p.inkSoft : settings.p.surfaceHigh
					}
					// Full size, and white. Before it was a thin grey arrow on
					// grey and did not read as a button.
					contentItem: Item {
						Kirigami.Icon {
							anchors.centerIn: parent
							width: Kirigami.Units.iconSizes.smallMedium
							height: width
							source: "draw-arrow-back"
							isMask: true
							color: settings.p.ink
						}
					}
				}

				QQC2.Label {
					Layout.fillWidth: true
					text: qsTr("Settings")
					color: settings.p.ink
					font.bold: true
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.25
				}
			}

			Rectangle {
				anchors.bottom: parent.bottom
				width: parent.width
				height: 1
				color: settings.p.surfaceHigh
			}
		}

		// --- whatever is being downloaded ------------------------------------
		// Below the bar and full width: it is the only thing that can be happening
		// while looking at this screen, so it is seen without looking for it.
		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
			visible: app.busy
			color: settings.p.surfaceHigh
			clip: true

			Rectangle {
				anchors.left: parent.left
				anchors.top: parent.top
				anchors.bottom: parent.bottom
				width: parent.width * Math.max(0, Math.min(100, app.taskPct)) / 100
				color: settings.p.blue
				Behavior on width { NumberAnimation { duration: 200 } }
			}

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: settings.indent + settings.margin
				anchors.rightMargin: settings.indent + Kirigami.Units.smallSpacing
				spacing: Kirigami.Units.largeSpacing

				QQC2.Label {
					Layout.fillWidth: true
					text: qsTr("%1  %2%").arg(app.taskText).arg(app.taskPct)
					color: settings.p.white
					font.bold: true
					elide: Text.ElideRight
				}

				QQC2.AbstractButton {
					id: cancelButton
					Layout.preferredWidth: Kirigami.Units.gridUnit * 2.8
					Layout.preferredHeight: Kirigami.Units.gridUnit * 2.8
					onClicked: app.cancel()
					background: Rectangle {
						radius: height / 2
						color: cancelButton.pressed ? settings.p.red : "transparent"
					}
					contentItem: Kirigami.Icon {
						source: "dialog-cancel"
						isMask: true
						color: settings.p.white
					}
				}
			}
		}

		// --- the content, which scrolls --------------------------------------
		Flickable {
			Layout.fillWidth: true
			Layout.fillHeight: true
			contentHeight: body.implicitHeight
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			// No 'pressDelay': not needed any more since the rows use a
			// TapHandler that yields the gesture to the drag on its own. And the
			// delay had its own price -- 150 ms of wait before the
			// row reacts to a legitimate tap.
			flickableDirection: Flickable.VerticalFlick
			QQC2.ScrollBar.vertical: QQC2.ScrollBar { }

			ColumnLayout {
				id: body
				// Bounded and centred width. Across a landscape screen
				// -- 1200 px -- the title sits all the way to the left and its
				// control all the way to the right, with half a metre of nothing between:
				// you have to sweep the whole row with your eyes to relate the
				// two things. 34 units is what a settings line comfortably
				// takes without them coming apart.
				width: settings.usableWidth
				x: settings.indent
				spacing: 0

				// --- appearance ---------------------------------------------
				SectionHeader { text: qsTr("APPEARANCE") }

				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: settings.rowHeight
					Options {
						anchors.fill: parent
						anchors.leftMargin: settings.margin
						anchors.rightMargin: settings.margin
						anchors.topMargin: Kirigami.Units.smallSpacing
						anchors.bottomMargin: Kirigami.Units.smallSpacing
						keys: ["light", "dark", "auto"]
						labels: [qsTr("Light"), qsTr("Dark"), qsTr("Automatic")]
						selected: settings.theme
						onPicked: (c) => settings.setTheme(c)
					}
				}

				SettingRow {
					title: settings.theme === "auto"
						? (settings.nightMode
							? qsTr("It is night where you are now")
							: qsTr("It is day where you are now"))
						: qsTr("Automatic switches on its own at nightfall")
					hint: settings.theme === "auto"
						? qsTr("the sunset time is computed from your position and the date")
						: qsTr("with the map dark and the panels off")
					enabled: false
					separator: false
				}

				// --- units --------------------------------------------------
				SectionHeader { text: qsTr("DISTANCES") }

				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: settings.rowHeight
					Options {
						anchors.fill: parent
						anchors.leftMargin: settings.margin
						anchors.rightMargin: settings.margin
						anchors.topMargin: Kirigami.Units.smallSpacing
						anchors.bottomMargin: Kirigami.Units.smallSpacing
						keys: ["km", "miles", "auto"]
						labels: [qsTr("Kilometres"), qsTr("Miles"), qsTr("Automatic")]
						selected: settings.units
						onPicked: (c) => settings.setUnits(c)
					}
				}

				SettingRow {
					title: settings.units === "auto"
						? (settings.miles
							? qsTr("Now: miles, by the system language")
							: qsTr("Now: kilometres, by the system language"))
						: qsTr("Automatic takes it from the system language")
					hint: qsTr("also governs what the voice says")
					enabled: false
					separator: false
				}

				// --- voice --------------------------------------------------
				SectionHeader { text: qsTr("VOICE") }

				Repeater {
					model: settings.voices
					delegate: SettingRow {
						id: voiceRow
						required property var modelData
						readonly property bool installed:
							app.voices.indexOf(modelData.id) >= 0
						readonly property bool selected: app.activeVoice === modelData.id

						title: modelData.name
						hint: installed
							? (selected ? qsTr("%1 · in use").arg(modelData.language)
								: modelData.language)
							: modelData.language + qsTr(" · tap to download, 60 MB")
						enabled: !app.busy
						onClicked: {
							if (voiceRow.installed)
								app.activeVoice = voiceRow.modelData.id
							else
								app.downloadVoice(voiceRow.modelData.id)
						}

						// A ROUND SELECTOR, not a mark that appears and
						// disappears. Before, only a tick showed on the chosen one and
						// nothing on the others, so it was not clear that the rows
						// WERE selectable -- it looked like an informational list.
						//
						// The empty circle says "this can be chosen"; the full one,
						// "this is it". And the download arrow marks the ones that are not
						// even here yet, because tapping them does something else.
						rightItem: Item {
							width: Kirigami.Units.gridUnit * 1.6
							height: width

							// Not downloaded: arrow, not selector.
							Kirigami.Icon {
								anchors.centerIn: parent
								width: Kirigami.Units.iconSizes.smallMedium
								height: width
								visible: !voiceRow.installed
								source: "download"
								isMask: true
								color: settings.p.inkSoft
							}

							// Downloaded: round selector.
							Rectangle {
								anchors.centerIn: parent
								visible: voiceRow.installed
								width: Kirigami.Units.gridUnit * 1.4
								height: width
								radius: width / 2
								color: "transparent"
								border.width: 2
								border.color: voiceRow.selected ? settings.p.green
									: settings.p.inkSoft

								Rectangle {
									anchors.centerIn: parent
									visible: voiceRow.selected
									width: parent.width * 0.55
									height: width
									radius: width / 2
									color: settings.p.green
								}
							}
						}
					}
				}

				SettingRow {
					title: app.voices.length > 0
						? qsTr("Tap a downloaded one to use it")
						: qsTr("With no voice downloaded espeak speaks: understandable, but a robot")
					hint: app.voices.length > 0
						? qsTr("the voice in use also sets the application language")
						: ""
					enabled: false
					separator: false
				}

				// --- maps ---------------------------------------------------
				SectionHeader { text: qsTr("OFFLINE MAPS") }

				Repeater {
					model: app.maps
					delegate: SettingRow {
						id: mapRow
						required property string modelData
						// Whether it can also be DRAWN out of coverage. They are two
						// different downloads -- for Spain, 1.1 GB of being able to go
						// against 1.9 GB of being able to see -- and saying it here avoids the
						// surprise of leaving home with "map downloaded" and
						// finding the screen blank when the signal drops.
						readonly property bool isDrawn:
							app.drawables.indexOf(modelData) >= 0
						title: modelData
						hint: isDrawn ? qsTr("routes, search and map on the phone")
							: qsTr("routes and search; the map needs network")
						enabled: !app.busy
						// The whole row downloads the drawing for AROUND HERE when it is missing. There
						// is no separate button because the action is the same as what the
						// support text says: complete what this region is missing.
						//
						// From here and not the whole region: 132 MB against 1.9
						// GB in Spain. Whoever wants the country downloads it tile by
						// tile as they pass through, which is what is really
						// needed.
						onClicked: {
							if (isDrawn || app.busy)
								return
							if (settings.knowWhere)
								app.downloadDrawingNear(mapRow.modelData,
									settings.myLat, settings.myLon, 0)
							else
								app.downloadDrawing(mapRow.modelData)
						}
						rightItem: QQC2.AbstractButton {
							id: remove
							width: Kirigami.Units.gridUnit * 2.8
							height: width
							enabled: !app.busy
							onClicked: app.deleteMap(mapRow.modelData)
							background: Rectangle {
								radius: height / 2
								color: remove.pressed ? settings.p.red : "transparent"
							}
							// The icon, smaller than its button: at full
							// size the bin filled the whole circle and looked like
							// a drawing bug.
							contentItem: Item {
								Kirigami.Icon {
									anchors.centerIn: parent
									width: Kirigami.Units.iconSizes.small
									height: width
									source: "edit-delete"
									isMask: true
									color: remove.pressed ? settings.p.white
										: settings.p.inkSoft
								}
							}
						}
					}
				}

				SettingRow {
					visible: app.maps.length === 0
					title: qsTr("None downloaded")
					hint: qsTr("routes and searches will go over the network")
					enabled: false
				}

				// The download row. The field takes almost all the width:
				// typing "europe/spain" with your finger needs room.
				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: settings.rowHeight

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: settings.margin
						anchors.rightMargin: settings.margin
						spacing: Kirigami.Units.smallSpacing

						QQC2.TextField {
							id: regionField
							Layout.fillWidth: true
							Layout.preferredHeight: Kirigami.Units.gridUnit * 2.8
							placeholderText: qsTr("region, e.g. europe/spain")
							color: settings.p.inkDark
							placeholderTextColor: settings.p.inkSoft
							leftPadding: Kirigami.Units.largeSpacing
							background: Rectangle {
								radius: height / 2
								color: settings.p.white
							}
							onAccepted: if (download.enabled) app.downloadMap(text.trim())
						}

						QQC2.AbstractButton {
							id: download
							Layout.preferredWidth: Kirigami.Units.gridUnit * 6
							Layout.preferredHeight: Kirigami.Units.gridUnit * 2.8
							enabled: !app.busy && regionField.text.trim().length > 2
							onClicked: app.downloadMap(regionField.text.trim())
							background: Rectangle {
								radius: height / 2
								color: download.enabled
									? (download.pressed ? settings.p.blueCasing : settings.p.blue)
									: settings.p.surfaceHigh
							}
							contentItem: QQC2.Label {
								text: qsTr("Download")
								color: download.enabled ? settings.p.white : settings.p.inkSoft
								font.bold: true
								horizontalAlignment: Text.AlignHCenter
								verticalAlignment: Text.AlignVCenter
							}
						}
					}
				}

				SettingRow {
					title: qsTr("The map drawing needs network the first time")
					hint: qsTr("afterwards it stays saved and that path is visible without coverage")
					enabled: false
					separator: false
				}

				// A breather at the end, so the last row does not stick to the
				// bottom edge when scrolled all the way.
				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: Kirigami.Units.gridUnit * 2
				}
			}
		}
	}
}
