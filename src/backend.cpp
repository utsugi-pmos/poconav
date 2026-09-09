// SPDX-License-Identifier: LGPL-2.0-or-later
#include "backend.h"

#include <QDir>
#include <QRegularExpression>
#include <QtMath>
#include <cmath>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkInformation>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcessEnvironment>
#include <QSettings>
#include <QStandardPaths>
#include <QUrl>

namespace {

// Piper's voices. Not in any distribution repository -- this is the project's
// one documented exception to the everything-from-repositories rule, and it is
// what makes the difference between a voice that sounds like a person and
// espeak.
const char *kVoiceServer =
	"https://huggingface.co/rhasspy/piper-voices/resolve/main";

QString dataDir()
{
	return QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
}

// "es_ES-davefx-medium" -> "es/es_ES/davefx/medium/es_ES-davefx-medium"
// The layout of the voice repository is derived from the name rather than
// listed, because listing it means fetching a catalogue of several hundred
// voices to use exactly one of them.
QString voicePath(const QString &id)
{
	const QStringList parts = id.split(QLatin1Char('-'));
	if (parts.size() < 3)
		return QString();
	const QString local = parts.at(0);              // es_ES
	const QString language = local.section(QLatin1Char('_'), 0, 0);  // es
	return QStringLiteral("%1/%2/%3/%4/%5")
		.arg(language, local, parts.at(1), parts.at(2), id);
}

// The app was called QuickMaps until 1.0. Renaming it moved every path with
// it, and one of those paths holds gigabytes of downloaded map tiles: leaving
// them behind would look like the maps had been lost and would mean downloading
// them all again over a phone connection.
//
// A rename, not a copy: there may not be room on the phone for two copies, and
// a rename cannot half-succeed. If the new name already exists the old one is
// left untouched -- whatever is there now is what the app has been using, and
// silently replacing it with an older tree would be worse than doing nothing.
void moveFrom(const QString &old, const QString &newName)
{
	if (old == newName || QFileInfo::exists(newName) || !QFileInfo::exists(old))
		return;
	if (QFile::rename(old, newName))
		qInfo("moved %s -> %s", qUtf8Printable(old), qUtf8Printable(newName));
	else
		qWarning("could not move %s", qUtf8Printable(old));
}

// The directories and the config key used to be Spanish. Everything a user has
// already downloaded lives under the old names, and gigabytes of maps silently
// disappearing from the list is not an acceptable way to rename a variable.
//
// Same shape as the QuickMaps move above: rename if the old one is there and the
// new one is not, so it costs nothing on a fresh install and runs once otherwise.
void moveFromSpanishNames()
{
	const QString data = dataDir();
	moveFrom(data + QStringLiteral("/mapas"), data + QStringLiteral("/maps"));
	moveFrom(data + QStringLiteral("/voces"), data + QStringLiteral("/voices"));

	const QString conf =
		QStandardPaths::writableLocation(QStandardPaths::ConfigLocation);
	moveFrom(conf + QStringLiteral("/poconav-voz.conf"),
		conf + QStringLiteral("/poconav-voice.conf"));
}

void moveFromQuickMaps()
{
	const QString dataPath = dataDir();
	moveFrom(QFileInfo(dataPath).path() + QStringLiteral("/quickmaps"), dataPath);

	const QString conf =
		QStandardPaths::writableLocation(QStandardPaths::ConfigLocation);
	moveFrom(conf + QStringLiteral("/quickmaps.conf"),
		conf + QStringLiteral("/poconav.conf"));
	moveFrom(conf + QStringLiteral("/quickmaps-voice.conf"),
		conf + QStringLiteral("/poconav-voice.conf"));
}


// From a position to the map tiles that surround it.
//
// The drawing packages are not split by province or by region: they are split
// by ZOOM 7 TILE. "7-62-48" is the tile that contains Murcia, about 300 km on a
// side at this latitude, and it weighs 132 MB. Spain is 23 of those.
//
// This is the answer to "by small regions": the catalogue does not offer Spain
// split into provinces -- only the whole country and, oddly, Barcelona -- but it
// DOES offer it split into these tiles, which is also a better split for
// driving: it does not care about administrative borders, it cares about where
// you are.
//
// The maths is the usual one for tile maps. The latitude goes through Mercator,
// which is what makes a tile taller near the equator than near the pole.
QStringList boxesNear(double lat, double lon, int anillo)
{
	const int n = 1 << 7;
	const double latRad = qDegreesToRadians(qBound(-85.05, lat, 85.05));
	const int x0 = int((lon + 180.0) / 360.0 * n);
	const int y0 = int((1.0 - std::log(std::tan(latRad) + 1.0 / std::cos(latRad))
		/ M_PI) / 2.0 * n);

	QStringList out;
	for (int dy = -anillo; dy <= anillo; ++dy) {
		for (int dx = -anillo; dx <= anillo; ++dx) {
			const int y = y0 + dy;
			if (y < 0 || y >= n)
				continue;
			// x wraps around the world; y does not. Near the antimeridian the
			// neighbouring tile is at the other end of the index, and without
			// this modulo one that does not exist would be requested.
			const int x = ((x0 + dx) % n + n) % n;
			out << QStringLiteral("7-%1-%2").arg(x).arg(y);
		}
	}
	return out;
}

// All the tiles a rectangle covers.
//
// Used to know which map a route needs BEFORE adopting it: the planner keeps the
// route without decoding it, but Valhalla does give the rectangle that contains
// it, and for tiles 300 km on a side the rectangle and the line give practically
// the same thing -- with the advantage that the rectangle SKIPS NONE, whereas
// sampling a line can.
QStringList boxesInArea(double minLat, double minLon,
	double maxLat, double maxLon)
{
	const int n = 1 << 7;
	auto aX = [n](double lon) {
		return int(qBound(0.0, (lon + 180.0) / 360.0 * n, double(n - 1)));
	};
	auto aY = [n](double lat) {
		const double r = qDegreesToRadians(qBound(-85.05, lat, 85.05));
		return int(qBound(0.0,
			(1.0 - std::log(std::tan(r) + 1.0 / std::cos(r)) / M_PI) / 2.0 * n,
			double(n - 1)));
	};
	// y grows towards the SOUTH, so the maximum latitude gives the lowest row.
	const int x1 = aX(minLon), x2 = aX(maxLon);
	const int y1 = aY(maxLat), y2 = aY(minLat);

	QStringList out;
	for (int y = qMin(y1, y2); y <= qMax(y1, y2); ++y)
		for (int x = qMin(x1, x2); x <= qMax(x1, x2); ++x)
			out << QStringLiteral("7-%1-%2").arg(x).arg(y);
	return out;
}

} // namespace

