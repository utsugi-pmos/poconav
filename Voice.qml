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
// If one day a connector with Spanish appeared, `hayEspanol` sets itself to true
// and the voice comes out through Qt without touching anything else.
import QtQuick
import QtTextToSpeech

TextToSpeech {
	id: voz

	property bool activa: true
	// If Qt could speak Spanish, Qt would be used. Today it cannot.
	property bool hayEspanol: false

	// The fallback output: whoever listens to this takes care of saying it.
	signal hablar(string frase)

	// Which maneuver has already been announced, and at which of the two moments.
	// Without this it would repeat the same phrase on every GPS fix, that is once
	// per second.
	property int _avisada: -1
	property int _dicha: -1
	// The maneuver in which "continue for N" was already said.
	property int _continuada: -1

	volume: 1.0

	Component.onCompleted: elegirVoz()
	onEngineChanged: _buscarEspanol()

	function elegirVoz() {
		// speechd is the one that brings the real languages; flite is the default
		// one and only has English. Changing engine re-enumerates the languages,
		// so this goes first.
		const motores = availableEngines()
		if (motores.indexOf("speechd") >= 0 && engine !== "speechd")
			engine = "speechd"
		else
			_buscarEspanol()
	}

	function _buscarEspanol() {
		hayEspanol = false
		const idiomas = availableLocales()
		// es_ES is preferred if present; if not, any Spanish will do: a different
		// accent is understood, an English voice is not.
		for (var i = 0; i < idiomas.length; ++i) {
			if (idiomas[i].name.indexOf("es_ES") === 0) {
				locale = idiomas[i]
				hayEspanol = true
				return
			}
		}
		for (var j = 0; j < idiomas.length; ++j) {
			if (idiomas[j].name.indexOf("es") === 0) {
				locale = idiomas[j]
				hayEspanol = true
				return
			}
		}
	}

	function decir(texto) {
		if (!activa || !texto)
			return
		if (hayEspanol) {
			// Cut off whatever it was saying, do not queue: in a car the new
			// instruction always overrides the old one, and a queue ends up
			// talking about a junction you have already passed.
			if (state === TextToSpeech.Speaking)
				stop()
			say(texto)
			return
		}
		hablar(texto)
	}

	// On changing route what was said must be forgotten, or the first maneuver of
	// the new route would go unannounced for having the same index.
	function reiniciar() {
		_avisada = -1
		_dicha = -1
		_continuada = -1
	}

	// SHUT UP NOW. Not the same as 'reiniciar': that forgets what was said, and
	// this cuts off what is playing. On cancelling a route both are needed, or the
	// speaker carries on with an instruction from a trip that no longer exists.
	signal callar()
	function silenciar() {
		if (hayEspanol && state === TextToSpeech.Speaking)
			stop()
		reiniciar()
		callar()
	}

	// Called on every GPS fix. Two announcements per maneuver: one from far off
	// so you can change lane, and another right on top of the junction.
	function seguir(ruta, velocidad) {
		if (!activa || !ruta || !ruta.hay)
			return
		const siguiente = ruta.maniobra + 1
		if (siguiente >= ruta.maniobras.length)
			return

		// The distances scale with speed: at 120 km/h, 350 m is ten seconds and
		// arrives late; in the city, 900 m is three junctions early and you would
		// not know which one it means.
		const rapido = velocidad > 22        // ~80 km/h
		const lejos = rapido ? 900 : 350
		const cerca = rapido ? 250 : 110

		// "Continue for three kilometres", on entering the stretch. Only if the
		// stretch is long: saying it every two hundred metres in the city would be
		// a parrot. Valhalla already writes the phrase.
		const actual = ruta.maniobras[ruta.maniobra]
		if (_continuada !== ruta.maniobra) {
			_continuada = ruta.maniobra
			if (actual && actual.luego && actual.metros > 1200)
				decir(actual.luego)
		}

		const m = ruta.maniobras[siguiente]
		const d = ruta.metrosHastaManiobra

		if (_avisada !== siguiente && d <= lejos && d > cerca) {
			decir(m.aviso || m.dilo)
			_avisada = siguiente
		}
		if (_dicha !== siguiente && d <= cerca) {
			decir(m.dilo)
			_dicha = siguiente
			// The far-off alert no longer applies even if it was never given.
			_avisada = siguiente
		}
	}
}
