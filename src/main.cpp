// SPDX-License-Identifier: LGPL-2.0-or-later
#include "backend.h"

#include <QGuiApplication>
#include <QIcon>
#include <QSettings>
#include <QStandardPaths>
#include <QLibraryInfo>
#include <QLocale>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QTranslator>

int main(int argc, char *argv[])
{
	// Wayland on this phone reports the wrong physical DPI, and Kirigami sizes
	// every touch target from it. Left alone, the buttons come out too small to
	// hit while driving.
	QGuiApplication::setHighDpiScaleFactorRoundingPolicy(
		Qt::HighDpiScaleFactorRoundingPolicy::PassThrough);

	QGuiApplication app(argc, argv);

	// Only the application name, WITHOUT an organisation, and it is not an
	// oversight.
	//
	// AppDataLocation is worth "<data>/<organisation>/<application>" when an
	// organisation is set, and "<data>/<application>" when not. With both set to
	// "poconav" the maps ended up in ~/.local/share/poconav/poconav, one level
	// below where the already-downloaded ones were -- and the app said "there are
	// no maps" with a gigabyte on disk.
	//
	// Changing this orphans whatever is already downloaded, so it is not touched.
	QCoreApplication::setApplicationName(QStringLiteral("poconav"));

	// THE ICON THEME HAS TO BE STATED, and without this the map buttons come out
	// as EMPTY circles -- no speaker, no compass, no target.
	//
	// A Plasma application inherits the theme through KDE's integration. This is a
	// bare QGuiApplication, so it inherits nothing, and besides this phone's
	// kdeglobals has no [Icons] section. Qt then settles for 'hicolor', which has
	// NONE of the names we use: checked with find, they all live in breeze and
	// breeze-dark.
	//
	// It is set as a FALLBACK and not by force, so that if one day the system does
	// declare a theme, its own wins and breeze is only resorted to for what it is
	// missing.
	// And it has to be told WHERE to look, which is what really failed. Measured:
	//
	//   QIcon::themeSearchPaths()  ->  ":/icons"
	//   QIcon::hasThemeIcon("gps") ->  false
	//
	// Only Qt's internal resource. '/usr/share/icons' was NOT there, because
	// those paths come from XDG_DATA_DIRS and, starting without a full desktop
	// session, that variable comes empty. Result: the map buttons were drawn as
	// EMPTY circles, no speaker, no compass and no target.
	//
	// They are added by hand instead of trusting the environment: the app has to
	// look the same whether Plasma, a test script or systemd starts it.
	QStringList rutasIconos = QIcon::themeSearchPaths();
	const QStringList candidatas = {
		QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
			+ QStringLiteral("/icons"),
		QStringLiteral("/usr/local/share/icons"),
		QStringLiteral("/usr/share/icons"),
	};
	for (const QString &d : candidatas)
		if (!rutasIconos.contains(d))
			rutasIconos << d;
	QIcon::setThemeSearchPaths(rutasIconos);

	QIcon::setFallbackThemeName(QStringLiteral("breeze"));
	if (QIcon::themeName().isEmpty())
		QIcon::setThemeName(QStringLiteral("breeze"));

	QGuiApplication::setDesktopFileName(QStringLiteral("poconav"));
	QGuiApplication::setWindowIcon(QIcon::fromTheme(QStringLiteral("poconav")));

	// MapLibre lives outside Qt's plugin tree, and that is why Qt does not see it.
	//
	// It is the only way to a map that is DRAWN without coverage: Qt's osm plugin
	// only paints images fetched from the network, and without it only what is in
	// the cache of already-visited places remains -- measured on this phone, 9 MB
	// against the 2.2 GB of routing data.
	//
	// Ours is installed in /usr/lib/poconav and not in /usr, and that is not a
	// quirk: the files are named THE SAME as those of the Qt5 package already on
	// the phone -- /usr/lib/libQMapLibre.so.3 both -- and Pure Maps uses that one.
	// Installing on top would not be coexisting, it would be leaving it without a
	// map.
	//
	// The path that is added is the plugin ROOT, not its parent: Qt looks in
	// "<root>/geoservices/". With the root wrongly set the symptom is that
	// 'maplibre' does not show in the list and that is that -- the .so is
	// installed, it can be listed with 'ls', and the map stays blank all the same.
	// Only QT_DEBUG_PLUGINS=1 tells the tale.
	QCoreApplication::addLibraryPath(QStringLiteral("/usr/lib/poconav/plugins"));

	// --probar: loads the self-test instead of the interface, requests real routes
	// where the app requests them, and exits with a non-zero code if something
	// fails. See SelfTest.qml for why it was needed.
	const bool probando = app.arguments().contains(QStringLiteral("--probar"));

	// --retratos <folder>: loads the real interface and photographs it. It is
	// passed to QML through a context property instead of reading the arguments
	// from there, which QML cannot do.
	// --solo-mapa [plugin]: a map and nothing else, so the plugin can be looked at
	// without the rest of the app around it. See MapOnly.qml.
	QString soloMapa;
	const int iMapa = app.arguments().indexOf(QStringLiteral("--solo-mapa"));
	if (iMapa >= 0) {
		soloMapa = QStringLiteral("maplibre");
		if (iMapa + 1 < app.arguments().size()
			&& !app.arguments().at(iMapa + 1).startsWith(QLatin1Char('-')))
			soloMapa = app.arguments().at(iMapa + 1);
	}

	QString retratos;
	const int iRet = app.arguments().indexOf(QStringLiteral("--retratos"));
	if (iRet >= 0 && iRet + 1 < app.arguments().size())
		retratos = app.arguments().at(iRet + 1);

	// --- language ----------------------------------------------------------
	// The texts are written in Spanish and marked with qsTr(), so with no
	// translation loaded the app comes out exactly as it was: the normal case does
	// not depend on anything working.
	//
	// The language is NOT chosen separately: it is taken from the voice set in the
	// settings. It already rules over the route directions, and having an English
	// voice reading a Spanish interface would be two settings for a single
	// decision.
	QTranslator traductor;
	Backend backend;
	// POCONAV_IDIOMA overrides everything else. It is for testing a translation
	// without having to download a 60 MB voice just to see how the screen looks in
	// another language.
	QString idioma = qEnvironmentVariable("POCONAV_IDIOMA");
	if (idioma.isEmpty()) {
		idioma = backend.vozActiva().left(5);   // "es_ES-davefx..." -> "es_ES"
		if (idioma.size() < 5 || !idioma.contains(QLatin1Char('_')))
			idioma = QLocale::system().name();
	}
	// AND HERE IT IS LOADED, which is what was missing. Until now this block
	// computed the language with great care and did nothing with it: the
	// QTranslator was declared, never loaded and never installed. The app always
	// came out in its source Spanish -- which is exactly what you see when a
	// translation works and the system language is Spanish, and that is why it went
	// unnoticed: I checked that the .ts files had the strings instead of checking
	// that the screen came out in English.
	//
	// It tries first where the package installs them and then next to the binary,
	// so a freshly compiled executable can be translated without installing it.
	//
	// QLocale and not the bare string: with "en_GB" it looks for 'poconav_en_GB.qm'
	// and, if it is not there, 'poconav_en.qm'. Without that fallback a British
	// voice would leave the interface untranslated with English right next to it.
	const QStringList dondeBuscar = {
		QStringLiteral("/usr/share/poconav/translations"),
		QCoreApplication::applicationDirPath() + QStringLiteral("/translations"),
		QCoreApplication::applicationDirPath(),
	};
	bool traducida = false;
	for (const QString &d : dondeBuscar) {
		if (traductor.load(QLocale(idioma), QStringLiteral("poconav"),
				QStringLiteral("_"), d)) {
			traducida = QCoreApplication::installTranslator(&traductor);
			break;
		}
	}
	// Having NO translation is not an error: Spanish is the source language and has
	// no .qm. It is only reported when photographing, which is when it matters to
	// know what language the screen came out in.
	if (!retratos.isEmpty())
		qInfo("language: %s  voice: %s  translated: %s", qPrintable(idioma),
			qPrintable(backend.vozActiva()), traducida ? "yes" : "no");

	QQmlApplicationEngine motor;
	// And its QML module, for the same reason: the plugin is loaded through the
	// library list, but 'import MapLibre' is resolved through a different one.
	motor.addImportPath(QStringLiteral("/usr/lib/poconav/qml"));
	// A plain context property rather than a registered QML type: there is
	// exactly one backend and QML must not be able to make another. A second one
	// would mean two piper processes and two writers into the data directory.
	motor.rootContext()->setContextProperty(QStringLiteral("app"), &backend);
	motor.rootContext()->setContextProperty(QStringLiteral("retratosEn"), retratos);
	motor.rootContext()->setContextProperty(QStringLiteral("soloMapa"), soloMapa);

	motor.load(QUrl(!soloMapa.isEmpty()
		? QStringLiteral("qrc:/qt/qml/PocoNav/MapOnly.qml")
		: probando
		? QStringLiteral("qrc:/qt/qml/PocoNav/SelfTest.qml")
		: QStringLiteral("qrc:/qt/qml/PocoNav/main.qml")));
	if (motor.rootObjects().isEmpty())
		return 1;

	return app.exec();
}
