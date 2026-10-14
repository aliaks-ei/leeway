#!/usr/bin/env bash
# Builds "Leeway.app" into ./build.
#   --install    also copies it to ~/Applications
#   --universal  builds for Apple silicon and Intel (used by make-release.sh)
#
# Signing:
#   LEEWAY_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#     signs with that certificate, with the Hardened Runtime and a secure timestamp, as notarization requires.
#   Without it, the app gets an ad hoc signature, which is enough on the Mac that built it.
set -euo pipefail

cd "$(dirname "$0")/.."

install=false
universal=false
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    --universal) universal=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if $universal; then
  swift build -c release --arch arm64 --arch x86_64
  products=.build/apple/Products/Release
else
  swift build -c release
  products=.build/release
fi

app="build/Leeway.app"
contents="$app/Contents"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Frameworks"
cp "$products/Leeway" "$contents/MacOS/Leeway"
cp Resources/Info.plist "$contents/Info.plist"
cp Resources/AppIcon.icns "$contents/Resources/AppIcon.icns"
cp -R "$products/Sparkle.framework" "$contents/Frameworks/"
# SwiftPM links Sparkle next to the binary; in the app it is in Contents/Frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$contents/MacOS/Leeway"

# A unique build number for each commit, so macOS and Sparkle can tell builds apart.
if build_number=$(git rev-list --count HEAD 2>/dev/null); then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents/Info.plist"
fi

identity="${LEEWAY_SIGN_IDENTITY:-}"
if [[ -n "$identity" ]]; then
  sign=(codesign --force --sign "$identity" --options runtime --timestamp)
else
  sign=(codesign --force --sign -)
fi
# Sign from the inside out: Sparkle's helpers, the framework, then the app.
sparkle="$contents/Frameworks/Sparkle.framework/Versions/B"
"${sign[@]}" "$sparkle/XPCServices/Installer.xpc"
"${sign[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
"${sign[@]}" "$sparkle/Autoupdate"
"${sign[@]}" "$sparkle/Updater.app"
"${sign[@]}" "$contents/Frameworks/Sparkle.framework"
"${sign[@]}" "$app"
codesign --verify --strict --deep "$app"
echo "Built $app (${identity:-ad hoc signature})"

if $install; then
  mkdir -p "$HOME/Applications"
  pkill -x Leeway 2>/dev/null || true
  rm -rf "$HOME/Applications/Leeway.app"
  # Builds before the rename were called "AI Usage Bar".
  pkill -x AIUsageBar 2>/dev/null || true
  rm -rf "$HOME/Applications/AI Usage Bar.app"
  cp -R "$app" "$HOME/Applications/"
  echo "Installed to ~/Applications/Leeway.app"
fi
