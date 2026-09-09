// SPDX-License-Identifier: LGPL-2.0-or-later
//
// `poconav --only-map` -- a map and nothing else.
//
// WHY IT EXISTS
// -------------
// Because the map with MapLibre was not requesting a single tile and there was no
// way to know whether the fault was the connector's or that of everything main.qml
// puts around it: a Loader that rebuilds it, layers on top, panels that cover it,
// bindings that change its heading and zoom.
//
// Here there is none of that. If the map draws on this screen and not on the real
// one, the fault is in the wrapper. If it does not draw here either, it is the
// connector's, and then at least you look in the right place.
//
// The connector is passed on the command line so the two can be compared on the
// same screen:
//
//     poconav --only-map            maplibre against the own server
//     poconav --only-map osm        the usual one, over the internet
import QtQuick
import QtQuick.Window
import QtLocation
import QtPositioning

Window {
	id: window
	visible: true
	width: 720
	height: 1280
	color: "#202020"
	title: "PocoNav: map only"

	// 'mapOnly' is set by main.cpp: "maplibre", "osm" or "minimum".
	//
	// "minimum" is maplibre with a hand-written three-layer style, with no labels
	// or icons. It serves to separate two faults that from outside look the same:
	// MapLibre not drawing here, or the big style -- 107 layers of someone else's
	// JSON -- missing or having something extra.
	readonly property string mode: mapOnly || "maplibre"
	readonly property string connector: mode === "osm" ? "osm" : "maplibre"
	readonly property string theme: mode === "minimum" ? "minimum" : "light"

	Map {
		id: map
		anchors.fill: parent
		// Bolnuevo, which is the area that has been downloaded.
		center: QtPositioning.coordinate(37.5875, -1.2531)
		zoomLevel: 13

		plugin: Plugin {
			name: window.connector

			PluginParameter {
				name: "maplibre.map.styles"
				value: "http://127.0.0.1:8554/map/style?theme=" + window.theme
			}
			PluginParameter {
				name: "osm.mapping.providersrepository.address"
				value: "file:///usr/share/poconav/providers/light"
			}
			PluginParameter {
				name: "osm.useragent"
				value: "PocoNav/1.0 (postmarketOS; personal use)"
			}
		}

		Component.onCompleted: {
			console.log("only-map: mode", window.mode, "| connector", plugin.name,
				"| types:", supportedMapTypes.length,
				"| size:", width + "x" + height)
		}

		onMapReadyChanged: console.log("only-map: mapReady =", mapReady)
	}

	// Every two seconds it moves a little. A still map may request nothing because
	// it already has what it shows; moving it forces new tiles to be requested and
	// distinguishes "does not request" from "does not need to".
	Timer {
		interval: 2000
		running: true
		repeat: true
		property int ticks: 0
		onTriggered: {
			ticks += 1
			map.zoomLevel = 12 + (ticks % 4)
			if (ticks === 10)
				console.log("only-map: 20 s spinning, zoom", map.zoomLevel)
		}
	}
}
