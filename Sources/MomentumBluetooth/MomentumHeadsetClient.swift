import Foundation
import MomentumCore

public struct MomentumSnapshot: Equatable, Codable, Sendable {
    public let devices: [MomentumDevice]
    public let ownIndex: UInt8
    public let maxConnections: UInt8
    public let batteryPercentage: UInt8?

    public init(
        devices: [MomentumDevice],
        ownIndex: UInt8,
        maxConnections: UInt8,
        batteryPercentage: UInt8? = nil
    ) {
        self.devices = devices
        self.ownIndex = ownIndex
        self.maxConnections = maxConnections
        self.batteryPercentage = batteryPercentage
    }
}

public struct MomentumSoundPersonalizationPrerequisites: Equatable, Sendable {
    public let compatibilityMode: MomentumBluetoothCompatibilityMode
    public let profileState: MomentumSoundPersonalizationProfileState

    public init(
        compatibilityMode: MomentumBluetoothCompatibilityMode,
        profileState: MomentumSoundPersonalizationProfileState
    ) {
        self.compatibilityMode = compatibilityMode
        self.profileState = profileState
    }
}

private actor MomentumClientOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
public final class MomentumHeadsetClient {
    private static let operationGate = MomentumClientOperationGate()
    private let headsetAddress: String?
    private var operationAddress: String?

    public init(headsetAddress: String? = nil) {
        self.headsetAddress = headsetAddress
    }

    public func snapshot() async throws -> MomentumSnapshot {
        try await withExclusiveOperation {
            try await self.snapshotWithinOperation()
        }
    }

    public func controlsSnapshot() async throws -> MomentumControlsSnapshot {
        try await withExclusiveOperation {
            try await self.withControlTransport { transport in
                try await self.controlsSnapshot(using: transport)
            }
        }
    }

    /// Read-only diagnostic for the confirmed Sennheiser audio/podcast mode getter.
    /// The command has no payload and does not change headphone state.
    public func soundPersonalizationModePayload() async throws -> Data {
        try await withExclusiveOperation {
            try await self.withControlTransport { transport in
                try await self.exchange(
                    command: MomentumCommands.getSoundMode,
                    expecting: [MomentumCommands.getSoundModeResponse],
                    using: transport
                ).payload
            }
        }
    }

    public func soundMode() async throws -> MomentumSoundMode {
        try MomentumControlCodec.parseSoundMode(try await soundPersonalizationModePayload())
    }

    public func soundPersonalizationPrerequisites() async throws -> MomentumSoundPersonalizationPrerequisites {
        try await withExclusiveOperation {
            try await self.withControlTransport { transport in
                try await self.soundPersonalizationPrerequisites(using: transport)
            }
        }
    }

