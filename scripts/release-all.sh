#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then echo "Usage: release-all.sh <version>"; exit 1; fi

echo "=== Peariscope v${VERSION} Release ==="
mkdir -p releases

# 1. Rebuild worklet bundles (included in native apps as fallback)
echo "--- Building worklet bundles ---"
cd pear
npx bare-pack --preset darwin --linked --base . --out ./worklet.bundle ./worklet.js
npx bare-pack --preset ios --linked --base . --out ./worklet-ios.bundle ./worklet.js
npx bare-pack --preset android --linked --base . --out ./worklet-android.bundle ./worklet.js
cp worklet-android.bundle ../android/app/src/main/assets/worklet.bundle
cd ..

# 2. Build native apps
echo "--- Building macOS ---"
./scripts/release-mac.sh $VERSION

echo "--- Building iOS ---"
./scripts/release-ios.sh $VERSION

echo "--- Building Android ---"
./scripts/release-android.sh $VERSION

# 3. Create GitHub Release on jboert/Peariscope
echo "--- Creating GitHub Release ---"
gh release create "v${VERSION}" \
    --repo jboert/Peariscope \
    --title "Peariscope v${VERSION}" \
    --body "$(cat <<EOF
## Peariscope v${VERSION}

### Downloads
- **macOS**: Peariscope-${VERSION}.dmg (auto-updates via Sparkle)
- **iOS**: Peariscope-${VERSION}.ipa (ad-hoc) or TestFlight
- **Android**: Peariscope-${VERSION}.apk

### Worklet OTA
All native apps will automatically receive worklet updates via P2P Hyperdrive.
No app reinstall needed for networking changes.
EOF
)" \
    "releases/Peariscope-${VERSION}.dmg" \
    "releases/Peariscope-${VERSION}.ipa" \
    "releases/Peariscope-${VERSION}.apk"

echo "=== Release v${VERSION} complete ==="
