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
	Q_PROPERTY(bool busy READ busy NOTIFY taskChanged)
	Q_PROPERTY(QString taskText READ taskText NOTIFY taskChanged)
	Q_PROPERTY(int taskPct READ taskPct NOTIFY taskChanged)

	Q_PROPERTY(QStringList voices READ voices NOTIFY voicesChanged)
	Q_PROPERTY(QString activeVoice READ activeVoice WRITE setActiveVoice NOTIFY activeVoiceChanged)
	Q_PROPERTY(QStringList maps READ maps NOTIFY mapsChanged)
	// The ones that also bring what they need to BE DRAWN. A separate list
	// because they are two different downloads: you can be able to go somewhere
	// and not be able to paint it.
	Q_PROPERTY(QStringList drawables READ drawables NOTIFY mapsChanged)
	Q_PROPERTY(bool hasLocalDrawing READ hasLocalDrawing NOTIFY mapsChanged)

	// True when there are routable tiles on disk. This says local data CAN
	// answer, not that it is preferred -- the order is decided by hasNetwork below.
	Q_PROPERTY(bool hasLocalMap READ hasLocalMap NOTIFY mapsChanged)

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
	Q_PROPERTY(bool hasNetwork READ hasNetwork NOTIFY hasNetworkChanged)

public:
	explicit Backend(QObject *parent = nullptr);
	~Backend() override;

	bool busy() const { return m_busy; }
	QString taskText() const { return m_taskText; }
	int taskPct() const { return m_taskPct; }
	QStringList voices() const { return m_voices; }
	QString activeVoice() const { return m_activeVoice; }
	void setActiveVoice(const QString &id);
	QStringList maps() const { return m_maps; }
	QStringList drawables() const { return m_drawables; }
	bool hasLocalDrawing() const { return !m_drawables.isEmpty(); }
	bool hasLocalMap() const { return !m_maps.isEmpty(); }
	bool hasNetwork() const { return m_hasNetwork; }

	// Downloads. Both refuse to start while another one runs: two writers into
	// the same data directory is a corrupted map, and the phone's link is not
	// wide enough for it to be worth the risk.
	Q_INVOKABLE void downloadVoice(const QString &id);
	Q_INVOKABLE void downloadMap(const QString &region);
	// The tiles used to DRAW, downloaded separately from the routing ones.
	Q_INVOKABLE void downloadDrawing(const QString &region);
	// The map for AROUND HERE: only the zoom 7 tiles that surround that position.
	// It is what makes downloading the drawing 132 MB and not 1.9 GB.
	Q_INVOKABLE void downloadDrawingNear(const QString &region, double lat,
		double lon, int ring);
	// The same tiles without downloading anything, so it can say how many there
	// are and how much they will take up BEFORE starting.
	Q_INVOKABLE QStringList boxesAt(double lat, double lon, int ring) const;
	// The map for WHERE YOU ARE GOING: the tiles passed to it, and not the ones
	// underneath the phone. It is what is needed before setting off on a trip.
	Q_INVOKABLE void downloadDrawingBoxes(const QString &region,
		const QStringList &boxes);
	// The tiles a rectangle covers. It is how the map a route needs is known
	// before adopting it: the planner keeps it without decoding, but Valhalla
	// does give the rectangle that contains it.
	Q_INVOKABLE QStringList boxesInRectangle(double minLat, double minLon,
		double maxLat, double maxLon) const;
	Q_INVOKABLE void cancel();
	Q_INVOKABLE void deleteMap(const QString &region);

	// Speech. The phrase goes straight into piper's stdin; the process stays
	// alive between phrases because loading the model costs ~4 s and a driving
	// instruction that late has already been missed.
	Q_INVOKABLE void speak(const QString &phrase);
	// Cuts off whatever is being said NOW. On cancelling a route it is not enough
	// to stop sending phrases: the one already out keeps playing.
	Q_INVOKABLE void stopSpeaking();

	// Keeps the screen from blanking while navigating -- and only while
	// navigating, so a map left open in a pocket still lets the phone sleep.
	Q_INVOKABLE void keepScreenOn(bool on);

	// Where downloaded data lives, so QML can hand it to the routing engine.
	Q_INVOKABLE QString dataPath() const;

signals:
	void taskChanged();
	void voicesChanged();
	void activeVoiceChanged();
	void mapsChanged();
	void hasNetworkChanged();
	void taskFinished(bool ok, const QString &message);

private slots:
	void onProgress(qint64 received, qint64 total);
	void onDownloadFinished();

private:
	void rescan();
	void announce(const QString &text, int pct);
	void finish(bool ok, const QString &message);
	void startVoice();
	void request(const QUrl &url, const QString &destination);

	// Starts the app's own routing server. A child process, not a service:
	// nothing installs it, nothing enables it, and it dies with the app.
	//
	// It exists only because Alpine's valhalla-dev package ships no headers, so
	// the library cannot be reached from C++ at all -- the Python module is the
	// only door in, and that door happens to be in another process.
	void startRouteServer();
	void _downloadMap(const QString &region, bool drawing);

	// Subscribes to QNetworkInformation. There may be no backend available; in
	// that case it is assumed that there IS a network, which is the normal case
	// and the one that leaves the local fallback intact: it asks out, fails, and
	// falls back home.
	void watchNetwork();

	bool m_hasNetwork = true;

	QNetworkAccessManager *m_net = nullptr;
	QNetworkReply *m_download = nullptr;
	QFile *m_outFile = nullptr;

	bool m_busy = false;
	QString m_taskText;
	int m_taskPct = 0;

	// The region being downloaded and the voice that was requested: needed to
	// know what to announce and what to set when it finishes.
	QString m_regionInProgress;
	QString m_requestedVoice;
	// What was left half-done from the downloader's last line.
	QString m_rest;

	QStringList m_voices;
	QString m_activeVoice;
	// Where the chosen voice is remembered between starts.
	void _saveVoice() const;
	QString _savedVoice() const;
	static QString _voiceFile();
	QStringList m_maps;
	QStringList m_drawables;
	// The tiles requested for the download in progress; empty means the whole
	// region.
	QStringList m_boxes;

	QProcess *m_piper = nullptr;
	QProcess *m_aplay = nullptr;
	QProcess *m_inhibitor = nullptr;
	QProcess *m_routeServer = nullptr;
	QProcess *m_downloader = nullptr;
};
