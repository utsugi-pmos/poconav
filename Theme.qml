// SPDX-License-Identifier: LGPL-2.0-or-later
//
// Every colour and every corner radius in PocoNav, in one file.
//
// The look is Google Maps' driving mode on Android Auto, on purpose: it is the
// one navigation interface most drivers already know, so the blue maneuver
// card, the green arrival time and the white round buttons all mean something
// before you read them. Copying a visual language that is already in the
// driver's head is worth more than any originality here.
//
// It does NOT follow the desktop theme. A navigator has to look the same at
// noon and at midnight, and a white panel on a windscreen at night is a lamp
// pointed at the driver. Change these values and the whole application follows.
//
// NOW it IS a singleton, and before it could not be: a qmldir was needed, and with
// qmlscene there was none. Since the application is a real QML module,
// qt_add_qml_module generates it on its own.
//
// It matters because 'noche' is a SHARED state. With one instance per file there
// would be ten copies of the switch and it would have to be passed by hand from
// parent to child; one badly wired copy and half the interface stays in day mode.
pragma Singleton
import QtQuick

QtObject {
	// --- day or night -------------------------------------------------------
	// Set by the window, from the settings or from the dusk time. The panels were
	// always dark anyway -- a white panel on a windscreen at night is a lamp
	// pointed at the driver -- so at night it does NOT get darker: it is TURNED
	// OFF. The same colours, lowered in intensity, because at three in the morning
	// the midday blue dazzles just as much as white.
	property bool noche: false

	// --- brand ------------------------------------------------------------
	readonly property color azul: noche ? "#174ea6" : "#1a73e8"   // maneuver card
	readonly property color azulClaro: noche ? "#3367d6" : "#4285f4" // the route
	readonly property color azulCasco: noche ? "#0d3c78" : "#1558b0" // its casing
	readonly property color verde: noche ? "#1e8e3e" : "#34a853"  // arrival time
	readonly property color ambar: noche ? "#c68a00" : "#f9ab00"  // a guess
	readonly property color rojo: noche ? "#b3261e" : "#ea4335"

	// --- surfaces ---------------------------------------------------------
	// Blacker at night and not just darker: on an OLED screen black emits nothing,
	// so the panel stops existing instead of being a grey rectangle floating on the
	// dashboard.
	readonly property color fondo: noche ? "#000000" : "#202124"
	readonly property color fondoAlto: noche ? "#1b1b1d" : "#303134"
	readonly property color blanco: "#ffffff"
	// The text does not go full either at night: pure white on black in the dark
	// leaves a trail when the eyes move.
	readonly property color tinta: noche ? "#d6d7da" : "#ffffff"
	readonly property color tintaSuave: noche ? "#7c8085" : "#9aa0a6"
	readonly property color tintaOscura: "#202124" // text on white

	// --- shape ------------------------------------------------------------
	// Generous, like the real thing: cards are pebbles, not boxes.
	readonly property int radio: 16
	readonly property int radioGrande: 28
}
