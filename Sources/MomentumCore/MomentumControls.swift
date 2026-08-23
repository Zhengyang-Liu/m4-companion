import Foundation

public enum MomentumSoundMode: UInt8, Codable, CaseIterable, Sendable {
    case equalizer = 1
    case soundPersonalization = 3

    public var displayName: String {
        switch self {
        case .equalizer: "Equalizer"
        case .soundPersonalization: "Sound Personalization"
        }
    }
}

public enum MomentumBluetoothCompatibilityMode: UInt8, Codable, Sendable {
    case betterAudio = 0
    case betterCompatibility = 1
}

public enum MomentumSoundPersonalizationProfileState: UInt8, Codable, Sendable {
    case notParameterized = 0
    case calibrating = 1
    case calibrated = 2
    case activationInhibited = 3
}

public enum MomentumSoundModeTransitionPolicy {
    public static func reached(desired: MomentumSoundMode, readback: MomentumSoundMode) -> Bool {
        desired == readback
    }
}

public enum MomentumAntiWind: UInt8, Codable, CaseIterable, Sendable {
    case off = 0
    case maximum = 1
    case automatic = 2
}

public enum MomentumAncMode: UInt8, Codable, Sendable {
    case antiWind = 1
    case comfort = 2
    case adaptive = 3
}

public struct MomentumAncModes: Equatable, Codable, Sendable {
    public let antiWind: MomentumAntiWind
    public let comfortEnabled: Bool
    public let adaptiveEnabled: Bool

    public init(antiWind: MomentumAntiWind, comfortEnabled: Bool, adaptiveEnabled: Bool) {
        self.antiWind = antiWind
        self.comfortEnabled = comfortEnabled
        self.adaptiveEnabled = adaptiveEnabled
    }
}

public struct MomentumEqConfig: Equatable, Codable, Sendable {
    public let bandCount: UInt8
    public let minimumGainDB: Double
    public let maximumGainDB: Double

    public init(bandCount: UInt8, minimumGainDB: Double, maximumGainDB: Double) {
        self.bandCount = bandCount
        self.minimumGainDB = minimumGainDB
        self.maximumGainDB = maximumGainDB
    }
}

public struct MomentumEqBand: Equatable, Codable, Identifiable, Sendable {
    public let index: UInt8
    public let gainDB: Double
    public var id: UInt8 { index }

    public init(index: UInt8, gainDB: Double) {
        self.index = index
        self.gainDB = gainDB
    }
}

public struct MomentumControlsSnapshot: Equatable, Codable, Sendable {
    public let soundMode: MomentumSoundMode
    public let ancEnabled: Bool
    public let ancModes: MomentumAncModes
    public let transparencyLevel: UInt8
    public let transparentHearingEnabled: Bool
    public let eqConfig: MomentumEqConfig
    public let eqBands: [MomentumEqBand]
    public let bassBoostEnabled: Bool

    public init(
        soundMode: MomentumSoundMode = .equalizer,
        ancEnabled: Bool,
        ancModes: MomentumAncModes,
        transparencyLevel: UInt8,
        transparentHearingEnabled: Bool,
        eqConfig: MomentumEqConfig,
        eqBands: [MomentumEqBand],
        bassBoostEnabled: Bool
    ) {
        self.soundMode = soundMode
        self.ancEnabled = ancEnabled
        self.ancModes = ancModes
        self.transparencyLevel = transparencyLevel
        self.transparentHearingEnabled = transparentHearingEnabled
        self.eqConfig = eqConfig
        self.eqBands = eqBands
        self.bassBoostEnabled = bassBoostEnabled
    }
}

public struct MomentumControlWrite: Equatable, Sendable {
    public let command: UInt16
    public let payload: Data

    public init(command: UInt16, payload: Data) {
        self.command = command
        self.payload = payload
    }
}

public struct MomentumEQPreset: Equatable, Identifiable, Sendable {
    public let name: String
    public let gainsDB: [Double]
    public var id: String { name }

