// SPDX-License-Identifier: LGPL-2.0-or-later
//
// `poconav --portraits <folder>`: the application photographs itself.
//
// WHY, instead of a normal screenshot
// -------------------------------------------------
// Because the compositor's capture depends on the phone being in front, with the
// screen on and the session unlocked. With the session locked KWin
// returns a BLANK image on purpose, which is exactly what
// was happening to me: 10 kB captures, all identical, without a single clue.
//
// This needs none of that. It starts with QT_QPA_PLATFORM=offscreen, is
// painted in memory and saved with grabToImage. No screen is needed, nor for
// anyone to unlock, nor even for the phone to be at hand.
//
// And above all: it can portray screens that are hard to reproduce by hand --
// driving a specific route, with the route panel open, in both
// orientations -- and always the same ones, which is what is needed to compare
// a margin change with what came before.
//
// THE CANVAS. `root.canvas` is photographed and not the window: the contentItem of a
// window is built by C++ and grabToImage rejects it with "item has no QML
// engine". That is why everything visible hangs off an Item made in QML.
import QtQuick
import QtPositioning

QtObject {
	id: portraits

	property var window: null
	property string folder: ""

	property int _step: 0
	property var _queue: []

	// A place with a roundabout and a motorway exit nearby, so the
	// maneuvers portrayed are the interesting ones.
	readonly property var begin: QtPositioning.coordinate(37.5875, -1.2531)
	readonly property var end: QtPositioning.coordinate(37.9917, -1.1305)
	// Cartagena -> Vera takes the AP-7 with a toll; Bolnuevo -> Murcia has
	// none, so with that one there would be nothing to warn about.
	readonly property var tollBegin: QtPositioning.coordinate(37.6155, -0.9875)
	readonly property var tollEnd: QtPositioning.coordinate(37.2410, -1.8630)

	function run() {
		// Each entry: the file name, whether it is landscape, and what to prepare.
		_queue = [
			{ f: "01-start-landscape",      wide: 1200, tall: 540,  prep: "explore" },
			{ f: "02-start-vertical",      wide: 540,  tall: 1200, prep: "explore" },
			{ f: "03-search-landscape",      wide: 1200, tall: 540,  prep: "search" },
			{ f: "04-search-vertical",      wide: 540,  tall: 1200, prep: "search" },
			{ f: "04b-results-vertical", wide: 540,  tall: 1200, prep: "results" },
			{ f: "05-settings-landscape",     wide: 1200, tall: 540,  prep: "settings" },
			{ f: "06-settings-vertical",     wide: 540,  tall: 1200, prep: "settings" },
			{ f: "07-routes-landscape",       wide: 1200, tall: 540,  prep: "routes" },
			{ f: "08-routes-vertical",       wide: 540,  tall: 1200, prep: "routes" },
			// THE OVERFLOWED LIST, which is the scroll indicator case.
			//
			// With three routes and a normal screen, the whole list fits and the
			// indicator does not show -- correct, but then there is no way to
			// check that it shows when it should. This screen is deliberately
			// SHORT to force the overflow with the same three routes.
			//
			// It is not a made-up size: 540x400 is what is left in landscape
			// with the keyboard open, which is a real situation.
			{ f: "08b-routes-overflowed",    wide: 540,  tall: 400,  prep: "routes" },
			{ f: "09-warning-landscape",       wide: 1200, tall: 540,  prep: "warning" },
			{ f: "10-drive-landscape",    wide: 1200, tall: 540,  prep: "drive" },
			{ f: "11-drive-vertical",    wide: 540,  tall: 1200, prep: "drive" }
		]
		_step = 0
		_next()
	}

	function _next() {
		if (_step >= _queue.length) {
			console.log("portraits: " + _queue.length + " in " + folder)
			Qt.exit(0)
			return
		}
		const e = _queue[_step]
		window.width = e.wide
		window.height = e.tall
		// The state is set again right before firing, not only here: on
		// opening, the application restores the last route on its own and starts
		// driving, and that clobbered the first portrait -- the driving screen
		// came out where the initial one should have.
		portraits._prepare(e.prep)
		// Two waits: one for the layout to be redone after changing the size
		// and another for whatever was requested over the network to arrive. Without the first
		// portraits come out with the previous orientation half-applied.
		shortWait.restart()
	}

	readonly property Timer shortWait: Timer {
		interval: 700
		onTriggered: longWait.restart()
	}

	readonly property Timer longWait: Timer {
		interval: 2500
		onTriggered: portraits._fire()
	}

	function _prepare(what) {
		const v = window
		if (what === "explore") {
			v.closeAll()
			v.mode = "explore"
		} else if (what === "search") {
			v.closeAll()
			v.mode = "explore"
			v.openFinder()
		} else if (what === "results") {
			v.closeAll()
			v.mode = "explore"
			v.searchInPortrait("cartagena")
			longWait.interval = 4000
		} else if (what === "settings") {
			v.closeAll()
			v.mode = "explore"
			v.openSettings()
		} else if (what === "routes" || what === "warning") {
			v.closeAll()
			// With the toll filter on for the warning: it is the only way
			// for there to be a route that breaks a rule and the dialog to exist.
			v.setTollFilter(what === "warning")
			if (what === "warning")
				v.planFrom(tollBegin, tollEnd, "Vera")
			else
				v.planFrom(begin, end, "Murcia")
			if (what === "warning")
				longWait.interval = 9000   // two requests, and over the network they are slow
		} else if (what === "drive") {
			v.closeAll()
			v.driveTest(begin, end)
			// More wait: the route has to be computed, the car started and let
			// to travel a stretch so the photo has speed and a real
			// maneuver ahead.
			longWait.interval = 12000
		}
	}

	function _fire() {
		const e = _queue[_step]
		if (e.prep === "explore" || e.prep === "search" || e.prep === "settings")
			portraits._prepare(e.prep)
		if (e.prep === "warning")
			window.showWarning()

		// A frame is left so that whatever was just requested is drawn before
		// the photo.
		Qt.callLater(function () {
			window.canvas.grabToImage(function (r) {
				r.saveToFile(portraits.folder + "/" + e.f + ".png")
				// What has actually been painted is measured, not what was requested:
				// with the 'offscreen' platform the size change is not
				// immediate and a portrait with the previous size misleads.
				console.log("  " + e.f + ".png  requested " + e.wide + "x" + e.tall
					+ "  canvas " + window.canvas.width + "x" + window.canvas.height
					+ "  mode " + window.mode
					+ "  buttons y=" + window.measureButtons())
				portraits._step += 1
				longWait.interval = 2500
				portraits._next()
			})
		})
	}
}
