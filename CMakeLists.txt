cmake_minimum_required(VERSION 3.21)
project(240mp VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Strip qDebug(...) calls in Release builds
add_compile_definitions($<$<CONFIG:Release>:QT_NO_DEBUG_OUTPUT>)

# Release version string. CI passes the git tag (-DAPP_VERSION=vX.Y.Z); local
# builds report "dev", which disables the in-app self-update download path.
set(APP_VERSION "dev" CACHE STRING "Release version (CI passes the git tag)")

find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick Qml Network Svg)
find_package(OpenSSL REQUIRED)          # PlexBackend: Ed25519 device JWT (no CNG equivalent)
find_package(SDL2 CONFIG REQUIRED)      # gamepad input (InputManager)

# WIN32: GUI subsystem, no console window. Logs go to DATA_ROOT/logs/240mp.log
# and to the parent console when launched from a terminal (src/win_utils.cpp).
add_executable(240mp WIN32
    src/main.cpp
    src/win_utils.cpp
    src/AppCore.cpp
    src/modules/local_files/LocalFilesBackend.cpp
    src/modules/plex/PlexBackend.cpp
    src/modules/jellyfin/JellyfinBackend.cpp
    src/modules/ambient_mode/AmbientModeBackend.cpp
    src/modules/youtube/YouTubeBackend.cpp
    src/player/MpvController.cpp
    src/input/InputManager.cpp
    src/input/IdleTracker.cpp
    src/update/UpdateManager.cpp
    assets/240mp.rc
)

target_compile_definitions(240mp PRIVATE APP_VERSION="${APP_VERSION}")

target_link_libraries(240mp PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::Qml
    Qt6::Network
    Qt6::Svg
    OpenSSL::Crypto
    SDL2::SDL2
)

target_include_directories(240mp PRIVATE
    src
)

# ── Dev-run convenience ────────────────────────────────────────────────────────
# Make the freshly built exe directly runnable (double-click included): deploy
# the Qt runtime beside it, then copy the non-Qt DLLs. Without this, launching
# build/240mp.exe outside a Qt-on-PATH shell dies with a "Qt6Quick.dll not
# found" loader error.
find_program(WINDEPLOYQT_EXECUTABLE windeployqt HINTS "${Qt6_DIR}/../../../bin")
if(WINDEPLOYQT_EXECUTABLE)
    add_custom_command(TARGET 240mp POST_BUILD
        COMMAND "${WINDEPLOYQT_EXECUTABLE}" --qmldir "${CMAKE_SOURCE_DIR}"
            --no-translations $<TARGET_FILE:240mp>
        COMMENT "Deploying Qt runtime beside the executable (windeployqt)"
    )
else()
    message(WARNING "windeployqt not found — build/240mp.exe will need Qt's bin dir on PATH to run (scripts/run-local.ps1 handles that)")
endif()
add_custom_command(TARGET 240mp POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "$<TARGET_FILE:SDL2::SDL2>" "$<TARGET_FILE_DIR:240mp>"
    COMMENT "Copying SDL2.dll beside the executable"
)
if(DEFINED OPENSSL_ROOT_DIR)
    file(GLOB _openssl_dlls "${OPENSSL_ROOT_DIR}/bin/libcrypto-3-x64.dll")
    if(_openssl_dlls)
        add_custom_command(TARGET 240mp POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                ${_openssl_dlls} "$<TARGET_FILE_DIR:240mp>"
            COMMENT "Copying OpenSSL libcrypto beside the executable"
        )
    endif()
endif()

# ── Install rules ──────────────────────────────────────────────────────────────
# Flat layout: 240mp.exe sits next to Main.qml/views/modules/assets/scripts at
# the package root — resolveAppRoot() finds Main.qml zero levels up. CI runs
# windeployqt over the staged folder afterwards to add the Qt runtime.
install(TARGETS 240mp RUNTIME DESTINATION . COMPONENT Runtime)

install(IMPORTED_RUNTIME_ARTIFACTS SDL2::SDL2
    RUNTIME DESTINATION . COMPONENT Runtime)

if(DEFINED OPENSSL_ROOT_DIR AND _openssl_dlls)
    install(FILES ${_openssl_dlls} DESTINATION . COMPONENT Runtime)
endif()

install(FILES "${CMAKE_SOURCE_DIR}/Main.qml" "${CMAKE_SOURCE_DIR}/LICENSE"
    DESTINATION . COMPONENT Runtime)

install(DIRECTORY
    "${CMAKE_SOURCE_DIR}/views"
    "${CMAKE_SOURCE_DIR}/modules"
    "${CMAKE_SOURCE_DIR}/assets"
    DESTINATION . COMPONENT Runtime)

install(DIRECTORY "${CMAKE_SOURCE_DIR}/scripts"
    DESTINATION . COMPONENT Runtime
    FILES_MATCHING PATTERN "*.lua")

# ── CPack ──────────────────────────────────────────────────────────────────────
set(CPACK_PACKAGE_NAME "240-MP")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "240-MP Media Player")
set(CPACK_PACKAGE_VENDOR "240-MP")
set(CPACK_GENERATOR "ZIP")

include(CPack)
