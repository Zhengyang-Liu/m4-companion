import Darwin
import Foundation

@_silgen_name("notify_post")
private func systemNotifyPost(_ name: UnsafePointer<CChar>) -> UInt32

@_silgen_name("notify_register_dispatch")
private func systemNotifyRegisterDispatch(
    _ name: UnsafePointer<CChar>,
    _ outToken: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping @convention(block) (Int32) -> Void
) -> UInt32

@_silgen_name("notify_cancel")
private func systemNotifyCancel(_ token: Int32) -> UInt32

public struct MomentumWidgetState: Codable, Equatable, Sendable {
    public let snapshot: MomentumSnapshot
    public let switchingDeviceIndex: UInt8?
    public let actionToken: String?

    public init(
        snapshot: MomentumSnapshot,
        switchingDeviceIndex: UInt8? = nil,
        actionToken: String? = nil
    ) {
        self.snapshot = snapshot
        self.switchingDeviceIndex = switchingDeviceIndex
        self.actionToken = actionToken
    }
}

public enum MomentumActionCapability {
    public static func generate() -> String {
        UUID().uuidString + UUID().uuidString
    }

    public static func isWellFormed(_ token: String?) -> Bool {
        guard let token, token.count == 72 else { return false }
        let split = token.index(token.startIndex, offsetBy: 36)
        return UUID(uuidString: String(token[..<split])) != nil
            && UUID(uuidString: String(token[split...])) != nil
    }

    public static func isValid(presented: String?, expected: String) -> Bool {
        guard isWellFormed(presented),
              isWellFormed(expected),
              let presented,
              presented.utf8.count == expected.utf8.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(presented.utf8, expected.utf8) {
            difference |= lhs ^ rhs
        }
        return difference == 0
    }
}

public struct MomentumWidgetActionRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let deviceIndex: UInt8
    public let expectedName: String
    public let desiredConnected: Bool
    public let actionToken: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        deviceIndex: UInt8,
        expectedName: String,
        desiredConnected: Bool,
        actionToken: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.deviceIndex = deviceIndex
        self.expectedName = expectedName
        self.desiredConnected = desiredConnected
        self.actionToken = actionToken
    }
}

public enum MomentumWidgetActionValidator {
    public static let maximumAge: TimeInterval = 30
    public static let futureTolerance: TimeInterval = 5

    public static func isAuthorized(
        _ request: MomentumWidgetActionRequest,
        expectedToken: String,
        snapshot: MomentumSnapshot,
        now: Date = Date()
    ) -> Bool {
        guard MomentumActionCapability.isValid(
            presented: request.actionToken,
            expected: expectedToken
        ) else { return false }
        let age = now.timeIntervalSince(request.createdAt)
        guard age >= -futureTolerance, age <= maximumAge,
              request.deviceIndex != snapshot.ownIndex,
              !request.expectedName.isEmpty,
              request.expectedName.utf8.count <= 255,
              let device = snapshot.devices.first(where: { $0.index == request.deviceIndex }),
              device.name == request.expectedName else {
            return false
        }
        return true
    }
}

public enum MomentumWidgetActionNotificationError: Error {
    case registrationFailed(UInt32)
}

public enum MomentumWidgetActionNotification {
    public static let name = "com.zhengyangliu.MomentumDeviceSwitcher.widgetAction"

    @discardableResult
    public static func post() -> Bool {
        name.withCString { systemNotifyPost($0) == 0 }
    }

    public static func observe(
        on queue: DispatchQueue,
        handler: @escaping () -> Void
    ) throws -> Int32 {
        var token: Int32 = 0
        let status = name.withCString { pointer in
            systemNotifyRegisterDispatch(pointer, &token, queue) { _ in handler() }
        }
        guard status == 0 else {
            throw MomentumWidgetActionNotificationError.registrationFailed(status)
        }
        return token
    }

    public static func cancel(_ token: Int32) {
        _ = systemNotifyCancel(token)
    }
}

public enum MomentumWidgetActionStore {
    private static let queueName = "widget-actions"
    private static let readyPrefix = "ready-"
    private static let processingPrefix = "processing-"
    private static let maximumRequestBytes = 16 * 1024

    public static var directoryURL: URL {
        directoryURL(in: MomentumSnapshotStore.directoryURL)
    }

    public static func directoryURL(in directory: URL) -> URL {
        directory.appendingPathComponent(queueName, isDirectory: true)
    }

    @discardableResult
    public static func prepareDirectory(in directory: URL = MomentumSnapshotStore.directoryURL) throws -> URL {
        let queue = directoryURL(in: directory)
        try MomentumSnapshotStore.prepareDirectory(directory)
        try MomentumSnapshotStore.prepareDirectory(queue)
        return queue
    }

