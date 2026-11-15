#!/usr/bin/env python3
"""Compile and exercise the real app view model without starting the app."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build", "--product", "CoreTests"], cwd=root, check=True)
build = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=root, text=True).strip())
objects = sorted(build.glob("MomentumCore.build/*.swift.o")) + sorted(build.glob("MomentumBluetooth.build/*.swift.o"))
assert objects, "SwiftPM dependency objects missing"
binary = build / "DisconnectedViewModelTests"
subprocess.run([
    "swiftc", "-parse-as-library", "-swift-version", "6", "-I", str(build / "Modules"),
    str(root / "NativeApp/MomentumMainView.swift"),
    str(root / "Tests/DisconnectedViewModelTests.swift"),
    *map(str, objects), "-framework", "IOBluetooth", "-o", str(binary)
], cwd=root, check=True)
subprocess.run([str(binary)], cwd=root, check=True)
