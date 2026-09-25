# Forum post draft

## M4 Companion — an unofficial MOMENTUM 4 controller for macOS

I wanted the controls I use most on my phone to be available directly on my Mac, so I built **M4 Companion**.

It is a native, open-source macOS app for Sennheiser MOMENTUM 4 with:

- multipoint device switching;
- battery and connection status;
- Adaptive / Custom / Off noise control;
- transparency and Anti-Wind controls;
- five-band EQ, presets, and Bass Boost;
- medium and large interactive desktop widgets;
- local phone-side state synchronization while the app is open.

Everything runs locally over Bluetooth. There is no account, cloud backend, telemetry, or analytics.

**Current status:** v0.2.3 Technical Preview for macOS 14+. The DMG is ad-hoc signed and not notarized, so macOS may require **Open Anyway** or the scoped quarantine command documented in the README. I clean-tested the release-style DMG locally; the menu bar app and WidgetKit widget both loaded and worked after the bypass.

Download: https://github.com/Zhengyang-Liu/m4-companion/releases/tag/v0.2.3

Source: https://github.com/Zhengyang-Liu/m4-companion

Website: https://zhengyang-liu.github.io/m4-companion/

This is an independent, unofficial project and is not affiliated with or endorsed by Sennheiser or Sonova.