    public init(name: String, gainsDB: [Double]) {
        self.name = name
        self.gainsDB = gainsDB
    }

    public static let momentum4FiveBand: [MomentumEQPreset] = [
        MomentumEQPreset(name: "Rock", gainsDB: [0, 2, 2.5, 1.5, -2]),
        MomentumEQPreset(name: "Pop", gainsDB: [0, -2.5, 0, 2.5, 0]),
        MomentumEQPreset(name: "Dance", gainsDB: [3.5, 2, -1.5, 1.5, 3]),
        MomentumEQPreset(name: "Hip Hop", gainsDB: [3, 1.5, -1.5, 0, -1.5]),
        MomentumEQPreset(name: "Classical", gainsDB: [-2, -1.5, 0, 3.5, 4]),
        MomentumEQPreset(name: "Movie", gainsDB: [0, 0, 2, 2, -2]),
        MomentumEQPreset(name: "Jazz", gainsDB: [-3.2, 0, 2.2, 2.2, 0])
    ]

    public static func available(forBandCount count: Int) -> [MomentumEQPreset] {
        count == 5 ? momentum4FiveBand : []
    }
}

public struct MomentumUserEQProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let gainsDB: [Double]

    public init(id: UUID = UUID(), name: String, gainsDB: [Double]) {
        self.id = id
        self.name = name
        self.gainsDB = gainsDB
    }
}

public struct MomentumEQProfileChoice: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let gainsDB: [Double]
    public let userProfileID: UUID?

    public var isUserDefined: Bool { userProfileID != nil }
}

public enum MomentumUserEQProfileError: Error, Equatable {
    case invalidName
}

public enum MomentumUserEQProfilePolicy {
    public static func saving(
        _ profile: MomentumUserEQProfile,
        in existing: [MomentumUserEQProfile]
    ) throws -> [MomentumUserEQProfile] {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MomentumUserEQProfileError.invalidName }
        let saved = MomentumUserEQProfile(id: profile.id, name: name, gainsDB: profile.gainsDB)
        let others = existing.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        return [saved] + others
    }

    public static func userFirst(
        userProfiles: [MomentumUserEQProfile],
        builtInProfiles: [MomentumEQPreset]
    ) -> [MomentumEQProfileChoice] {
        userProfiles.map {
            MomentumEQProfileChoice(
                id: "user-\($0.id.uuidString)",
                name: $0.name,
                gainsDB: $0.gainsDB,
                userProfileID: $0.id
            )
        } + builtInProfiles.map {
            MomentumEQProfileChoice(
                id: "built-in-\($0.name)",
                name: $0.name,
                gainsDB: $0.gainsDB,
                userProfileID: nil
            )
        }
    }
}

public enum MomentumEQBatchPlan {
    public static func rollbackIndices(successfulWriteCount: Int) -> [Int] {
        guard successfulWriteCount > 0 else { return [] }
        return Array((0..<successfulWriteCount).reversed())
    }

    public static func rollbackFailureIndices(
        attemptedIndices: [Int],
        writeSucceeded: [Bool]
    ) -> [Int] {
        attemptedIndices.enumerated().compactMap { offset, index in
            guard writeSucceeded.indices.contains(offset), writeSucceeded[offset] else {
                return index
            }
            return nil
        }
    }
}

public enum MomentumConnectedParameter {
    public static func parse(_ value: String?) -> Bool? {
        switch value {
        case "0": false
        case "1": true
        default: nil
        }
    }
}

public enum MomentumDeferredWritePolicy {
    public static func acceptsDraft(activeControl: String?, requestedControl: String) -> Bool {
        activeControl == nil || activeControl == requestedControl
    }

    public static func acceptsImmediateAction(activeControl: String?) -> Bool {
        activeControl == nil
    }
}