    public func setAudioMode(_ desired: MomentumSoundMode) async throws -> MomentumControlsSnapshot {
        try await withExclusiveOperation {
            try await self.withControlTransport { transport in
                let currentPacket = try await self.exchange(
                    command: MomentumCommands.getSoundMode,
                    expecting: [MomentumCommands.getSoundModeResponse],
                    using: transport
                )
                let current = try MomentumControlCodec.parseSoundMode(currentPacket.payload)
                if current == desired {
                    return try await self.controlsSnapshot(using: transport)
                }

                if desired == .soundPersonalization {
                    let prerequisites = try await self.soundPersonalizationPrerequisites(using: transport)
                    guard prerequisites.profileState == .calibrated else {
                        throw MomentumBluetoothError.switchFailed(
                            "No calibrated Sound Personalization profile is stored on the headphones."
                        )
                    }
                    guard prerequisites.compatibilityMode == .betterCompatibility else {
                        throw MomentumBluetoothError.switchFailed(
                            "Disable High Resolution Audio mode before enabling Sound Personalization."
                        )
                    }
                }

                var commandResponse: GaiaPacket?
                var commandError: Error?
                do {
                    commandResponse = try await self.exchange(
                        command: MomentumCommands.setAudioMode,
                        payload: MomentumControlCodec.encodeAudioMode(desired),
                        expecting: [
                            MomentumCommands.setAudioModeResponse,
                            MomentumCommands.setAudioModeResponse | 0x0080
                        ],
                        using: transport
                    )
                } catch {
                    commandError = error
                }

                var lastPollError: Error?
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(250))
                    do {
                        let packet = try await self.exchange(
                            command: MomentumCommands.getSoundMode,
                            expecting: [MomentumCommands.getSoundModeResponse],
                            using: transport
                        )
                        let readback = try MomentumControlCodec.parseSoundMode(packet.payload)
                        if MomentumSoundModeTransitionPolicy.reached(desired: desired, readback: readback) {
                            return try await self.controlsSnapshot(using: transport)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastPollError = error
                    }
                }

                if let commandResponse,
                   commandResponse.commandID == (MomentumCommands.setAudioModeResponse | 0x0080) {
                    throw MomentumProtocolError.deviceRejected(
                        command: MomentumCommands.setAudioMode,
                        status: commandResponse.payload.first
                    )
                }
                if let commandError { throw commandError }
                if let lastPollError { throw lastPollError }
                throw MomentumBluetoothError.switchFailed(
                    "The headphones did not enter \(desired.displayName)."
                )
            }
        }
    }

    private func soundPersonalizationPrerequisites(
        using transport: RFCOMMMomentumTransport
    ) async throws -> MomentumSoundPersonalizationPrerequisites {
        let compatibility = try await self.exchange(
            command: MomentumCommands.getBluetoothCompatibilityMode,
            expecting: [MomentumCommands.getBluetoothCompatibilityModeResponse],
            using: transport
        )
        let profile = try await self.exchange(
            command: MomentumCommands.getSoundPersonalizationProfileState,
            expecting: [MomentumCommands.getSoundPersonalizationProfileStateResponse],
            using: transport
        )
        return MomentumSoundPersonalizationPrerequisites(
            compatibilityMode: try MomentumControlCodec.parseBluetoothCompatibilityMode(
                compatibility.payload
            ),
            profileState: try MomentumControlCodec.parseSoundPersonalizationProfileState(
                profile.payload
            )
        )
    }


    /// Registers only for known, non-destructive notification feature IDs and
    /// returns their initial state dump. No setting or operational command is sent.
    public func soundPersonalizationNotificationProbe() async throws -> [GaiaPacket] {
        try await withExclusiveOperation {
            try await self.withControlTransport { transport in
                var packets: [GaiaPacket] = []
                var parseError: Error?
                transport.onPacket = { data in
                    do {
                        let packet = try GaiaPacket(data: data)
                        guard packet.vendorID == MomentumCommands.vendorID else { return }
                        packets.append(packet)
                    } catch {
                        parseError = error
                    }
                }

                for feature: UInt8 in [16, 20] {
                    try transport.send(
                        GaiaPacket(
                            vendorID: MomentumCommands.vendorID,
                            commandID: 0x0007,
                            payload: Data([feature])
                        ).data
                    )
                    try await Task.sleep(for: .seconds(1))
                    if let parseError { throw parseError }
                }
                return packets
            }
        }
    }

    public func setAncEnabled(_ enabled: Bool) async throws -> MomentumControlsSnapshot {
        try await performControlWrites([
            MomentumControlWrite(
                command: MomentumCommands.setAncEnabled,
                payload: MomentumControlCodec.encodeBoolean(enabled)
            )
        ])
    }

    public func setAdaptiveEnabled(_ enabled: Bool) async throws -> MomentumControlsSnapshot {
        if !enabled { return try await setCustomMode() }
        let adaptivePayload = try MomentumControlCodec.encodeAncMode(.adaptive, state: 1)
        return try await performControlWrites([
            MomentumControlWrite(
                command: MomentumCommands.setTransparentHearing,
                payload: MomentumControlCodec.encodeBoolean(false)
            ),
            MomentumControlWrite(
                command: MomentumCommands.setAncEnabled,
                payload: MomentumControlCodec.encodeBoolean(true)
            ),
            MomentumControlWrite(command: MomentumCommands.setAncMode, payload: adaptivePayload)
        ])
    }

    public func setCustomMode() async throws -> MomentumControlsSnapshot {
        try await performControlWrites(MomentumControlPlan.customMode)
    }

    public func setCustomMode(restoringLevel level: Int) async throws -> MomentumControlsSnapshot {
        try await performControlWrites(MomentumControlPlan.customModeRestoring(level: level))
    }

    public func setAntiWind(_ value: MomentumAntiWind) async throws -> MomentumControlsSnapshot {
        let payload = try MomentumControlCodec.encodeAncMode(.antiWind, state: value.rawValue)
        return try await performControlWrites([
            MomentumControlWrite(command: MomentumCommands.setAncMode, payload: payload)
        ])
    }

    public func setTransparencyLevel(_ level: Int) async throws -> MomentumControlsSnapshot {
        try await performControlWrites(MomentumControlPlan.transparency(level: level))
    }

    public func setTransparentHearingEnabled(_ enabled: Bool) async throws -> MomentumControlsSnapshot {
        try await performControlWrites([
            MomentumControlWrite(
                command: MomentumCommands.setTransparentHearing,
                payload: MomentumControlCodec.encodeBoolean(enabled)
            )
        ])
    }

    public func setEqBand(index: UInt8, gainDB: Double) async throws -> MomentumControlsSnapshot {
        try await withExclusiveOperation {
            try await self.withControlTransport { transport in
                let configPacket = try await self.exchange(
                    command: MomentumCommands.getEqConfig,
                    expecting: [MomentumCommands.getEqConfigResponse],
                    using: transport
                )
                let config = try MomentumControlCodec.parseEqConfig(configPacket.payload)
                let payload = try MomentumControlCodec.encodeEqBand(index: index, gainDB: gainDB, config: config)
                try await self.writeControl(
                    MomentumControlWrite(command: MomentumCommands.setEqBand, payload: payload),
                    using: transport
                )
                return try await self.controlsSnapshot(using: transport)
            }
        }
    }

    public func setEqBands(_ gainsDB: [Double]) async throws -> MomentumControlsSnapshot {
        try await withExclusiveOperation {
            try await self.withControlTransport { transport in
                let configPacket = try await self.exchange(
                    command: MomentumCommands.getEqConfig,
                    expecting: [MomentumCommands.getEqConfigResponse],
                    using: transport
                )
                let config = try MomentumControlCodec.parseEqConfig(configPacket.payload)
                guard gainsDB.count == Int(config.bandCount) else {
                    throw MomentumProtocolError.invalidEqBand(UInt8(clamping: gainsDB.count))
                }
                var previousGains: [Double] = []
                previousGains.reserveCapacity(Int(config.bandCount))
                for band in UInt8(0)..<config.bandCount {
                    let packet = try await self.exchange(
                        command: MomentumCommands.getEqBand,
                        payload: Data([band]),
                        expecting: [MomentumCommands.getEqBandResponse],
                        using: transport
                    )
                    previousGains.append(
                        try MomentumControlCodec.parseEqBand(packet.payload, requestedBand: band).gainDB
                    )
                }

                var successfulWriteCount = 0
                do {
                    for (index, gainDB) in gainsDB.enumerated() {
                        let band = UInt8(index)
                        let payload = try MomentumControlCodec.encodeEqBand(
                            index: band,
                            gainDB: gainDB,
                            config: config
                        )
                        try await self.writeControl(
                            MomentumControlWrite(command: MomentumCommands.setEqBand, payload: payload),
                            using: transport
                        )
                        successfulWriteCount += 1
                    }
                    return try await self.controlsSnapshot(using: transport)
                } catch {
                    let originalError = error
                    let rollbackIndices = MomentumEQBatchPlan.rollbackIndices(
                        successfulWriteCount: successfulWriteCount
                    )
                    let rollback = Task { @MainActor in
                        var outcomes: [Bool] = []
                        outcomes.reserveCapacity(rollbackIndices.count)
                        for index in rollbackIndices {
                            do {
                                guard let band = UInt8(exactly: index),
                                      previousGains.indices.contains(index) else {
                                    outcomes.append(false)
                                    continue
                                }
                                let payload = try MomentumControlCodec.encodeEqBand(
                                    index: band,
                                    gainDB: previousGains[index],
                                    config: config
                                )
                                try await self.writeControl(
                                    MomentumControlWrite(command: MomentumCommands.setEqBand, payload: payload),
                                    using: transport
                                )
                                outcomes.append(true)
                            } catch {
                                outcomes.append(false)
                            }
                        }
                        return MomentumEQBatchPlan.rollbackFailureIndices(
                            attemptedIndices: rollbackIndices,
                            writeSucceeded: outcomes
                        )
                    }
                    let failedBands = await rollback.value
                    if !failedBands.isEmpty {
                        throw MomentumBluetoothError.eqBatchRollbackFailed(
                            original: originalError.localizedDescription,
                            failedBands: failedBands
                        )
                    }
                    if originalError is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    throw originalError
                }
            }
        }
    }

    public func setBassBoost(_ enabled: Bool) async throws -> MomentumControlsSnapshot {
        try await performControlWrites([
            MomentumControlWrite(
                command: MomentumCommands.setBassBoost,
                payload: MomentumControlCodec.encodeBoolean(enabled)
            )
        ])
    }

    private func performControlWrites(
        _ writes: [MomentumControlWrite]
    ) async throws -> MomentumControlsSnapshot {
        try await withExclusiveOperation {
            try await self.withControlTransport { transport in
                for write in writes {
                    try await self.writeControl(write, using: transport)
                }
                return try await self.controlsSnapshot(using: transport)
            }
        }
    }

    private func withControlTransport<T>(
        _ operation: (RFCOMMMomentumTransport) async throws -> T
    ) async throws -> T {
        let transport = RFCOMMMomentumTransport(expectedAddress: operationAddress)
        do {
            try await transport.connect()
            let result = try await operation(transport)
            transport.disconnect()
            try? await Task.sleep(for: .milliseconds(200))
            return result
        } catch {
            transport.disconnect()
            try? await Task.sleep(for: .milliseconds(200))
            throw error
        }
    }

    private func writeControl(
        _ write: MomentumControlWrite,
        using transport: RFCOMMMomentumTransport
    ) async throws {
        let success = write.command | 0x0100
        let failure = success | 0x0080
        let response = try await exchange(
            command: write.command,
            payload: write.payload,
            expecting: [success, failure],
            using: transport
        )
        try MomentumControlCodec.validateWriteResponse(command: write.command, response: response)
    }

    private func controlsSnapshot(
        using transport: RFCOMMMomentumTransport
    ) async throws -> MomentumControlsSnapshot {
        let soundModePacket = try await exchange(
            command: MomentumCommands.getSoundMode,
            expecting: [MomentumCommands.getSoundModeResponse],
            using: transport
        )
        let ancPacket = try await exchange(
            command: MomentumCommands.getAncEnabled,
            expecting: [MomentumCommands.getAncEnabledResponse],
            using: transport
        )
        let modesPacket = try await exchange(
            command: MomentumCommands.getAncModes,
            expecting: [MomentumCommands.getAncModesResponse],
            using: transport
        )
        let transparencyPacket = try await exchange(
            command: MomentumCommands.getTransparencyLevel,
            expecting: [MomentumCommands.getTransparencyLevelResponse],
            using: transport
        )
        let transparentHearingPacket = try await exchange(
            command: MomentumCommands.getTransparentHearing,
            expecting: [MomentumCommands.getTransparentHearingResponse],
            using: transport
        )
        let eqConfigPacket = try await exchange(
            command: MomentumCommands.getEqConfig,
            expecting: [MomentumCommands.getEqConfigResponse],
            using: transport
        )
        let eqConfig = try MomentumControlCodec.parseEqConfig(eqConfigPacket.payload)
        var eqBands: [MomentumEqBand] = []
        eqBands.reserveCapacity(Int(eqConfig.bandCount))
        for band in UInt8(0)..<eqConfig.bandCount {
            let packet = try await exchange(
                command: MomentumCommands.getEqBand,
                payload: Data([band]),
                expecting: [MomentumCommands.getEqBandResponse],
                using: transport
            )
            eqBands.append(try MomentumControlCodec.parseEqBand(packet.payload, requestedBand: band))
        }
        let bassPacket = try await exchange(
            command: MomentumCommands.getBassBoost,
            expecting: [MomentumCommands.getBassBoostResponse],
            using: transport
        )
        return MomentumControlsSnapshot(
            soundMode: try MomentumControlCodec.parseSoundMode(soundModePacket.payload),
            ancEnabled: try MomentumControlCodec.parseBoolean(
                ancPacket.payload,
                command: MomentumCommands.getAncEnabled
            ),
            ancModes: try MomentumControlCodec.parseAncModes(modesPacket.payload),
            transparencyLevel: try MomentumControlCodec.parseTransparencyLevel(transparencyPacket.payload),
            transparentHearingEnabled: try MomentumControlCodec.parseBoolean(
                transparentHearingPacket.payload,
                command: MomentumCommands.getTransparentHearing
            ),
            eqConfig: eqConfig,
            eqBands: eqBands,
            bassBoostEnabled: try MomentumControlCodec.parseBoolean(
                bassPacket.payload,
                command: MomentumCommands.getBassBoost
            )
        )
    }

    private func snapshotWithinOperation() async throws -> MomentumSnapshot {
        let transport = RFCOMMMomentumTransport(expectedAddress: operationAddress)
        do {
            try await transport.connect()
            let result = try await snapshot(using: transport)
            transport.disconnect()
            try? await Task.sleep(for: .milliseconds(200))
            return result
        } catch {
            transport.disconnect()
            try? await Task.sleep(for: .milliseconds(200))
            throw error
        }
    }

    private func snapshot(using transport: RFCOMMMomentumTransport) async throws -> MomentumSnapshot {
        let countPacket = try await exchange(
            command: MomentumCommands.listSize,
            expecting: [MomentumCommands.listSizeResponse],
            using: transport
        )
        let count = try PairedDeviceList.parseCount(countPacket.payload)

        let ownPacket = try await exchange(
            command: MomentumCommands.ownIndex,
            expecting: [MomentumCommands.ownIndexResponse],
            using: transport
        )
        guard let ownIndex = ownPacket.payload.first else {
            throw MomentumProtocolError.unexpectedResponse(ownPacket.commandID)
        }

        let maxPacket = try await exchange(
            command: MomentumCommands.maxConnections,
            expecting: [MomentumCommands.maxConnectionsResponse],
            using: transport
        )
        guard let maxConnections = maxPacket.payload.first else {
            throw MomentumProtocolError.unexpectedResponse(maxPacket.commandID)
        }

        var devices: [MomentumDevice] = []
        var seenIndices = Set<UInt8>()
        for index in 0..<count {
            let requestedIndex = UInt8(index)
            let packet = try await exchange(
                command: MomentumCommands.deviceInfo,
                payload: Data([requestedIndex]),
                expecting: [MomentumCommands.deviceInfoResponse],
                using: transport
            )
            let device = try MomentumDevice(response: packet)
            guard device.index == requestedIndex, seenIndices.insert(device.index).inserted else {
                throw MomentumProtocolError.malformedDeviceInfo
            }
            devices.append(device)
        }
        guard devices.filter({ $0.index == ownIndex }).count == 1 else {
            throw MomentumProtocolError.malformedDeviceInfo
        }

        let batteryPercentage = try await BatteryLevel.bestEffortQuery {
            let batteryPacket = try await exchange(
                command: MomentumCommands.battery,
                expecting: [MomentumCommands.batteryResponse],
                using: transport
            )
            return try BatteryLevel.parse(batteryPacket.payload)
        }

        return MomentumSnapshot(
            devices: PairedDeviceList.displayOrder(devices, ownIndex: ownIndex),
            ownIndex: ownIndex,
            maxConnections: maxConnections,
            batteryPercentage: batteryPercentage
        )
    }

    public func switchPeer(
        to targetIndex: UInt8,
        expectedName: String? = nil
    ) async throws -> MomentumSnapshot {
        try await withExclusiveOperation {
            try await self.switchPeerWithinOperation(to: targetIndex, expectedName: expectedName)
        }
    }

    private func switchPeerWithinOperation(
        to targetIndex: UInt8,
        expectedName: String? = nil
    ) async throws -> MomentumSnapshot {
        let before = try await snapshotWithinOperation()
        guard let target = before.devices.first(where: { $0.index == targetIndex }) else {
            throw SwitchPlanningError.targetDeviceMissing
        }
        if let expectedName, target.name != expectedName {
            throw MomentumProtocolError.deviceIdentityChanged
        }

        let plan = try SwitchPlanner.plan(
            devices: before.devices,
            ownIndex: before.ownIndex,
            targetIndex: targetIndex,
            maxConnections: before.maxConnections
        )
        guard let connectIndex = plan.connectIndex else { return before }

        let originalPeers = before.devices.filter {
            $0.isConnected && $0.index != before.ownIndex && $0.index != connectIndex
        }

        do {
            for index in plan.disconnectIndices {
                try await invoke(
                    command: MomentumCommands.disconnect,
                    success: MomentumCommands.disconnectResponse,
                    failure: MomentumCommands.disconnectResponse | 0x0080,
                    index: index
                )
                try await Task.sleep(for: .milliseconds(250))
            }
            return try await connectAndWait(
                index: connectIndex,
                expectedName: target.name,
                ownIndex: before.ownIndex
            )
        } catch is CancellationError {
            try await rollbackAfterCancellation(
                peers: originalPeers,
                ownIndex: before.ownIndex,
                target: target
            )
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                try await rollbackAfterCancellation(
                    peers: originalPeers,
                    ownIndex: before.ownIndex,
                    target: target
                )
                throw CancellationError()
            }
            do {
                _ = try await restore(
                    peers: originalPeers,
                    ownIndex: before.ownIndex,
                    removing: target
                )
            } catch let rollbackError {
                throw MomentumBluetoothError.switchFailed(
                    "Switch failed: \(error.localizedDescription) Rollback also failed: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
    }

    public func disconnectPeer(
        index: UInt8,
        expectedName: String? = nil
    ) async throws -> MomentumSnapshot {
        try await withExclusiveOperation {
            try await self.disconnectPeerWithinOperation(index: index, expectedName: expectedName)
        }
    }

    private func disconnectPeerWithinOperation(
        index: UInt8,
        expectedName: String? = nil
    ) async throws -> MomentumSnapshot {
        let before = try await snapshotWithinOperation()
        guard index != before.ownIndex else {
            throw MomentumBluetoothError.switchFailed(
                "This Mac must stay connected so the switcher can control the headphones."
            )
        }
        guard let target = before.devices.first(where: { $0.index == index }) else {
            throw SwitchPlanningError.targetDeviceMissing
        }
        if let expectedName, target.name != expectedName {
            throw MomentumProtocolError.deviceIdentityChanged
        }
        guard target.isConnected else { return before }

        try await invoke(
            command: MomentumCommands.disconnect,
            success: MomentumCommands.disconnectResponse,
            failure: MomentumCommands.disconnectResponse | 0x0080,
            index: index
        )
        try await Task.sleep(for: .seconds(1))
        let updated = try await snapshotWithinOperation()
        guard let updatedTarget = updated.devices.first(where: { $0.index == index }),
              updatedTarget.name == target.name else {
            throw MomentumProtocolError.deviceIdentityChanged
        }
        guard updatedTarget.isConnected == false else {
            throw MomentumBluetoothError.switchFailed("The selected device did not disconnect.")
        }
        return updated
    }

    private func connectAndWait(
        index: UInt8,
        expectedName: String,
        ownIndex: UInt8
    ) async throws -> MomentumSnapshot {
        let transport = RFCOMMMomentumTransport(expectedAddress: operationAddress)
        do {
            try await transport.connect()
            var verifiedSnapshot: MomentumSnapshot?
            let connected = try await ConnectionAttemptPolicy.connect(
                maximumAttempts: 2,
                pollsPerAttempt: 15,
                sendConnect: {
                    let response = try await self.exchange(
                        command: MomentumCommands.connect,
                        payload: Data([index]),
                        expecting: [MomentumCommands.connectResponse, MomentumCommands.connectError],
                        using: transport
                    )
                    guard response.commandID == MomentumCommands.connectResponse else {
                        throw MomentumProtocolError.deviceRejected(
                            command: MomentumCommands.connect,
                            status: response.payload.first
                        )
                    }
                },
                pollConnected: {
                    try await Task.sleep(for: .milliseconds(300))
                    let statusPacket = try await self.exchange(
                        command: MomentumCommands.connectionStatus,
                        payload: Data([index]),
                        expecting: [MomentumCommands.connectionStatusResponse],
                        using: transport
                    )
                    guard try ConnectionStatus.parse(statusPacket.payload, expectedIndex: index) else {
                        return false
                    }
                    let updated = try await self.snapshot(using: transport)
                    let ownConnected = updated.devices.first(where: { $0.index == ownIndex })?.isConnected == true
                    let connectedTarget = updated.devices.first(where: { $0.index == index })
                    guard connectedTarget?.name == expectedName else {
                        throw MomentumProtocolError.deviceIdentityChanged
                    }
                    guard ownConnected, connectedTarget?.isConnected == true else {
                        throw MomentumBluetoothError.switchFailed(
                            "The headphones connected the target but dropped this Mac."
                        )
                    }
                    verifiedSnapshot = updated
                    return true
                }
            )
            guard connected, let verifiedSnapshot else {
                throw MomentumBluetoothError.switchFailed("The headphones did not establish both connections in time.")
            }
            transport.disconnect()
            try? await Task.sleep(for: .milliseconds(200))
            return verifiedSnapshot
        } catch {
            transport.disconnect()
            try? await Task.sleep(for: .milliseconds(200))
            throw error
        }
    }

    private func rollbackAfterCancellation(
        peers: [MomentumDevice],
        ownIndex: UInt8,
        target: MomentumDevice
    ) async throws {
        let rollback = Task.detached { [weak self, peers, ownIndex, target] in
            guard let self else { throw CancellationError() }
            return try await self.restore(
                peers: peers,
                ownIndex: ownIndex,
                removing: target
            )
        }
        do {
            _ = try await rollback.value
        } catch {
            throw MomentumBluetoothError.switchFailed(
                "Operation was cancelled and rollback failed: \(error.localizedDescription)"
            )
        }
    }

    private func restore(
        peers: [MomentumDevice],
        ownIndex: UInt8,
        removing target: MomentumDevice
    ) async throws -> MomentumSnapshot {
        var updated = try await snapshotWithinOperation()

        guard let currentTarget = updated.devices.first(where: { $0.index == target.index }),
              currentTarget.name == target.name else {
            throw MomentumProtocolError.deviceIdentityChanged
        }
        if currentTarget.isConnected {
            try await invoke(
                command: MomentumCommands.disconnect,
                success: MomentumCommands.disconnectResponse,
                failure: MomentumCommands.disconnectResponse | 0x0080,
                index: target.index
            )
            try await Task.sleep(for: .seconds(1))
            updated = try await snapshotWithinOperation()
            guard let disconnectedTarget = updated.devices.first(where: { $0.index == target.index }),
                  disconnectedTarget.name == target.name,
                  disconnectedTarget.isConnected == false else {
                throw MomentumBluetoothError.switchFailed("Could not remove the newly connected target during rollback.")
            }
        }

        for peer in peers {
            guard let currentPeer = updated.devices.first(where: { $0.index == peer.index }),
                  currentPeer.name == peer.name else {
                throw MomentumProtocolError.deviceIdentityChanged
            }
            if currentPeer.isConnected { continue }
            updated = try await connectAndWait(
                index: peer.index,
                expectedName: peer.name,
                ownIndex: ownIndex
            )
        }
        let ownConnected = updated.devices.first(where: { $0.index == ownIndex })?.isConnected == true
        let targetRemoved = updated.devices.first(where: {
            $0.index == target.index && $0.name == target.name
        })?.isConnected == false
        let peersRestored = peers.allSatisfy { peer in
            updated.devices.first(where: { $0.index == peer.index && $0.name == peer.name })?.isConnected == true
        }
        guard ownConnected, targetRemoved, peersRestored else {
            throw MomentumBluetoothError.switchFailed("Could not verify the previous connection state after rollback.")
        }
        return updated
    }

    private func invoke(
        command: UInt16,
        success: UInt16,
        failure: UInt16,
        index: UInt8
    ) async throws {
        let response = try await exchange(
            command: command,
            payload: Data([index]),
            expecting: [success, failure]
        )
        guard response.commandID == success else {
            throw MomentumProtocolError.deviceRejected(command: command, status: response.payload.first)
        }
    }

    private func withExclusiveOperation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await Self.operationGate.acquire()
        do {
            try Task.checkCancellation()
            operationAddress = try RFCOMMMomentumTransport.resolveHeadsetAddress(expectedAddress: headsetAddress)
            let result = try await operation()
            operationAddress = nil
            await Self.operationGate.release()
            return result
        } catch {
            operationAddress = nil
            await Self.operationGate.release()
            throw error
        }
    }

    private func exchange(
        command: UInt16,
        payload: Data = Data(),
        expecting expectedCommands: Set<UInt16>,
        using connectedTransport: RFCOMMMomentumTransport? = nil
    ) async throws -> GaiaPacket {
        let transport = connectedTransport ?? RFCOMMMomentumTransport(expectedAddress: operationAddress)
        let ownsTransport = connectedTransport == nil
        var response: GaiaPacket?
        var parseError: Error?

        transport.onPacket = { data in
            do {
                let packet = try GaiaPacket(data: data)
                guard packet.vendorID == MomentumCommands.vendorID,
                      expectedCommands.contains(packet.commandID) else { return }
                response = packet
            } catch {
                parseError = error
            }
        }

        do {
            try await transport.connect()
            try transport.send(
                GaiaPacket(
                    vendorID: MomentumCommands.vendorID,
                    commandID: command,
                    payload: payload
                ).data
            )

            for _ in 0..<100 {
                try Task.checkCancellation()
                if let parseError { throw parseError }
                if let response {
                    if ownsTransport {
                        transport.disconnect()
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    return response
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw MomentumBluetoothError.responseTimedOut(command)
        } catch {
            if ownsTransport {
                transport.disconnect()
                try? await Task.sleep(for: .milliseconds(200))
            }
            throw error
        }
    }
}
