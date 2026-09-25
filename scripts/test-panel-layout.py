#!/usr/bin/env python3
"""Exercise the real SwiftUI view in AppKit without Bluetooth I/O.
Requires built MomentumCore/MomentumBluetooth frameworks (xcodebuild first).
"""
from pathlib import Path
import os
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
frameworks = Path(os.environ.get("M4_TEST_FRAMEWORKS", root / ".release-build/Build/Products/Release"))
source = (root / "NativeApp/MomentumMainView.swift").read_text()
harness = r'''
import AppKit

extension MomentumMainViewModel {
    func layoutFixture(mode: MomentumSoundMode, busy: Bool) {
        snapshot = MomentumSnapshot(devices: [
            MomentumDevice(index: 0, priority: 0, isConnected: true, name: "This Mac")
        ], ownIndex: 0, maxConnections: 2, batteryPercentage: 40)
        controls = MomentumControlsSnapshot(
            soundMode: mode, ancEnabled: true,
            ancModes: MomentumAncModes(antiWind: .automatic, comfortEnabled: false, adaptiveEnabled: true),
            transparencyLevel: 0, transparentHearingEnabled: false,
            eqConfig: MomentumEqConfig(bandCount: 5, minimumGainDB: -6, maximumGainDB: 6),
            eqBands: (0..<5).map { MomentumEqBand(index: UInt8($0), gainDB: 0) },
            bassBoostEnabled: false
        )
        soundMode = mode
        eqGains = [0, 0, 0, 0, 0]
        busyAction = busy ? "layout-fixture" : nil
    }
}
@MainActor func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
}
@MainActor func pump() {
    let end = Date().addingTimeInterval(0.1)
    while Date() < end {
        if let event = NSApp.nextEvent(matching: .any, until: end, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let model = MomentumMainViewModel(client: MomentumHeadsetClient(), cacheSnapshot: { _ in })
model.layoutFixture(mode: .equalizer, busy: false)
let controller = NSHostingController(rootView: MomentumMainView(model: model, checkForUpdates: {}, quit: {}))
let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 700),
                    styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                    backing: .buffered, defer: false)
panel.contentViewController = controller
panel.setContentSize(NSSize(width: 390, height: 700))
// Real WindowServer-backed layout, placed offscreen to avoid stealing focus.
panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
panel.orderFront(nil)
var failures: [String] = []
for mode in MomentumSoundMode.selectableModes {
    for busy in [false, true, false] {
        model.layoutFixture(mode: mode, busy: busy)
        pump()
        let views = descendants(controller.view)
        let scroll = views.compactMap { $0 as? NSScrollView }.first!
        let picker = views.compactMap { $0 as? NSSegmentedControl }.first {
            $0.segmentCount == 3 && $0.label(forSegment: 0) == "Equalizer"
        }!
        let label = "\(mode.displayName) busy=\(busy)"
        print("\(label): panel=\(panel.frame.width) scroll=\(scroll.frame.width) picker=\(picker.frame.width) intrinsic=\(picker.intrinsicContentSize.width)")
        if abs(panel.frame.width - 390) > 0.5 || abs(scroll.frame.width - 390) > 0.5 {
            failures.append("\(label): content escaped the 390-point panel")
        }
        if picker.intrinsicContentSize.width > picker.frame.width + 0.5 {
            failures.append("\(label): picker minimum width exceeds its allocation; native relayout can widen the entire scroll view")
        }
        if picker.isEnabled == busy { failures.append("\(label): busy-state disabling lost") }
        if picker.selectedSegment != MomentumSoundMode.selectableModes.firstIndex(of: mode)! {
            failures.append("\(label): wrong selected segment")
        }
    }
}
panel.orderOut(nil)
// Test the native target/action bridge against an isolated binding: no headset writes.
var actionSelection = MomentumSoundMode.equalizer
var actionCount = 0
private let inputHost = NSHostingController(rootView: MomentumSoundModePicker(selection: Binding(
    get: { actionSelection },
    set: { actionSelection = $0; actionCount += 1 }
)))
panel.contentViewController = inputHost
panel.setContentSize(NSSize(width: 322, height: 24))
panel.orderFront(nil)
pump()
let input = descendants(inputHost.view).compactMap { $0 as? NSSegmentedControl }.first!
for (index, mode) in MomentumSoundMode.selectableModes.enumerated() {
    input.selectedSegment = index
    input.sendAction(input.action, to: input.target)
    if actionSelection != mode { failures.append("Native action selected the wrong sound mode") }
}
let acceptedActions = actionCount
input.isEnabled = false
input.selectedSegment = 0
input.sendAction(input.action, to: input.target)
input.isEnabled = true
input.selectedSegment = -1
input.sendAction(input.action, to: input.target)
if actionCount != acceptedActions { failures.append("Disabled/invalid native actions changed the binding") }
if input.accessibilityLabel() != "Sound Mode" { failures.append("Picker accessibility label lost") }
print("PASS: native action mapping, disabled/invalid guards, and accessibility label")
for failure in failures { print("FAIL: \(failure)") }
if !failures.isEmpty { exit(1) }
print("PASS: sound-mode layout remains bounded in every selection and busy state")
'''
with tempfile.TemporaryDirectory(prefix="m4-layout-test-") as tmp:
    main = Path(tmp) / "main.swift"
    main.write_text(source + "\n" + harness)
    binary = Path(tmp) / "LayoutTests"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-target", f"{platform.machine()}-apple-macos14.0",
        "-F", str(frameworks), "-framework", "MomentumCore", "-framework", "MomentumBluetooth",
        "-Xlinker", "-rpath", "-Xlinker", str(frameworks), str(main), "-o", str(binary)
    ], check=True)
    raise SystemExit(subprocess.run([str(binary)]).returncode)