Backend::Backend(QObject *parent)
	: QObject(parent)
	, m_net(new QNetworkAccessManager(this))
{
	// Before mkpath: QFile::rename refuses to overwrite, so creating the new
	// tree first would make the move impossible for ever.
	moveFromQuickMaps();
	moveFromSpanishNames();
	QDir().mkpath(dataDir() + QStringLiteral("/voices"));
	QDir().mkpath(dataDir() + QStringLiteral("/maps"));
	rescan();
	watchNetwork();
	startVoice();
	startRouteServer();
}

void Backend::watchNetwork()
{
	// The backend is loaded once for the whole process. If there is none --
	// a minimal session without NetworkManager, for example -- the assumption
	// that there is a network stands: asking out and falling back home costs a
	// quick failure, whereas assuming there is NO network would leave the app
	// never going out to the internet on a perfectly connected phone.
	if (!QNetworkInformation::loadDefaultBackend()) {
		qInfo("no QNetworkInformation: assuming there is a network");
		return;
	}
	QNetworkInformation *info = QNetworkInformation::instance();
	if (!info)
		return;

	auto read = [this, info] {
		// 'Online' and not "other than Disconnected": in between are Local and
		// Site, which mean having an IP on the home network WITHOUT a way out to
		// the internet. That is exactly the state of the phone plugged in over
		// USB with WiFi off, and taking it as good would send every route to an
		// unreachable server.
		const bool now =
			info->reachability() == QNetworkInformation::Reachability::Online;
		if (now == m_hasNetwork)
			return;
		m_hasNetwork = now;
		emit hasNetworkChanged();
	};
	connect(info, &QNetworkInformation::reachabilityChanged, this, read);
	read();
}

