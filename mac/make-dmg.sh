#!/bin/zsh
# Builds a universal (Apple silicon + Intel) Release copy of Binge Library, signs it ad hoc
# (no Apple developer certificate), and packages it as dist/Binge-Library.dmg.
#
# Keep that exact file name when uploading to a GitHub release: the website downloads
# releases/latest/download/Binge-Library.dmg, which always serves the newest release's copy.
#
# The app isn't notarized, so on first open people use System Settings ▸ Privacy & Security ▸
# Open Anyway. Ad-hoc signing keeps your developer certificate (and the email in its name) out
# of the downloaded app.
set -euo pipefail
cd "${0:A:h}"

if ! xcode-select -p | grep -q "Xcode.app"; then
  echo "Xcode isn't selected. Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

xcodegen generate >/dev/null
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" BingeLibrary/Info.plist)
DD=build.noindex/dmg
rm -rf "$DD/Build/Products/Release/Binge Library.app"

xcodebuild -project BingeLibrary.xcodeproj -scheme BingeLibrary -configuration Release \
  -derivedDataPath "$DD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  build -quiet

APP="$DD/Build/Products/Release/Binge Library.app"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p ../dist
OUT="../dist/Binge-Library.dmg"
rm -f "$OUT"
hdiutil create -volname "Binge Library" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
rm -rf "$STAGE"

echo "Created ${OUT:A} (version $VERSION)"
shasum -a 256 "$OUT"