    public static func readyFileURL(for id: UUID, in directory: URL) -> URL {
        directoryURL(in: directory)
            .appendingPathComponent("\(readyPrefix)\(id.uuidString).json")
    }

    public static func enqueue(_ request: MomentumWidgetActionRequest) throws {
        try enqueue(request, in: MomentumSnapshotStore.directoryURL)
    }

    public static func enqueue(_ request: MomentumWidgetActionRequest, in directory: URL) throws {
        let queue = directoryURL(in: directory)
        try MomentumSnapshotStore.prepareDirectory(directory)
        try MomentumSnapshotStore.prepareDirectory(queue)
        let temporary = queue.appendingPathComponent(".\(request.id.uuidString).tmp")
        let destination = readyFileURL(for: request.id, in: directory)
        let data = try JSONEncoder().encode(request)
        guard data.count <= maximumRequestBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: temporary.path
        )
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: destination.path
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public static func hasPendingRequests() -> Bool {
        hasPendingRequests(in: MomentumSnapshotStore.directoryURL)
    }

    public static func hasPendingRequests(in directory: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL(in: directory),
            includingPropertiesForKeys: nil
        ) else { return false }
        return files.contains { $0.lastPathComponent.hasPrefix(readyPrefix) }
    }

    public static func claimNextAuthorized(
        expectedToken: String,
        snapshot: MomentumSnapshot,
        now: Date = Date()
    ) throws -> MomentumWidgetActionRequest? {
        try claimNextAuthorized(
            expectedToken: expectedToken,
            snapshot: snapshot,
            now: now,
            from: MomentumSnapshotStore.directoryURL
        )
    }

    public static func claimNextAuthorized(
        expectedToken: String,
        snapshot: MomentumSnapshot,
        now: Date = Date(),
        from directory: URL
    ) throws -> MomentumWidgetActionRequest? {
        let queue = directoryURL(in: directory)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: queue,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for source in files
            .filter({ $0.lastPathComponent.hasPrefix(readyPrefix) && $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let processing = queue.appendingPathComponent(
                source.lastPathComponent.replacingOccurrences(
                    of: readyPrefix,
                    with: processingPrefix,
                    options: [.anchored]
                )
            )
            do {
                try FileManager.default.moveItem(at: source, to: processing)
            } catch {
                continue
            }
            defer { try? FileManager.default.removeItem(at: processing) }

            let values = try processing.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let data = try Data(contentsOf: processing, options: [.mappedIfSafe])
            guard data.count <= maximumRequestBytes,
                  let request = try? JSONDecoder().decode(MomentumWidgetActionRequest.self, from: data),
                  MomentumWidgetActionValidator.isAuthorized(
                      request,
                      expectedToken: expectedToken,
                      snapshot: snapshot,
                      now: now
                  ) else {
                continue
            }
            return request
        }
        return nil
    }
}

public final class MomentumWidgetActionQueueWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let fileDescriptor: Int32

    public init(
        directory: URL = MomentumSnapshotStore.directoryURL,
        queue: DispatchQueue = .main,
        handler: @escaping @Sendable () -> Void
    ) throws {
        let watchedDirectory = try MomentumWidgetActionStore.prepareDirectory(in: directory)
        let descriptor = open(watchedDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        fileDescriptor = descriptor
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    public func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}

public enum MomentumSnapshotStore {
    private static var userHomeURL: URL {
        if let account = getpwuid(getuid()), let home = account.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var directoryURL: URL {
        userHomeURL
            .appendingPathComponent("Library/Application Support/MomentumDeviceSwitcher", isDirectory: true)
    }

    public static var fileURL: URL {
        directoryURL.appendingPathComponent("snapshot.json")
    }

    public static func save(_ snapshot: MomentumSnapshot) throws {
        try save(MomentumWidgetState(snapshot: snapshot))
    }

    public static func save(_ state: MomentumWidgetState) throws {
        try save(state, in: directoryURL)
    }

    public static func save(_ state: MomentumWidgetState, in directory: URL) throws {
        try prepareDirectory(directory)
        let data = try JSONEncoder().encode(state)
        let destination = directory.appendingPathComponent("snapshot.json")
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: destination.path
        )
    }

    static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
    }

    public static func loadState() throws -> MomentumWidgetState {
        try loadState(from: directoryURL)
    }

    public static func loadState(from directory: URL) throws -> MomentumWidgetState {
        let data = try Data(contentsOf: directory.appendingPathComponent("snapshot.json"))
        if let state = try? JSONDecoder().decode(MomentumWidgetState.self, from: data) {
            return state
        }
        let legacySnapshot = try JSONDecoder().decode(MomentumSnapshot.self, from: data)
        return MomentumWidgetState(snapshot: legacySnapshot)
    }

    public static func load() throws -> MomentumSnapshot {
        try loadState().snapshot
    }
}
