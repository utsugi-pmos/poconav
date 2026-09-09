# PocoNav: a real binary, not a QML file handed to qmlscene.
#
# It was qmlscene until now, and that cost more than it looked. qmlscene is
# deprecated, it cannot own a desktop file (so Plasma showed a generic window
# with no icon), it cannot be translated, and above all it left the app with no
# place to put code -- which is why downloads, speech and the screen lock all
# ended up as shell scripts poking at the settings file.
cmake_minimum_required(VERSION 3.20)
project(poconav VERSION 1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick Network Positioning)
# LinguistTools is what brings qt_add_translations, which compiles the .ts to .qm.
# Optional on purpose: without it, the application builds all the same and stays in
# its original Spanish. A missing translator cannot stop the build.
find_package(Qt6 6.5 QUIET COMPONENTS LinguistTools)

qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(poconav
	src/main.cpp
	src/backend.cpp
	src/backend.h
)

# The QML goes inside the binary. On a phone this is not about tidiness: loose
# .qml files next to the binary can be edited by anything running as the user,
# and a map that reroutes you is a bad thing to leave writable.
# Theme is a singleton: you have to tell CMake, or the module registers it as
# an ordinary type and 'Theme.blue' does not exist.
set_source_files_properties(Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(poconav
	URI PocoNav
	VERSION 1.0
	QML_FILES
		main.qml
		Theme.qml
		Route.qml
		Voice.qml
		Settings.qml
		DestinationSearch.qml
		DrivingPanel.qml
		ManeuverArrow.qml
		Lanes.qml
		SelfTest.qml
		Planner.qml
		RoutesPanel.qml
		FilterWarning.qml
		Portraits.qml
		Simulator.qml
		Sun.qml
		MapOnly.qml
)

target_link_libraries(poconav PRIVATE
	Qt6::Core
	Qt6::Gui
	Qt6::Qml
	Qt6::Quick
	Qt6::Network
	Qt6::Positioning
)

include(GNUInstallDirs)
install(TARGETS poconav
	BUNDLE DESTINATION .
	RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
	LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
# The translations. Compiling .ts -> .qm is done by Qt; if there are none, this
# does nothing and the application stays in its original Spanish.
file(GLOB _ts "${CMAKE_CURRENT_SOURCE_DIR}/translations/*.ts")
if(_ts AND Qt6LinguistTools_FOUND)
	qt_add_translations(poconav TS_FILES ${_ts}
		QM_FILES_OUTPUT_VARIABLE _qm)
	install(FILES ${_qm}
		DESTINATION ${CMAKE_INSTALL_DATADIR}/poconav/translations)
endif()

install(FILES poconav.desktop
	DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
# The files that describe where the tiles come from. One per theme.
install(DIRECTORY providers/
	DESTINATION ${CMAKE_INSTALL_DATADIR}/poconav/providers)

install(FILES poconav.svg
	DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps)
