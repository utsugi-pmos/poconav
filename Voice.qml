// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The voice: when to speak, and with what.
//
// The phrases are NOT written here. Valhalla already returns three different
// wordings per maneuver, meant to be read aloud and without abbreviations:
//
//   verbal_transition_alert_instruction   the far-off alert
//   verbal_pre_transition_instruction     just before, with the distance in it
//   verbal_post_transition_instruction    what comes next
//
// Composing the phrases ourselves would mean rewriting, worse, what the router
// has already done well, and in the wrong language.
//
// HOW THE SOUND COMES OUT. It was attempted through QtTextToSpeech, which would
// be the natural way, and IT CANNOT BE DONE: Alpine builds `qt6-qtspeech` with
// two connectors and only two -- `flite` and `mock` (checked with `apk info -L`,
// and neither links libspeechd). Flite speaks `en_US` and nothing else.
// Installing speech-dispatcher changes nothing, because the connector that would
// use it is not compiled, and there is no subpackage that brings it.
//
// But `espeak-ng` does speak Spanish. So the phrase comes out through the SAME
// channel the screen already uses: the application writes it into its settings
// file and the startup script reads it and calls espeak-ng. Ugly, yes; but it is
// honest, it does not force compiling Qt by hand and the write is immediate
// (measured).
//
// If one day a connector with Spanish appeared, `hasSpanish` sets itself to true
// and the voice comes out through Qt without touching anything else.
import QtQuick
import QtTextToSpeech

TextToSpeech {
	id: voice

	property bool active: true
	// If Qt could speak Spanish, Qt would be used. Today it cannot.
	property bool hasSpanish: false

	// The fallback output: whoever listens to this takes care of saying it.
	signal speakOut(string phrase)

	// Which maneuver has already been announced, and at which of the two moments.
	// Without this it would repeat the same phrase on every GPS fix, that is once
	// per second.
	property int _warned: -1
	property int _said: -1
	// The maneuver in which "continue for N" was already said.
	property int _continued: -1

	volume: 1.0

	Component.onCompleted: pickVoice()
	onEngineChanged: _findSpanish()

	function pickVoice() {
		// speechd is the one that brings the real languages; flite is the default
		// one and only has English. Changing engine re-enumerates the languages,
		// so this goes first.
		const engines = availableEngines()
		if (engines.indexOf("speechd") >= 0 && engine !== "speechd")
			engine = "speechd"
		else
			_findSpanish()
	}

	function _findSpanish() {
		hasSpanish = false
		const languages = availableLocales()
		// es_ES is preferred if present; if not, any Spanish will do: a different
		// accent is understood, an English voice is not.
		for (var i = 0; i < languages.length; ++i) {
			if (languages[i].name.indexOf("es_ES") === 0) {
				locale = languages[i]
				hasSpanish = true
				return
			}
		}
		for (var j = 0; j < languages.length; ++j) {
			if (languages[j].name.indexOf("es") === 0) {
				locale = languages[j]
				hasSpanish = true
				return
			}
		}
	}

	function speak(text) {
		if (!active || !text)
			return
		if (hasSpanish) {
			// Cut off whatever it was saying, do not queue: in a car the new
			// instruction always overrides the old one, and a queue ends up
			// talking about a junction you have already passed.
			if (state === TextToSpeech.Speaking)
				stop()
			say(text)
			return
		}
		speakOut(text)
	}

	// On changing route what was said must be forgotten, or the first maneuver of
	// the new route would go unannounced for having the same index.
	function reset() {
		_warned = -1
		_said = -1
		_continued = -1
	}

	// SHUT UP NOW. Not the same as 'reset': that forgets what was said, and
	// this cuts off what is playing. On cancelling a route both are needed, or the
	// speaker carries on with an instruction from a trip that no longer exists.
	signal stopSpeaking()
	function silence() {
		if (hasSpanish && state === TextToSpeech.Speaking)
			stop()
		reset()
		stopSpeaking()
	}

	// Called on every GPS fix. Two announcements per maneuver: one from far off
	// so you can change lane, and another right on top of the junction.
	function follow(route, speed) {
		if (!active || !route || !route.exists)
			return
		const next = route.maneuver + 1
		if (next >= route.maneuvers.length)
			return

		// The distances scale with speed: at 120 km/h, 350 m is ten seconds and
		// arrives late; in the city, 900 m is three junctions early and you would
		// not know which one it means.
		const fast = speed > 22        // ~80 km/h
		const far = fast ? 900 : 350
		const near = fast ? 250 : 110

		// "Continue for three kilometres", on entering the stretch. Only if the
		// stretch is long: saying it every two hundred metres in the city would be
		// a parrot. Valhalla already writes the phrase.
		const current = route.maneuvers[route.maneuver]
		if (_continued !== route.maneuver) {
			_continued = route.maneuver
			if (current && current.afterwards && current.meters > 1200)
				speak(current.afterwards)
		}

		const m = route.maneuvers[next]
		const d = route.metersToManeuver

		if (_warned !== next && d <= far && d > near) {
			speak(m.warning || m.spoken)
			_warned = next
		}
		if (_said !== next && d <= near) {
			speak(m.spoken)
			_said = next
			// The far-off alert no longer applies even if it was never given.
			_warned = next
		}
	}
}