void Backend::startRouteServer()
{
	if (m_routeServer)
		return;
	m_routeServer = new QProcess(this);
	// The server reads the data directory from the environment rather than
	// working it out again: two places deciding the same path is two places to
	// drift apart.
	QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
	env.insert(QStringLiteral("POCONAV_DATA"), dataDir());
	m_routeServer->setProcessEnvironment(env);
	m_routeServer->start(QStringLiteral("poconav-routes"), {});
	// Not waited for. It only matters once a route is asked for, and by then it
	// has had seconds to come up -- blocking the first frame on it would delay
	// the map for nothing.
}

Backend::~Backend()
{
	keepScreenOn(false);
	// Closing piper's stdin is what actually ends the chain: it sees EOF, exits,
	// and aplay goes with it. Killing it outright would leave aplay holding the
	// sound device.
	if (m_piper && m_piper->state() != QProcess::NotRunning) {
		m_piper->closeWriteChannel();
		// And if it does not go quietly, the kill is waited on TOO. Without that
		// second wait the process is still alive when the QProcess is destroyed:
		//
		//   QProcess: Destroyed while process ("piper") is still running.
		//
		// Piper takes a while to notice the EOF -- unloading onnxruntime is not
		// instant, measured at about four seconds -- so the short timeout almost
		// always expires and without this a stray piper with its 60 MB model was
		// left behind on every close.
		if (!m_piper->waitForFinished(2000)) {
			m_piper->kill();
			m_piper->waitForFinished(1000);
		}
	}
	// And aplay after it. Closing piper's input should be enough -- it sees EOF,
	// exits, and aplay is left with no source --, but MEASURED it does not always
	// happen within the timeout: the self-test came out with
	//
	//   QProcess: Destroyed while process ("aplay") is still running.
	//
	// and that is a stray process holding onto the sound card after closing the
	// app. The next time it starts, it cannot play.
	if (m_aplay && m_aplay->state() != QProcess::NotRunning) {
		m_aplay->terminate();
		if (!m_aplay->waitForFinished(1000)) {
			m_aplay->kill();
			m_aplay->waitForFinished(1000);
		}
	}
	// The routing server holds Valhalla's tile index in memory -- hundreds of
	// megabytes. Leaving it behind would cost that much again on every launch.
	if (m_routeServer && m_routeServer->state() != QProcess::NotRunning) {
		m_routeServer->terminate();
		if (!m_routeServer->waitForFinished(2000)) {
			m_routeServer->kill();
			m_routeServer->waitForFinished(1000);
		}
	}
}

QString Backend::dataPath() const
{
	return dataDir();
}

// --- what is installed -------------------------------------------------------

void Backend::rescan()
{
	const QDir dv(dataDir() + QStringLiteral("/voices"));
	m_voices.clear();
	const auto onnx = dv.entryList({ QStringLiteral("*.onnx") }, QDir::Files, QDir::Name);
	for (const QString &f : onnx)
		m_voices << QFileInfo(f).completeBaseName();

	// THE CHOSEN VOICE IS REMEMBERED, and the first one alphabetically is not
	// taken.
	//
	// Before, 'm_voices.value(0)' was taken, i.e. the first in the directory
	// listing. A real and baffling consequence: after downloading an English
	// voice, on the next start it took over by being "en_GB..." before
	// "es_ES..." -- and since the interface language comes from the voice, THE
	// WHOLE APP CAME UP IN ENGLISH without anyone having asked for that.
	if (m_activeVoice.isEmpty() || !m_voices.contains(m_activeVoice)) {
		const QString saved = _savedVoice();
		if (m_voices.contains(saved))
			m_activeVoice = saved;
		else
			m_activeVoice = m_voices.value(0);
		emit activeVoiceChanged();
	}

	// A region counts as present only when its routing tiles are there. The
	// geocoder alone would let the app find an address and then fail to route to
	// it, which is worse than admitting there is no map.
	const QDir dm(dataDir() + QStringLiteral("/maps"));
	m_maps.clear();
	m_drawables.clear();
	for (const QString &r : dm.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name)) {
		if (QFileInfo::exists(dm.filePath(r) + QStringLiteral("/valhalla/tiles")))
			m_maps << r;
		// And the ones that can also be DRAWN. They are separate lists on
		// purpose: a region may have what it needs to route and not what it needs
		// to be shown, or the other way round. Showing a single list would force
		// choosing which of the two to lie about.
		const QDir dd(dm.filePath(r) + QStringLiteral("/mapboxgl"));
		if (dd.exists() && !dd.entryList({ QStringLiteral("*.mbtiles") },
				QDir::Files).isEmpty())
			m_drawables << r;
	}

	emit voicesChanged();
	emit mapsChanged();
}