public enum MomentumControlRecoveryDisposition: Equatable, Sendable {
    case applyAuthoritative
    case keepOptimisticUnknown
}

public enum MomentumControlRecoveryPolicy {
    public static func disposition(hasAuthoritativeSnapshot: Bool) -> MomentumControlRecoveryDisposition {
        hasAuthoritativeSnapshot ? .applyAuthoritative : .keepOptimisticUnknown
    }
}

public enum MomentumLaunchPolicy {
    public static func shouldShowWindow(launchedAsLoginItem: Bool) -> Bool {
        !launchedAsLoginItem
    }

    public static func shouldUseAccessoryActivation(launchedAsLoginItem: Bool) -> Bool {
        true
    }

    public static let shouldKeepDockIconAfterWindowCloses = false
}

public enum MomentumCustomANCLevelPolicy {
    public static func updatedRememberedLevel(
        current: Int?,
        ancEnabled: Bool,
        adaptiveEnabled: Bool,
        reportedLevel: UInt8
    ) -> Int? {
        guard ancEnabled, !adaptiveEnabled else { return current }
        return Int(reportedLevel)
    }

    public static func levelToRestore(remembered: Int?, fallback: Double) -> Int {
        min(100, max(0, remembered ?? Int(fallback.rounded())))
    }
}

public enum MomentumNoiseControlMode: String, CaseIterable, Identifiable, Sendable {
    case adaptive = "Adaptive"
    case custom = "Custom"
    case off = "Off"

    public var id: Self { self }

    public static func resolve(ancEnabled: Bool, adaptiveEnabled: Bool) -> Self {
        guard ancEnabled else { return .off }
        return adaptiveEnabled ? .adaptive : .custom
    }
}

public enum MomentumConnectionIndicatorStyle: Equatable, Sendable {
    case pulsingGreen
    case steadyGreen
    case steadyGray
}

public enum MomentumConnectionIndicatorPolicy {
    public static func style(isSwitching: Bool, isConnected: Bool) -> MomentumConnectionIndicatorStyle {
        if isSwitching { return .pulsingGreen }
        return isConnected ? .steadyGreen : .steadyGray
    }
}

public enum MomentumRefreshPresentationPolicy {
    public static func shouldBlock(hasSnapshot: Bool, hasControls: Bool) -> Bool {
        !hasSnapshot || !hasControls
    }

    public static func shouldRefreshControls(hasControls: Bool) -> Bool {
        !hasControls
    }
}

public enum MomentumControlSyncPolicy {
    public static let pollIntervalSeconds = 5

    public static func shouldApplyReadback(
        startedAtGeneration: Int,
        currentGeneration: Int,
        hasActiveUserOperation: Bool
    ) -> Bool {
        startedAtGeneration == currentGeneration && !hasActiveUserOperation
    }
}

public enum MomentumControlPresentation {
    public static func eqBandLabels(count: Int) -> [String] {
        switch count {
        case 3:
            return ["Bass", "Mid", "Treble"]
        case 5:
            return ["63 Hz", "250 Hz", "1k Hz", "4k Hz", "8k Hz"]
        default:
            return (0..<max(0, count)).map { "Band \($0 + 1)" }
        }
    }

    public static func gains(bandCount: Int, bands: [MomentumEqBand]) -> [Double] {
        let byIndex = Dictionary(uniqueKeysWithValues: bands.map { (Int($0.index), $0.gainDB) })
        return (0..<max(0, bandCount)).map { byIndex[$0] ?? 0 }
    }

    public static func flatGains(bandCount: Int) -> [Double] {
        Array(repeating: 0, count: max(0, bandCount))
    }
}

public enum MomentumControlCodec {
    public static func parseSoundPersonalizationProfileState(
        _ payload: Data
    ) throws -> MomentumSoundPersonalizationProfileState {
        guard payload.count == 1,
              let state = MomentumSoundPersonalizationProfileState(rawValue: payload[0]) else {
            throw MomentumProtocolError.malformedControlPayload(
                command: MomentumCommands.getSoundPersonalizationProfileState
            )
        }
        return state
    }

