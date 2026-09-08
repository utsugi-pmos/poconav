// SPDX-License-Identifier: LGPL-2.0-or-later
//
// Several routes between two points, so you can choose.
//
// THE IDEA. A navigator that gives only ONE route forces you to accept its rules. If
// you asked to avoid tolls, it takes you through villages twenty minutes longer and does not tell you
// there was a motorway right next to it. Measured, Cartagena -> Vera:
//
//   with toll   110.8 km   69 min
//   no toll     140.8 km   88 min
//
// Nineteen minutes is a decision, and the decision is the driver's. So
// both are shown, with the compliant one first and the other marked.
//
// HOW THEY ARE OBTAINED. Valhalla returns alternatives with `alternates`, but they all
// respect the same preferences: asking for "no tolls" you will never see the toll
// one. TWO requests are needed:
//
//   A  with your filters on         -> the ones that comply
//   B  with your filters relaxed    -> the ones that exist, compliant or not
//
// B is only requested if some filter is active; with no filters there is nothing to
// break and it would be spending double for nothing.
//
// HOW WE KNOW WHAT IT BREAKS. Valhalla's summary carries `has_toll`,
// `has_highway` and `has_ferry` -- verified by reading the keys it returns, not
// assumed. Surface carries NONE: there is no way to ask a route
// whether it goes over dirt without requesting the attributes of each segment, which is another request
// per route.
//
// It is deduced: a route that ONLY appears when the filters are relaxed breaks one
// by construction. If no flag explains it and the dirt filter was
// on, it is that one. It costs not one extra request.
import QtQuick
import QtPositioning

