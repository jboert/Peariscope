#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then echo "Usage: release-ios.sh <version>"; exit 1; fi

# Archive
xcodebuild archive -project apple/Peariscope.xcodeproj \
    -scheme PeariscopeIOS \
    -destination 'generic/platform=iOS' \
    -configuration Release \
    -allowProvisioningUpdates \
    -archivePath /tmp/Peariscope.xcarchive \
    MARKETING_VERSION=$VERSION \
    CURRENT_PROJECT_VERSION=$(date +%Y%m%d%H%M)

# Export IPA (release-testing / ad-hoc)
cat > /tmp/ExportOptions.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>release-testing</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>L35T4H6XMC</string>
</dict>
</plist>
PLIST

mkdir -p releases

xcodebuild -exportArchive \
    -archivePath /tmp/Peariscope.xcarchive \
    -exportPath "releases/" \
    -exportOptionsPlist /tmp/ExportOptions.plist

mv releases/Peariscope.ipa "releases/Peariscope-${VERSION}.ipa"
echo "Release IPA: releases/Peariscope-${VERSION}.ipa"
