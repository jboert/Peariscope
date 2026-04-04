#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then echo "Usage: release-mac.sh <version>"; exit 1; fi

# Build release
xcodebuild build -project apple/Peariscope.xcodeproj \
    -scheme PeariscopeMac -destination 'platform=macOS' \
    -configuration Release \
    MARKETING_VERSION=$VERSION \
    CURRENT_PROJECT_VERSION=$(date +%Y%m%d%H%M)

# Create DMG — find the app in DerivedData
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Release/Peariscope.app" -maxdepth 5 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find Peariscope.app in DerivedData"
    exit 1
fi
DMG_PATH="releases/Peariscope-${VERSION}.dmg"
mkdir -p releases

hdiutil create -volname "Peariscope" -srcfolder "$APP_PATH" \
    -ov -format UDZO "$DMG_PATH"

# Sign DMG for Sparkle (if sign_update is available)
if command -v sparkle/bin/sign_update &>/dev/null; then
    sparkle/bin/sign_update "$DMG_PATH"
fi

# Notarize (requires Apple credentials)
if xcrun notarytool --help &>/dev/null; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "peariscope" --wait || true
    xcrun stapler staple "$DMG_PATH" || true
fi

echo "Release DMG: $DMG_PATH"
echo "Update appcast.xml with the new entry"
