cmake_minimum_required(VERSION 3.20)
project(Peariscope LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# --- Qt6 ---
find_package(Qt6 REQUIRED COMPONENTS Quick QuickControls2 Widgets DBus)

# --- PkgConfig dependencies ---
find_package(PkgConfig REQUIRED)
pkg_check_modules(PipeWire REQUIRED IMPORTED_TARGET libpipewire-0.3)
pkg_check_modules(LibAVCodec REQUIRED IMPORTED_TARGET libavcodec)
pkg_check_modules(LibAVUtil REQUIRED IMPORTED_TARGET libavutil)
pkg_check_modules(LibSWScale REQUIRED IMPORTED_TARGET libswscale)
pkg_check_modules(Protobuf REQUIRED IMPORTED_TARGET protobuf)
pkg_check_modules(Avahi REQUIRED IMPORTED_TARGET avahi-client)
pkg_check_modules(DBus1 REQUIRED IMPORTED_TARGET dbus-1)

# --- System libraries ---
find_package(OpenGL REQUIRED)
find_package(X11 REQUIRED COMPONENTS Xtst)
find_package(OpenSSL REQUIRED)

# --- Protobuf code generation ---
find_program(PROTOC_EXECUTABLE protoc REQUIRED)
set(PROTO_FILE "${CMAKE_SOURCE_DIR}/protocol/messages.proto")
set(PROTO_SRCS "${CMAKE_CURRENT_BINARY_DIR}/messages.pb.cc")
set(PROTO_HDRS "${CMAKE_CURRENT_BINARY_DIR}/messages.pb.h")
add_custom_command(
    OUTPUT ${PROTO_SRCS} ${PROTO_HDRS}
    COMMAND ${PROTOC_EXECUTABLE}
        --cpp_out=${CMAKE_CURRENT_BINARY_DIR}
        -I${CMAKE_SOURCE_DIR}/protocol
        ${PROTO_FILE}
    DEPENDS ${PROTO_FILE}
    COMMENT "Running protoc on messages.proto"
)

# --- Sources ---
set(APP_SOURCES
    src/main.cpp
    src/app/AppController.cpp
    src/app/AppController.h
    src/app/RecentConnectionsModel.h
    src/app/QrCode.cpp
    src/app/QrCode.h
    src/app/CrashLog.cpp
    src/app/CrashLog.h
    src/app/SleepWakeMonitor.cpp
    src/app/SleepWakeMonitor.h
    src/app/NetworkMonitor.cpp
    src/app/NetworkMonitor.h
    src/app/NativeUpdater.cpp
    src/app/NativeUpdater.h
    src/capture/PipewireCapture.cpp
    src/capture/PipewireCapture.h
    src/video/FfmpegEncoder.cpp
    src/video/FfmpegEncoder.h
    src/video/FfmpegDecoder.cpp
    src/video/FfmpegDecoder.h
    src/video/GlRenderer.cpp
    src/video/GlRenderer.h
    src/audio/PwAudioCapture.cpp
    src/audio/PwAudioCapture.h
    src/audio/FfmpegAudioEncoder.cpp
    src/audio/FfmpegAudioEncoder.h
    src/audio/FfmpegAudioDecoder.cpp
    src/audio/FfmpegAudioDecoder.h
    src/audio/PwAudioPlayer.cpp
    src/audio/PwAudioPlayer.h
    src/input/X11InputCapture.cpp
    src/input/X11InputCapture.h
    src/input/X11InputInjector.cpp
    src/input/X11InputInjector.h
    src/auth/KeyManager.cpp
    src/auth/KeyManager.h
    src/networking/IpcBridge.cpp
    src/networking/IpcBridge.h
    src/app/AvahiAdvertiser.cpp
    src/app/AvahiAdvertiser.h
    ${PROTO_SRCS}
    ${PROTO_HDRS}
)

qt_add_executable(Peariscope ${APP_SOURCES})
set_target_properties(Peariscope PROPERTIES OUTPUT_NAME peariscope-app)

# --- QML Module ---
file(GLOB QML_FILES RELATIVE ${CMAKE_SOURCE_DIR} src/qml/*.qml)
file(GLOB QML_COMPONENT_FILES RELATIVE ${CMAKE_SOURCE_DIR} src/qml/components/*.qml)

qt_add_qml_module(Peariscope
    URI Peariscope
    VERSION 1.0
    QML_FILES
        ${QML_FILES}
        ${QML_COMPONENT_FILES}
    RESOURCES
        assets/app-logo@3x.png
    SOURCES
        src/app/AppController.h
        src/app/AppController.cpp
        src/app/RecentConnectionsModel.h
)

# Register Theme.qml as a QML singleton
set_source_files_properties(src/qml/components/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

# --- Include directories ---
target_include_directories(Peariscope PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}
    src
    src/app
)

# --- Link libraries ---
target_link_libraries(Peariscope PRIVATE
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Widgets
    Qt6::DBus
    PkgConfig::PipeWire
    PkgConfig::LibAVCodec
    PkgConfig::LibAVUtil
    PkgConfig::LibSWScale
    OpenGL::GL
    X11
    Xext
    Xtst
    OpenSSL::Crypto
    PkgConfig::Protobuf
    PkgConfig::Avahi
    PkgConfig::DBus1
    pthread
)

# --- Copy assets ---
add_custom_command(TARGET Peariscope POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_SOURCE_DIR}/assets"
        "$<TARGET_FILE_DIR:Peariscope>/assets"
    COMMENT "Copying assets"
)

# --- Copy pear runtime ---
if(EXISTS "${CMAKE_SOURCE_DIR}/pear")
    add_custom_command(TARGET Peariscope POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_SOURCE_DIR}/pear"
            "$<TARGET_FILE_DIR:Peariscope>/pear"
        COMMENT "Copying pear runtime"
    )
endif()

# --- Find node binary for bundling ---
find_program(NODE_EXECUTABLE node REQUIRED)
message(STATUS "Found node: ${NODE_EXECUTABLE}")
