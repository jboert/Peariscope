# Peariscope Windows Build Instructions

## Prerequisites
- Visual Studio 2022 with C++ Desktop workload
- CMake 3.20+
- Protocol Buffers (protobuf) installed and on PATH (`vcpkg install protobuf` or manual)
- Node.js 18+ installed and on PATH

## Directory Structure
After unzipping, you should have:
```
WINDOWS/
  windows/          # C++ source code + CMakeLists.txt
  protocol/         # messages.proto (protobuf schema)
  pear/             # JS worklet + node_modules
  icons/            # App icon PNGs (convert to .ico for Windows)
```

## Build Steps

1. Install Node.js dependencies (if node_modules not included):
   ```
   cd pear
   npm install
   ```

2. Configure CMake:
   ```
   cd windows
   mkdir build && cd build
   cmake .. -G "Visual Studio 17 2022" -A x64
   ```
   If protobuf is installed via vcpkg:
   ```
   cmake .. -G "Visual Studio 17 2022" -A x64 -DCMAKE_TOOLCHAIN_FILE=[vcpkg-root]/scripts/buildsystems/vcpkg.cmake
   ```

3. Build:
   ```
   cmake --build . --config Release
   ```

4. The built exe will be in `build/Release/Peariscope.exe`
   The post-build step copies the `pear/` directory next to the exe.

## Architecture

- **IpcBridge** launches `node pear/worklet.js` as a subprocess
- Communication is via stdin/stdout using 4-byte BE length-prefixed binary frames
- Protocol: Native→Worklet messages 0x01-0x07, Worklet→Native 0x81-0x8B
- Stream channels: 0=video (H.264/H.265 Annex B), 1=input (protobuf InputEvent), 2=control (protobuf ControlMessage)
- Screen capture: DXGI Desktop Duplication API
- Video encode/decode: Media Foundation (H.264/H.265)
- Rendering: Direct3D 11

## Key Dependencies (linked by CMakeLists.txt)
- d3d11, dxgi — GPU and screen capture
- mf, mfplat, mfreadwrite — Media Foundation video codec
- protobuf::libprotobuf — control channel serialization
- dwmapi, user32, gdi32, crypt32, ws2_32 — Windows system APIs

## Notes
- The app runs as a GUI application (WIN32_EXECUTABLE)
- Node.js must be available on PATH at runtime for the IPC bridge to work
- The worklet.js has a Node.js compatibility shim that wraps process.stdin/stdout as IPC pipes