void Backend::setActiveVoice(const QString &id)
{
	if (m_activeVoice == id)
		return;
	m_activeVoice = id;
	_saveVoice();
	emit activeVoiceChanged();
	// The model is loaded once at startup, so switching voices means restarting
	// the process. Cheap enough: it happens when a person taps a settings row,
	// not while driving.
	startVoice();
}

// A FILE OF ITS OWN, not the interface's one.
//
// The interface's file is managed by QML's Settings element, which writes ITS
// whole set of properties every time. Sharing it caused two problems in a row:
// first a name clash -- 'voice' was already the mute switch, and ended up worth
// 'true' on top of the voice name -- and then, with another name, the key read
// back empty even though it was written in the file and QSettings said it had
// read it fine (status=0, 20 keys).
//
// The exact mechanism was not pursued further: two processes writing the same
// .conf is fragile by definition, and separating them costs one line.
QString Backend::_voiceFile()
{
	return QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
		+ QStringLiteral("/poconav-voice.conf");
}

QString Backend::_savedVoice() const
{
	QSettings s(_voiceFile(), QSettings::IniFormat);
	// WITHOUT a group, and not "General/chosenVoice". QSettings reserves the INI's
	// [General] section for keys that are NOT in any group, and to avoid stepping
	// on it, it writes a group actually named "General" as [%General]. So asking
	// for "General/chosenVoice" looks in a section that does not exist.
	//
	// Symptom: QSettings said the file was fine (status=0) and that it saw the
	// key (keys=1), and the read returned an empty string all the same.
	const QString v = s.value(QStringLiteral("chosenVoice")).toString();
	if (!v.isEmpty())
		return v;
	// The key was "vozElegida" before the rename. Read it once so the phone does
	// not forget which voice was chosen; the next write stores the new name.
	return s.value(QStringLiteral("vozElegida")).toString();
}

void Backend::_saveVoice() const
{
	QSettings s(_voiceFile(), QSettings::IniFormat);
	s.setValue(QStringLiteral("chosenVoice"), m_activeVoice);
}

// --- progress ----------------------------------------------------------------

void Backend::announce(const QString &text, int pct)
{
	m_busy = true;
	m_taskText = text;
	m_taskPct = pct;
	emit taskChanged();
}

void Backend::finish(bool ok, const QString &message)
{
	m_busy = false;
	m_taskText.clear();
	m_taskPct = 0;
	m_regionInProgress.clear();
	rescan();
	emit taskChanged();
	emit taskFinished(ok, message);
}

// --- downloading -------------------------------------------------------------

void Backend::request(const QUrl &url, const QString &destination)
{
	QDir().mkpath(QFileInfo(destination).absolutePath());

	m_outFile = new QFile(destination, this);
	if (!m_outFile->open(QIODevice::WriteOnly)) {
		delete m_outFile;
		m_outFile = nullptr;
		finish(false, tr("Cannot write to %1").arg(destination));
		return;
	}

	QNetworkRequest req(url);
	req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
		QNetworkRequest::NoLessSafeRedirectPolicy);
	m_download = m_net->get(req);
	connect(m_download, &QNetworkReply::downloadProgress, this, &Backend::onProgress);
	connect(m_download, &QNetworkReply::finished, this, &Backend::onDownloadFinished);
	// Written as it arrives, not held in memory: a region is hundreds of
	// megabytes and this phone has no room to buffer one.
	connect(m_download, &QNetworkReply::readyRead, this, [this] {
		if (m_outFile && m_download)
			m_outFile->write(m_download->readAll());
	});
}