    public static func parseBluetoothCompatibilityMode(
        _ payload: Data
    ) throws -> MomentumBluetoothCompatibilityMode {
        guard payload.count == 1,
              let mode = MomentumBluetoothCompatibilityMode(rawValue: payload[0]) else {
            throw MomentumProtocolError.malformedControlPayload(
                command: MomentumCommands.getBluetoothCompatibilityMode
            )
        }
        return mode
    }

    public static func encodeAudioMode(_ mode: MomentumSoundMode) -> Data {
        Data([0, mode.rawValue])
    }

    public static func parseSoundMode(_ payload: Data) throws -> MomentumSoundMode {
        guard payload.count == 2, payload[0] == 0,
              let mode = MomentumSoundMode(rawValue: payload[1]) else {
            throw MomentumProtocolError.malformedControlPayload(command: MomentumCommands.getSoundMode)
        }
        return mode
    }

    public static func validateWriteResponse(command: UInt16, response: GaiaPacket) throws {
        let success = command | 0x0100
        let failure = success | 0x0080
        switch response.commandID {
        case success:
            return
        case failure:
            throw MomentumProtocolError.deviceRejected(command: command, status: response.payload.first)
        default:
            throw MomentumProtocolError.unexpectedResponse(response.commandID)
        }
    }

    public static func parseBoolean(_ payload: Data, command: UInt16) throws -> Bool {
        guard let value = payload.first else {
            throw MomentumProtocolError.malformedControlPayload(command: command)
        }
        guard value <= 1 else {
            throw MomentumProtocolError.invalidControlValue(command: command, value: value)
        }
        return value == 1
    }

    public static func encodeBoolean(_ value: Bool) -> Data {
        Data([value ? 1 : 0])
    }

    public static func parseAncModes(_ payload: Data) throws -> MomentumAncModes {
        guard payload.count >= 6, payload.count.isMultiple(of: 2) else {
            throw MomentumProtocolError.malformedControlPayload(command: MomentumCommands.getAncModes)
        }
        var antiWind: MomentumAntiWind?
        var comfort: Bool?
        var adaptive: Bool?
        for offset in stride(from: 0, to: payload.count, by: 2) {
            let mode = payload[offset]
            let state = payload[offset + 1]
            switch mode {
            case MomentumAncMode.antiWind.rawValue:
                guard let parsed = MomentumAntiWind(rawValue: state) else {
                    throw MomentumProtocolError.invalidControlValue(command: MomentumCommands.getAncModes, value: state)
                }
                antiWind = parsed
            case MomentumAncMode.comfort.rawValue:
                guard state <= 1 else {
                    throw MomentumProtocolError.invalidControlValue(command: MomentumCommands.getAncModes, value: state)
                }
                comfort = state == 1
            case MomentumAncMode.adaptive.rawValue:
                guard state <= 1 else {
                    throw MomentumProtocolError.invalidControlValue(command: MomentumCommands.getAncModes, value: state)
                }
                adaptive = state == 1
            default:
                continue
            }
        }
        guard let antiWind, let comfort, let adaptive else {
            throw MomentumProtocolError.malformedControlPayload(command: MomentumCommands.getAncModes)
        }
        return MomentumAncModes(antiWind: antiWind, comfortEnabled: comfort, adaptiveEnabled: adaptive)
    }

    public static func encodeAncMode(_ mode: MomentumAncMode, state: UInt8) throws -> Data {
        switch mode {
        case .antiWind:
            guard MomentumAntiWind(rawValue: state) != nil else {
                throw MomentumProtocolError.invalidControlValue(command: MomentumCommands.setAncMode, value: state)
            }
        case .comfort, .adaptive:
            guard state <= 1 else {
                throw MomentumProtocolError.invalidControlValue(command: MomentumCommands.setAncMode, value: state)
            }
        }
        return Data([mode.rawValue, state])
    }

