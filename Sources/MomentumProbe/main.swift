import Foundation
import MomentumBluetooth
import MomentumCore

@main
struct MomentumProbe {
    @MainActor
    static func main() async {
        do {
            let client = MomentumHeadsetClient()
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["controls"] {
                let controls = try await client.controlsSnapshot()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(controls), as: UTF8.self))
                return
            }
            if arguments == ["set-antiwind-auto"] {
                let controls = try await client.setAntiWind(.automatic)
                print("external change: antiWind=\(controls.ancModes.antiWind.rawValue)")
                return
            }
            if arguments == ["restore-controls"] {
                var controls = try await client.setAntiWind(.maximum)
                controls = try await client.setBassBoost(true)
                print("restored controls: antiWind=\(controls.ancModes.antiWind.rawValue) bassBoost=\(controls.bassBoostEnabled)")
                return
            }
            if arguments == ["verify-controls"] {
                var controls = try await client.controlsSnapshot()
                controls = try await client.setAncEnabled(controls.ancEnabled)
                controls = try await client.setAdaptiveEnabled(controls.ancModes.adaptiveEnabled)
                controls = try await client.setAntiWind(controls.ancModes.antiWind)
                if let firstBand = controls.eqBands.first {
                    controls = try await client.setEqBand(index: firstBand.index, gainDB: firstBand.gainDB)
                }
                controls = try await client.setBassBoost(controls.bassBoostEnabled)
                print("verified controls: ANC=\(controls.ancEnabled) adaptive=\(controls.ancModes.adaptiveEnabled) antiWind=\(controls.ancModes.antiWind.rawValue) EQ=\(controls.eqBands.count) bassBoost=\(controls.bassBoostEnabled)")
                return
            }

            let snapshot: MomentumSnapshot
            if arguments.count == 2, arguments[0] == "switch", let index = UInt8(arguments[1]) {
                snapshot = try await client.switchPeer(to: index)
            } else {
                snapshot = try await client.snapshot()
            }
            precondition(snapshot.maxConnections == 2)
            precondition(snapshot.devices.contains(where: { $0.index == snapshot.ownIndex && $0.isConnected }))
            print("paired=\(snapshot.devices.count) max=\(snapshot.maxConnections) own=\(snapshot.ownIndex) battery=\(snapshot.batteryPercentage.map(String.init) ?? "unknown")")
            for device in snapshot.devices {
                print("\(device.index)\t\(device.isConnected ? "connected" : "disconnected")\t\(device.name)")
            }
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