void Backend::onProgress(qint64 received, qint64 total)
{
	if (total <= 0)
		return;
	announce(m_taskText, int(received * 100 / total));
}

void Backend::onDownloadFinished()
{
	QNetworkReply *r = m_download;
	m_download = nullptr;
	if (!r)
		return;
	r->deleteLater();

	QString file;
	if (m_outFile) {
		m_outFile->write(r->readAll());
		m_outFile->close();
		file = m_outFile->fileName();
		delete m_outFile;
		m_outFile = nullptr;
	}

	if (r->error() != QNetworkReply::NoError) {
		// A half-written file left on disk would be counted as installed on the
		// next start and would fail much later, somewhere unrelated.
		if (!file.isEmpty())
			QFile::remove(file);
		if (r->error() == QNetworkReply::OperationCanceledError)
			finish(false, tr("Cancelled"));
		else
			finish(false, r->errorString());
		return;
	}

	// The just-downloaded voice sets itself. Downloading it and then having to
	// choose it again would be one step too many for no reason.
	finish(true, tr("Done"));
	if (!m_requestedVoice.isEmpty()) {
		setActiveVoice(m_requestedVoice);
		m_requestedVoice.clear();
	}
}

void Backend::downloadVoice(const QString &id)
{
	if (m_busy) {
		emit taskFinished(false, tr("A download is already in progress"));
		return;
	}
	const QString path = voicePath(id);
	if (path.isEmpty()) {
		emit taskFinished(false, tr("Voice name not recognised: %1").arg(id));
		return;
	}

	const QString dir = dataDir() + QStringLiteral("/voices/");
	// The .json goes first and is small: it carries the sample rate, and without
	// it the voice plays at the wrong speed and sounds like a chipmunk.
	m_requestedVoice = id;
	announce(tr("Downloading the voice…"), 0);

	QNetworkRequest req(QUrl(QString::fromLatin1(kVoiceServer)
		+ QStringLiteral("/") + path + QStringLiteral(".onnx.json")));
	req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
		QNetworkRequest::NoLessSafeRedirectPolicy);
	QNetworkReply *meta = m_net->get(req);
	connect(meta, &QNetworkReply::finished, this, [this, meta, id, path, dir] {
		meta->deleteLater();
		if (meta->error() != QNetworkReply::NoError) {
			finish(false, meta->errorString());
			return;
		}
		QFile j(dir + id + QStringLiteral(".onnx.json"));
		if (j.open(QIODevice::WriteOnly)) {
			j.write(meta->readAll());
			j.close();
		}
		announce(tr("Downloading the voice…"), 1);
		request(QUrl(QString::fromLatin1(kVoiceServer) + QStringLiteral("/")
			+ path + QStringLiteral(".onnx")), dir + id + QStringLiteral(".onnx"));
	});
}

// Maps are not downloaded here, and that is deliberate.
//
// The map server's layout is not a plain file tree: component versions have to
// be scraped from its directory index, the region's file list comes from a
// catalogue, and Valhalla in particular arrives as numbered packages that have
// to be resolved before anything can be fetched. All of that already exists,
// tested, in 'local-maps' -- it is what downloaded the first gigabyte.
//
// Rewriting it in C++ would buy nothing and would very likely get it subtly
// wrong. So the app runs its own downloader: our script, in our package,
// started and stopped by us. The download belongs to the app either way.
void Backend::downloadMap(const QString &region)
{
	_downloadMap(region, false);
}

