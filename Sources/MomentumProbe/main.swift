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
            if arguments == ["sound-personalization"] {
                let payload = try await client.soundPersonalizationModePayload()
                let controls = try await client.controlsSnapshot()
                let payloadHex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("audio-mode-payload=\(payloadHex)")
                print("eq-gains=\(controls.eqBands.sorted { $0.index < $1.index }.map { $0.gainDB })")
                print("bass-boost=\(controls.bassBoostEnabled)")
                let notifications = try await client.soundPersonalizationNotificationProbe()
                for packet in notifications {
                    let bytes = packet.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                    print(String(format: "packet=0x%04X payload=%@", packet.commandID, bytes))
                }
                return
            }

            if arguments == ["sound-prerequisites"] {
                let mode = try await client.soundMode()
                let prerequisites = try await client.soundPersonalizationPrerequisites()
                print("sound-mode=\(mode.displayName)")
                print("compatibility-mode=\(prerequisites.compatibilityMode)")
                print("profile-state=\(prerequisites.profileState)")
                return
            }

            if arguments == ["toggle-sound-mode"] {
                let before = try await client.soundMode()
                let desired: MomentumSoundMode = before == .soundPersonalization ? .equalizer : .soundPersonalization
                let controls = try await client.setAudioMode(desired)
                print("sound-mode-before=\(before.displayName)")
                print("sound-mode-after=\(controls.soundMode.displayName)")
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
