# Security Policy

## Supported versions

M4 Companion is currently a Technical Preview. Security fixes are provided for the latest published release only.

| Version | Supported |
| --- | --- |
| Latest v0.2.x release | ✅ |
| Older builds | ❌ |

## Reporting a vulnerability

Please do **not** open a public issue for a suspected vulnerability or include secrets, capability tokens, Bluetooth identifiers, paired-device names, or other private data in a public report.

Use GitHub's private vulnerability reporting flow:

[Report a vulnerability privately](https://github.com/Zhengyang-Liu/m4-companion/security/advisories/new)

Include, where possible:

- the affected M4 Companion version and macOS version;
- the headset firmware version;
- a clear description of the impact and prerequisites;
- minimal reproduction steps or a proof of concept;
- whether the issue requires physical proximity, an already paired device, or local user access;
- logs with personal paths, device names, Bluetooth addresses, tokens, and signing identifiers removed.

You should receive an acknowledgement through the GitHub advisory within 7 days. Time to remediation depends on severity and reproducibility. Please allow a reasonable coordinated-disclosure period before publishing details.

## Scope

Security-relevant areas include Bluetooth message parsing, connection/control authorization, the widget-to-host action channel, local snapshot permissions, app sandbox exceptions, and release integrity.

General bugs and compatibility problems that do not expose sensitive information can be reported through [GitHub Issues](https://github.com/Zhengyang-Liu/m4-companion/issues).

## Technical Preview notice

Published v0.2.2 binaries are ad-hoc signed and unnotarized. This is a distribution limitation, not a request to disable system-wide protections. Follow only the app-scoped Gatekeeper instructions in the README and obtain releases from this repository's official release page.
