#!/usr/bin/env python3
from pathlib import Path
import plistlib
import sys

root = Path(__file__).resolve().parent.parent
project = (root / "project.yml").read_text()
host = (root / "NativeApp" / "MomentumSwitcherHost.swift").read_text()
plist = plistlib.loads((root / "NativeApp" / "Info.plist").read_bytes())
gitignore = (root / ".gitignore").read_text()
build_script = (root / "scripts" / "build-adhoc-dmg.sh").read_text()
appcast_script = (root / "scripts" / "generate-appcast.sh").read_text()
host_entitlements = plistlib.loads(
    (root / "NativeApp" / "MomentumDeviceSwitcher.entitlements").read_bytes()
)
adhoc_host_entitlements = plistlib.loads(
    (root / "Distribution" / "Host-AdHoc.entitlements").read_bytes()
)

checks = {
    "Sparkle 2.9.6 package is pinned": "exactVersion: 2.9.6" in project,
    "host links the Sparkle product": "package: Sparkle" in project,
    "host creates the standard updater": "SPUStandardUpdaterController" in host,
    "host exposes Check for Updates": "Check for Updates" in host,
    "feed uses the GitHub Pages appcast": plist.get("SUFeedURL")
        == "https://zhengyang-liu.github.io/m4-companion/appcast.xml",
    "public EdDSA key is configured": bool(plist.get("SUPublicEDKey")),
    "automatic checks are enabled": plist.get("SUEnableAutomaticChecks") is True,
    "sandboxed installer launcher is enabled":
        plist.get("SUEnableInstallerLauncherService") is True,
    "private Sparkle key exports are ignored": ".sparkle-private-key" in gitignore,
    "release build receives the marketing version": 'MARKETING_VERSION="$VERSION"' in build_script,
    "release build receives a monotonic build number": 'CURRENT_PROJECT_VERSION="$BUILD_NUMBER"' in build_script,
    "appcast uses the dedicated Keychain account":
        "com.zhengyangliu.MomentumDeviceSwitcher" in appcast_script,
    "appcast supports an isolated test download URL": "DOWNLOAD_URL_PREFIX" in appcast_script,
    "development sandbox permits update downloads":
        host_entitlements.get("com.apple.security.network.client") is True,
    "Ad-hoc sandbox permits update downloads":
        adhoc_host_entitlements.get("com.apple.security.network.client") is True,
    "development sandbox can reach the installer launcher":
        {"$(PRODUCT_BUNDLE_IDENTIFIER)-spks", "$(PRODUCT_BUNDLE_IDENTIFIER)-spki"}.issubset(
            set(host_entitlements.get(
                "com.apple.security.temporary-exception.mach-lookup.global-name", []
            ))
        ),
    "Ad-hoc sandbox can reach the installer launcher":
        {
            "com.zhengyangliu.MomentumDeviceSwitcher-spks",
            "com.zhengyangliu.MomentumDeviceSwitcher-spki",
        }.issubset(set(adhoc_host_entitlements.get(
            "com.apple.security.temporary-exception.mach-lookup.global-name", []
        ))),
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(("PASS" if passed else "FAIL") + ": " + name)
if failed:
    sys.exit(1)
