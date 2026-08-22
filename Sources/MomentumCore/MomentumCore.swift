import Foundation

public struct GaiaPacket: Equatable, Sendable {
    public let vendorID: UInt16
    public let commandID: UInt16
    public let payload: Data

    public init(vendorID: UInt16, commandID: UInt16, payload: Data = Data()) {
        self.vendorID = vendorID
        self.commandID = commandID
        self.payload = payload
    }

    public init(data: Data) throws {
        guard data.count >= 4 else { throw MomentumProtocolError.packetTooShort }
        vendorID = UInt16(data[0]) << 8 | UInt16(data[1])
        commandID = UInt16(data[2]) << 8 | UInt16(data[3])
        payload = Data(data.dropFirst(4))
    }

    public var data: Data {
        Data([
            UInt8(vendorID >> 8), UInt8(vendorID & 0xff),
            UInt8(commandID >> 8), UInt8(commandID & 0xff)
        ]) + payload
    }
}

public enum MomentumProtocolError: LocalizedError, Equatable {
    case packetTooShort
    case payloadTooLarge
    case invalidDeviceCount(Int)
    case invalidBatteryPercentage(UInt8)
    case malformedDeviceInfo
    case deviceIdentityChanged
    case unexpectedResponse(UInt16)
    case deviceRejected(command: UInt16, status: UInt8?)
    case malformedControlPayload(command: UInt16)
    case invalidControlValue(command: UInt16, value: UInt8)
    case invalidEqBand(UInt8)
    case invalidEqGain(Double)

    public var errorDescription: String? {
        switch self {
        case .packetTooShort:
            return "GAIA3 packet is shorter than four bytes."
        case .payloadTooLarge:
            return "GAIA3 payload exceeds the RFCOMM frame limit."
        case let .invalidDeviceCount(count):
            return "The headphones returned an invalid paired-device count (\(count))."
        case let .invalidBatteryPercentage(value):
            return "The headphones returned an invalid battery percentage (\(value))."
        case .malformedDeviceInfo:
            return "The headphones returned malformed device information."
        case .deviceIdentityChanged:
            return "The selected paired-device entry changed; refresh and try again."
        case let .unexpectedResponse(command):
            return "Unexpected GAIA3 response 0x\(String(command, radix: 16))."
        case let .deviceRejected(command, status):
            var message = "The headphones rejected command 0x\(String(command, radix: 16))"
            if let status { message += " (status \(status))" }
            return message + "."
        case let .malformedControlPayload(command):
            return "The headphones returned malformed control data for command 0x\(String(command, radix: 16))."
        case let .invalidControlValue(command, value):
            return "The headphones returned invalid value \(value) for command 0x\(String(command, radix: 16))."
        case let .invalidEqBand(band):
            return "Equalizer band \(band) is outside the device's supported range."
        case let .invalidEqGain(gain):
            return "Equalizer gain \(gain) dB cannot be represented by the device."
        }
    }
}

public struct MomentumDevice: Identifiable, Equatable, Codable, Sendable {
    public let index: UInt8
    public let priority: UInt8
    public let isConnected: Bool
    public let name: String

    public var id: UInt8 { index }

    public init(index: UInt8, priority: UInt8, isConnected: Bool, name: String) {
        self.index = index
        self.priority = priority
        self.isConnected = isConnected
        self.name = name
    }

    public init(response: GaiaPacket) throws {
        guard response.commandID == MomentumCommands.deviceInfoResponse else {
            throw MomentumProtocolError.unexpectedResponse(response.commandID)
        }
        guard response.payload.count >= 3 else {
            throw MomentumProtocolError.malformedDeviceInfo
        }
        index = response.payload[0]
        priority = response.payload[1]
        isConnected = response.payload[2] != 0
        let nameBytes = response.payload.dropFirst(3).prefix { $0 != 0 }
        name = String(decoding: nameBytes, as: UTF8.self)
    }
}

public enum PairedDeviceList {
    public static let maximumSaneCount = 64

