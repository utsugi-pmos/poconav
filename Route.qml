// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The route: asking for one, understanding the answer, and knowing where along
// it you are.
//
// WHY VALHALLA AND NOT QtLocation's RouteModel. Qt's own routing speaks OSRM,
// and it works -- same road, same length. But Qt writes the turns itself, in
// English, and it loses things the driver needs. Measured on the same pair of
// points, Bolnuevo to Mazarron:
//
//   Qt/OSRM   "Enter the roundabout and take the second exit"
//             "exit roundabout to/onto  "        <- name missing, two steps
//                                                   for one roundabout
//   Valhalla  "Haga la rotonda y tome la salida 3.º hacia RM-D6."
//
// The server does the wording, so the language is a request parameter and the
// exit number is in it. Qt's parser cannot be made to do either.
//
// The price is that the HTTP call, the polyline and the progress along it are
// ours. That is what this file is.
import QtQuick
import QtPositioning

QtObject {
	id: ruta

	// --- the answer -------------------------------------------------------
	property var puntos: []          // coordinates, for the line on the map
	property var maniobras: []       // {tipo, texto, calle, metros, segundos, ini}
	property real metrosTotal: 0
	property real segundosTotal: 0
	property var destino: null       // coordinate asked for
	property string nombreDestino: ""
	// The polyline exactly as the server sent it. Kept because saving a route
	// to disk as thousands of lat/lon pairs is hundreds of kilobytes of JSON,
	// and this same string is a couple of hundred bytes per kilometre.
	property string forma: ""

	// "", "pidiendo", "lista", "error"
	property string estado: ""
	property string fallo: ""
	readonly property bool hay: estado === "lista" && puntos.length > 1

	// --- where you are on it ----------------------------------------------
	property int indice: 0           // nearest shape point
	property real desvio: 0          // metres from the line
	property int maniobra: 0         // which instruction is current
	property real metrosHastaManiobra: 0
	property real metrosRestantes: 0
	property real segundosRestantes: 0
	// 60 m is wide enough for GPS noise and a dual carriageway, narrow enough
	// that a wrong turn shows up within a block.
	readonly property bool fueraDeRuta: hay && desvio > 60

	// You have arrived. `indice > 0` is not redundant: without it, a twenty-metre route would
	// be declared finished before the car even starts.
	readonly property bool llegado: hay && indice > 0 && metrosRestantes < 25

	// The legal limit at the point where you are, in km/h. 0 = unknown, which is
	// different from "none", and that is why nothing is drawn instead of a zero.
	property var _limitePorPunto: []
	readonly property int limite: (_limitePorPunto.length > indice)
		? (_limitePorPunto[indice] || 0) : 0

	// Cumulative distance along `puntos`, so "how far to the next turn" is a
	// subtraction instead of a walk over the whole line every second.
	property var acumulado: []

	// The public Valhalla of FOSSGIS. Same project that serves the tiles, no
	// account, no key. Light use with an honest User-Agent is what its terms
	// ask for, which is exactly what a phone doing one route at a time is.
	readonly property string servidorPublico: "https://valhalla1.openstreetmap.de/route"
	// The application's own routing server: its backend starts it when
	// it opens and it dies with it. It speaks Valhalla JSON because it IS Valhalla
	// -- the same engine as the public one, loaded in here -- so the same
	// request and the same reader work for both.
	//
	// 127.0.0.1 and NOT "localhost", on purpose. Anyone resolving "localhost" to ::1
	// first gets a "connection refused" that looks like the server is
	// down. It had me chasing a ghost a whole night: wget failed and
	// python worked against the SAME server, at the same time.
	readonly property string servidorLocal: "http://127.0.0.1:8554"
	property bool hayLocal: false
	// Whether there is also something to DRAW with out of coverage. It is another flag, not the
	// same one: they download separately and you can have one without the other. The window
	// uses it to choose which connector draws the map.
	property bool dibujoLocal: false
	// THE TILES on disk, by name: ["7-63-49"].
	//
	// The list is needed, not just "there is or there is not". Having a drawing map and having
	// a map OF HERE are different things, and confusing them gives the worst possible
	// screen: blank and unexplained.
	property var cuadrosDibujo: []
	// Whether the home server has ever ANSWERED at all.
	//
	// Not the same as 'hayLocal': answering "I have no maps" is answering. It is
	// separate because it decides how often to ask again -- the server takes
	// a few seconds to load the tile index when the application starts, and
	// until it loads there is no one to ask.
	property bool sondeoContestado: false

	// THE ORDER: internet first, and the phone when there is no internet.
	//
	// It was the other way round, with this argument written right here: "if there are
	// downloaded maps they are used ALWAYS, nobody wants the answer that on top of being
	// slower spends data". The argument is good for the spending and bad for
	// driving -- the public server sees this week's closures, roadworks and
	// reversed directions, and the phone's tiles are from the date they
	// were downloaded. On a map, "faster" is not worth a route that no longer exists.
	//
	// The local one is not a degraded mode: it resolves the same routes with the same
	// engine, and it is the only thing there is in a tunnel, in a village or abroad
	// with no data. That is why the fallback goes BOTH WAYS: the right one is
	// asked, and if it cannot the other is tried before telling the driver
	// there is no route.
	property bool hayRed: app.hayRed
	readonly property bool _primeroFuera: hayRed || !hayLocal
	readonly property string servidor: _primeroFuera
		? servidorPublico : servidorLocal + "/route"
	readonly property string agente: "PocoNav/1.0 (postmarketOS; personal use)"

	// --- kilometres or miles -------------------------------------------------
	// Valhalla is asked in the driver's units, and not always in
	// kilometres converting afterwards, because the spoken phrases CARRY THE
	// UNIT INSIDE: "continue for half a mile" is written by the server, not
	// by us.
	//
	// The price is that its numbers also come in those units. Inside the
	// application EVERYTHING is metres and km/h, always, and the conversion happens here
	// on the way in. Mixing units internally is the sure way for a distance one day
	// to come out 1.6 times longer with nobody knowing why.
	property bool millas: false
	readonly property real _aMetros: millas ? 1609.344 : 1000
	readonly property real _aKmh: millas ? 1.609344 : 1
	readonly property string _unidades: millas ? "miles" : "kilometers"

	// The language of the instructions is set by the voice chosen in settings, not a separate
	// setting: having an English voice reading Spanish text -- or the
	// other way round -- serves no one, and it is two places to get it wrong.
	//
	// The voice name is "es_ES-davefx-medium" and Valhalla wants "es-ES", so
	// it is trimmed at the first hyphen and the underscore is swapped. If there is no voice
	// set, Spanish: it is the language of the interface.
	readonly property string idioma: {
		const v = app.vozActiva
		if (!v || v.length < 5)
			return "es-ES"
		return v.split("-")[0].replace("_", "-")
	}

	// Route preferences. Valhalla takes them as a 0..1 willingness, not as a
	// ban: 0 means "only if there is no other way", which is what a driver
	// actually wants -- a hard ban can leave you with no route at all.
	property bool evitarPeajes: false
	property bool evitarAutopistas: false

	// --- lane guidance, from a second router --------------------------------
	// MEASURED: Valhalla 3.8.3 returns no lane information at all -- three
	// routes, including the M-30 and Gran Via, 41 maneuvers, zero with `lanes`.
	// OSRM does return it, as intersections[].lanes with `valid` and
	// `indications`. So the text comes from Valhalla, in Spanish, and the lanes
	// come from OSRM.
	//
	// The two routers can disagree about which road to take. That is why lanes
	// are attached by PROXIMITY to a Valhalla maneuver and not by index: if the
	// routes diverge, nothing matches and no lanes are shown. Never guess a
	// lane -- a wrong arrow at a junction is worse than no arrow.
	readonly property string servidorCarriles:
		"https://routing.openstreetmap.de/routed-car/route/v1/driving/"
	property var _carriles: null

	function _pedirCarriles(origen, aDonde) {
		if (_carriles)
			_carriles.abort()
		const x = new XMLHttpRequest()
		_carriles = x
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			// The route may have been destroyed while this was in flight -- the
			// lanes and the limits take longer than the route and arrive late. Without
			// this guard, the handler writes over an object that no longer
			// exists. The self-test uncovered it on its first run.
			if (!ruta)
				return
			ruta._carriles = null
			if (x.status !== 200)
				return
			try {
				ruta._casarCarriles(JSON.parse(x.responseText))
			} catch (e) {
				// Lanes are a bonus. Losing them must never cost the route.
			}
		}
		x.open("GET", servidorCarriles
			+ origen.longitude + "," + origen.latitude + ";"
			+ aDonde.longitude + "," + aDonde.latitude
			+ "?overview=false&steps=true&annotations=false")
		x.setRequestHeader("User-Agent", agente)
		x.send()
	}

	function _casarCarriles(respuesta) {
		if (!hay || !respuesta.routes || !respuesta.routes.length)
			return
		const pasos = respuesta.routes[0].legs[0].steps
		const copia = maniobras.slice()
		var puestos = 0

		for (var i = 0; i < pasos.length; ++i) {
			const cruces = pasos[i].intersections || []
			for (var j = 0; j < cruces.length; ++j) {
				const c = cruces[j]
				if (!c.lanes || !c.lanes.length || !c.location)
					continue
				const donde = QtPositioning.coordinate(c.location[1], c.location[0])

				// The nearest maneuver, and only if it is really near. 30 m is
				// about one junction: further than that and the two routers are
				// talking about different places.
				var mejor = -1, mejorD = 30
				for (var k = 0; k < copia.length; ++k) {
					const d = donde.distanceTo(puntos[copia[k].ini])
					if (d < mejorD) { mejorD = d; mejor = k }
				}
				if (mejor < 0)
					continue

				const carriles = []
				for (var n = 0; n < c.lanes.length; ++n)
					carriles.push({
						sirve: c.lanes[n].valid === true,
						hacia: c.lanes[n].indications || []
					})
				copia[mejor] = Object.assign({}, copia[mejor], { carriles: carriles })
				++puestos
			}
		}

		if (puestos > 0)
			maniobras = copia
	}

	// --- speed limits ------------------------------------------------------
	// Neither Valhalla nor OSRM give them in the route response -- verified: public
	// OSRM does not even accept 'annotations=maxspeed', and its 'speed' is the
	// computed one, not the legal one. But Valhalla's 'trace_attributes' DOES, and on top
	// it returns the shape indices, which are the same ones we already follow here.
	// Measured in Madrid: 135 of 154 segments with a limit.
	//
	// A single request per route, and by POST: the encoded shape of a long
	// route does not fit in a URL.
	property var _limites: null

	function _pedirLimites(codificada) {
		if (_limites)
			_limites.abort()
		const x = new XMLHttpRequest()
		_limites = x
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			// The route may have been destroyed while this was in flight -- the
			// lanes and the limits take longer than the route and arrive late. Without
			// this guard, the handler writes over an object that no longer
			// exists. The self-test uncovered it on its first run.
			if (!ruta)
				return
			ruta._limites = null
			if (x.status !== 200)
				return
			try {
				ruta._leerLimites(JSON.parse(x.responseText))
			} catch (e) {
				// A bonus. Its failure must not cost the route.
			}
		}
		const cuerpo = JSON.stringify({
			encoded_polyline: codificada,
			costing: "auto",
			shape_match: "edge_walk",
			filters: {
				attributes: ["edge.speed_limit", "edge.begin_shape_index",
					"edge.end_shape_index"],
				action: "include"
			}
		})
		// To the same one as the route, and in the same order: the limits have to
		// come from the map that drew the path. Mixing them -- route from the internet,
		// limits from the phone -- is asking for a new stretch to come out with no limit or with
		// that of the road that was there before.
		x.open("POST", (_primeroFuera
			? "https://valhalla1.openstreetmap.de" : servidorLocal)
			+ "/trace_attributes")
		x.setRequestHeader("User-Agent", agente)
		x.setRequestHeader("Content-Type", "application/json")
		x.send(cuerpo)
	}

	function _leerLimites(respuesta) {
		const aristas = respuesta.edges
		if (!aristas || !aristas.length || !puntos.length)
			return
		// A flat table by shape index: looking up the limit is then a single
		// access, and this is consulted once a second.
		const tabla = new Array(puntos.length)
		for (var i = 0; i < aristas.length; ++i) {
			const e = aristas[i]
			if (!e.speed_limit)
				continue
			const desde = e.begin_shape_index || 0
			const hasta = Math.min(puntos.length - 1, e.end_shape_index || desde)
			for (var j = desde; j <= hasta; ++j)
				// Always km/h. Asked in miles, Valhalla answers in mph.
				tabla[j] = Math.round(e.speed_limit * ruta._aKmh)
		}
		_limitePorPunto = tabla
	}

	property var _peticion: null
	property var _sonda: null

	// Asks our own server whether it can route. It answers
	// {"listo":true/false}, and the false matters as much as the true: the process
	// can be alive and not have maps yet, or have them half-downloaded.
	// Trusting that it answers would be accepting an incomplete region.
	//
	// It is local and fails fast when nobody is listening, so it can be
	// asked before every route at no cost.
	function sondearLocal() {
		if (_sonda)
			_sonda.abort()
		const s = new XMLHttpRequest()
		_sonda = s
		s.onreadystatechange = function () {
			if (s.readyState !== XMLHttpRequest.DONE)
				return
			ruta._sonda = null
			if (s.status !== 200) {
				ruta.hayLocal = false
				ruta.dibujoLocal = false
				ruta.cuadrosDibujo = []
				return
			}
			ruta.sondeoContestado = true
			try {
				const r = JSON.parse(s.responseText)
				// It is logged ONCE, on change, and not on every poll: it is the only
				// signal of why the map is drawn one way or another, and
				// without it the symptom is just "it comes over the internet".
				if (ruta.dibujoLocal !== (r.dibujable === true))
					console.log("poconav: dibujo local ->",
						r.dibujable === true, "(" + (r.mapas_dibujo || 0) + " mapas)")
				ruta.hayLocal = r.listo === true
				ruta.dibujoLocal = r.dibujable === true
				ruta.cuadrosDibujo = r.cuadros || []
			} catch (e) {
				ruta.hayLocal = false
				ruta.dibujoLocal = false
			}
		}
		try {
			s.open("GET", servidorLocal + "/status")
			s.send()
		} catch (e) {
			ruta._sonda = null
			ruta.hayLocal = false
			ruta.dibujoLocal = false
		}
	}

	// So that whoever asks for a route can report a refusal through the same
	// channel the server errors use, instead of failing in silence.
	function fallar(motivo) {
		estado = "error"
		fallo = motivo
	}

	function limpiar() {
		if (_peticion) {
			_peticion.abort()
			_peticion = null
		}
		if (_carriles) {
			_carriles.abort()
			_carriles = null
		}
		if (_limites) {
			_limites.abort()
			_limites = null
		}
		_limitePorPunto = []
		puntos = []
		maniobras = []
		acumulado = []
		metrosTotal = 0
		segundosTotal = 0
		destino = null
		nombreDestino = ""
		forma = ""
		estado = ""
		fallo = ""
		indice = 0
		maniobra = 0
	}

	// The same route, from where you are now. Separated from calcular() so that
	// it is clear in the code that calling it is NOT starting a new journey: the
	// destination and its name are not touched.
	function recalcular(origen) {
		if (!destino)
			return
		calcular(origen, destino, nombreDestino)
	}

	function calcular(origen, aDonde, nombre) {
		if (!origen || !aDonde)
			return
		if (_peticion)
			_peticion.abort()

		destino = aDonde
		nombreDestino = nombre || ""
		estado = "pidiendo"
		fallo = ""

		const consulta = {
			locations: [
				{ lat: origen.latitude, lon: origen.longitude },
				{ lat: aDonde.latitude, lon: aDonde.longitude }
			],
			costing: "auto",
			costing_options: {
				auto: {
					// 0 is not "forbidden", it is "only if there is no other
					// way". A hard ban can answer with no route at all, and a
					// driver who asked to dodge tolls still wants to arrive.
					use_tolls: evitarPeajes ? 0.0 : 0.5,
					use_highways: evitarAutopistas ? 0.0 : 0.5
				}
			},
			directions_options: { language: ruta.idioma, units: ruta._unidades }
		}

		_pedirRuta(consulta, !_primeroFuera)
	}

	// `enCasa` says who it is asked of. Separated from calcular() so it can
	// RETRY with the other one without rebuilding the query.
	//
	// That retry is not an ornament. Without it, any failure of the first one left
	// the application with no routes by ANY path: it was asked, answered wrong, and
	// that was that -- even though the other could have answered easily. A single mistake
	// of mine on the home server took down the internet ones too.
	//
	// It retries ONCE and in the opposite direction, never in a loop: the second
	// failure is a real no and it has to be said, not to keep trying while the
	// driver watches a spinner turn.
	function _pedirRuta(consulta, enCasa, yaReintentado) {
		const destinoUrl = enCasa ? servidorLocal + "/route" : servidorPublico

		// It only makes sense to try the other if the other exists: with no downloaded maps
		// there is nothing at home to fall back on.
		const hayOtro = enCasa ? true : hayLocal

		const x = new XMLHttpRequest()
		_peticion = x
		x.onreadystatechange = function () {
			if (x.readyState !== XMLHttpRequest.DONE)
				return
			ruta._peticion = null

			function rendirse(porque) {
				ruta.estado = "error"
				ruta.fallo = porque
			}
			function probarElOtro() {
				// NEITHER 'hayLocal' nor 'hayRed' is touched here. This particular trip
				// leaves the maps, or this server is down right now;
				// turning off the flag would send ALL the remaining routes of the session
				// the same way, including the ones the other would resolve
				// better. The network state is told by NetworkManager, not by a 404.
				ruta._pedirRuta(consulta, !enCasa, true)
			}

			if (x.status !== 200) {
				if (hayOtro && !yaReintentado) { probarElOtro(); return }
				// status 0 is what an aborted or unreachable request looks
				// like, and "error 0" tells the driver nothing.
				rendirse(x.status === 0 ? qsTr("no connection to the routing server")
					: qsTr("the routing server responded %1").arg(x.status))
				return
			}
			try {
				_leer(JSON.parse(x.responseText))
			} catch (e) {
				if (hayOtro && !yaReintentado) { probarElOtro(); return }
				rendirse(qsTr("I could not understand the server response"))
			}
		}
		x.open("GET", destinoUrl + "?json=" + encodeURIComponent(JSON.stringify(consulta)))
		x.setRequestHeader("User-Agent", agente)
		x.send()
	}

	// Pulls up to `cuantos` texts from a list in Valhalla's 'sign' field and
	// joins them. Returns "" if there is none, which is what the interface looks at to
	// decide whether to draw the sign or not.
	function _delSign(sign, lista, cuantos) {
		if (!sign || !sign[lista] || !sign[lista].length)
			return ""
		const salida = []
		for (var i = 0; i < sign[lista].length && i < cuantos; ++i)
			salida.push(String(sign[lista][i].text).trim())
		return salida.join(" · ")
	}

	// Adopts an ALREADY calculated route, without requesting it again.
	//
	// The planner uses it: it asked for several at once and the driver chooses
	// one. Requesting it from the server again would be waiting once more for something already
	// in memory -- and against the public server, one extra request each
	// time someone changes their mind between two options.
	//
	// From here on the route is indistinguishable from one requested via calcular():
	// same line, same maneuvers, same lanes and limits.
	function adoptar(viaje, aDonde, nombre) {
		if (!viaje)
			return
		if (_peticion) {
			_peticion.abort()
			_peticion = null
		}
		destino = aDonde
		nombreDestino = nombre || ""
		fallo = ""
		_leer({ trip: viaje })
	}

	function _leer(respuesta) {
		const viaje = respuesta.trip
		if (!viaje || !viaje.legs || viaje.legs.length === 0) {
			estado = "error"
			fallo = qsTr("there is no road to there")
			return
		}

		const tramo = viaje.legs[0]
		const linea = _descodificar(tramo.shape)
		if (linea.length < 2) {
			estado = "error"
			fallo = qsTr("the route came back empty")
			return
		}

		// Distances add up once, here, instead of on every position update.
		const acum = new Array(linea.length)
		acum[0] = 0
		for (var i = 1; i < linea.length; ++i)
			acum[i] = acum[i - 1] + linea[i - 1].distanceTo(linea[i])

		const pasos = []
		for (var j = 0; j < tramo.maneuvers.length; ++j) {
			const m = tramo.maneuvers[j]
			pasos.push({
				tipo: m.type,
				texto: m.instruction || "",
				// Valhalla hands the street names over separately, which is
				// what the big line on the driving panel wants: the whole
				// sentence is too long to read at 90 km/h.
				// Only the first two names. A dual carriageway carries up to five
				// synonyms -- "A-7 / E 15 / Autovia de la Mediterrania /
				// Autovia del Mediterraneo / ..." -- and together they filled two
				// lines of the card with the same road said in several
				// ways. Seen on screen.
				calle: (m.street_names && m.street_names.length)
					? m.street_names.slice(0, 2).join(" / ") : "",
				metros: (m.length || 0) * ruta._aMetros,
				segundos: m.time || 0,
				ini: m.begin_shape_index || 0,
				// Valhalla writes the phrases to be spoken aloud SEPARATELY, and
				// they are not the same as the written one: the spoken one carries no
				// abbreviations or symbols, which sound terrible. The three are
				// kept because each has its moment.
				aviso: m.verbal_transition_alert_instruction || "",
				dilo: m.verbal_pre_transition_instruction || m.instruction || "",
				luego: m.verbal_post_transition_instruction || "",
				// Which exit to take. Valhalla says it in the sentence too,
				// but a driver reads a number long before a sentence.
				salida: m.roundabout_exit_count || 0,
				// The motorway exits, from the 'sign' field, which Valhalla
				// returns SEPARATELY and with the pieces split apart. Measured on the A-3
				// leaving Madrid: 10 of 18 maneuvers carry it.
				//
				// It matters to have it loose because the number -- "15AB" -- is the
				// only thing the driver compares with the road's blue
				// sign, and inside the whole sentence it gets lost.
				salidaNum: _delSign(m.sign, "exit_number_elements", 1),
				// Where it heads. The destination ("Valencia") is preferred over the
				// road number, which is what the sign puts in large type.
				hacia: _delSign(m.sign, "exit_toward_elements", 2)
					|| _delSign(m.sign, "exit_branch_elements", 2)
			})
		}

		forma = tramo.shape
		puntos = linea
		acumulado = acum
		maniobras = pasos
		// The total comes from the LINE, not from summary.length, even though Valhalla
		// says so. They are two different measures of the same thing: the summary comes from the
		// graph edges and the line from the encoded polyline, and they do not match.
		//
		// Measured, Bolnuevo -> Murcia: 77.40 km per the summary and 77.31 per the
		// line. Since progress is measured over the line, those 91 metres of
		// difference were ALWAYS left to travel -- and since arrival requires
		// less than 25 m, the application never declared the journey finished. The
		// simulator found it by driving the whole route.
		//
		// The difference is 0.1 %, so for showing the kilometres it makes
		// no difference which is used; for knowing whether you have arrived, it does.
		metrosTotal = acum.length ? acum[acum.length - 1] : 0
		segundosTotal = viaje.summary.time || 0
		indice = 0
		maniobra = 0
		metrosRestantes = metrosTotal
		segundosRestantes = segundosTotal
		metrosHastaManiobra = pasos.length > 1 ? acum[pasos[1].ini] : metrosTotal
		estado = "lista"

		// After the route is accepted, never before: if the second server
		// is slow or fails, the route is already on screen.
		if (destino)
			_pedirCarriles(linea[0], destino)
		_pedirLimites(tramo.shape)
	}

	// --- surviving a power cut ---------------------------------------------
	// Once a route exists it needs no network at all: the shape and every
	// instruction are already here. What it does NOT survive is the process
	// dying -- and on a phone, in a car, that happens. So it goes to disk.
	function paraGuardar() {
		// The arrays, not `hay`. Called from onEstadoChanged, that binding has
		// not been re-evaluated yet and is still false -- the same trap that
		// silently killed encuadrarRuta(), and it silently saved nothing here.
		if (!puntos || puntos.length < 2 || !destino || !forma)
			return ""
		return JSON.stringify({
			forma: forma,
			maniobras: maniobras,
			metros: metrosTotal,
			segundos: segundosTotal,
			lat: destino.latitude,
			lon: destino.longitude,
			nombre: nombreDestino,
			cuando: Date.now()
		})
	}

	// Returns true if a route was rebuilt. `horas` is how stale is too stale:
	// a route from yesterday morning is not the one you are driving now, and
	// silently restoring it would be worse than restoring nothing.
	function restaurar(texto, horas) {
		if (!texto)
			return false
		var g
		try {
			g = JSON.parse(texto)
		} catch (e) {
			return false
		}
		if (!g || !g.forma || !g.maniobras || !g.maniobras.length)
			return false
		if (horas > 0 && Date.now() - (g.cuando || 0) > horas * 3600 * 1000)
			return false

		const linea = _descodificar(g.forma)
		if (linea.length < 2)
			return false
		const acum = new Array(linea.length)
		acum[0] = 0
		for (var i = 1; i < linea.length; ++i)
			acum[i] = acum[i - 1] + linea[i - 1].distanceTo(linea[i])

		forma = g.forma
		puntos = linea
		acumulado = acum
		maniobras = g.maniobras
		metrosTotal = g.metros || 0
		segundosTotal = g.segundos || 0
		destino = QtPositioning.coordinate(g.lat, g.lon)
		nombreDestino = g.nombre || ""
		indice = 0
		maniobra = 0
		metrosRestantes = metrosTotal
		segundosRestantes = segundosTotal
		metrosHastaManiobra = maniobras.length > 1
			? acum[maniobras[1].ini] : metrosTotal
		fallo = ""
		estado = "lista"
		return true
	}

	// Google's polyline, at Valhalla's precision of six decimals.
	function _descodificar(s) {
		const salida = []
		var i = 0, lat = 0, lon = 0
		while (i < s.length) {
			var b, desp = 0, r = 0
			do { b = s.charCodeAt(i++) - 63; r |= (b & 0x1f) << desp; desp += 5 } while (b >= 0x20)
			lat += (r & 1) ? ~(r >> 1) : (r >> 1)
			desp = 0; r = 0
			do { b = s.charCodeAt(i++) - 63; r |= (b & 0x1f) << desp; desp += 5 } while (b >= 0x20)
			lon += (r & 1) ? ~(r >> 1) : (r >> 1)
			salida.push(QtPositioning.coordinate(lat / 1e6, lon / 1e6))
		}
		return salida
	}

	// Where on the line you are. Called once per fix.
	function situar(donde) {
		if (!hay || !donde)
			return

		// A long route is thousands of points and this runs every second, so
		// the search starts as a window around where you were. It only falls
		// back to the whole line when that window has nothing plausible in it,
		// which is what happens when you leave the route or the app was in the
		// background while the car kept moving.
		var mejor = -1, mejorD = Number.MAX_VALUE
		const desde = Math.max(0, indice - 40)
		const hasta = Math.min(puntos.length, indice + 400)
		for (var i = desde; i < hasta; ++i) {
			const d = donde.distanceTo(puntos[i])
			if (d < mejorD) { mejorD = d; mejor = i }
		}
		if (mejorD > 150) {
			for (var j = 0; j < puntos.length; ++j) {
				const d2 = donde.distanceTo(puntos[j])
				if (d2 < mejorD) { mejorD = d2; mejor = j }
			}
		}
		if (mejor < 0)
			return

		indice = mejor
		desvio = mejorD

		// The current instruction is the last one already begun.
		var m = 0
		for (var k = 0; k < maniobras.length; ++k) {
			if (maniobras[k].ini <= mejor)
				m = k
			else
				break
		}
		maniobra = m

		const recorrido = acumulado[mejor]
		metrosRestantes = Math.max(0, metrosTotal - recorrido)

		const siguiente = m + 1 < maniobras.length ? maniobras[m + 1] : null
		metrosHastaManiobra = siguiente
			? Math.max(0, acumulado[siguiente.ini] - recorrido) : metrosRestantes

		// Time left: whole maneuvers still ahead, plus the fraction of the one
		// being driven. Valhalla's own per-step times, not a speed guess.
		var seg = 0
		for (var n = m + 1; n < maniobras.length; ++n)
			seg += maniobras[n].segundos
		const actual = maniobras[m]
		if (actual.metros > 1)
			seg += actual.segundos * Math.min(1, metrosHastaManiobra / actual.metros)
		segundosRestantes = seg
	}
}
