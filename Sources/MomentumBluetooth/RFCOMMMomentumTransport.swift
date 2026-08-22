import Foundation
@preconcurrency import IOBluetooth
import MomentumCore

public enum MomentumBluetoothError: LocalizedError {
    case headsetNotPaired
    case ambiguousHeadsets
    case serviceUnavailable
    case connectionTimedOut
    case rfcommFailure(IOReturn)
    case notConnected
    case responseTimedOut(UInt16)
    case switchFailed(String)
    case eqBatchRollbackFailed(original: String, failedBands: [Int])

    public var errorDescription: String? {
        switch self {
        case .headsetNotPaired: return "MOMENTUM 4 is not paired with this Mac."
        case .ambiguousHeadsets: return "Multiple MOMENTUM 4 headsets match. Disconnect all but one and try again."
        case .serviceUnavailable: return "The MOMENTUM 4 GAIA control service is unavailable."
        case .connectionTimedOut: return "Timed out opening the MOMENTUM 4 control channel."
        case let .rfcommFailure(status): return String(format: "Bluetooth RFCOMM failed (0x%08x).", UInt32(bitPattern: status))
        case .notConnected: return "The MOMENTUM 4 control channel is not connected."
        case let .responseTimedOut(command): return "The headphones did not answer command 0x\(String(command, radix: 16))."
        case let .switchFailed(message): return message
        case let .eqBatchRollbackFailed(original, failedBands):
            return "EQ update failed (\(original)); rollback also failed for bands \(failedBands.map { String($0 + 1) }.joined(separator: ", ")). The headphones may be in a partial state."
        }
    }
}

public struct MomentumHeadsetCandidate: Sendable {
    public let address: String
    public let isConnected: Bool

    public init(address: String, isConnected: Bool) {
        self.address = address
        self.isConnected = isConnected
    }
}

public enum MomentumHeadsetAddressResolver {
    public static func resolve(_ candidates: [MomentumHeadsetCandidate]) throws -> String {
        guard candidates.count <= 1 else {
            throw MomentumBluetoothError.ambiguousHeadsets
        }
        guard let candidate = candidates.first else {
            throw MomentumBluetoothError.headsetNotPaired
        }
        return candidate.address
    }
}

@MainActor
final class RFCOMMMomentumTransport: NSObject, @preconcurrency IOBluetoothRFCOMMChannelDelegate {
    var onPacket: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let expectedAddress: String?

    private static let serviceBytes: [UInt8] = [
        0xa2, 0x12, 0x9f, 0xf3, 0x08, 0x1b, 0x4c, 0x45,
        0x8a, 0xfe, 0x46, 0x9d, 0x9c, 0x48, 0x42, 0xec
    ]

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var deframer = GaiaSPPDeframer()
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(expectedAddress: String? = nil) {
        self.expectedAddress = expectedAddress
        super.init()
    }

    var isConnected: Bool { channel?.isOpen() == true }

    static func resolveHeadsetAddress(expectedAddress: String? = nil) throws -> String {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            throw MomentumBluetoothError.headsetNotPaired
        }
        let matching = devices.filter { $0.name?.localizedCaseInsensitiveContains("MOMENTUM 4") == true }
        if let expectedAddress {
            guard let match = matching.first(where: {
                normalizedAddress($0.addressString) == normalizedAddress(expectedAddress)
            }), let address = match.addressString else {
                throw MomentumBluetoothError.headsetNotPaired
            }
            return address
        }
        return try MomentumHeadsetAddressResolver.resolve(matching.compactMap { device in
            guard let address = device.addressString else { return nil }
            return MomentumHeadsetCandidate(address: address, isConnected: device.isConnected())
        })
    }

    func connect() async throws {
        if isConnected { return }
        let resolvedAddress = try Self.resolveHeadsetAddress(expectedAddress: expectedAddress)
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            throw MomentumBluetoothError.headsetNotPaired
        }
        let device = devices.first {
            Self.normalizedAddress($0.addressString) == Self.normalizedAddress(resolvedAddress)
        }
        guard let device else {
            throw MomentumBluetoothError.headsetNotPaired
        }
        self.device = device
        let uuid = Self.serviceUUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    self?.finishConnection(.failure(MomentumBluetoothError.connectionTimedOut))
                }

                if let record = device.getServiceRecord(for: uuid) {
                    openChannel(device: device, record: record)
                } else {
                    let status = device.performSDPQuery(self, uuids: [uuid])
                    if status != kIOReturnSuccess {
                        finishConnection(.failure(MomentumBluetoothError.rfcommFailure(status)))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishConnection(.failure(CancellationError()))
            }
        }
    }

    func send(_ packet: Data) throws {
        guard let channel, channel.isOpen() else { throw MomentumBluetoothError.notConnected }
        let frame = try GaiaSPP.frame(packet)
        let status = frame.withUnsafeBytes { bytes in
            channel.writeSync(
                UnsafeMutableRawPointer(mutating: bytes.baseAddress),
                length: UInt16(bytes.count)
            )
        }
        guard status == kIOReturnSuccess else { throw MomentumBluetoothError.rfcommFailure(status) }
    }

    func disconnect() {
        timeoutTask?.cancel()
        timeoutTask = nil
        closeChannel()
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    @objc func sdpQueryComplete(_ remoteDevice: IOBluetoothDevice, status: IOReturn) {
        guard continuation != nil else { return }
        guard status == kIOReturnSuccess,
              let record = remoteDevice.getServiceRecord(for: Self.serviceUUID()) else {
            finishConnection(.failure(MomentumBluetoothError.serviceUnavailable))
            return
        }
        openChannel(device: remoteDevice, record: record)
    }

    private func openChannel(device: IOBluetoothDevice, record: IOBluetoothSDPServiceRecord) {
        guard continuation != nil else { return }
        var channelID = BluetoothRFCOMMChannelID()
        let channelStatus = record.getRFCOMMChannelID(&channelID)
        guard channelStatus == kIOReturnSuccess else {
            finishConnection(.failure(MomentumBluetoothError.rfcommFailure(channelStatus)))
            return
        }
        var opened: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        guard status == kIOReturnSuccess else {
            finishConnection(.failure(MomentumBluetoothError.rfcommFailure(status)))
            return
        }
        channel = opened
    }

    @objc func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel, status: IOReturn) {
        guard continuation != nil else {
            rfcommChannel.close()
            return
        }
        guard status == kIOReturnSuccess else {
            finishConnection(.failure(MomentumBluetoothError.rfcommFailure(status)))
            return
        }
        channel = rfcommChannel
        finishConnection(.success(()))
    }

    @objc func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel,
        data pointer: UnsafeMutableRawPointer,
        length: Int
    ) {
        for packet in deframer.ingest(Data(bytes: pointer, count: length)) {
            onPacket?(packet)
        }
    }

    @objc func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel) {
        channel = nil
        device = nil
        onClose?()
    }

    private func finishConnection(_ result: Result<Void, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if case .failure = result { closeChannel() }
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success: continuation.resume()
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    private func closeChannel() {
        if let channel, channel.isOpen() { channel.close() }
        channel = nil
        device = nil
    }

    private static func normalizedAddress(_ address: String) -> String {
        String(address.lowercased().filter(\.isHexDigit))
    }

    private static func serviceUUID() -> IOBluetoothSDPUUID {
        serviceBytes.withUnsafeBytes { bytes in
            IOBluetoothSDPUUID(bytes: bytes.baseAddress!, length: bytes.count)
        }
    }
}