// The map's DRAWING is downloaded separately, and it is not an organisational
// whim.
//
// Knowing how to get somewhere and knowing how to show it are two separate
// downloads of very different size: for Spain, 1.1 GB of routing data against
// 1.9 GB of drawing tiles. Joining them would force waiting for both in order to
// navigate, and whoever only wants to get there has no reason to pay for the
// pretty map.
//
// The reverse holds too: on a trip you might want the drawing of a region you
// only pass through, without downloading its routes.
void Backend::downloadDrawing(const QString &region)
{
	m_boxes.clear();
	_downloadMap(region, true);
}

// The map for around here: only the tiles that surround this position.
//
// 'anillo' is how many tiles on each side. 0 is only the one underneath -- 132
// MB --, 1 is the nine around it. It is left to choose because the difference
// between "where I live" and "Saturday's trip" is exactly that.
void Backend::downloadDrawingNear(const QString &region, double lat, double lon,
	int anillo)
{
	m_boxes = boxesNear(lat, lon, qBound(0, anillo, 3));
	_downloadMap(region, true);
}

QStringList Backend::boxesAt(double lat, double lon, int anillo) const
{
	return boxesNear(lat, lon, qBound(0, anillo, 3));
}

QStringList Backend::boxesInRectangle(double minLat, double minLon,
	double maxLat, double maxLon) const
{
	return boxesInArea(minLat, minLon, maxLat, maxLon);
}

// The map for WHERE YOU ARE GOING, which is the one really needed.
//
// Downloading the tile underneath the phone is of little use: you are already
// there, and if you got there you had a map or coverage. What is needed before
// leaving is the one for the places you are going to pass through, and that is
// only known once the route is computed.
void Backend::downloadDrawingBoxes(const QString &region, const QStringList &boxes)
{
	if (boxes.isEmpty()) {
		emit taskFinished(false, tr("There is no tile to download"));
		return;
	}
	// Filtered here and not in QML: what comes from the interface ends up as part
	// of a command line, and "7-63-49" is all it can be.
	static const QRegularExpression wellFormed(QStringLiteral("^\\d+-\\d+-\\d+$"));
	QStringList clean;
	for (const QString &c : boxes)
		if (wellFormed.match(c).hasMatch())
			clean << c;
	if (clean.isEmpty()) {
		emit taskFinished(false, tr("Invalid tile name"));
		return;
	}
	m_boxes = clean;
	_downloadMap(region, true);
}

