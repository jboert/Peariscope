#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Installing dependencies ==="
sudo zypper install -y \
  cmake gcc-c++ \
  qt6-declarative-devel qt6-base-devel qt6-quickcontrols2-devel \
  pipewire-devel \
  libX11-devel libXtst-devel libXext-devel \
  libopenssl-devel \
  protobuf-devel \
  nodejs-default

# Try ffmpeg-7 packages first, fall back to ffmpeg-devel
if ! sudo zypper install -y ffmpeg-7-libavcodec-devel ffmpeg-7-libavutil-devel ffmpeg-7-libswscale-devel 2>/dev/null; then
  echo "ffmpeg-7 packages not found, trying ffmpeg-devel..."
  sudo zypper install -y ffmpeg-devel
fi

# Fix Windows-style backslash paths if present (from zip extraction)
if find "$SCRIPT_DIR" -maxdepth 1 -name '*\\*' -type f 2>/dev/null | grep -q .; then
  echo ""
  echo "=== Fixing backslash paths from Windows archive ==="
  # Move files with backslash names to proper directory structure
  find "$SCRIPT_DIR" -name '*\\*' -type f | sort -r | while IFS= read -r f; do
    newpath="$(echo "$f" | tr '\\' '/')"
    mkdir -p "$(dirname "$newpath")"
    mv "$f" "$newpath" 2>/dev/null || true
  done
  # Clean up empty backslash-named artifacts
  find "$SCRIPT_DIR" -name '*\\*' -type f -empty -delete 2>/dev/null || true
fi

echo ""
echo "=== Building ==="
cd "$SCRIPT_DIR"
mkdir -p build && cd build
cmake .. -Wno-dev
make -j$(nproc)

echo ""
echo "=== Done! Run with: cd build && ./peariscope-app ==="
