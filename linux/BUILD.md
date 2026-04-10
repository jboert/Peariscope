# Building Peariscope on Linux

## Dependencies (openSUSE)

```bash
sudo zypper install -y \
  cmake gcc-c++ \
  qt6-declarative-devel qt6-base-devel qt6-quickcontrols2-devel \
  pipewire-devel \
  ffmpeg-7-libavcodec-devel ffmpeg-7-libavutil-devel ffmpeg-7-libswscale-devel \
  libX11-devel libXtst-devel libXext-devel \
  libopenssl-devel \
  protobuf-devel \
  nodejs20
```

If the ffmpeg-7 packages aren't available, try without the `ffmpeg-7-` prefix:
```bash
sudo zypper install -y libavcodec-devel libavutil-devel libswscale-devel
```

Or on Tumbleweed / with Packman repo:
```bash
sudo zypper install -y ffmpeg-devel
```

## Dependencies (Ubuntu/Debian)

```bash
sudo apt install -y \
  cmake g++ \
  qt6-declarative-dev qt6-base-dev \
  libpipewire-0.3-dev \
  libavcodec-dev libavutil-dev libswscale-dev \
  libx11-dev libxtst-dev libxext-dev \
  libssl-dev \
  protobuf-compiler libprotobuf-dev \
  nodejs
```

## Build

```bash
cd peariscope-linux
mkdir -p build && cd build
cmake ..
make -j$(nproc)
```

The binary will be at `build/peariscope-app`.

## Run

```bash
cd build
./peariscope-app
```

### Requirements at runtime:
- **X11 session** (not Wayland) — screen capture and input injection use X11/XShm/XTest
- **PipeWire** daemon running — for audio capture/playback
- **Node.js** on PATH — the networking layer spawns a Node.js subprocess
- The `pear/` directory must be alongside the binary (copied automatically by the build)

### If running under Wayland:
You can force X11 with: `QT_QPA_PLATFORM=xcb ./peariscope-app`
Screen capture and input injection require an X11 session though, so for full functionality log in with an X11/Xorg session.

## Project Structure

```
peariscope-linux/
├── CMakeLists.txt          # Build configuration
├── BUILD.md                # This file
├── protocol/
│   └── messages.proto      # Protobuf message definitions (shared with other platforms)
├── pear/                   # Node.js networking runtime (Hyperswarm DHT)
│   ├── package.json
│   ├── lib/
│   └── node_modules/
├── assets/
│   └── app-logo@3x.png
└── src/
    ├── main.cpp
    ├── app/                # AppController, QrCode, CrashLog, RecentConnectionsModel
    ├── capture/            # Screen capture (X11/XShm)
    ├── video/              # H.264 encode/decode (FFmpeg), OpenGL renderer
    ├── audio/              # Audio capture/playback (PipeWire), AAC encode/decode (FFmpeg)
    ├── input/              # Keyboard/mouse capture and injection (X11/XTest)
    ├── auth/               # Key management (OpenSSL AES-256-GCM)
    ├── networking/         # IPC bridge to Node.js subprocess
    └── qml/                # Qt Quick UI (shared with Windows/Mac)
        ├── Main.qml
        ├── HostPage.qml
        ├── ConnectPage.qml
        ├── SettingsPage.qml
        └── components/
```
