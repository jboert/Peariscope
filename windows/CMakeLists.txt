cmake_minimum_required(VERSION 3.20)
project(Peariscope VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Find required Windows SDK components
find_package(Protobuf REQUIRED)

# Generate protobuf C++ sources
protobuf_generate_cpp(PROTO_SRCS PROTO_HDRS
    ${CMAKE_SOURCE_DIR}/../protocol/messages.proto
)

add_executable(Peariscope
    src/main.cpp

    # App
    src/app/App.cpp
    src/app/App.h
    src/app/HostWindow.cpp
    src/app/HostWindow.h
    src/app/ViewerWindow.cpp
    src/app/ViewerWindow.h

    # Screen capture
    src/capture/DxgiCapture.cpp
    src/capture/DxgiCapture.h

    # Video encode/decode
    src/video/MfEncoder.cpp
    src/video/MfEncoder.h
    src/video/MfDecoder.cpp
    src/video/MfDecoder.h
    src/video/D3DRenderer.cpp
    src/video/D3DRenderer.h

    # Input
    src/input/InputCapture.cpp
    src/input/InputCapture.h
    src/input/InputInjector.cpp
    src/input/InputInjector.h

    # Auth
    src/auth/KeyManager.cpp
    src/auth/KeyManager.h

    # Networking
    src/networking/IpcBridge.cpp
    src/networking/IpcBridge.h

    # Generated protobuf
    ${PROTO_SRCS}
    ${PROTO_HDRS}
)

target_include_directories(Peariscope PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}  # For generated protobuf headers
    src
)

target_link_libraries(Peariscope PRIVATE
    # Windows SDK
    d3d11
    dxgi
    mf
    mfplat
    mfreadwrite
    mfuuid
    evr
    wmcodecdspuuid

    # Protobuf
    protobuf::libprotobuf

    # System
    dwmapi
    user32
    gdi32
    ole32
    crypt32
    ws2_32
    shell32
    shlwapi
)

# Subsystem: Windows (GUI app, not console)
set_target_properties(Peariscope PROPERTIES
    WIN32_EXECUTABLE TRUE
)

# Copy pear runtime files to output directory
add_custom_command(TARGET Peariscope POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:Peariscope>/pear"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_SOURCE_DIR}/../pear"
        "$<TARGET_FILE_DIR:Peariscope>/pear"
    COMMENT "Copying Pear runtime files"
)