    public static func parseTransparencyLevel(_ payload: Data) throws -> UInt8 {
        guard let level = payload.first else {
            throw MomentumProtocolError.malformedControlPayload(command: MomentumCommands.getTransparencyLevel)
        }
        guard level <= 100 else {
            throw MomentumProtocolError.invalidControlValue(command: MomentumCommands.getTransparencyLevel, value: level)
        }
        return level
    }

    public static func encodeTransparencyLevel(_ level: Int) -> Data {
        Data([UInt8(min(100, max(0, level)))])
    }

    public static func parseEqConfig(_ payload: Data) throws -> MomentumEqConfig {
        guard payload.count >= 3, payload[0] > 0 else {
            throw MomentumProtocolError.malformedControlPayload(command: MomentumCommands.getEqConfig)
        }
        let minimum = Double(Int8(bitPattern: payload[1])) / 10
        let maximum = Double(Int8(bitPattern: payload[2])) / 10
        guard minimum <= maximum else {
            throw MomentumProtocolError.malformedControlPayload(command: MomentumCommands.getEqConfig)
        }
        return MomentumEqConfig(bandCount: payload[0], minimumGainDB: minimum, maximumGainDB: maximum)
    }

    public static func parseEqBand(_ payload: Data, requestedBand: UInt8) throws -> MomentumEqBand {
        guard !payload.isEmpty else {
            throw MomentumProtocolError.malformedControlPayload(command: MomentumCommands.getEqBand)
        }
        let rawGain: UInt8
        if payload.count >= 2 {
            guard payload[0] == requestedBand else {
                throw MomentumProtocolError.invalidControlValue(command: MomentumCommands.getEqBand, value: payload[0])
            }
            rawGain = payload[1]
        } else {
            rawGain = payload[0]
        }
        return MomentumEqBand(index: requestedBand, gainDB: Double(Int8(bitPattern: rawGain)) / 10)
    }

    public static func encodeEqBand(index: UInt8, gainDB: Double, config: MomentumEqConfig) throws -> Data {
        guard index < config.bandCount else { throw MomentumProtocolError.invalidEqBand(index) }
        guard gainDB.isFinite else { throw MomentumProtocolError.invalidEqGain(gainDB) }
        let clamped = min(config.maximumGainDB, max(config.minimumGainDB, gainDB))
        let tenths = Int((clamped * 10).rounded())
        guard tenths >= Int(Int8.min), tenths <= Int(Int8.max) else {
            throw MomentumProtocolError.invalidEqGain(gainDB)
        }
        return Data([index, UInt8(bitPattern: Int8(tenths))])
    }
}

public enum MomentumControlPlan {
    public static let customMode: [MomentumControlWrite] = [
        MomentumControlWrite(command: MomentumCommands.setTransparentHearing, payload: MomentumControlCodec.encodeBoolean(false)),
        MomentumControlWrite(command: MomentumCommands.setAncEnabled, payload: MomentumControlCodec.encodeBoolean(true)),
        MomentumControlWrite(command: MomentumCommands.setAncMode, payload: Data([MomentumAncMode.adaptive.rawValue, 0]))
    ]

    public static func customModeRestoring(level: Int) -> [MomentumControlWrite] {
        customMode + [
            MomentumControlWrite(
                command: MomentumCommands.setTransparencyLevel,
                payload: MomentumControlCodec.encodeTransparencyLevel(level)
            )
        ]
    }

    public static func transparency(level: Int) -> [MomentumControlWrite] {
        [
            MomentumControlWrite(command: MomentumCommands.setAncMode, payload: Data([MomentumAncMode.adaptive.rawValue, 0])),
            MomentumControlWrite(command: MomentumCommands.setTransparencyLevel, payload: MomentumControlCodec.encodeTransparencyLevel(level))
        ]
    }
}
