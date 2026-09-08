// SPDX-License-Identifier: LGPL-2.0-or-later
//
// What QML cannot do, and why this class exists.
//
// PocoNav started as pure QML. That was fine while it only drew a map, but it
// made every later feature arrive crippled: QML cannot write a file, cannot
// start a process, cannot talk to logind. The workarounds piled up -- a shell
// script polling the settings file to speak a phrase, another one holding the
// screen awake, a third one downloading maps behind the app's back.
//
// All of that was the cost of a design decision, not a limitation of Qt. This
// class pays it back. The app now owns its downloads, its voice and its screen.
#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QStringList>

class QNetworkAccessManager;
class QNetworkReply;
class QFile;

class Backend : public QObject
{
	Q_OBJECT

	// Whether a download is running, and how it is going. QML binds straight to
	// these -- no polling, no status file, no parsing.
	Q_PROPERTY(bool trabajando READ trabajando NOTIFY tareaCambiada)
	Q_PROPERTY(QString tareaTexto READ tareaTexto NOTIFY tareaCambiada)
	Q_PROPERTY(int tareaPct READ tareaPct NOTIFY tareaCambiada)

	Q_PROPERTY(QStringList voces READ voces NOTIFY vocesCambiadas)
	Q_PROPERTY(QString vozActiva READ vozActiva WRITE setVozActiva NOTIFY vozActivaCambiada)
	Q_PROPERTY(QStringList mapas READ mapas NOTIFY mapasCambiados)
	// The ones that also bring what they need to BE DRAWN. A separate list
	// because they are two different downloads: you can be able to go somewhere
	// and not be able to paint it.
	Q_PROPERTY(QStringList dibujables READ dibujables NOTIFY mapasCambiados)
	Q_PROPERTY(bool hayDibujoLocal READ hayDibujoLocal NOTIFY mapasCambiados)

	// True when there are routable tiles on disk. This says local data CAN
	// answer, not that it is preferred -- the order is decided by hayRed below.
	Q_PROPERTY(bool hayMapaLocal READ hayMapaLocal NOTIFY mapasCambiados)

	// Whether the phone can reach the internet right now.
	//
	// This decides who gets ASKED FIRST, and it has to be known before asking
	// rather than discovered by a request that fails. Without it, every route
	// computed underground or in a village would first spend a DNS timeout on
	// the public server -- seconds, at a junction, which is exactly when a
	// driver has none to spare.
	//
	// It comes from QNetworkInformation, which on this phone is NetworkManager:
	// the same source that knows the WiFi dropped, reported the moment it does,
	// not polled.
	Q_PROPERTY(bool hayRed READ hayRed NOTIFY hayRedCambiada)

public:
	explicit Backend(QObject *parent = nullptr);
	~Backend() override;

	bool trabajando() const { return m_trabajando; }
	QString tareaTexto() const { return m_tareaTexto; }
	int tareaPct() const { return m_tareaPct; }
	QStringList voces() const { return m_voces; }
	QString vozActiva() const { return m_vozActiva; }
	void setVozActiva(const QString &id);
	QStringList mapas() const { return m_mapas; }
	QStringList dibujables() const { return m_dibujables; }
	bool hayDibujoLocal() const { return !m_dibujables.isEmpty(); }
	bool hayMapaLocal() const { return !m_mapas.isEmpty(); }
	bool hayRed() const { return m_hayRed; }