    public static func displayOrder(_ devices: [MomentumDevice], ownIndex: UInt8) -> [MomentumDevice] {
        devices.sorted { lhs, rhs in
            if lhs.index == ownIndex { return true }
            if rhs.index == ownIndex { return false }
            return lhs.index < rhs.index
        }
    }

    public static func parseCount(_ payload: Data) throws -> Int {
        guard payload.count >= 2 else { throw MomentumProtocolError.malformedDeviceInfo }
        let count = Int(UInt16(payload[0]) << 8 | UInt16(payload[1]))
        guard count <= maximumSaneCount else {
            throw MomentumProtocolError.invalidDeviceCount(count)
        }
        return count
    }
}

public enum ConnectionStatus {
    public static func parse(_ payload: Data, expectedIndex: UInt8) throws -> Bool {
        guard payload.count >= 2,
              payload[payload.startIndex] == expectedIndex else {
            throw MomentumProtocolError.malformedDeviceInfo
        }
        return payload[payload.index(after: payload.startIndex)] != 0
    }
}

public enum BatteryLevel {
    public static func parse(_ payload: Data) throws -> UInt8 {
        guard let value = payload.first else { throw MomentumProtocolError.packetTooShort }
        guard value <= 100 else { throw MomentumProtocolError.invalidBatteryPercentage(value) }
        return value
    }

    @MainActor
    public static func bestEffortQuery(
        _ operation: () async throws -> UInt8
    ) async throws -> UInt8? {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}

public enum GaiaSPP {
    public static func frame(_ gaiaPacket: Data) throws -> Data {
        guard gaiaPacket.count >= 4 else { throw MomentumProtocolError.packetTooShort }
        let payloadLength = gaiaPacket.count - 4
        guard payloadLength <= Int(UInt16.max) else { throw MomentumProtocolError.payloadTooLarge }
        return Data([
            0xff, 0x03,
            UInt8((payloadLength >> 8) & 0xff),
            UInt8(payloadLength & 0xff)
        ]) + gaiaPacket
    }
}

public struct GaiaSPPDeframer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func ingest(_ incoming: Data) -> [Data] {
        buffer.append(incoming)
        var packets: [Data] = []
        while true {
            while buffer.count >= 2 {
                let first = buffer.startIndex
                let second = buffer.index(after: first)
                guard buffer[first] != 0xff || buffer[second] != 0x03 else { break }
                buffer.removeFirst()
            }
            guard buffer.count >= 4 else { break }
            let start = buffer.startIndex
            let lengthHigh = buffer[buffer.index(start, offsetBy: 2)]
            let lengthLow = buffer[buffer.index(start, offsetBy: 3)]
            let payloadLength = Int(lengthHigh) << 8 | Int(lengthLow)
            let frameLength = 8 + payloadLength
            guard buffer.count >= frameLength else { break }
            let packetStart = buffer.index(start, offsetBy: 4)
            let packetEnd = buffer.index(start, offsetBy: frameLength)
            packets.append(Data(buffer[packetStart..<packetEnd]))
            buffer.removeFirst(frameLength)
        }
        return packets
    }
}

public enum SwitchPlanningError: LocalizedError, Equatable {
    case ownDeviceMissing
    case targetDeviceMissing
    case ownDeviceNotConnected
    case insufficientConnectionSlots

    public var errorDescription: String? {
        switch self {
        case .ownDeviceMissing: return "This Mac is missing from the headphones' paired-device list."
        case .targetDeviceMissing: return "The selected device is no longer paired."
        case .ownDeviceNotConnected: return "This Mac must remain connected while switching devices."
        case .insufficientConnectionSlots: return "The headphones do not support two simultaneous connections."
        }
    }
}

public struct SwitchPlan: Equatable, Sendable {
    public let disconnectIndices: [UInt8]
    public let connectIndex: UInt8?
}

