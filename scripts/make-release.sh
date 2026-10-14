#!/usr/bin/env bash
# Builds a disk image to share: build/Leeway-<version>.dmg with the app, an Applications shortcut and
# first-launch instructions, plus build/Leeway-<version>.dmg.sha256.
#
# Notarized release (recommended), with an Apple Developer account:
#   LEEWAY_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   LEEWAY_NOTARY_PROFILE=leeway   # once: xcrun notarytool store-credentials leeway --apple-id … --team-id …
# or, with an App Store Connect API key instead of a stored profile (used by the release workflow):
#   LEEWAY_NOTARY_KEY=/path/to/AuthKey.p8 LEEWAY_NOTARY_KEY_ID=… LEEWAY_NOTARY_ISSUER=…
# The script then notarizes and staples the app and the disk image, and macOS opens them without a warning.
#
# Without these variables the app has an ad hoc signature and receivers must allow it in System Settings.
#
# Sparkle updates (optional): LEEWAY_APPCAST_DIR=/path/to/site copies the disk image there and runs
# Sparkle's generate_appcast, which signs it with the EdDSA key in your Keychain (see the README).
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build-app.sh --universal

identity="${LEEWAY_SIGN_IDENTITY:-}"
notary=()
if [[ -n "${LEEWAY_NOTARY_PROFILE:-}" ]]; then
  notary=(--keychain-profile "$LEEWAY_NOTARY_PROFILE")
elif [[ -n "${LEEWAY_NOTARY_KEY:-}" ]]; then
  notary=(--key "$LEEWAY_NOTARY_KEY" --key-id "${LEEWAY_NOTARY_KEY_ID:?}" --issuer "${LEEWAY_NOTARY_ISSUER:?}")
fi
notarize=false
if [[ -n "$identity" && ${#notary[@]} -gt 0 ]]; then notarize=true; fi

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
dmg="build/Leeway-$version.dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

if $notarize; then
  echo "Notarizing the app…"
  ditto -c -k --keepParent "build/Leeway.app" "$stage/Leeway.zip"
  xcrun notarytool submit "$stage/Leeway.zip" "${notary[@]}" --wait
  xcrun stapler staple "build/Leeway.app"
  rm "$stage/Leeway.zip"
fi

cp -R "build/Leeway.app" "$stage/"
ln -s /Applications "$stage/Applications"

if $notarize; then
  first_launch='FIRST LAUNCH
Apple has notarized this app, so it opens without a warning.'
else
  first_launch='FIRST LAUNCH
Apple has not notarized this app, so macOS blocks it the first time:
1. When macOS says it cannot verify the app, click Done.
2. Open System Settings > Privacy & Security.
3. Scroll down to "Leeway was blocked" and click Open Anyway.
4. Enter your password, then click Open Anyway again.
You do this once for each new version.

Before you do this, make sure that the disk image is the one that was published.
In Terminal, run:  shasum -a 256 ~/Downloads/Leeway-*.dmg
and compare the result with the checksum from the person who sent it.
Do not open a copy whose checksum is different.'
fi

cat > "$stage/Read Me First.txt" <<TEXT
Leeway shows your Claude Code and Codex plan limits in the menu bar.
Needs macOS 15 (Sequoia) or later.

INSTALL
1. Drag "Leeway" onto the Applications folder.
2. Open it from Applications.

$first_launch

USING IT
The app finds ~/.claude, ~/.codex and folders such as ~/.claude-work by itself.
Sign in with Claude Code (claude, then /login) or Codex (codex login) first.
Click the gear in the popover for Settings: rename, hide or add accounts,
choose what the menu bar shows, and turn on Launch at login.

The app reads your existing logins on this Mac and sends them only to
Anthropic and OpenAI to read your usage. It does not refresh or change them.
TEXT

rm -f "$dmg"
hdiutil create -quiet -volname "Leeway" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"

if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" --timestamp "$dmg"
fi
if $notarize; then
  echo "Notarizing the disk image…"
  xcrun notarytool submit "$dmg" "${notary[@]}" --wait
  xcrun stapler staple "$dmg"
fi

(cd build && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "Built $dmg"
echo "SHA-256: $(cut -d' ' -f1 "$dmg.sha256")"
if ! $notarize; then
  echo "Not notarized. Publish the SHA-256 above where receivers can check it."
fi

if [[ -n "${LEEWAY_APPCAST_DIR:-}" ]]; then
  mkdir -p "$LEEWAY_APPCAST_DIR"
  cp "$dmg" "$LEEWAY_APPCAST_DIR/"
  .build/artifacts/sparkle/Sparkle/bin/generate_appcast "$LEEWAY_APPCAST_DIR"
  echo "Updated the appcast in $LEEWAY_APPCAST_DIR"
fi
