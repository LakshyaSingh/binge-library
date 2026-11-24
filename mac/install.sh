#!/bin/zsh
# Build a release copy of Binge Library and install it into /Applications.
# Build output goes to build.noindex so Spotlight never shows duplicate copies.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate >/dev/null
APP="build.noindex/Build/Products/Release/Binge Library.app"
# Remove the previous build first, so a failed build can never reinstall an old copy.
rm -rf "$APP"
xcode-select -p | grep -q "Xcode" || { echo "Xcode isn't installed or selected (xcode-select points to $(xcode-select -p)). Install Xcode, then run this again."; exit 1; }
xcodebuild -project BingeLibrary.xcodeproj -scheme BingeLibrary -configuration Release \
  -derivedDataPath build.noindex build | grep -E "error:|BUILD" || true
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
osascript -e 'quit app "Binge Library"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/Binge Library.app"
ditto "$APP" "/Applications/Binge Library.app"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Unregister every build copy (Release and Debug) so the launcher only knows the one in /Applications.
for built in build.noindex/Build/Products/*/"Binge Library.app"; do
  $LSR -u "$built" 2>/dev/null || true
done
$LSR -f "/Applications/Binge Library.app"
open "/Applications/Binge Library.app"
echo "Installed /Applications/Binge Library.app"