public enum SwitchPlanner {
    public static func plan(
        devices: [MomentumDevice],
        ownIndex: UInt8,
        targetIndex: UInt8,
        maxConnections: UInt8
    ) throws -> SwitchPlan {
        guard maxConnections >= 2 else { throw SwitchPlanningError.insufficientConnectionSlots }
        guard let own = devices.first(where: { $0.index == ownIndex }) else {
            throw SwitchPlanningError.ownDeviceMissing
        }
        guard own.isConnected else { throw SwitchPlanningError.ownDeviceNotConnected }
        guard let target = devices.first(where: { $0.index == targetIndex }) else {
            throw SwitchPlanningError.targetDeviceMissing
        }
        if target.index == ownIndex || target.isConnected {
            return SwitchPlan(disconnectIndices: [], connectIndex: nil)
        }
        let disconnect = devices
            .filter { $0.isConnected && $0.index != ownIndex && $0.index != targetIndex }
            .map(\.index)
            .sorted()
        return SwitchPlan(disconnectIndices: disconnect, connectIndex: targetIndex)
    }
}

public enum ConnectionAttemptPolicy {
    @MainActor
    public static func connect(
        maximumAttempts: Int,
        pollsPerAttempt: Int,
        sendConnect: () async throws -> Void,
        pollConnected: () async throws -> Bool
    ) async throws -> Bool {
        precondition(maximumAttempts > 0 && pollsPerAttempt > 0)
        var lastCommandError: Error?
        for _ in 0..<maximumAttempts {
            do {
                try await sendConnect()
                lastCommandError = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastCommandError = error
            }
            for _ in 0..<pollsPerAttempt {
                if try await pollConnected() { return true }
            }
        }
        if let lastCommandError { throw lastCommandError }
        return false
    }
}

public enum MomentumCommands {
    public static let vendorID: UInt16 = 0x0495
    public static let listSize: UInt16 = 0x1400
    public static let listSizeResponse: UInt16 = 0x1500
    public static let deviceInfo: UInt16 = 0x1401
    public static let deviceInfoResponse: UInt16 = 0x1501
    public static let battery: UInt16 = 0x0603
    public static let batteryResponse: UInt16 = 0x0703
    public static let connectionStatus: UInt16 = 0x1404
    public static let connectionStatusResponse: UInt16 = 0x1504
    public static let connect: UInt16 = 0x1402
    public static let connectResponse: UInt16 = 0x1502
    public static let connectError: UInt16 = 0x1582
    public static let disconnect: UInt16 = 0x1403
    public static let disconnectResponse: UInt16 = 0x1503
    public static let ownIndex: UInt16 = 0x1407
    public static let ownIndexResponse: UInt16 = 0x1507
    public static let maxConnections: UInt16 = 0x1409
    public static let maxConnectionsResponse: UInt16 = 0x1509

    public static let setAncMode: UInt16 = 0x1a00
    public static let setAncModeResponse: UInt16 = 0x1b00
    public static let getAncModes: UInt16 = 0x1a01
    public static let getAncModesResponse: UInt16 = 0x1b01
    public static let setTransparencyLevel: UInt16 = 0x1a02
    public static let setTransparencyLevelResponse: UInt16 = 0x1b02
    public static let getTransparencyLevel: UInt16 = 0x1a03
    public static let getTransparencyLevelResponse: UInt16 = 0x1b03
    public static let setAncEnabled: UInt16 = 0x1a04
    public static let setAncEnabledResponse: UInt16 = 0x1b04
    public static let getAncEnabled: UInt16 = 0x1a05
    public static let getAncEnabledResponse: UInt16 = 0x1b05

    public static let setTransparentHearing: UInt16 = 0x1804
    public static let setTransparentHearingResponse: UInt16 = 0x1904
    public static let getTransparentHearing: UInt16 = 0x1805
    public static let getTransparentHearingResponse: UInt16 = 0x1905

    public static let getEqConfig: UInt16 = 0x1000
    public static let getEqConfigResponse: UInt16 = 0x1100
    public static let setEqBand: UInt16 = 0x1001
    public static let setEqBandResponse: UInt16 = 0x1101
    public static let getEqBand: UInt16 = 0x1002
    public static let getEqBandResponse: UInt16 = 0x1102
    public static let setBassBoost: UInt16 = 0x1008
    public static let setBassBoostResponse: UInt16 = 0x1108
    public static let getBassBoost: UInt16 = 0x1009
    public static let getBassBoostResponse: UInt16 = 0x1109
}
