# Releasing

## Publish a release

1. Set `CFBundleShortVersionString` in `Resources/Info.plist` to the new version, for example `0.5.0`, and merge it to `main`.
2. Tag the commit and push the tag:

   ```bash
   git tag v0.5.0 && git push origin v0.5.0
   ```

The [Release workflow](../.github/workflows/release.yml) then:

1. checks that the tag matches `CFBundleShortVersionString`
2. runs the tests
3. builds a universal app (Apple silicon and Intel) and `Leeway-<version>.dmg` with `scripts/make-release.sh`
4. signs and notarizes them when the signing secrets are set (see below)
5. publishes a GitHub Release with the disk image, its `.sha256` file and generated release notes

A tag with a hyphen, such as `v0.5.0-beta.1`, becomes a pre-release.

To build a disk image without a release, run the workflow by hand: Actions → Release → Run workflow. The disk image is attached to the run as an artifact for 14 days.

## Build on your Mac

```bash
./scripts/make-release.sh
```

The script writes `build/Leeway-<version>.dmg` and `build/Leeway-<version>.dmg.sha256`. The disk image contains the app, an Applications shortcut and "Read Me First.txt".

## Signing and notarization

Without a Developer ID, the app has an ad hoc signature. On the first launch, receivers must open System Settings → Privacy & Security and click **Open Anyway**, once for each version.

With an [Apple Developer Program](https://developer.apple.com/programs/) membership, macOS opens the app without a warning.

### What you need

| Item | Where to get it |
|---|---|
| Developer ID Application certificate, exported as `.p12` with a password | Only the Account Holder can create it: Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application. Then export the certificate and its private key from Keychain Access. |
| App Store Connect API key (`.p8`), its Key ID and the Issuer ID | App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → +, with the Developer role. The `.p8` file can be downloaded only once. |

### In GitHub Actions

Add these secrets to the `release` environment (Settings → Environments → release). Only tags `v*` and `main` can use that environment.

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | `base64 -i DeveloperID.p12 \| pbcopy`, then paste |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the `.p12` password |
| `NOTARY_API_KEY` | the contents of `AuthKey_XXXXXXXXXX.p8` |
| `NOTARY_API_KEY_ID` | the Key ID |
| `NOTARY_API_ISSUER_ID` | the Issuer ID |

Or with the GitHub CLI:

```bash
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_P12 --env release
```

```bash
gh secret set NOTARY_API_KEY --env release < AuthKey_XXXXXXXXXX.p8
```

With the certificate only, the workflow signs but does not notarize. With both, it signs with the Hardened Runtime, notarizes and staples the app and the disk image, and checks the result with `spctl`.

### On your Mac

```bash
xcrun notarytool store-credentials leeway --apple-id you@example.com --team-id TEAMID
```

```bash
LEEWAY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" LEEWAY_NOTARY_PROFILE=leeway ./scripts/make-release.sh
```

`LEEWAY_NOTARY_KEY`, `LEEWAY_NOTARY_KEY_ID` and `LEEWAY_NOTARY_ISSUER` (an API key) work in place of `LEEWAY_NOTARY_PROFILE`.

## Updates with Sparkle

"Check for Updates" in the gear menu uses [Sparkle](https://sparkle-project.org) when Info.plist has `SUFeedURL` and `SUPublicEDKey`. Until then, it opens the GitHub Releases page (`LeewayReleasesURL`).

1. Run `.build/artifacts/sparkle/Sparkle/bin/generate_keys` once. It keeps the private key in your Keychain and prints the public key.
2. Set `SUPublicEDKey` to the public key and `SUFeedURL` to the URL of your `appcast.xml`.
3. Release with `LEEWAY_APPCAST_DIR=/path/to/site ./scripts/make-release.sh`, then upload that folder.

Sparkle installs an update only when its EdDSA signature matches the public key. The release workflow does not make the appcast yet.