void Backend::_downloadMap(const QString &region, bool drawing)
{
	if (m_busy) {
		emit taskFinished(false, tr("A download is already in progress"));
		return;
	}
	// Catalogue regions carry a slash -- "europe/spain" -- so the slash is
	// allowed. What is NOT allowed is "..": the name ends up forming a disk path,
	// and without this check it could write outside the data directory.
	if (region.isEmpty() || region.contains(QStringLiteral(".."))
		|| region.startsWith(QLatin1Char('/'))) {
		emit taskFinished(false, tr("Invalid region name"));
		return;
	}

	m_regionInProgress = region;
	announce(drawing ? tr("Looking for the map of %1…").arg(region)
		: tr("Looking for %1…").arg(region), 0);

	m_downloader = new QProcess(this);
	m_downloader->setProcessChannelMode(QProcess::MergedChannels);

	// Each region in ITS OWN folder, so that deleting one does not leave another
	// without a file they shared. The slash is flattened to a hyphen: this way
	// the listing of what is installed is a single level of directories and there
	// is no need to walk a tree to know what is downloaded.
	QString folder = region;
	folder.replace(QLatin1Char('/'), QLatin1Char('-'));
	const QString destination = dataDir() + QStringLiteral("/maps/") + folder;

	QProcess *proc = m_downloader;

	connect(proc, &QProcess::readyReadStandardOutput, this, [this, proc] {
		// The text is accumulated because a read does NOT arrive split into
		// lines: it may cut "PROGRESS 45 ..." right after the "4" and then a 4%
		// that never existed would be announced. Only up to the last newline is
		// processed, and the rest waits for the next read.
		m_rest += QString::fromUtf8(proc->readAllStandardOutput());
		const int last = m_rest.lastIndexOf(QLatin1Char('\n'));
		if (last < 0)
			return;
		const QString whole = m_rest.left(last);
		m_rest = m_rest.mid(last + 1);

		for (const QString &l : whole.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
			if (!l.startsWith(QStringLiteral("PROGRESS ")))
				continue;
			// "PROGRESS <pct> <text>"
			const QString rest = l.mid(9);
			const int cut = rest.indexOf(QLatin1Char(' '));
			if (cut <= 0)
				continue;
			announce(rest.mid(cut + 1).trimmed(), rest.left(cut).toInt());
		}
	});

	// finished and errorOccurred can BOTH fire -- if the program does not exist
	// errorOccurred(FailedToStart) and finished(CrashExit) arrive --, so whichever
	// arrives second has to find the ground clean. Before, the finished handler
	// used the member without checking it and would have dereferenced it once
	// already set to null.
	connect(proc, &QProcess::finished, this,
		[this, proc](int code, QProcess::ExitStatus status) {
			if (m_downloader != proc)
				return;
			m_downloader = nullptr;
			m_rest.clear();
			proc->deleteLater();
			if (status == QProcess::CrashExit)
				finish(false, tr("The download was interrupted"));
			else if (code != 0)
				finish(false, tr("Could not download (check the region name)"));
			else
				finish(true, tr("Map ready"));
		});

	connect(proc, &QProcess::errorOccurred, this,
		[this, proc](QProcess::ProcessError failure) {
			if (m_downloader != proc)
				return;
			// Only being unable to start it matters. The other failures come
			// accompanied by 'finished', and jumping ahead here would give two
			// warnings for the same problem.
			if (failure != QProcess::FailedToStart)
				return;
			m_downloader = nullptr;
			m_rest.clear();
			proc->deleteLater();
			finish(false, tr("Cannot find the map downloader"));
		});

	QStringList args = { QStringLiteral("--download"), region,
		QStringLiteral("--destination"), destination };
	if (drawing) {
		// The country tiles AND the GLOBAL pieces. Without the fonts NO label is
		// drawn: the map comes out with its streets and its rivers and without a
		// single name, which for driving is almost worse than not having it.
		args << QStringLiteral("--only")
		     << QStringLiteral("mapboxgl_country,mapboxgl_glyphs,mapboxgl_global");
		if (!m_boxes.isEmpty())
			args << QStringLiteral("--packages")
			     << m_boxes.join(QLatin1Char(','));
	}
	m_downloader->start(QStringLiteral("local-maps"), args);
}

void Backend::cancel()
{
	m_requestedVoice.clear();
	// terminate() and not kill(): the downloader removes its half-written .part
	// file when it is asked to stop, and a killed one would leave it behind to
	// be mistaken for a finished download later.
	if (m_downloader && m_downloader->state() != QProcess::NotRunning) {
		m_downloader->terminate();
		return;   // the 'finished' handler takes care of the rest
	}
	if (m_download)
		m_download->abort();   // the finished handler cleans up the partial file
	else if (m_busy)
		finish(false, tr("Cancelled"));
}

void Backend::deleteMap(const QString &region)
{
	if (region.isEmpty() || region.contains(QStringLiteral("..")))
		return;
	QDir(dataDir() + QStringLiteral("/maps/") + region).removeRecursively();
	rescan();
}

// --- speech ------------------------------------------------------------------

