// SPDX-License-Identifier: LGPL-2.0-or-later
//
// Choosing where to go: by name, from your saved places, and with the two
// preferences that change the road you get.
//
// Nominatim is the OSM search. Its terms are strict and they are respected here
// on purpose: an identifiable User-Agent, and a query sent ONLY when you ask
// for it -- never as you type. Search-as-you-type against Nominatim is
// explicitly forbidden and would get the whole phone blocked, which is a
// terrible way to find out.
//
// The search needs the network. Saved places and holding a finger on the map do
// not, which is why this panel says so when there is no signal instead of just
// failing.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtPositioning
import org.kde.kirigami as Kirigami

Item {
	id: finder

	// Bias results towards where you are, otherwise "farmacia" is a lottery
	// over the whole planet.
	property var near: null
	property int tall: Kirigami.Units.gridUnit * 3.5

	// Owned by the caller and handed back through the signals, so this panel
	// never has to know where preferences live.
	property string favoritesJson: "[]"
	property bool avoidTolls: false
	property bool avoidMotorways: false
	property bool avoidFerries: false
	property bool avoidUnpaved: false

	signal chosen(var coordinate, string name)
	signal favoritesChanged(string json)
	signal toggleTolls()
	signal toggleMotorways()
	signal toggleFerries()
	signal toggleUnpaved()

	readonly property var p: Theme

	// If there are downloaded maps, the search runs on the phone. Whoever creates us decides it:
	// it is the same poll the routes already use, and there is no reason to do it
	// twice or for the two things to be able to disagree.
	property bool hasLocal: false

	// Reachable from outside so the field can be written to from the
	// self-test: checking the debounce requires actually typing.
	property alias field: field
	property alias results: results
	// How many queries have been fired. The self-test looks at it to check that
	// typing nine letters gives ONE search and not nine; counting inserted rows
	// is no good, because a single search inserts twelve.
	property int queries: 0

	property string status: ""   // "", "searching", "ready", "error"
	property string failure: ""
	property var _pending: null

	readonly property bool noNetwork: status === "error" && failure.indexOf("connection") >= 0

	visible: false
	anchors.fill: parent

	onFavoritesJsonChanged: _loadFavorites()
	Component.onCompleted: _loadFavorites()

	function open() {
		visible = true
		field.forceActiveFocus()
		field.selectAll()
	}

	function close() {
		// Keyboard away WHENEVER you leave here, not only when pressing search.
		// It goes in 'close' and not in every place that chooses a destination because
		// all the exits pass through here -- a result, a save, the cross --
		// and putting this in three places guarantees that one day it is missing from one.
		field.focus = false
		Qt.inputMethod.hide()
		if (_pending) {
			_pending.abort()
			_pending = null
		}
		visible = false
	}

	// --- saved places -----------------------------------------------------
	function _loadFavorites() {
		favorites.clear()
		var items
		try {
			items = JSON.parse(favoritesJson)
		} catch (e) {
			return
		}
		if (!items || !items.length)
			return
		for (var i = 0; i < items.length; ++i)
			favorites.append({
				name: items[i].name,
				lat: items[i].lat,
				lon: items[i].lon
			})
	}

	function _dumpFavorites() {
		const output = []
		for (var i = 0; i < favorites.count; ++i) {
			const f = favorites.get(i)
			output.push({ name: f.name, lat: f.lat, lon: f.lon })
		}
		favoritesChanged(JSON.stringify(output))
	}

	function save(name, lat, lon) {
		// Same place twice is clutter, and "same" here means the same spot,
		// not the same spelling: Nominatim writes a name a dozen ways.
		for (var i = 0; i < favorites.count; ++i) {
			const f = favorites.get(i)
			if (Math.abs(f.lat - lat) < 1e-5 && Math.abs(f.lon - lon) < 1e-5)
				return
		}
		favorites.append({ name: name, lat: lat, lon: lon })
		_dumpFavorites()
	}

	function forget(index) {
		favorites.remove(index)
		_dumpFavorites()
	}

	// --- search as you type (0.8 s debounce) ---------------------------------
	//
	// It waits for text to stop arriving and then searches, instead of searching
	// on every key: typing "cartagena" is nine keystrokes and would be nine
	// searches to throw away eight.
	//
	// ONLY AGAINST THE PHONE, and it is not a technical limitation: Nominatim EXPRESSLY
	// FORBIDS search as you type -- "you must not implement such a
	// service on the client side using the API" --, and it is the condition under
	// which that server is used. Without downloaded maps, the search box stays as
	// it was: you type and you press.
	//
	// On the phone there is no such problem: the database is ours and a search takes
	// between 5 and 30 ms, measured over the whole of Spain.
	readonly property Timer debounce: Timer {
		interval: 800
		onTriggered: {
			const text = field.text.trim()
			if (text.length >= 2 && finder.hasLocal)
				finder._searchAtHome(text, false)
		}
	}

	function onTyping() {
		if (!hasLocal)
			return
		// Emptying the field clears the list at once: leaving the results of what
		// has already been deleted is what makes a live search feel
		// sticky.
		if (field.text.trim().length < 2) {
			debounce.stop()
			results.clear()
			status = ""
			return
		}
		debounce.restart()
	}

	function search() {
		debounce.stop()
		// Keyboard away. It takes up half the screen and what you want to see right
		// after searching are the RESULTS, which are below.
		field.focus = false
		Qt.inputMethod.hide()
		const text = field.text.trim()
		if (text.length < 2)
			return
		if (_pending)
			_pending.abort()

		results.clear()
		status = "searching"
		failure = ""

		// With downloaded maps the search runs on the phone, otherwise over the network. Same
		// rule as the routes: if it is at home, the home one is used.
		if (hasLocal)
			_searchAtHome(text, true)
		else
			_searchByNetwork(text)
	}

	// The application's own server, the same one that computes the routes. Its
	// database comes with the downloaded region.
	// 'allowNetwork' distinguishes the two ways of getting here. Searching live it CANNOT
	// fall back to Nominatim even if the phone finds nothing: it would be
	// exactly what its policy forbids, one request for every pause while
	// typing. Pressing search, yes.
	function _searchAtHome(text, allowNetwork) {
		finder.queries += 1
		const body = { q: text, limit: 12 }
		if (near)
			body.near = { lat: near.latitude, lon: near.longitude }

		const x = new XMLHttpRequest()
		_pending = x
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			finder._pending = null
			// If the home server fails, the network is tried before giving
			// up: it may not have started yet, or the downloaded region
			// may not cover what is being searched for.
			if (x.status !== 200) {
				if (allowNetwork)
					finder._searchByNetwork(text)
				else
					status = "ready"
				return
			}
			try {
				const items = JSON.parse(x.responseText).results || []
				// It is cleared HERE and not only in search(): when searching live, the
				// timer calls this function directly, and without this each pause
				// while typing would add another batch below the previous one.
				//
				// And it is cleared on RECEIVING, not on requesting: emptying the list while
				// the response arrives leaves it blank for a moment on every
				// pause, which is exactly the flicker that makes a live
				// search feel broken.
				results.clear()
				for (var i = 0; i < items.length; ++i) {
					const r = items[i]
					const c = QtPositioning.coordinate(r.lat, r.lon)
					results.append({
						name: r.name,
						// The type comes from OSM in English and with an underscore
						// ("place_town"). It is shown readable: it is the only thing that
						// distinguishes two places with the same name.
						detail: finder._readable(r.kind),
						lat: c.latitude,
						lon: c.longitude,
						far: near ? near.distanceTo(c) : 0
					})
				}
				if (results.count === 0 && allowNetwork) {
					// No results at home is NOT the same as not having
					// searched: it may be outside the downloaded region.
					finder._searchByNetwork(text)
					return
				}
				status = "ready"
			} catch (e) {
				if (allowNetwork)
					finder._searchByNetwork(text)
				else
					status = "ready"
			}
		}
		x.open("POST", "http://127.0.0.1:8554/search")
		x.setRequestHeader("Content-Type", "application/json")
		x.send(JSON.stringify(body))
	}

	function _readable(kind) {
		if (!kind)
			return ""
		const t = kind.split("_")
		const names = {
			"place": "town", "boundary": "municipality", "highway": "road",
			"natural": "natural feature", "amenity": "amenity", "tourism": "tourism",
			"shop": "shop", "leisure": "leisure", "building": "building",
			"aeroway": "airport", "railway": "railway", "landuse": "area",
			"healthcare": "healthcare", "aerialway": "cable car"
		}
		return names[t[0]] || t[0]
	}

	function _searchByNetwork(text) {
		var url = "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=8"
			+ "&accept-language=es&q=" + encodeURIComponent(text)
		if (near) {
			// A box around you, unbounded: it ranks what is near first without
			// hiding the rest.
			const d = 0.6
			url += "&viewbox=" + (near.longitude - d) + "," + (near.latitude + d)
				+ "," + (near.longitude + d) + "," + (near.latitude - d)
		}

		const x = new XMLHttpRequest()
		_pending = x
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			finder._pending = null
			if (x.status !== 200) {
				status = "error"
				failure = x.status === 0 ? qsTr("no connection")
					: qsTr("the search server responded %1").arg(x.status)
				return
			}
			try {
				const items = JSON.parse(x.responseText)
				for (var i = 0; i < items.length; ++i) {
					const r = items[i]
					const c = QtPositioning.coordinate(parseFloat(r.lat), parseFloat(r.lon))
					results.append({
						name: r.name && r.name.length ? r.name
							: r.display_name.split(",")[0],
						detail: r.display_name,
						lat: c.latitude,
						lon: c.longitude,
						far: near ? near.distanceTo(c) : 0
					})
				}
				status = "ready"
			} catch (e) {
				status = "error"
				failure = qsTr("I could not understand the search response")
			}
		}
		x.open("GET", url)
		x.setRequestHeader("User-Agent", "PocoNav/1.0 (postmarketOS; personal use)")
		x.send()
	}

	// --- distances, in whatever the driver uses ----------------------------
	// Internally EVERYTHING is metres; here and only here it is turned into what is read.
	//
	// In miles FEET are used below 0.1 mile and not yards: it is what
	// navigators in the US say and what people expect to hear. The cut-off
	// is at 528 feet, which is half a mile divided by five -- round in their
	// system, ugly in ours, and that is why dividing by a thousand does not work.
	property bool miles: false

	function _dist(m) {
		if (miles) {
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

	function _farText(m) {
		return m <= 0 ? "" : "  ·  " + _dist(m)
	}

	ListModel { id: results }
	ListModel { id: favorites }

	// Tapping outside closes. Also stops taps reaching the map underneath.
	MouseArea {
		anchors.fill: parent
		onClicked: finder.close()
	}

	Rectangle {
		anchors.fill: parent
		color: "#000000"
		opacity: 0.45
	}

	Rectangle {
		// Anchored to the top rather than centred: the virtual keyboard eats
		// the bottom half of a phone, and in landscape it eats more than half.
		anchors.top: parent.top
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.topMargin: Kirigami.Units.largeSpacing
		width: Math.min(parent.width - Kirigami.Units.largeSpacing * 2,
			Kirigami.Units.gridUnit * 36)
		height: Math.min(parent.height - Kirigami.Units.largeSpacing * 2,
			content.implicitHeight + Kirigami.Units.largeSpacing * 2)
		radius: finder.p.cornerRadiusLarge
		color: finder.p.surface

		// Swallows the taps that would otherwise close the sheet.
		MouseArea { anchors.fill: parent }

		ColumnLayout {
			id: content
			anchors.fill: parent
			anchors.margins: Kirigami.Units.largeSpacing
			spacing: Kirigami.Units.smallSpacing

			RowLayout {
				Layout.fillWidth: true
				spacing: Kirigami.Units.smallSpacing

				QQC2.TextField {
					id: field
					Layout.fillWidth: true
					Layout.preferredHeight: finder.tall
					placeholderText: qsTr("Where to?")
					font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.3
					inputMethodHints: Qt.ImhNoPredictiveText
					onAccepted: finder.search()
					onTextChanged: finder.onTyping()
					color: finder.p.inkDark
					placeholderTextColor: finder.p.inkSoft
					leftPadding: Kirigami.Units.largeSpacing * 1.5
					rightPadding: leftPadding
					background: Rectangle {
						radius: height / 2
						color: finder.p.white
					}
				}

				QQC2.AbstractButton {
					id: magnifyButton
					Layout.preferredWidth: finder.tall
					Layout.preferredHeight: finder.tall
					onClicked: finder.search()
					background: Rectangle {
						radius: height / 2
						color: magnifyButton.pressed ? finder.p.blueCasing : finder.p.blue
					}
					contentItem: Kirigami.Icon {
						source: "search"
						isMask: true
						color: finder.p.white
					}
				}

				QQC2.AbstractButton {
					id: closeButton
					Layout.preferredWidth: finder.tall
					Layout.preferredHeight: finder.tall
					onClicked: finder.close()
					background: Rectangle {
						radius: height / 2
						color: closeButton.pressed ? finder.p.inkSoft : finder.p.surfaceHigh
					}
					contentItem: Kirigami.Icon {
						source: "dialog-close"
						isMask: true
						color: finder.p.ink
					}
				}
			}

			QQC2.Label {
				Layout.fillWidth: true
				visible: text.length > 0
				text: {
					if (finder.status === "searching")
						return qsTr("Searching…")
					if (finder.noNetwork)
						return qsTr("No connection. Your saved places still work, and "
							+ "you can hold your finger on the map to set "
							+ "the destination there.")
					if (finder.status === "error")
						return finder.failure
					if (finder.status === "ready" && results.count === 0)
						return qsTr("No results")
					if (finder.status !== "ready" && favorites.count === 0)
						return finder.hasLocal
							? qsTr("Type: it searches on its own.")
							: qsTr("Type a place, a street or a town.")
					return ""
				}
				color: finder.p.inkSoft
				wrapMode: Text.WordWrap
				padding: Kirigami.Units.smallSpacing
			}

			// --- saved places, while there is nothing else to show ---------
			QQC2.Label {
				Layout.fillWidth: true
				visible: favoritesList.visible
				text: qsTr("Saved")
				font.bold: true
				color: finder.p.inkSoft
				padding: Kirigami.Units.smallSpacing
			}

			ListView {
				id: favoritesList
				Layout.fillWidth: true
				Layout.preferredHeight: Math.min(count * finder.tall * 1.2,
					Kirigami.Units.gridUnit * 14)
				visible: count > 0 && results.count === 0
				clip: true
				model: favorites
				spacing: 1

				delegate: QQC2.ItemDelegate {
					id: favRow
					width: ListView.view.width
					height: finder.tall * 1.2
					// Without this, Breeze paints the delegate white and the light
					// text on top is illegible over the dark sheet.
					background: Rectangle {
						radius: finder.p.cornerRadius
						color: favRow.pressed ? finder.p.surfaceHigh : "transparent"
					}
					onClicked: {
						finder.chosen(QtPositioning.coordinate(model.lat, model.lon),
							model.name)
						finder.close()
					}

					contentItem: RowLayout {
						spacing: Kirigami.Units.smallSpacing
						QQC2.Label {
							Layout.fillWidth: true
							text: model.name + finder._farText(finder.near
								? finder.near.distanceTo(
									QtPositioning.coordinate(model.lat, model.lon)) : 0)
							font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.15
							color: finder.p.ink
							elide: Text.ElideRight
						}
						QQC2.AbstractButton {
							id: forgetButton
							Layout.preferredWidth: finder.tall
							Layout.preferredHeight: finder.tall
							onClicked: finder.forget(model.index)
							background: Rectangle {
								radius: height / 2
								color: forgetButton.pressed ? finder.p.surfaceHigh : "transparent"
							}
							contentItem: Kirigami.Icon {
								source: "edit-delete"
								isMask: true
								color: finder.p.inkSoft
							}
						}
					}
				}
			}

			// --- what the search found -------------------------------------
			ListView {
				Layout.fillWidth: true
				Layout.preferredHeight: Math.min(count * finder.tall * 1.5,
					Kirigami.Units.gridUnit * 20)
				visible: count > 0
				clip: true
				model: results
				spacing: 1

				delegate: QQC2.ItemDelegate {
					id: resultRow
					width: ListView.view.width
					height: finder.tall * 1.5
					background: Rectangle {
						radius: finder.p.cornerRadius
						color: resultRow.pressed ? finder.p.surfaceHigh : "transparent"
					}
					onClicked: {
						finder.chosen(QtPositioning.coordinate(model.lat, model.lon),
							model.name)
						finder.close()
					}

					contentItem: RowLayout {
						spacing: Kirigami.Units.smallSpacing

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0
							QQC2.Label {
								Layout.fillWidth: true
								text: model.name + finder._farText(model.far)
								font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.15
								font.bold: true
								color: finder.p.ink
								elide: Text.ElideRight
							}
							QQC2.Label {
								Layout.fillWidth: true
								text: model.detail
								font.pointSize: Kirigami.Theme.smallFont.pointSize
								color: finder.p.inkSoft
								elide: Text.ElideRight
							}
						}

						QQC2.AbstractButton {
							id: favButton
							Layout.preferredWidth: finder.tall
							Layout.preferredHeight: finder.tall
							onClicked: finder.save(model.name, model.lat, model.lon)
							background: Rectangle {
								radius: height / 2
								color: favButton.pressed ? finder.p.surfaceHigh : "transparent"
							}
							contentItem: Kirigami.Icon {
								source: "bookmark-new"
								isMask: true
								color: finder.p.inkSoft
							}
						}
					}
				}
			}

			// --- how the route gets calculated -----------------------------
			// Here and not in a settings screen: these change the road
			// you will be given, so they go next to the destination.
			//
			// They FORBID nothing: the planner also shows the routes that
			// break them, marked, and asks before taking you down one. What they
			// decide is which comes first and which carries a warning.
			RowLayout {
				Layout.fillWidth: true
				Layout.topMargin: Kirigami.Units.smallSpacing
				spacing: Kirigami.Units.smallSpacing

				QQC2.AbstractButton {
					id: swTolls
					Layout.fillWidth: true
					// Starting width ZERO so the split is in equal
					// parts. With only fillWidth each button keeps what
					// its text asks for, and "Avoid unpaved" is longer
					// than "Avoid ferries": the two rows did not line up.
					Layout.preferredWidth: 0
					Layout.preferredHeight: finder.tall
					onClicked: finder.toggleTolls()
					background: Rectangle {
						radius: height / 2
						color: finder.avoidTolls ? finder.p.blue : finder.p.surfaceHigh
					}
					contentItem: QQC2.Label {
						text: qsTr("Avoid tolls")
						color: finder.p.ink
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}

				QQC2.AbstractButton {
					id: swMotorways
					Layout.fillWidth: true
					// Starting width ZERO so the split is in equal
					// parts. With only fillWidth each button keeps what
					// its text asks for, and "Avoid unpaved" is longer
					// than "Avoid ferries": the two rows did not line up.
					Layout.preferredWidth: 0
					Layout.preferredHeight: finder.tall
					onClicked: finder.toggleMotorways()
					background: Rectangle {
						radius: height / 2
						color: finder.avoidMotorways ? finder.p.blue : finder.p.surfaceHigh
					}
					contentItem: QQC2.Label {
						text: qsTr("Avoid motorways")
						color: finder.p.ink
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}
			}

			// Second row. These two are used far less -- a ferry only
			// appears when going to the islands or to Ceuta -- but when they appear,
			// finding out halfway is too late.
			RowLayout {
				Layout.fillWidth: true
				spacing: Kirigami.Units.smallSpacing

				QQC2.AbstractButton {
					id: swFerries
					Layout.fillWidth: true
					// Starting width ZERO so the split is in equal
					// parts. With only fillWidth each button keeps what
					// its text asks for, and "Avoid unpaved" is longer
					// than "Avoid ferries": the two rows did not line up.
					Layout.preferredWidth: 0
					Layout.preferredHeight: finder.tall
					onClicked: finder.toggleFerries()
					background: Rectangle {
						radius: height / 2
						color: finder.avoidFerries ? finder.p.blue : finder.p.surfaceHigh
					}
					contentItem: QQC2.Label {
						text: qsTr("Avoid ferries")
						color: finder.p.ink
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}

				QQC2.AbstractButton {
					id: swUnpaved
					Layout.fillWidth: true
					// Starting width ZERO so the split is in equal
					// parts. With only fillWidth each button keeps what
					// its text asks for, and "Avoid unpaved" is longer
					// than "Avoid ferries": the two rows did not line up.
					Layout.preferredWidth: 0
					Layout.preferredHeight: finder.tall
					onClicked: finder.toggleUnpaved()
					background: Rectangle {
						radius: height / 2
						color: finder.avoidUnpaved ? finder.p.blue : finder.p.surfaceHigh
					}
					contentItem: QQC2.Label {
						text: qsTr("Avoid unpaved")
						color: finder.p.ink
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
					}
				}
			}

			QQC2.Label {
				Layout.fillWidth: true
				// With a margin: flush to the edge it looked like cut-off text, not a
				// credit.
				Layout.rightMargin: Kirigami.Units.smallSpacing
				Layout.topMargin: Kirigami.Units.smallSpacing
				text: qsTr("Search by OpenStreetMap (Nominatim)")
				font.pointSize: Kirigami.Theme.smallFont.pointSize
				color: finder.p.inkSoft
				opacity: 0.8
				horizontalAlignment: Text.AlignRight
			}
		}
	}
}
