#!/bin/bash
set -euo pipefail

PROJECT_DIR="/home/jb/peariscope-linux"
BUILD_DIR="$PROJECT_DIR/build"
APPDIR="$BUILD_DIR/AppDir"
OUTPUT_DIR="/home/jb"
PEAR_RUNTIME_DIR="$HOME/.config/pear/current/by-arch/linux-x64"

echo "=== Building Peariscope AppImage ==="

# Clean previous AppDir
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib"
mkdir -p "$APPDIR/usr/share/applications"
mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"

# 1. Copy the main binary
echo "Copying binary..."
cp "$BUILD_DIR/peariscope-app" "$APPDIR/usr/bin/"

# 2. Copy pear worklet directory (must be alongside binary for path resolution)
echo "Copying pear worklet..."
cp -a "$BUILD_DIR/pear" "$APPDIR/usr/bin/pear"
# Remove the nested staging duplicate to save space
rm -rf "$APPDIR/usr/bin/pear/pear" 2>/dev/null || true
# Remove non-linux prebuilds to save space
find "$APPDIR/usr/bin/pear/node_modules" -path "*/prebuilds/darwin-*" -exec rm -rf {} + 2>/dev/null || true
find "$APPDIR/usr/bin/pear/node_modules" -path "*/prebuilds/win32-*" -exec rm -rf {} + 2>/dev/null || true
find "$APPDIR/usr/bin/pear/node_modules" -path "*/prebuilds/android-*" -exec rm -rf {} + 2>/dev/null || true

# 3. Bundle the pear runtime alongside the binary
echo "Bundling pear runtime..."
cp "$PEAR_RUNTIME_DIR/bin/pear-runtime" "$APPDIR/usr/bin/"
cp "$PEAR_RUNTIME_DIR/lib/launch.so" "$APPDIR/usr/lib/"
# The app resolves pear via ~/.config/pear/bin/pear -> pear-runtime.
# In the AppImage, pear-runtime is on PATH in usr/bin/, and the app's
# ResolvePearPath() falls back to searching PATH for "pear".
# Create a symlink so "pear" on PATH resolves to pear-runtime.
ln -sf pear-runtime "$APPDIR/usr/bin/pear-cli"

# 5. Copy .desktop file and icon
cp "$PROJECT_DIR/peariscope.desktop" "$APPDIR/usr/share/applications/"
cp "$PROJECT_DIR/assets/app-logo@3x.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/peariscope.png"

# 6. Run linuxdeploy with Qt plugin
echo "Running linuxdeploy..."
export QMAKE=/usr/bin/qmake6
export QML_SOURCES_PATHS="$PROJECT_DIR/src/qml"
export EXTRA_QT_PLUGINS="xcbglintegrations"
export LD_LIBRARY_PATH="/usr/lib64:${LD_LIBRARY_PATH:-}"
export OUTPUT="$OUTPUT_DIR/Peariscope-x86_64.AppImage"

cd "$BUILD_DIR"
/home/jb/linuxdeploy-x86_64.AppImage \
    --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/peariscope-app" \
    --desktop-file "$APPDIR/usr/share/applications/peariscope.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/256x256/apps/peariscope.png" \
    --plugin qt \
    --output appimage

echo ""
echo "=== Done! ==="
ls -lh "$OUTPUT"