void Backend::startVoice()
{
	if (m_piper) {
		m_piper->closeWriteChannel();
		m_piper->waitForFinished(2000);
		m_piper->deleteLater();
		m_piper = nullptr;
	}
	if (m_aplay) {
		m_aplay->deleteLater();
		m_aplay = nullptr;
	}
	if (m_activeVoice.isEmpty())
		return;

	const QString model = dataDir() + QStringLiteral("/voices/")
		+ m_activeVoice + QStringLiteral(".onnx");
	if (!QFileInfo::exists(model))
		return;

	// The sample rate comes from the model itself. Assuming 22050 works for most
	// voices and makes the rest unintelligible.
	int rate = 22050;
	QFile j(model + QStringLiteral(".json"));
	if (j.open(QIODevice::ReadOnly)) {
		const QJsonObject o = QJsonDocument::fromJson(j.readAll()).object();
		rate = o.value(QStringLiteral("audio")).toObject()
			.value(QStringLiteral("sample_rate")).toInt(rate);
		if (o.contains(QStringLiteral("sample_rate")))
			rate = o.value(QStringLiteral("sample_rate")).toInt(rate);
	}

	m_piper = new QProcess(this);
	m_aplay = new QProcess(this);
	// Raw audio straight from one process into the other: writing a wav file per
	// phrase would add a disk round-trip to something that has to be quick.
	m_piper->setStandardOutputProcess(m_aplay);
	m_aplay->start(QStringLiteral("aplay"),
		{ QStringLiteral("-q"), QStringLiteral("-t"), QStringLiteral("raw"),
		  QStringLiteral("-r"), QString::number(rate),
		  QStringLiteral("-f"), QStringLiteral("S16_LE"),
		  QStringLiteral("-c"), QStringLiteral("1"), QStringLiteral("-") });
	m_piper->start(QStringLiteral("piper"),
		{ QStringLiteral("-m"), model, QStringLiteral("--output-raw") });
}

// BE QUIET RIGHT NOW, not when the phrase finishes.
//
// Needed because piper and aplay form a pipe with its own lead: a delivered
// phrase IS ALREADY being generated and playing, and there is no way to pull it
// back. On cancelling a route, the app went quiet inside and the speaker kept
// saying "turn left" -- past the moment and with no route to refer to, which is
// worse than saying nothing.
//
// The only way to really cut it off is to tear the pipe down and bring it back
// up. It costs a few seconds of reloading the model, but that only shows on the
// next phrase, and cancelling a route is not usually followed by another at
// once.
void Backend::stopSpeaking()
{
	if (!m_piper && !m_aplay)
		return;

	// aplay FIRST: it is the one with the sound in flight. Killing piper first
	// leaves what is already generated in aplay's buffer and it keeps playing.
	if (m_aplay && m_aplay->state() != QProcess::NotRunning) {
		m_aplay->kill();
		m_aplay->waitForFinished(500);
	}
	if (m_piper && m_piper->state() != QProcess::NotRunning) {
		m_piper->kill();
		m_piper->waitForFinished(500);
	}
	delete m_aplay;
	delete m_piper;
	m_aplay = nullptr;
	m_piper = nullptr;

	// And it is brought back up, so the next phrase has someone to say it.
	startVoice();
}

void Backend::speak(const QString &phrase)
{
	if (phrase.isEmpty())
		return;

	if (m_piper && m_piper->state() == QProcess::Running) {
		m_piper->write(phrase.toUtf8() + '\n');
		return;
	}

	// Fallback while no neural voice is installed. Robotic, but it is in the
	// repositories and it is there from the first run -- an app that says
	// nothing until a 60 MB download finishes is worse.
	//
	// -s 165 instead of the default 175: slower reads better over road noise.
	QProcess::startDetached(QStringLiteral("espeak-ng"),
		{ QStringLiteral("-v"), m_activeVoice.left(2).isEmpty()
			? QStringLiteral("es") : m_activeVoice.left(2),
		  QStringLiteral("-s"), QStringLiteral("165"),
		  QStringLiteral("-a"), QStringLiteral("200"),
		  QStringLiteral("--"), phrase });
}

// --- screen ------------------------------------------------------------------

void Backend::keepScreenOn(bool on)
{
	if (on) {
		if (m_inhibitor)
			return;
		m_inhibitor = new QProcess(this);
		// 'idle' only. Not 'sleep': if the driver presses the power button the
		// phone should sleep, because that is what pressing it means.
		m_inhibitor->start(QStringLiteral("systemd-inhibit"),
			{ QStringLiteral("--what=idle"), QStringLiteral("--who=PocoNav"),
			  QStringLiteral("--why=navigating"),
			  QStringLiteral("sh"), QStringLiteral("-c"),
			  QStringLiteral("while :; do sleep 3600; done") });
		return;
	}
	if (m_inhibitor) {
		m_inhibitor->kill();
		m_inhibitor->waitForFinished(1000);
		m_inhibitor->deleteLater();
		m_inhibitor = nullptr;
	}
}
