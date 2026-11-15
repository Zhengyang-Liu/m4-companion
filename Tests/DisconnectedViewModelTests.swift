import Foundation
import MomentumBluetooth
import MomentumCore

@main
struct DisconnectedViewModelTests {
    @MainActor
    static func main() async throws {
        // A snapshot (including the cache/accept path) is not proof of a live connection.
        let model = MomentumMainViewModel(client: MomentumHeadsetClient()) { _ in }
        let peer = MomentumDevice(index: 1, priority: 1, isConnected: false, name: "Phone")
        model.accept(snapshot: MomentumSnapshot(devices: [
            MomentumDevice(index: 0, priority: 0, isConnected: true, name: "Mac"), peer
        ], ownIndex: 0, maxConnections: 2, batteryPercentage: 70))
        model.togglePeer(peer)
        try expect(model.busyAction == nil, "Cached snapshot must not authorize peer switching")
        model.setAnc(true)
        try expect(model.busyAction == nil && !model.ancEnabled, "Unverified controls must reject optimistic ANC changes")
        model.setTransparencyDraft(40)
        try expect(model.activeDeferredWrites == 0, "Unverified controls must reject deferred writes")
        try expect(!model.canEditDeferredControl("transparency"), "Unverified sliders must be disabled")
        print("PASS cached state cannot authorize headphone operations")

        var connected = true
        var reads = 0
        let snapshot = MomentumSnapshot(devices: [peer], ownIndex: 0, maxConnections: 2)
        let controls = MomentumControlsSnapshot(
            soundMode: .equalizer, ancEnabled: true,
            ancModes: MomentumAncModes(antiWind: .automatic, comfortEnabled: false, adaptiveEnabled: true),
            transparencyLevel: 42, transparentHearingEnabled: false,
            eqConfig: MomentumEqConfig(bandCount: 1, minimumGainDB: -6, maximumGainDB: 6),
            eqBands: [MomentumEqBand(index: 0, gainDB: 0)], bassBoostEnabled: false
        )
        try await testDisconnectDuringInitialRefresh(controls: controls)
        try await testDisconnectDuringInitialRefresh(controls: controls, failRead: true)

        let liveModel = MomentumMainViewModel(
            client: MomentumHeadsetClient(),
            connectionAvailable: { connected },
            readSnapshot: { reads += 1; return snapshot },
            readControls: { reads += 1; return controls }
        ) { _ in }
        await liveModel.refresh()
        try expect(liveModel.isHeadsetConnected && liveModel.canControlHeadset, "Fresh live readback enables controls")
        connected = false
        let previousReads = reads
        await liveModel.refresh()
        try expect(reads == previousReads, "Offline refresh must not issue any headphone reads")
        try expect(!liveModel.isHeadsetConnected && !liveModel.canControlHeadset, "Disconnect invalidates live control state")
        try expect(liveModel.snapshot == nil && liveModel.controls == nil, "Disconnect clears stale snapshots")
        try expect(!liveModel.isBusy && liveModel.errorMessage == nil, "Offline is an idle state, not a timeout error")
        print("PASS offline refresh clears state without sending commands")
        connected = true
        await liveModel.refresh()
        try expect(liveModel.canControlHeadset, "Reconnect reloads controls")
        try expect(reads == previousReads + 2, "Reconnect reloads both snapshots")
        print("PASS reconnect revalidates controls")
        liveModel.setEqDraft(index: 0, gain: 2)
        try expect(liveModel.activeDeferredWrites == 1, "Connected EQ draft is scheduled")
        connected = false
        liveModel.checkConnection()
        try expect(liveModel.activeDeferredWrites == 0 && !liveModel.canControlHeadset, "Disconnect cancels pending slider writes")
        let offlineReads = reads
        await liveModel.syncExternalControlChanges()
        try expect(reads == offlineReads, "Background sync does no headphone I/O while offline")
        connected = true
        await liveModel.syncExternalControlChanges()
        try expect(liveModel.canControlHeadset, "Background sync restores controls after reconnect")
        print("PASS pending slider cancellation and background reconnect")
        liveModel.startAutomaticSync()
        connected = false
        try await Task.sleep(for: .milliseconds(1200))
        try expect(!liveModel.canControlHeadset && liveModel.snapshot == nil, "Open panel detects disconnect without a click")
        try expect(reads == offlineReads + 2, "Connection monitor does no RFCOMM reads")
        liveModel.stopAutomaticSync()
        print("PASS live connection monitor disables idle controls")
    }

    @MainActor
    static func testDisconnectDuringInitialRefresh(
        controls: MomentumControlsSnapshot, failRead: Bool = false
    ) async throws {
        var connected = false
        var snapshotReads = 0
        var controlReads = 0
        var cachedSnapshots: [MomentumSnapshot] = []
        var pendingRead: CheckedContinuation<MomentumSnapshot, any Error>?
        var readStarted: CheckedContinuation<Void, Never>?
        let staleSnapshot = MomentumSnapshot(devices: [], ownIndex: 0, maxConnections: 2, batteryPercentage: 10)
        let freshSnapshot = MomentumSnapshot(devices: [], ownIndex: 0, maxConnections: 2, batteryPercentage: 90)
        let model = MomentumMainViewModel(
            client: MomentumHeadsetClient(),
            connectionAvailable: { connected },
            readSnapshot: {
                snapshotReads += 1
                if snapshotReads == 1 {
                    return try await withCheckedThrowingContinuation { continuation in
                        pendingRead = continuation
                        readStarted?.resume()
                        readStarted = nil
                    }
                }
                return freshSnapshot
            },
            readControls: { controlReads += 1; return controls },
            cacheSnapshot: { cachedSnapshots.append($0) }
        )
        // Clear any on-disk cache so the in-flight refresh has no published state.
        model.checkConnection()
        connected = true
        let initialRefresh = Task { await model.refresh() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if pendingRead != nil {
                continuation.resume()
            } else {
                readStarted = continuation
            }
        }
        try expect(model.isLoading && model.snapshot == nil && model.controls == nil && !model.isHeadsetConnected,
                   "Initial refresh must be suspended with empty published state")
        connected = false
        try expect(!model.checkConnection(), "Disconnect is observed while the initial read is suspended")
        connected = true
        if failRead {
            pendingRead!.resume(throwing: NSError(domain: "DelayedRead", code: 1))
        } else {
            pendingRead!.resume(returning: staleSnapshot)
        }
        pendingRead = nil
        await initialRefresh.value
        try expect(cachedSnapshots.isEmpty, "Invalidated initial read must not cache a stale snapshot")
        try expect(model.snapshot == nil && model.controls == nil && !model.isHeadsetConnected,
                   "Invalidated initial read must not republish connected state")
        try expect(!model.canControlHeadset && !model.canEditDeferredControl("transparency"),
                   "Invalidated initial read must not authorize controls")
        try expect(controlReads == 0, "Invalidated initial read must not continue to read controls")
        try expect(!model.isBusy && model.errorMessage == nil, "Invalidated refresh must finish idle without an error")
        await model.refresh()
        try expect(snapshotReads == 2 && controlReads == 1, "Subsequent refresh must read both fresh snapshots")
        try expect(cachedSnapshots.count == 1 && cachedSnapshots.first?.batteryPercentage == 90,
                   "Only the fresh subsequent snapshot is cached")
        try expect(model.snapshot?.batteryPercentage == 90 && model.isHeadsetConnected && model.canControlHeadset,
                   "Fresh subsequent refresh restores connected state and controls")
        print("PASS disconnect invalidates suspended initial read \(failRead ? "failure" : "success") and fresh refresh recovers")
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ViewModelRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