	// Downloads. Both refuse to start while another one runs: two writers into
	// the same data directory is a corrupted map, and the phone's link is not
	// wide enough for it to be worth the risk.
	Q_INVOKABLE void bajarVoz(const QString &id);
	Q_INVOKABLE void bajarMapa(const QString &region);
	// The tiles used to DRAW, downloaded separately from the routing ones.
	Q_INVOKABLE void bajarDibujo(const QString &region);
	// The map for AROUND HERE: only the zoom 7 tiles that surround that position.
	// It is what makes downloading the drawing 132 MB and not 1.9 GB.
	Q_INVOKABLE void bajarDibujoCerca(const QString &region, double lat,
		double lon, int anillo);
	// The same tiles without downloading anything, so it can say how many there
	// are and how much they will take up BEFORE starting.
	Q_INVOKABLE QStringList cuadrosDe(double lat, double lon, int anillo) const;
	// The map for WHERE YOU ARE GOING: the tiles passed to it, and not the ones
	// underneath the phone. It is what is needed before setting off on a trip.
	Q_INVOKABLE void bajarDibujoCuadros(const QString &region,
		const QStringList &cuadros);
	// The tiles a rectangle covers. It is how the map a route needs is known
	// before adopting it: the planner keeps it without decoding, but Valhalla
	// does give the rectangle that contains it.
	Q_INVOKABLE QStringList cuadrosDelRectangulo(double minLat, double minLon,
		double maxLat, double maxLon) const;
	Q_INVOKABLE void cancelar();
	Q_INVOKABLE void borrarMapa(const QString &region);

	// Speech. The phrase goes straight into piper's stdin; the process stays
	// alive between phrases because loading the model costs ~4 s and a driving
	// instruction that late has already been missed.
	Q_INVOKABLE void decir(const QString &frase);
	// Cuts off whatever is being said NOW. On cancelling a route it is not enough
	// to stop sending phrases: the one already out keeps playing.
	Q_INVOKABLE void callar();

	// Keeps the screen from blanking while navigating -- and only while
	// navigating, so a map left open in a pocket still lets the phone sleep.
	Q_INVOKABLE void mantenerPantalla(bool si);

	// Where downloaded data lives, so QML can hand it to the routing engine.
	Q_INVOKABLE QString rutaDatos() const;

signals:
	void tareaCambiada();
	void vocesCambiadas();
	void vozActivaCambiada();
	void mapasCambiados();
	void hayRedCambiada();
	void terminado(bool ok, const QString &mensaje);

private slots:
	void alProgresar(qint64 hechos, qint64 total);
	void alTerminarDescarga();

private:
	void mirarQueHay();
	void anunciar(const QString &texto, int pct);
	void acabar(bool ok, const QString &mensaje);
	void arrancarVoz();
	void pedir(const QUrl &url, const QString &destino);

	// Starts the app's own routing server. A child process, not a service:
	// nothing installs it, nothing enables it, and it dies with the app.
	//
	// It exists only because Alpine's valhalla-dev package ships no headers, so
	// the library cannot be reached from C++ at all -- the Python module is the
	// only door in, and that door happens to be in another process.
	void arrancarRutas();
	void _bajarMapa(const QString &region, bool dibujo);

	// Subscribes to QNetworkInformation. There may be no backend available; in
	// that case it is assumed that there IS a network, which is the normal case
	// and the one that leaves the local fallback intact: it asks out, fails, and
	// falls back home.
	void vigilarRed();

	bool m_hayRed = true;

	QNetworkAccessManager *m_red = nullptr;
	QNetworkReply *m_bajada = nullptr;
	QFile *m_salida = nullptr;

	bool m_trabajando = false;
	QString m_tareaTexto;
	int m_tareaPct = 0;

	// The region being downloaded and the voice that was requested: needed to
	// know what to announce and what to set when it finishes.
	QString m_regionEnCurso;
	QString m_vozPedida;
	// What was left half-done from the downloader's last line.
	QString m_resto;

	QStringList m_voces;
	QString m_vozActiva;
	// Where the chosen voice is remembered between starts.
	void _guardarVoz() const;
	QString _vozGuardada() const;
	static QString _ficheroVoz();
	QStringList m_mapas;
	QStringList m_dibujables;
	// The tiles requested for the download in progress; empty means the whole
	// region.
	QStringList m_cuadros;

	QProcess *m_piper = nullptr;
	QProcess *m_aplay = nullptr;
	QProcess *m_inhibidor = nullptr;
	QProcess *m_rutas = nullptr;
	QProcess *m_descargador = nullptr;
};
