#!/bin/bash
NEW_VERSION=$1
if [ -z "$NEW_VERSION" ]; then echo "Usage: bump-version.sh <version>"; exit 1; fi

echo "$NEW_VERSION" > VERSION

# Update pear/package.json
cd pear && npm version $NEW_VERSION --no-git-tag-version && cd ..

# Update iOS/macOS Info.plists
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" apple/Resources/IOS-Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" apple/Resources/MacOS-Info.plist

echo "Version bumped to $NEW_VERSION"
echo "Remember to update WORKLET_VERSION in pear/worklet.js if the worklet changed"
