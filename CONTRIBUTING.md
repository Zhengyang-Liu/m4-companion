# Contributing to M4 Companion

Thanks for helping improve M4 Companion. Contributions can include bug fixes, tests, documentation, accessibility improvements, and carefully validated protocol support.

## Before you start

- Search [existing issues](https://github.com/Zhengyang-Liu/m4-companion/issues) before opening a new one.
- For a substantial change, open an issue first so the approach and hardware impact can be discussed.
- Report security problems privately as described in [SECURITY.md](SECURITY.md).
- Remember that v0.1.0 supports MOMENTUM 4 only; do not claim compatibility with another model without repeatable hardware validation.

## Development setup

You need macOS 14 or later, Xcode 16.3 or later (Swift 6.1 toolchain), and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/Zhengyang-Liu/m4-companion
cd m4-companion
xcodegen generate
open MomentumDeviceSwitcher.xcodeproj
```

Select your own Apple Developer team for both the **MomentumDeviceSwitcher** app and **MomentumDeviceWidget** extension targets. Use bundle identifiers unique to your developer account if Xcode reports a conflict. Never commit a Team ID, provisioning profile, certificate, or machine-specific signing setting.

The `.xcodeproj` is generated from `project.yml`; make lasting project changes in that specification and regenerate the project.

## Project layout

- `Sources/MomentumCore`: protocol data structures, codecs, planning, and pure policies.
- `Sources/MomentumBluetooth`: RFCOMM transport, discovery, headset operations, and local widget state.
- `NativeApp`: macOS host application and full SwiftUI interface.
- `WidgetExtension`: medium and large WidgetKit extension.
- `project.yml`: XcodeGen project definition.

Keep protocol parsing and decision logic in testable, side-effect-free code where practical. Keep Bluetooth I/O in `MomentumBluetooth` and UI concerns in the app or widget targets.

## Testing

Run the local checks before submitting a pull request:

```bash
swift run CoreTests
xcodegen generate
xcodebuild \
  -project MomentumDeviceSwitcher.xcodeproj \
  -scheme MomentumDeviceSwitcher \
  -configuration Debug \
  build
```

The build command may require your local signing configuration. Do not work around that by committing credentials or provisioning artifacts.

Hardware testing must be deliberate:

- Use a headset you own or are authorized to test.
- Record the macOS version, headset model, and firmware version.
- Verify both successful behavior and failure/rollback behavior.
- Avoid destructive or unknown protocol commands.
- `MomentumProbe` communicates with real hardware; run it only when that is your intent.

## Pull requests

A focused pull request should:

1. Explain the problem and the chosen solution.
2. Include or update tests for parsing, planning, state transitions, and failure paths.
3. Describe real-hardware testing, or state clearly that it was not performed.
4. Update user-facing documentation when behavior, requirements, permissions, or limitations change.
5. Contain no build products, personal machine paths, Bluetooth addresses, device names, Team IDs, emails, tokens, certificates, or provisioning profiles.
6. Keep unrelated formatting or generated-file churn out of the diff.

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE).

## Protocol research

The headset control protocol is private and undocumented. Contributions based on independent observation and interoperability research are welcome, but they must be conservative and reviewable:

- Document packet direction, expected response, validation, timeout, and rollback behavior.
- Separate confirmed behavior from hypotheses.
- Add fixtures or synthetic tests that contain no identifiers from real devices.
- Do not submit confidential material, leaked keys, proprietary application code, or content you are not permitted to redistribute.
- Do not name a third-party dependency or source unless its use and license have been verified.

## Privacy in issues and logs

Paired-device names, Bluetooth addresses, local paths, widget action tokens, and signing details can identify a person or machine. Redact them before posting. Prefer small, purpose-built diagnostic excerpts over complete system logs.

## Style

- Follow the existing Swift style and Swift concurrency model.
- Prefer explicit validation and bounded retries for device I/O.
- Preserve the controlling Mac connection during peer switching.
- Surface uncertain state instead of presenting an optimistic value as confirmed.
- Add concise comments for protocol constraints and non-obvious safety behavior.

## License and trademarks

M4 Companion is unofficial and unaffiliated with Sennheiser or Sonova. Use product names only as needed to describe compatibility, and do not add official-looking branding or imply endorsement.
