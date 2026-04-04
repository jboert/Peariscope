#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then echo "Usage: release-android.sh <version>"; exit 1; fi

# Extract version code from version string (e.g., 1.1.0 → 10100)
IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
VERSION_CODE=$((MAJOR * 10000 + MINOR * 100 + ${PATCH:-0}))

cd android

# Build release APK
./gradlew assembleRelease \
    -PversionCode=$VERSION_CODE \
    -PversionName=$VERSION

mkdir -p ../releases
cp app/build/outputs/apk/release/app-release.apk \
    "../releases/Peariscope-${VERSION}.apk"

echo "Release APK: releases/Peariscope-${VERSION}.apk"
