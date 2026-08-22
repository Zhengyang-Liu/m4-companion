# Releasing M4 Companion

M4 Companion uses Sparkle 2 with an EdDSA update-signing key stored in the
maintainer's macOS Login Keychain under this account:

```text
com.zhengyangliu.MomentumDeviceSwitcher
```

The private key must never be committed, pasted into logs, or uploaded as a
GitHub artifact. Only `SUPublicEDKey` belongs in `NativeApp/Info.plist`.

## Build a release candidate

Use a new semantic version and a monotonically increasing integer build number:

```bash
VERSION=0.1.1 BUILD_NUMBER=2 ./scripts/build-adhoc-dmg.sh
```

Before publishing, verify:

```bash
swift run CoreTests
python3 scripts/test-sparkle-config.py
codesign --verify --deep --strict "dist/dmg-root/M4 Companion.app"
```

## Publish the GitHub Release first

Create tag `v<VERSION>` and upload the exact DMG produced by the build script.
Do not replace an existing release asset after its Sparkle signature has been
published.

## Generate and publish the appcast

After the GitHub Release asset is live, generate the signed feed entry:

```bash
VERSION=0.1.1 ./scripts/generate-appcast.sh
xmllint --noout docs/appcast.xml
```

Review that the enclosure URL matches the uploaded GitHub Release asset, then
commit and push `docs/appcast.xml`. GitHub Pages serves it at:

```text
https://zhengyang-liu.github.io/m4-companion/appcast.xml
```

Publishing order matters: uploading the release first prevents clients from
seeing an appcast item whose DMG is not available yet.

## Key recovery

Sparkle's `generate_keys` tool can export the private key for secure offline
backup. Treat the exported file like a password and never keep it in this
repository, even if ignored. Import that backup into the Keychain on a new
maintainer machine before generating an appcast.

Sparkle EdDSA signing authenticates update archives. It does not replace Apple
Developer ID signing or notarization.