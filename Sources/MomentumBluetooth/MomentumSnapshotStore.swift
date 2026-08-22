import Darwin
import Foundation

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

public enum MomentumSnapshotStore {
    private static var userHomeURL: URL {
        if let account = getpwuid(getuid()), let home = account.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static var directoryURL: URL {
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
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        let data = try JSONEncoder().encode(state)
        let destination = directory.appendingPathComponent("snapshot.json")
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: destination.path
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
