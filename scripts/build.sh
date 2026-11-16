#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build dist
xcodebuild -project Furnace.xcodeproj -scheme Furnace -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >build/device-build.log 2>&1 || {
  tail -n 120 build/device-build.log
  exit 1
}
mkdir -p build/package/Payload
ditto build/device/Build/Products/Release-iphoneos/Furnace.app build/package/Payload/Furnace.app
ditto -c -k --keepParent build/package/Payload dist/Furnace-unsigned.ipa
uv run --locked python scripts/verify_ipa.py dist/Furnace-unsigned.ipa
ditto -c -k --keepParent build/device/Build/Products/Release-iphoneos/Furnace.app.dSYM dist/Furnace.dSYM.zip
{
  xcodebuild -version
  xcrun --sdk iphoneos --show-sdk-version
  sw_vers
  git rev-parse HEAD
  plist=build/device/Build/Products/Release-iphoneos/Furnace.app/Info.plist
  printf 'version=%s\nbuild=%s\n' \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
} >dist/build-info.txt
