import MomentumBluetooth
import MomentumCore
import SwiftUI

@MainActor
final class MomentumMainViewModel: ObservableObject {
    @Published private(set) var snapshot: MomentumSnapshot?
    @Published private(set) var controls: MomentumControlsSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var busyAction: String?
    @Published private(set) var activeDeferredWrites = 0
    @Published var errorMessage: String?

    @Published var ancEnabled = false
    @Published var adaptiveEnabled = false
    @Published var antiWind: MomentumAntiWind = .automatic
    @Published var transparencyLevel = 0.0
    @Published var eqGains: [Double] = []
    @Published var bassBoostEnabled = false

    private let client: MomentumHeadsetClient
    private let cacheSnapshot: (MomentumSnapshot) -> Void
    private var transparencyTask: Task<Void, Never>?
    private var transparencyGeneration = 0
    private var eqTasks: [UInt8: Task<Void, Never>] = [:]
    private var eqGenerations: [UInt8: Int] = [:]
    private var automaticSyncTask: Task<Void, Never>?
    private var interactionGeneration = 0
    private var activeDeferredControl: String?

    init(
        client: MomentumHeadsetClient,
        cacheSnapshot: @escaping (MomentumSnapshot) -> Void
    ) {
        self.client = client
        self.cacheSnapshot = cacheSnapshot
        if let cached = try? MomentumSnapshotStore.load() {
            snapshot = cached
        }
    }

    var isBusy: Bool {
        isLoading || busyAction != nil || activeDeferredWrites > 0
    }

    var orderedDevices: [MomentumDevice] {
        guard let snapshot else { return [] }
        return PairedDeviceList.displayOrder(snapshot.devices, ownIndex: snapshot.ownIndex)
    }

    var eqLabels: [String] {
        MomentumControlPresentation.eqBandLabels(count: eqGains.count)
    }

    var eqRange: ClosedRange<Double> {
        guard let config = controls?.eqConfig else { return -6...6 }
        return config.minimumGainDB...config.maximumGainDB
    }

    var availablePresets: [MomentumEQPreset] {
        MomentumEQPreset.available(forBandCount: eqGains.count)
    }

    func canEditDeferredControl(_ controlID: String) -> Bool {
        !isLoading
            && busyAction == nil
            && MomentumDeferredWritePolicy.acceptsDraft(
                activeControl: activeDeferredControl,
                requestedControl: controlID
            )
    }

