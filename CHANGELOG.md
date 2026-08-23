# Changelog

All notable changes to M4 Companion are documented here.

## Unreleased

## [0.2.0] - 2026-08-22

### Added

- Sparkle 2 integration with daily signed-update checks and a manual **Check for Updates…** command.
- Reproducible EdDSA-signed appcast generation for GitHub Releases and GitHub Pages.
- A native menu bar control panel that keeps M4 Companion available without a Dock icon.

### Changed

- Replaced the orange product accent and icon artwork with the sampled cyan-blue `#0A96D4` theme.
- Replaced the Dock-backed window with a compact 390-point native menu bar panel.
- Menus now open immediately from cached state while connections refresh safely in the background.
- Corrected cold-launch placement, Show Desktop dismissal, first-click reopening, and transient Bluetooth read failures.

## [0.1.0] - 2026-08-21

### Added

- Native macOS control surface for Sennheiser MOMENTUM 4.
- Stable multipoint device list with the controlling Mac pinned first.
- One-click peer connect and disconnect with bounded retries and rollback.
- Battery level and connected-device status.
- Adaptive, Custom, and Off noise-control modes.
- ANC-to-transparency level and Anti-Wind controls.
- Dynamic five-band EQ, seven presets, Flat reset, and Bass Boost.
- Medium and large interactive desktop widgets.
- Phone-side setting synchronization while the main window is open.
- Login-item host for background widget actions.
- Universal Intel and Apple silicon Technical Preview DMG.

### Distribution note

The v0.1.0 binary is ad-hoc signed and not notarized. Follow the app-scoped Gatekeeper instructions in the README. A clean local reinstall from the release-style DMG was tested with the host app and WidgetKit widget both functioning after quarantine removal.

[0.2.0]: https://github.com/Zhengyang-Liu/m4-companion/releases/tag/v0.2.0
[0.1.0]: https://github.com/Zhengyang-Liu/m4-companion/releases/tag/v0.1.0