QtObject {
	id: plan

	// What the user asked to avoid.
	property bool evitarPeajes: false
	property bool evitarAutopistas: false
	property bool evitarFerris: false
	property bool evitarTierra: false

	property var origen: null
	property var destino: null
	property string nombreDestino: ""

	// "", "pidiendo", "listo", "error"
	property string estado: ""
	property string fallo: ""

	// How many are shown. Four fit on screen without scrolling, and scrolling
	// a list with the car moving is not something you can ask for.
	readonly property int cuantas: 4

	// Cada entrada: { trip, minutos, metros, peaje, autopista, ferri, tierra,
	//                 cumple, aviso, resumen }
	property var rutas: []
	readonly property bool hay: estado === "listo" && rutas.length > 0

	readonly property bool hayFiltros: evitarPeajes || evitarAutopistas
		|| evitarFerris || evitarTierra

	signal listo()

	// --- request ------------------------------------------------------------

	property var _servidor: null   // set by whoever uses us: the effective Route.servidor
	property string servidorLocal: "http://127.0.0.1:8554"
	property string servidorPublico: "https://valhalla1.openstreetmap.de/route"
	property bool hayLocal: false
	// The same order as in Route.qml, and for the same reasons: the internet is in charge
	// while there is any because it sees this week's closures, and the phone answers
	// when there is none. See the long comment there.
	property bool hayRed: app.hayRed
	readonly property bool _primeroFuera: hayRed || !hayLocal
	readonly property string agente: "PocoNav/1.0 (postmarketOS; personal use)"
	property string idioma: "es-ES"
	// Same treatment as in Route: it is requested in the driver's units and
	// converted to metres on the way in.
	property bool millas: false
	readonly property real _aMetros: millas ? 1609.344 : 1000

	property var _a: null
	property var _b: null
	property var _crudoA: null
	property var _crudoB: null

	function planificar(desde, aDonde, nombre) {
		if (!desde || !aDonde)
			return
		cancelar()

		origen = desde
		destino = aDonde
		nombreDestino = nombre || ""
		estado = "pidiendo"
		fallo = ""
		rutas = []
		_crudoA = null
		_crudoB = null

		// With the user's filters.
		_a = _pedir(_consulta(true), function (r) {
			plan._crudoA = r
			plan._quizaTerminar()
		}, function (porque) {
			// If the compliant one fails, there is nothing to show even if the other
			// arrives: it would be offering only routes the user does not want.
			//
			// The reason is written BEFORE the state, and not the other way round: whoever
			// listens to estadoChanged runs at once, and if the state changes
			// first it reads a still-empty reason. The self-test said
			// literally "FAIL plan: " with nothing after it.
			plan.fallo = porque
			plan.estado = "error"
		})

		if (hayFiltros) {
			_b = _pedir(_consulta(false), function (r) {
				plan._crudoB = r
				plan._quizaTerminar()
			}, function () {
				// The alternatives that break rules are a bonus. Their failing must
				// not cost the good route.
				plan._crudoB = { trip: null }
				plan._quizaTerminar()
			})
		}
	}

	// Cancellation goes through the LIST of live requests and not through _a/_b, because the
	// network retry creates a new request: keeping only the first,
	// changing destination while the retry was in flight let a response
	// from the previous trip arrive and be drawn as if it were the new one's.
	property var _vivas: []

	function cancelar() {
		for (var i = 0; i < _vivas.length; ++i)
			_vivas[i].abort()
		_vivas = []
		_a = null
		_b = null
	}

	function _consulta(conFiltros) {
		// 0 is not "forbidden" but "only if there is no other way". A hard
		// ban can answer that there is no route, and whoever asked to avoid tolls
		// still wants to arrive.
		const c = conFiltros
		return {
			locations: [
				{ lat: origen.latitude, lon: origen.longitude },
				{ lat: destino.latitude, lon: destino.longitude }
			],
			costing: "auto",
			// Three alternatives per request. With the two requests up to
			// six come out, and from there they are trimmed to the four best.
			alternates: 3,
			costing_options: {
				auto: {
					use_tolls: (c && evitarPeajes) ? 0.0 : 0.5,
					use_highways: (c && evitarAutopistas) ? 0.0 : 0.5,
					use_ferry: (c && evitarFerris) ? 0.0 : 0.5,
					use_tracks: (c && evitarTierra) ? 0.0 : 0.5
				}
			},
			directions_options: { language: idioma, units: millas ? "miles" : "kilometers" }
		}
	}

	// `enCasa` says who it is asked of, and it is separated from the rest so it can
	// RETRY over the network without rebuilding the query -- like in Route.qml.
	//
	// Without that retry the planner gave up as soon as the home server
	// said no, and saying no is normal outside the downloaded regions:
	// asking Murcia -> Paris with only Spain and Andorra gives a 400 in 15 ms.
	// The rule is "no coverage whenever possible, network when there is no other
	// thing", and without this the second half did not exist: with the maps in place, the
	// planner NEVER used the internet, not even when it was the only way.
	//
	// Measured on the phone, with Spain and Andorra downloaded:
	//   Murcia -> Andorra   1443 ms on the phone   (663 km, crosses two regions)
	//   Murcia -> Paris       15 ms   400 "No suitable edges near location"
	// The second is the one now re-requested over the network.
	function _pedir(consulta, alSalir, alFallar, enCasa, yaReintentado) {
		if (enCasa === undefined)
			enCasa = !_primeroFuera
		const x = new XMLHttpRequest()
		const url = (enCasa ? servidorLocal + "/route" : servidorPublico)
			+ "?json=" + encodeURIComponent(JSON.stringify(consulta))
		// Like in Route.qml: if the first cannot, the other is tried
		// ONCE, and only if the other exists.
		const hayOtro = enCasa ? true : hayLocal
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			if (x.status !== 200) {
				if (hayOtro && !yaReintentado) {
					// The flags are NOT touched: this trip leaves the downloaded
					// maps or this server is down now, but the next one
					// may be inside. Turning them off here would send
					// all the remaining routes of the session the same way.
					plan._pedir(consulta, alSalir, alFallar, !enCasa, true)
					return
				}
				alFallar(x.status === 0 ? qsTr("no connection to the routing server")
					: qsTr("the routing server responded %1").arg(x.status))
				return
			}
			try {
				alSalir(JSON.parse(x.responseText))
			} catch (e) {
				// A 200 with garbage inside counts as a failure: the other
				// is tried just as with an error code.
				if (hayOtro && !yaReintentado) {
					plan._pedir(consulta, alSalir, alFallar, !enCasa, true)
					return
				}
				alFallar(qsTr("I could not understand the server response"))
			}
		}
		x.open("GET", url)
		x.setRequestHeader("User-Agent", agente)
		x.send()
		_vivas.push(x)
		return x
	}

	// --- merge and sort -----------------------------------------------------

	function _quizaTerminar() {
		if (estado !== "pidiendo")
			return
		if (!_crudoA || (hayFiltros && !_crudoB))
			return
		_montar()
	}

	// Pulls the list of trips out of a response: the main one and its alternatives.
	function _viajes(respuesta) {
		if (!respuesta || !respuesta.trip)
			return []
		const fuera = [respuesta.trip]
		const alt = respuesta.alternates || []
		for (var i = 0; i < alt.length; ++i)
			if (alt[i].trip)
				fuera.push(alt[i].trip)
		return fuera
	}

	// Two routes are "the same" if they match in distance and time when rounded.
	// The two requests almost always return some duplicate, and showing the
	// same route twice with different labels would be absurd.
	function _clave(t) {
		return Math.round(t.summary.length * 10) + "/" + Math.round(t.summary.time)
	}

	function _montar() {
		const vistos = {}
		const lista = []

		function anyadir(t, deLosQueCumplen) {
			const k = _clave(t)
			if (vistos[k])
				return
			vistos[k] = true

			const s = t.summary
			const peaje = s.has_toll === true
			const autopista = s.has_highway === true
			const ferri = s.has_ferry === true

			// What it breaks, of what the user asked to avoid.
			const roto = []
			if (evitarPeajes && peaje) roto.push("peaje")
			if (evitarAutopistas && autopista) roto.push("autopista")
			if (evitarFerris && ferri) roto.push("ferri")

			// Dirt by elimination: it comes from the relaxed group and no flag
			// explains it, so the filter it breaks can only be that one.
			const tierra = !deLosQueCumplen && evitarTierra && roto.length === 0
			if (tierra) roto.push("tierra")

			lista.push({
				trip: t,
				minutos: Math.round(s.time / 60),
				metros: s.length * _aMetros,
				peaje: peaje,
				autopista: autopista,
				ferri: ferri,
				tierra: tierra,
				cumple: deLosQueCumplen && roto.length === 0,
				aviso: roto,
				resumen: _porDonde(t)
			})
		}

		const cumplen = _viajes(_crudoA)
		for (var i = 0; i < cumplen.length; ++i)
			anyadir(cumplen[i], true)
		const otras = _viajes(_crudoB)
		for (var j = 0; j < otras.length; ++j)
			anyadir(otras[j], false)

		// First the ones that respect your criteria, and within each group the one that
		// gets you there soonest. A toll one never comes on top if you asked to avoid them.
		lista.sort(function (a, b) {
			if (a.cumple !== b.cumple)
				return a.cumple ? -1 : 1
			return a.minutos - b.minutos
		})

		rutas = lista.slice(0, cuantas)
		estado = "listo"
		listo()
	}

	// "via A-30 and RM-2": the named roads you spend the most time on. Without
	// this, four rows that differ by only two minutes are
	// indistinguishable.
	function _porDonde(t) {
		const porVia = {}
		const piernas = t.legs || []
		for (var i = 0; i < piernas.length; ++i) {
			const ms = piernas[i].maneuvers || []
			for (var j = 0; j < ms.length; ++j) {
				const nombres = ms[j].street_names
				if (!nombres || !nombres.length)
					continue
				const v = String(nombres[0])
				porVia[v] = (porVia[v] || 0) + (ms[j].time || 0)
			}
		}
		const orden = Object.keys(porVia).sort(function (a, b) {
			return porVia[b] - porVia[a]
		})
		if (!orden.length)
			return ""
		return qsTr("via %1").arg(orden.slice(0, 2).join(qsTr(" and ")))
	}
}