    func startAutomaticSync() {
        guard automaticSyncTask == nil else { return }
        automaticSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(MomentumControlSyncPolicy.pollIntervalSeconds)
                    )
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await self.syncExternalControlChanges()
            }
        }
    }

    func stopAutomaticSync() {
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
    }

    private func syncExternalControlChanges() async {
        guard !isLoading, busyAction == nil, activeDeferredWrites == 0 else { return }
        let startedAtGeneration = interactionGeneration
        do {
            let readback = try await client.controlsSnapshot()
            let hasActiveUserOperation = isLoading || busyAction != nil || activeDeferredWrites > 0
            guard MomentumControlSyncPolicy.shouldApplyReadback(
                startedAtGeneration: startedAtGeneration,
                currentGeneration: interactionGeneration,
                hasActiveUserOperation: hasActiveUserOperation
            ) else { return }
            apply(readback)
        } catch is CancellationError {
            return
        } catch {
            // Phone-side synchronization is best effort; keep the last good UI state.
        }
    }

    func refresh() async {
        guard !isLoading, busyAction == nil, activeDeferredWrites == 0 else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let newSnapshot = try await client.snapshot()
            snapshot = newSnapshot
            cacheSnapshot(newSnapshot)
            apply(try await client.controlsSnapshot())
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func accept(snapshot: MomentumSnapshot) {
        self.snapshot = snapshot
    }

    func togglePeer(_ device: MomentumDevice) {
        guard !isLoading,
              busyAction == nil,
              activeDeferredWrites == 0,
              let current = snapshot,
              device.index != current.ownIndex else { return }
        interactionGeneration += 1
        busyAction = "connection-\(device.index)"
        errorMessage = nil
        snapshot = optimisticSnapshot(for: device, in: current)

        Task {
            defer { busyAction = nil }
            do {
                let authoritative: MomentumSnapshot
                if device.isConnected {
                    authoritative = try await client.disconnectPeer(index: device.index, expectedName: device.name)
                } else {
                    authoritative = try await client.switchPeer(to: device.index, expectedName: device.name)
                }
                snapshot = authoritative
                cacheSnapshot(authoritative)
            } catch is CancellationError {
                snapshot = current
            } catch {
                snapshot = current
                errorMessage = error.localizedDescription
            }
        }
    }

    func setAnc(_ enabled: Bool) {
        runControl(action: "anc", optimistic: { ancEnabled = enabled }) {
            try await self.client.setAncEnabled(enabled)
        }
    }

    func setAdaptive(_ enabled: Bool) {
        runControl(action: "mode", optimistic: {
            adaptiveEnabled = enabled
            ancEnabled = true
        }) {
            if enabled {
                return try await self.client.setAdaptiveEnabled(true)
            }
            return try await self.client.setCustomMode()
        }
    }

    func setNoiseControlMode(_ mode: MomentumNoiseControlMode) {
        switch mode {
        case .adaptive:
            setAdaptive(true)
        case .custom:
            setAdaptive(false)
        case .off:
            runControl(action: "mode", optimistic: {
                ancEnabled = false
                adaptiveEnabled = false
            }) {
                try await self.client.setAncEnabled(false)
            }
        }
    }

    func setAntiWind(_ value: MomentumAntiWind) {
        runControl(action: "anti-wind", optimistic: { antiWind = value }) {
            try await self.client.setAntiWind(value)
        }
    }

    func setBassBoost(_ enabled: Bool) {
        runControl(action: "bass-boost", optimistic: { bassBoostEnabled = enabled }) {
            try await self.client.setBassBoost(enabled)
        }
    }

    func setTransparencyDraft(_ value: Double) {
        let controlID = "transparency"
        guard busyAction == nil,
              !isLoading,
              MomentumDeferredWritePolicy.acceptsDraft(
                  activeControl: activeDeferredControl,
                  requestedControl: controlID
              ) else { return }
        interactionGeneration += 1
        let clamped = min(100, max(0, value))
        transparencyLevel = clamped
        transparencyGeneration += 1
        let generation = transparencyGeneration
        transparencyTask?.cancel()
        reserveDeferredControl(controlID)
        transparencyTask = Task {
            defer {
                if generation == transparencyGeneration {
                    finishDeferredControl(controlID)
                    transparencyTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                let readback = try await client.setTransparencyLevel(Int(clamped.rounded()))
                guard generation == transparencyGeneration else { return }
                apply(readback)
            } catch is CancellationError {
                guard generation == transparencyGeneration else { return }
                await recoverControls(after: CancellationError()) {
                    generation == self.transparencyGeneration
                }
            } catch {
                guard generation == transparencyGeneration else { return }
                await recoverControls(after: error) {
                    generation == self.transparencyGeneration
                }
            }
        }
    }

    func setEqDraft(index: Int, gain: Double) {
        let controlID = "eq-\(index)"
        guard busyAction == nil,
              !isLoading,
              MomentumDeferredWritePolicy.acceptsDraft(
                  activeControl: activeDeferredControl,
                  requestedControl: controlID
              ),
              eqGains.indices.contains(index),
              let band = UInt8(exactly: index) else { return }
        interactionGeneration += 1
        eqGains[index] = min(eqRange.upperBound, max(eqRange.lowerBound, gain))
        eqGenerations[band, default: 0] += 1
        let generation = eqGenerations[band]!
        let requestedGain = eqGains[index]
        eqTasks[band]?.cancel()
        reserveDeferredControl(controlID)
        eqTasks[band] = Task {
            defer {
                if eqGenerations[band] == generation {
                    finishDeferredControl(controlID)
                    eqTasks[band] = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                let readback = try await client.setEqBand(index: band, gainDB: requestedGain)
                guard eqGenerations[band] == generation else { return }
                apply(readback)
            } catch is CancellationError {
                guard eqGenerations[band] == generation else { return }
                await recoverControls(after: CancellationError()) {
                    self.eqGenerations[band] == generation
                }
            } catch {
                guard eqGenerations[band] == generation else { return }
                await recoverControls(after: error) {
                    self.eqGenerations[band] == generation
                }
            }
        }
    }

    func resetEQ() {
        applyEQPreset(
            named: "Flat",
            gains: MomentumControlPresentation.flatGains(bandCount: eqGains.count)
        )
    }

    func applyEQPreset(_ preset: MomentumEQPreset) {
        applyEQPreset(named: preset.name, gains: preset.gainsDB)
    }

    private func applyEQPreset(named name: String, gains: [Double]) {
        guard !isLoading,
              busyAction == nil,
              activeDeferredWrites == 0,
              !gains.isEmpty,
              gains.count == eqGains.count else { return }
        interactionGeneration += 1
        cancelEQDebounces()
        eqGains = gains
        busyAction = "preset-\(name)"
        errorMessage = nil
        Task {
            defer { busyAction = nil }
            do {
                apply(try await client.setEqBands(gains))
            } catch {
                await recoverControls(after: error)
            }
        }
    }

    private func runControl(
        action: String,
        optimistic: () -> Void,
        operation: @escaping () async throws -> MomentumControlsSnapshot
    ) {
        guard !isLoading, busyAction == nil, activeDeferredWrites == 0 else { return }
        interactionGeneration += 1
        busyAction = action
        errorMessage = nil
        optimistic()
        Task {
            defer { busyAction = nil }
            do {
                apply(try await operation())
            } catch {
                await recoverControls(after: error)
            }
        }
    }

    private func apply(_ snapshot: MomentumControlsSnapshot) {
        controls = snapshot
        ancEnabled = snapshot.ancEnabled
        adaptiveEnabled = snapshot.ancModes.adaptiveEnabled
        antiWind = snapshot.ancModes.antiWind
        transparencyLevel = Double(snapshot.transparencyLevel)
        eqGains = MomentumControlPresentation.gains(
            bandCount: Int(snapshot.eqConfig.bandCount),
            bands: snapshot.eqBands
        )
        bassBoostEnabled = snapshot.bassBoostEnabled
    }

    private func optimisticSnapshot(for device: MomentumDevice, in current: MomentumSnapshot) -> MomentumSnapshot {
        let devices = current.devices.map { candidate -> MomentumDevice in
            let connected: Bool
            if candidate.index == device.index {
                connected = !device.isConnected
            } else if !device.isConnected && candidate.index != current.ownIndex {
                connected = false
            } else {
                connected = candidate.isConnected
            }
            return MomentumDevice(
                index: candidate.index,
                priority: candidate.priority,
                isConnected: connected,
                name: candidate.name
            )
        }
        return MomentumSnapshot(
            devices: devices,
            ownIndex: current.ownIndex,
            maxConnections: current.maxConnections,
            batteryPercentage: current.batteryPercentage
        )
    }

    private func reserveDeferredControl(_ controlID: String) {
        guard activeDeferredControl == nil else { return }
        activeDeferredControl = controlID
        activeDeferredWrites = 1
    }

    private func finishDeferredControl(_ controlID: String) {
        guard activeDeferredControl == controlID else { return }
        activeDeferredControl = nil
        activeDeferredWrites = 0
    }

    private func recoverControls(
        after operationError: Error,
        ifCurrent: @escaping @MainActor () -> Bool = { true }
    ) async {
        do {
            let recovery = Task { @MainActor [client] in
                try await client.controlsSnapshot()
            }
            let authoritative = try await recovery.value
            guard ifCurrent() else { return }
            apply(authoritative)
            errorMessage = "Control update failed: \(operationError.localizedDescription) The headphone state was reloaded."
        } catch {
            guard ifCurrent() else { return }
            controls = nil
            errorMessage = "Control update failed: \(operationError.localizedDescription) State recovery also failed: \(error.localizedDescription) Displayed values are unverified."
        }
    }

    private func cancelEQDebounces() {
        for task in eqTasks.values { task.cancel() }
        eqTasks.removeAll()
        for key in eqGenerations.keys { eqGenerations[key, default: 0] += 1 }
    }
}

struct MomentumMainView: View {
    @ObservedObject var model: MomentumMainViewModel

    private let accent = Color(red: 1.0, green: 0.38, blue: 0.05)
    private let pageBackground = Color(red: 0.07, green: 0.07, blue: 0.075)
    private let cardBackground = Color(red: 0.12, green: 0.12, blue: 0.13)

    var body: some View {
        ZStack {
            pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if let error = model.errorMessage {
                        errorBanner(error)
                    }
                    connectionCard
                    noiseControlCard
                    equalizerCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 26)
            }
            if model.isLoading && model.snapshot == nil {
                ProgressView("Connecting to MOMENTUM 4…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(minWidth: 420, idealWidth: 440, minHeight: 560, idealHeight: 700)
        .preferredColorScheme(.dark)
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(accent.opacity(0.14))
                Image(systemName: "headphones")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(accent)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("MOMENTUM 4")
                    .font(.title2.weight(.bold))
                Text(model.snapshot == nil ? "Not available" : "Connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = model.snapshot?.batteryPercentage {
                Label("\(battery)%", systemImage: batterySymbol(battery))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(battery < 20 ? .red : .primary)
            }
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.top, 5)
    }

    private var connectionCard: some View {
        card(title: "Connections", symbol: "link") {
            if model.orderedDevices.isEmpty {
                Text("No paired devices available")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.orderedDevices.enumerated()), id: \.element.id) { offset, device in
                        connectionRow(device)
                        if offset < model.orderedDevices.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    private func connectionRow(_ device: MomentumDevice) -> some View {
        let isOwn = device.index == model.snapshot?.ownIndex
        return Button {
            model.togglePeer(device)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: deviceSymbol(device.name, isOwn: isOwn))
                    .frame(width: 22)
                    .foregroundStyle(device.isConnected ? accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isOwn ? "This Mac" : device.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isOwn && device.name.lowercased() != "this mac" {
                        Text(device.name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isOwn {
                    Text("Controller").font(.caption2).foregroundStyle(.secondary)
                }
                Circle()
                    .fill(device.isConnected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOwn || model.isBusy)
    }

    private var noiseControlCard: some View {
        card(title: "Noise Control", symbol: "waveform") {
            VStack(spacing: 15) {
                Picker("Mode", selection: Binding(
                    get: {
                        MomentumNoiseControlMode.resolve(
                            ancEnabled: model.ancEnabled,
                            adaptiveEnabled: model.adaptiveEnabled
                        )
                    },
                    set: { model.setNoiseControlMode($0) }
                )) {
                    ForEach(MomentumNoiseControlMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isBusy || model.controls == nil)

                VStack(spacing: 6) {
                    HStack {
                        Text("ANC")
                        Spacer()
                        Text("Transparency")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { model.transparencyLevel },
                        set: { model.setTransparencyDraft($0) }
                    ), in: 0...100, step: 1)
                    .disabled(
                        model.controls == nil
                            || !model.canEditDeferredControl("transparency")
                    )
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Anti-Wind").font(.caption).foregroundStyle(.secondary)
                    Picker("Anti-Wind", selection: Binding(
                        get: { model.antiWind },
                        set: { model.setAntiWind($0) }
                    )) {
                        Text("Off").tag(MomentumAntiWind.off)
                        Text("Max").tag(MomentumAntiWind.maximum)
                        Text("Auto").tag(MomentumAntiWind.automatic)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(model.isBusy || model.controls == nil)
                }
            }
        }
    }

    private var equalizerCard: some View {
        card(title: "Equalizer", symbol: "slider.vertical.3") {
            VStack(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        Button("Flat") { model.resetEQ() }
                            .buttonStyle(.bordered)
                        ForEach(model.availablePresets) { preset in
                            Button(preset.name) { model.applyEQPreset(preset) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .disabled(model.isBusy || model.eqGains.isEmpty)

                if model.eqGains.isEmpty {
                    Text(model.controls == nil ? "Equalizer unavailable" : "No EQ bands reported")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    HStack(alignment: .top, spacing: 2) {
                        ForEach(model.eqGains.indices, id: \.self) { index in
                            VerticalEQSlider(
                                model: model,
                                index: index,
                                label: model.eqLabels[index],
                                range: model.eqRange,
                                accent: accent
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Divider().opacity(0.4)
                HStack {
                    Toggle("Bass Boost", isOn: Binding(
                        get: { model.bassBoostEnabled },
                        set: { model.setBassBoost($0) }
                    ))
                    .disabled(model.isBusy || model.controls == nil)
                    Spacer()
                }
            }
        }
    }

    private func card<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol)
                .font(.headline.weight(.semibold))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { model.errorMessage = nil } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
    }

    private func deviceSymbol(_ name: String, isOwn: Bool) -> String {
        if isOwn { return "macbook" }
        let lower = name.lowercased()
        if lower.contains("iphone") || lower.contains("phone") { return "iphone" }
        if lower.contains("ipad") || lower.contains("tablet") { return "ipad" }
        return "desktopcomputer"
    }

    private func batterySymbol(_ percentage: UInt8) -> String {
        switch percentage {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        case 1...25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

@MainActor
private struct VerticalEQSlider: View {
    @ObservedObject var model: MomentumMainViewModel
    let index: Int
    let label: String
    let range: ClosedRange<Double>
    let accent: Color

    private var gain: Double {
        model.eqGains.indices.contains(index) ? model.eqGains[index] : 0
    }

    var body: some View {
        VStack(spacing: 7) {
            Text(String(format: "%+.1f", gain))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(gain == 0 ? .secondary : accent)
            Slider(value: Binding(
                get: { gain },
                set: { model.setEqDraft(index: index, gain: $0) }
            ), in: range, step: 0.1)
                .disabled(
                    model.controls == nil
                        || !model.canEditDeferredControl("eq-\(index)")
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 142)
                .frame(width: 48, height: 142)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}
