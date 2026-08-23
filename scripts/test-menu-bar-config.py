#!/usr/bin/env python3
from pathlib import Path
import plistlib
import sys

root = Path(__file__).resolve().parent.parent
host = (root / "NativeApp" / "MomentumSwitcherHost.swift").read_text()
main_view = (root / "NativeApp" / "MomentumMainView.swift").read_text()
site_css = (root / "docs" / "assets" / "site.css").read_text().lower()
plist = plistlib.loads((root / "NativeApp" / "Info.plist").read_bytes())

checks = {
    "app is an LSUIElement menu bar app": plist.get("LSUIElement") is True,
    "host installs a native status item": "NSStatusBar.system.statusItem" in host,
    "host owns a nonactivating popup panel":
        "NSPanel" in host and ".nonactivatingPanel" in host,
    "legacy NSPopover host is removed": "NSPopover" not in host,
    "panel uses the compact 390-point width":
        "NSSize(width: 390, height: 700)" in host,
    "host no longer creates a Dock window": "NSWindow(" not in host,
    "panel closes when it loses key status":
        "windowDidResignKey" in host and "orderOut(nil)" in host,
    "desktop clicks explicitly dismiss the panel":
        "addGlobalMonitorForEvents" in host and "closeControlPanel()" in host,
    "cached panel state refreshes connections without blocking presentation":
        "await viewModel.refresh()" in host
        and "if viewModel.shouldRefreshOnOpen" not in host,
    "automatic control sync starts after the connection refresh":
        host.index("await viewModel.refresh()") < host.index("viewModel.startAutomaticSync()"),
    "cold launch waits for a valid menu-bar anchor":
        "anchorRect.minY >= screenFrame.maxY - 2" in host
        and "retryShowControlPanel" in host
        and "asyncAfter" in host,
    "panel stops live sync when it closes": "windowDidResignKey" in host,
    "panel uses native popup-menu level": "level = .popUpMenu" in host,
    "panel is stationary during Show Desktop": ".stationary" in host,
    "status item uses the standard AppKit click dispatch":
        "sendAction(on:" not in host,
    "temporary popover diagnostics are removed":
        "DEBUG-popover" not in host and "PopoverDebug" not in host,
    "status-item clicks do not force accessory-app activation":
        "showControlPanel(activatingApplication: false)" in host,
    "external reopen requests may activate the accessory app":
        "showControlPanel(activatingApplication: true)" in host,
    "application activation is conditional":
        "if activatingApplication {\n            NSApp.activate(ignoringOtherApps: true)\n        }" in host,
    "app uses the sampled #0A96D4 accent":
        "Color(red: 10.0 / 255.0, green: 150.0 / 255.0, blue: 212.0 / 255.0)" in main_view,
    "website uses the same blue accent": "--accent: #0a96d4" in site_css,
    "warning styling remains semantic orange": ".foregroundStyle(.orange)" in main_view,
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(("PASS" if passed else "FAIL") + ": " + name)
if failed:
    sys.exit(1)
