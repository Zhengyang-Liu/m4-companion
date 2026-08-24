import Foundation
import MomentumBluetooth
import MomentumCore

@main
struct CoreTests {
    static func main() async throws {
        let packet = GaiaPacket(vendorID: 0x0495, commandID: 0x1401, payload: Data([0x02]))
        precondition(packet.data == Data([0x04, 0x95, 0x14, 0x01, 0x02]), "GAIA packet encoding must be big-endian")
        print("PASS GaiaPacket encoding")

        let response = GaiaPacket(
            vendorID: 0x0495,
            commandID: 0x1501,
            payload: Data([0x02, 0x00, 0x01]) + Data("Office PC\0".utf8)
        )
        let device = try MomentumDevice(response: response)
        precondition(device.index == 2)
        precondition(device.priority == 0)
        precondition(device.isConnected)
        precondition(device.name == "Office PC")
        print("PASS device-info parsing")

        let devices = [
            MomentumDevice(index: 0, priority: 2, isConnected: false, name: "iPhone"),
            MomentumDevice(index: 1, priority: 0, isConnected: true, name: "mac"),
            MomentumDevice(index: 2, priority: 3, isConnected: false, name: "Office PC"),
            MomentumDevice(index: 3, priority: 1, isConnected: true, name: "Home PC")
        ]
        let plan = try SwitchPlanner.plan(devices: devices, ownIndex: 1, targetIndex: 2, maxConnections: 2)
        precondition(plan.disconnectIndices == [3])
        precondition(plan.connectIndex == 2)
        print("PASS switch planning")

        let displayOrder = PairedDeviceList.displayOrder(devices, ownIndex: 1)
        precondition(displayOrder.map(\.index) == [1, 0, 2, 3])
        let changedPriorities = devices.map {
            MomentumDevice(index: $0.index, priority: 9 - $0.priority, isConnected: !$0.isConnected, name: $0.name)
        }
        precondition(PairedDeviceList.displayOrder(changedPriorities, ownIndex: 1).map(\.index) == [1, 0, 2, 3])
        print("PASS stable own-first display ordering")

        let framed = try GaiaSPP.frame(packet.data)
        precondition(framed == Data([0xff, 0x03, 0x00, 0x01, 0x04, 0x95, 0x14, 0x01, 0x02]))
        var deframer = GaiaSPPDeframer()
        precondition(deframer.ingest(Data(framed.prefix(3))).isEmpty)
        let decoded = deframer.ingest(Data(framed.dropFirst(3)))
        precondition(decoded == [packet.data])
        print("PASS SPP framing and split-read deframing")

        var noisyDeframer = GaiaSPPDeframer()
        let noisyDecoded = noisyDeframer.ingest(Data([0x00, 0x7e]) + framed)
        precondition(noisyDecoded == [packet.data])
        print("PASS SPP noise recovery")

        do {
            _ = try PairedDeviceList.parseCount(Data([0x01, 0x00]))
            preconditionFailure("Oversized device counts must be rejected")
        } catch MomentumProtocolError.invalidDeviceCount(256) {
            print("PASS oversized device-count rejection")
        }

        let battery = try BatteryLevel.parse(Data([70]))
        precondition(battery == 70)
        print("PASS battery percentage parsing")
        do {
            _ = try BatteryLevel.parse(Data([101]))
            preconditionFailure("Battery percentages above 100 must be rejected")
        } catch MomentumProtocolError.invalidBatteryPercentage(101) {
            print("PASS invalid battery percentage rejection")
        }

        let snapshot = MomentumSnapshot(
            devices: devices,
            ownIndex: 1,
            maxConnections: 2,
            batteryPercentage: 70
        )
        let switchingState = MomentumWidgetState(snapshot: snapshot, switchingDeviceIndex: 2)
        let decodedState = try JSONDecoder().decode(
            MomentumWidgetState.self,
            from: JSONEncoder().encode(switchingState)
        )
        precondition(decodedState == switchingState)
        precondition(decodedState.switchingDeviceIndex == 2)
        print("PASS switching-state cache round trip")

        let connectedStatus = try ConnectionStatus.parse(Data([2, 1]), expectedIndex: 2)
        let disconnectedStatus = try ConnectionStatus.parse(Data([2, 0]), expectedIndex: 2)
        precondition(connectedStatus)
        precondition(!disconnectedStatus)
        print("PASS connection-status parsing")

        do {
            _ = try await BatteryLevel.bestEffortQuery { throw CancellationError() }
            preconditionFailure("Battery queries must propagate cancellation")
        } catch is CancellationError {
            print("PASS battery-query cancellation propagation")
        }
        let unavailableBattery = try await BatteryLevel.bestEffortQuery {
            throw MomentumProtocolError.packetTooShort
        }
        precondition(unavailableBattery == nil)
        print("PASS battery-query non-cancellation fallback")

        var connectAttempts = 0
        var statusPolls = 0
        let connectedOnRetry = try await ConnectionAttemptPolicy.connect(
            maximumAttempts: 2,
            pollsPerAttempt: 3,
            sendConnect: {
                connectAttempts += 1
                if connectAttempts == 1 {
                    throw MomentumProtocolError.deviceRejected(command: MomentumCommands.connect, status: 1)
                }
            },
            pollConnected: {
                statusPolls += 1
                return connectAttempts == 2
            }
        )
        precondition(connectedOnRetry)
        precondition(connectAttempts == 2)
        precondition(statusPolls == 4)
        print("PASS bounded connect retry after first polling window")

        var asynchronousAttempts = 0
        var asynchronousPolls = 0
        let completedAfterError = try await ConnectionAttemptPolicy.connect(
            maximumAttempts: 2,
            pollsPerAttempt: 3,
            sendConnect: {
                asynchronousAttempts += 1
                throw MomentumProtocolError.deviceRejected(command: MomentumCommands.connect, status: 1)
            },
            pollConnected: {
                asynchronousPolls += 1
                return asynchronousPolls == 2
            }
        )
        precondition(completedAfterError)
        precondition(asynchronousAttempts == 1)
        print("PASS asynchronous completion after connect error without duplicate command")

        var transientPollAttempts = 0
        var transientPollCount = 0
        let completedAfterTransientPollErrors = try await ConnectionAttemptPolicy.connect(
            maximumAttempts: 2,
            pollsPerAttempt: 4,
            sendConnect: {
                transientPollAttempts += 1
            },
            pollConnected: {
                transientPollCount += 1
                if transientPollCount <= 2 {
                    throw MomentumProtocolError.packetTooShort
                }
                return transientPollCount == 3
            }
        )
        precondition(completedAfterTransientPollErrors)
        precondition(transientPollAttempts == 1)
        precondition(transientPollCount == 3)
        print("PASS transient connection-status polling errors stay within one click")

        let selectedAddress = try MomentumHeadsetAddressResolver.resolve([
            MomentumHeadsetCandidate(address: "AA-BB-CC-DD-EE-FF", isConnected: true)
        ])
        precondition(selectedAddress == "AA-BB-CC-DD-EE-FF")
        print("PASS unique headset selection")
        do {
            _ = try MomentumHeadsetAddressResolver.resolve([
                MomentumHeadsetCandidate(address: "AA", isConnected: true),
                MomentumHeadsetCandidate(address: "BB", isConnected: false)
            ])
            preconditionFailure("Multiple matching headsets must be ambiguous")
        } catch MomentumBluetoothError.ambiguousHeadsets {
            print("PASS mixed-state headset ambiguity rejection")
        }
        do {
            _ = try MomentumHeadsetAddressResolver.resolve([
                MomentumHeadsetCandidate(address: "AA", isConnected: true),
                MomentumHeadsetCandidate(address: "BB", isConnected: true)
            ])
            preconditionFailure("Multiple connected headsets must be ambiguous")
        } catch MomentumBluetoothError.ambiguousHeadsets {
            print("PASS connected-headset ambiguity rejection")
        }
        do {
            _ = try MomentumHeadsetAddressResolver.resolve([
                MomentumHeadsetCandidate(address: "AA", isConnected: false),
                MomentumHeadsetCandidate(address: "BB", isConnected: false)
            ])
            preconditionFailure("Multiple paired headsets must be ambiguous")
        } catch MomentumBluetoothError.ambiguousHeadsets {
            print("PASS paired-headset ambiguity rejection")
        }

        let token = MomentumActionCapability.generate()
        precondition(MomentumActionCapability.isWellFormed(token))
        precondition(MomentumActionCapability.isValid(presented: token, expected: token))
        precondition(!MomentumActionCapability.isValid(presented: "", expected: ""))
        precondition(!MomentumActionCapability.isValid(presented: "wrong", expected: token))
        precondition(!MomentumActionCapability.isValid(presented: String(token.dropLast()), expected: token))
        precondition(!MomentumActionCapability.isValid(presented: token + "0", expected: token))
        precondition(!MomentumActionCapability.isValid(presented: String(repeating: "x", count: 72), expected: token))
        precondition(!MomentumActionCapability.isValid(presented: nil, expected: token))
        print("PASS strict action capability validation")

        let widgetActionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let widgetActionNow = Date(timeIntervalSince1970: 1_000)
        let widgetAction = MomentumWidgetActionRequest(
            id: widgetActionID,
            createdAt: widgetActionNow,
            deviceIndex: 2,
            expectedName: "Office PC",
            desiredConnected: true,
            actionToken: token
        )
        let widgetActionRoundTrip = try JSONDecoder().decode(
            MomentumWidgetActionRequest.self,
            from: JSONEncoder().encode(widgetAction)
        )
        precondition(widgetActionRoundTrip == widgetAction)
        precondition(MomentumWidgetActionValidator.isAuthorized(
            widgetAction,
            expectedToken: token,
            snapshot: snapshot,
            now: widgetActionNow.addingTimeInterval(5)
        ))
        let staleWidgetAction = MomentumWidgetActionRequest(
            id: widgetActionID,
            createdAt: widgetActionNow.addingTimeInterval(-31),
            deviceIndex: 2,
            expectedName: "Office PC",
            desiredConnected: true,
            actionToken: token
        )
        precondition(!MomentumWidgetActionValidator.isAuthorized(
            staleWidgetAction,
            expectedToken: token,
            snapshot: snapshot,
            now: widgetActionNow
        ))
        let ownDeviceWidgetAction = MomentumWidgetActionRequest(
            id: widgetActionID,
            createdAt: widgetActionNow,
            deviceIndex: snapshot.ownIndex,
            expectedName: "mac",
            desiredConnected: false,
            actionToken: token
        )
        precondition(!MomentumWidgetActionValidator.isAuthorized(
            ownDeviceWidgetAction,
            expectedToken: token,
            snapshot: snapshot,
            now: widgetActionNow
        ))
        print("PASS background widget-action authorization policy")

        let widgetActionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4-widget-action-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: widgetActionDirectory) }
        let secondWidgetAction = MomentumWidgetActionRequest(
            id: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!,
            createdAt: widgetActionNow.addingTimeInterval(1),
            deviceIndex: 3,
            expectedName: "Home PC",
            desiredConnected: false,
            actionToken: token
        )
        try MomentumWidgetActionStore.enqueue(widgetAction, in: widgetActionDirectory)
        try MomentumWidgetActionStore.enqueue(secondWidgetAction, in: widgetActionDirectory)
        let requestPermissions = try FileManager.default.attributesOfItem(
            atPath: MomentumWidgetActionStore.readyFileURL(
                for: widgetAction.id,
                in: widgetActionDirectory
            ).path
        )[.posixPermissions] as? NSNumber
        precondition(requestPermissions?.intValue == 0o600)
        let firstClaimedWidgetAction = try MomentumWidgetActionStore.claimNextAuthorized(
            expectedToken: token,
            snapshot: snapshot,
            now: widgetActionNow.addingTimeInterval(5),
            from: widgetActionDirectory
        )
        let secondClaimedWidgetAction = try MomentumWidgetActionStore.claimNextAuthorized(
            expectedToken: token,
            snapshot: snapshot,
            now: widgetActionNow.addingTimeInterval(5),
            from: widgetActionDirectory
        )
        precondition(Set([firstClaimedWidgetAction?.id, secondClaimedWidgetAction?.id].compactMap { $0 }) == Set([
            widgetAction.id,
            secondWidgetAction.id
        ]))
        let thirdClaimedWidgetAction = try MomentumWidgetActionStore.claimNextAuthorized(
            expectedToken: token,
            snapshot: snapshot,
            now: widgetActionNow.addingTimeInterval(5),
            from: widgetActionDirectory
        )
        precondition(thirdClaimedWidgetAction == nil)
        print("PASS durable multi-request widget-action queue")

        let watcherSemaphore = DispatchSemaphore(value: 0)
        let watcher = try MomentumWidgetActionQueueWatcher(
            directory: widgetActionDirectory,
            queue: DispatchQueue.global(qos: .userInitiated)
        ) {
            watcherSemaphore.signal()
        }
        let watchedWidgetAction = MomentumWidgetActionRequest(
            deviceIndex: 2,
            expectedName: "Office PC",
            desiredConnected: true,
            actionToken: token
        )
        try MomentumWidgetActionStore.enqueue(watchedWidgetAction, in: widgetActionDirectory)
        precondition(watcherSemaphore.wait(timeout: .now() + 2) == .success)
        watcher.cancel()
        print("PASS cross-process widget-action queue watcher")

        let legacyStateJSON = try JSONSerialization.data(withJSONObject: [
            "snapshot": [
                "devices": [],
                "ownIndex": 0,
                "maxConnections": 2
            ]
        ])
        let legacyState = try JSONDecoder().decode(MomentumWidgetState.self, from: legacyStateJSON)
        precondition(legacyState.actionToken == nil)
        let migratedState = MomentumWidgetState(
            snapshot: legacyState.snapshot,
            actionToken: token
        )
        let migratedRoundTrip = try JSONDecoder().decode(
            MomentumWidgetState.self,
            from: JSONEncoder().encode(migratedState)
        )
        precondition(migratedRoundTrip.actionToken == token)
        print("PASS backward cache migration with action capability")

        precondition(MomentumCommands.getAncEnabled == 0x1a05)
        precondition(MomentumCommands.getAncEnabledResponse == 0x1b05)
        precondition(MomentumCommands.getAncModes == 0x1a01)
        precondition(MomentumCommands.getAncModesResponse == 0x1b01)
        precondition(MomentumCommands.getTransparencyLevel == 0x1a03)
        precondition(MomentumCommands.getTransparentHearing == 0x1805)
        precondition(MomentumCommands.getEqConfig == 0x1000)
        precondition(MomentumCommands.getEqBand == 0x1002)
        precondition(MomentumCommands.getBassBoost == 0x1009)
        precondition(MomentumCommands.setAudioMode == 0x0803)
        precondition(MomentumCommands.setAudioModeResponse == 0x0903)
        precondition(MomentumCommands.getSoundMode == 0x0804)
        precondition(MomentumCommands.getSoundModeResponse == 0x0904)
        precondition(MomentumCommands.getBluetoothCompatibilityMode == 0x0406)
        precondition(MomentumCommands.getBluetoothCompatibilityModeResponse == 0x0506)
        precondition(MomentumCommands.getSoundPersonalizationProfileState == 0x2001)
        precondition(MomentumCommands.getSoundPersonalizationProfileStateResponse == 0x2101)
        print("PASS noise-control, EQ, sound-mode, compatibility, and personalization command IDs")

        let notParameterized = try MomentumControlCodec.parseSoundPersonalizationProfileState(Data([0]))
        let calibrated = try MomentumControlCodec.parseSoundPersonalizationProfileState(Data([2]))
        precondition(notParameterized == .notParameterized)
        precondition(calibrated == .calibrated)

        let betterAudioMode = try MomentumControlCodec.parseBluetoothCompatibilityMode(Data([0]))
        let betterCompatibilityMode = try MomentumControlCodec.parseBluetoothCompatibilityMode(Data([1]))
        precondition(betterAudioMode == .betterAudio)
        precondition(betterCompatibilityMode == .betterCompatibility)

        let offSoundMode = try MomentumControlCodec.parseSoundMode(Data([0, 0]))
        let equalizerSoundMode = try MomentumControlCodec.parseSoundMode(Data([0, 1]))
        let podcastSoundMode = try MomentumControlCodec.parseSoundMode(Data([0, 2]))
        let personalizedSoundMode = try MomentumControlCodec.parseSoundMode(Data([0, 3]))
        precondition(offSoundMode == .off)
        precondition(equalizerSoundMode == .equalizer)
        precondition(podcastSoundMode == .podcast)
        precondition(personalizedSoundMode == .soundPersonalization)
        precondition(MomentumSoundMode.selectableModes == [
            .equalizer,
            .podcast,
            .soundPersonalization
        ])
        precondition(MomentumControlCodec.encodeAudioMode(.equalizer) == Data([0, 1]))
        precondition(MomentumControlCodec.encodeAudioMode(.podcast) == Data([0, 2]))
        precondition(MomentumControlCodec.encodeAudioMode(.soundPersonalization) == Data([0, 3]))
        precondition(MomentumSoundModeTransitionPolicy.reached(
            desired: .soundPersonalization,
            readback: .soundPersonalization
        ))
        precondition(!MomentumSoundModeTransitionPolicy.reached(
            desired: .soundPersonalization,
            readback: .equalizer
        ))

        do {
            _ = try MomentumControlCodec.parseSoundMode(Data([0, 3, 9]))
            preconditionFailure("Sound mode payload length must be strict")
        } catch MomentumProtocolError.malformedControlPayload(command: MomentumCommands.getSoundMode) {
            // Expected.
        }
        do {
            _ = try MomentumControlCodec.parseSoundMode(Data([1, 3]))
            preconditionFailure("Sound mode prefix must be zero")
        } catch MomentumProtocolError.malformedControlPayload(command: MomentumCommands.getSoundMode) {
            print("PASS Off, Equalizer, Podcast, and Sound Personalization codec")
        }

        let modes = try MomentumControlCodec.parseAncModes(Data([3, 1, 1, 2, 2, 0]))
        precondition(modes == MomentumAncModes(antiWind: .automatic, comfortEnabled: false, adaptiveEnabled: true))
        do {
            _ = try MomentumControlCodec.parseAncModes(Data([1, 3, 2, 0, 3, 1]))
            preconditionFailure("Unknown anti-wind states must be rejected")
        } catch MomentumProtocolError.invalidControlValue(command: MomentumCommands.getAncModes, value: 3) {
            print("PASS ANC mode-pair parsing and validation")
        }

        let parsedTrue = try MomentumControlCodec.parseBoolean(Data([1]), command: MomentumCommands.getAncEnabled)
        let parsedFalse = try MomentumControlCodec.parseBoolean(Data([0]), command: MomentumCommands.getAncEnabled)
        precondition(parsedTrue)
        precondition(!parsedFalse)
        do {
            _ = try MomentumControlCodec.parseBoolean(Data([2]), command: MomentumCommands.getAncEnabled)
            preconditionFailure("Boolean payloads must be exactly zero or one")
        } catch MomentumProtocolError.invalidControlValue(command: MomentumCommands.getAncEnabled, value: 2) {
            print("PASS strict control-boolean parsing")
        }

        let parsedTransparency = try MomentumControlCodec.parseTransparencyLevel(Data([100]))
        precondition(parsedTransparency == 100)
        do {
            _ = try MomentumControlCodec.parseTransparencyLevel(Data([101]))
            preconditionFailure("Transparency above 100 must be rejected")
        } catch MomentumProtocolError.invalidControlValue(command: MomentumCommands.getTransparencyLevel, value: 101) {
            print("PASS transparency parsing and validation")
        }
        precondition(MomentumControlCodec.encodeTransparencyLevel(-10) == Data([0]))
        precondition(MomentumControlCodec.encodeTransparencyLevel(140) == Data([100]))
        print("PASS transparency setter clamping")

        let eqConfig = try MomentumControlCodec.parseEqConfig(Data([5, 0xc4, 0x3c]))
        precondition(eqConfig == MomentumEqConfig(bandCount: 5, minimumGainDB: -6, maximumGainDB: 6))
        let bareEqBand = try MomentumControlCodec.parseEqBand(Data([0xce]), requestedBand: 2)
        let echoedEqBand = try MomentumControlCodec.parseEqBand(Data([4, 0x23]), requestedBand: 4)
        precondition(bareEqBand == MomentumEqBand(index: 2, gainDB: -5))
        precondition(echoedEqBand == MomentumEqBand(index: 4, gainDB: 3.5))
        do {
            _ = try MomentumControlCodec.parseEqBand(Data([3, 0]), requestedBand: 4)
            preconditionFailure("An echoed EQ band must match the requested band")
        } catch MomentumProtocolError.invalidControlValue(command: MomentumCommands.getEqBand, value: 3) {
            print("PASS EQ parsing for bare and echoed responses")
        }
        let encodedRoundedEqBand = try MomentumControlCodec.encodeEqBand(index: 1, gainDB: -3.25, config: eqConfig)
        let encodedClampedEqBand = try MomentumControlCodec.encodeEqBand(index: 1, gainDB: 99, config: eqConfig)
        precondition(encodedRoundedEqBand == Data([1, 0xdf]))
        precondition(encodedClampedEqBand == Data([1, 0x3c]))
        do {
            _ = try MomentumControlCodec.encodeEqBand(index: 5, gainDB: 0, config: eqConfig)
            preconditionFailure("EQ band indices must be validated")
        } catch MomentumProtocolError.invalidEqBand(5) {
            print("PASS signed-tenths EQ encoding, clamping, and band validation")
        }

        let customPlan = MomentumControlPlan.customMode
        precondition(customPlan == [
            MomentumControlWrite(command: MomentumCommands.setTransparentHearing, payload: Data([0])),
            MomentumControlWrite(command: MomentumCommands.setAncEnabled, payload: Data([1])),
            MomentumControlWrite(command: MomentumCommands.setAncMode, payload: Data([MomentumAncMode.adaptive.rawValue, 0]))
        ])
        precondition(MomentumControlPlan.customModeRestoring(level: 42) == customPlan + [
            MomentumControlWrite(command: MomentumCommands.setTransparencyLevel, payload: Data([42]))
        ])
        precondition(MomentumCustomANCLevelPolicy.updatedRememberedLevel(
            current: 37,
            ancEnabled: true,
            adaptiveEnabled: false,
            reportedLevel: 42
        ) == 42)
        precondition(MomentumCustomANCLevelPolicy.updatedRememberedLevel(
            current: 42,
            ancEnabled: true,
            adaptiveEnabled: true,
            reportedLevel: 100
        ) == 42)
        precondition(MomentumCustomANCLevelPolicy.updatedRememberedLevel(
            current: 42,
            ancEnabled: false,
            adaptiveEnabled: false,
            reportedLevel: 100
        ) == 42)
        precondition(MomentumCustomANCLevelPolicy.levelToRestore(remembered: 42, fallback: 100) == 42)
        precondition(MomentumCustomANCLevelPolicy.levelToRestore(remembered: nil, fallback: 37) == 37)
        print("PASS custom ANC level memory across mode changes")

        precondition(MomentumRefreshPresentationPolicy.shouldBlock(
            hasSnapshot: false,
            hasControls: false
        ))
        precondition(MomentumRefreshPresentationPolicy.shouldBlock(
            hasSnapshot: true,
            hasControls: false
        ))
        precondition(!MomentumRefreshPresentationPolicy.shouldBlock(
            hasSnapshot: true,
            hasControls: true
        ))
        precondition(MomentumRefreshPresentationPolicy.shouldRefreshControls(
            hasControls: false
        ))
        precondition(!MomentumRefreshPresentationPolicy.shouldRefreshControls(
            hasControls: true
        ))
        print("PASS cached controls keep panel interactive during background refresh")

        let firstUserProfile = MomentumUserEQProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Mine",
            gainsDB: [1, 2, 3, 4, 5]
        )
        let secondUserProfile = MomentumUserEQProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Night",
            gainsDB: [-1, -2, -3, -4, -5]
        )
        var userProfiles: [MomentumUserEQProfile] = []
        userProfiles = try MomentumUserEQProfilePolicy.saving(firstUserProfile, in: userProfiles)
        userProfiles = try MomentumUserEQProfilePolicy.saving(secondUserProfile, in: userProfiles)
        precondition(userProfiles.map(\.name) == ["Night", "Mine"])
        let updatedMine = MomentumUserEQProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: " mine ",
            gainsDB: [6, 6, 6, 6, 6]
        )
        userProfiles = try MomentumUserEQProfilePolicy.saving(updatedMine, in: userProfiles)
        precondition(userProfiles.map(\.name) == ["mine", "Night"])
        precondition(userProfiles[0].gainsDB == [6, 6, 6, 6, 6])
        let combinedProfiles = MomentumUserEQProfilePolicy.userFirst(
            userProfiles: userProfiles,
            builtInProfiles: MomentumEQPreset.available(forBandCount: 5)
        )
        precondition(combinedProfiles.prefix(2).map(\.name) == ["mine", "Night"])
        do {
            _ = try MomentumUserEQProfilePolicy.saving(
                MomentumUserEQProfile(name: "   ", gainsDB: [0, 0, 0, 0, 0]),
                in: userProfiles
            )
            preconditionFailure("Blank user EQ profile name must be rejected")
        } catch MomentumUserEQProfileError.invalidName {
            // Expected.
        }
        print("PASS user EQ profiles save, replace, and sort before built-ins")

        let transparencyPlan = MomentumControlPlan.transparency(level: 150)
        precondition(transparencyPlan == [
            MomentumControlWrite(command: MomentumCommands.setAncMode, payload: Data([MomentumAncMode.adaptive.rawValue, 0])),
            MomentumControlWrite(command: MomentumCommands.setTransparencyLevel, payload: Data([100]))
        ])
        print("PASS safe custom-mode and transparency sequencing")

        try MomentumControlCodec.validateWriteResponse(
            command: MomentumCommands.setAncEnabled,
            response: GaiaPacket(vendorID: MomentumCommands.vendorID, commandID: 0x1b04)
        )
        do {
            try MomentumControlCodec.validateWriteResponse(
                command: MomentumCommands.setAncEnabled,
                response: GaiaPacket(vendorID: MomentumCommands.vendorID, commandID: 0x1b84, payload: Data([7]))
            )
            preconditionFailure("Setter error responses must be surfaced")
        } catch MomentumProtocolError.deviceRejected(command: MomentumCommands.setAncEnabled, status: 7) {
            print("PASS setter response and error verification")
        }

        let controls = MomentumControlsSnapshot(
            soundMode: .soundPersonalization,
            ancEnabled: true,
            ancModes: modes,
            transparencyLevel: 42,
            transparentHearingEnabled: false,
            eqConfig: eqConfig,
            eqBands: [MomentumEqBand(index: 0, gainDB: 0)],
            bassBoostEnabled: true
        )
        let controlsData = try JSONEncoder().encode(controls)
        let decodedControls = try JSONDecoder().decode(MomentumControlsSnapshot.self, from: controlsData)
        precondition(decodedControls == controls)
        print("PASS Codable control snapshot round trip")

        precondition(MomentumControlPresentation.eqBandLabels(count: 3) == ["Bass", "Mid", "Treble"])
        precondition(MomentumControlPresentation.eqBandLabels(count: 5) == ["63 Hz", "250 Hz", "1k Hz", "4k Hz", "8k Hz"])
        precondition(MomentumControlPresentation.eqBandLabels(count: 2) == ["Band 1", "Band 2"])
        precondition(MomentumControlPresentation.eqBandLabels(count: 0).isEmpty)
        print("PASS human-friendly dynamic EQ labels")

        precondition(MomentumControlSyncPolicy.pollIntervalSeconds == 5)
        precondition(MomentumControlSyncPolicy.shouldApplyReadback(
            startedAtGeneration: 4,
            currentGeneration: 4,
            hasActiveUserOperation: false
        ))
        precondition(!MomentumControlSyncPolicy.shouldApplyReadback(
            startedAtGeneration: 4,
            currentGeneration: 5,
            hasActiveUserOperation: false
        ))
        precondition(!MomentumControlSyncPolicy.shouldApplyReadback(
            startedAtGeneration: 4,
            currentGeneration: 4,
            hasActiveUserOperation: true
        ))
        print("PASS external-control polling stale-readback protection")

        let incompleteBands = [MomentumEqBand(index: 1, gainDB: 2.5)]
        precondition(MomentumControlPresentation.gains(bandCount: 3, bands: incompleteBands) == [0, 2.5, 0])
        precondition(MomentumControlPresentation.flatGains(bandCount: 3) == [0, 0, 0])
        print("PASS stable EQ gain model and flat preset")

        let presets = MomentumEQPreset.momentum4FiveBand
        precondition(presets.map(\.name) == ["Rock", "Pop", "Dance", "Hip Hop", "Classical", "Movie", "Jazz"])
        precondition(presets.first?.gainsDB == [0, 2, 2.5, 1.5, -2])
        precondition(presets.last?.gainsDB == [-3.2, 0, 2.2, 2.2, 0])
        precondition(MomentumEQPreset.available(forBandCount: 5) == presets)
        precondition(MomentumEQPreset.available(forBandCount: 3).isEmpty)
        print("PASS official MOMENTUM 4 five-band EQ presets")

        precondition(MomentumEQBatchPlan.rollbackIndices(successfulWriteCount: 3) == [2, 1, 0])
        precondition(MomentumEQBatchPlan.rollbackIndices(successfulWriteCount: 0).isEmpty)
        print("PASS deterministic reverse-order EQ batch rollback")

        let temporaryStore = FileManager.default.temporaryDirectory
            .appendingPathComponent("MomentumSnapshotStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryStore) }
        try MomentumSnapshotStore.save(switchingState, in: temporaryStore)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: temporaryStore.path)[.posixPermissions] as? NSNumber
        let snapshotMode = try FileManager.default.attributesOfItem(
            atPath: temporaryStore.appendingPathComponent("snapshot.json").path
        )[.posixPermissions] as? NSNumber
        precondition(directoryMode?.intValue == 0o700)
        precondition(snapshotMode?.intValue == 0o600)
        try MomentumSnapshotStore.save(switchingState, in: temporaryStore)
        let retainedMode = try FileManager.default.attributesOfItem(
            atPath: temporaryStore.appendingPathComponent("snapshot.json").path
        )[.posixPermissions] as? NSNumber
        precondition(retainedMode?.intValue == 0o600)
        let storedState = try MomentumSnapshotStore.loadState(from: temporaryStore)
        precondition(storedState == switchingState)
        print("PASS private snapshot-store permissions and widget-compatible readback")

        precondition(MomentumConnectedParameter.parse("0") == false)
        precondition(MomentumConnectedParameter.parse("1") == true)
        precondition(MomentumConnectedParameter.parse("2") == nil)
        precondition(MomentumConnectedParameter.parse("") == nil)
        precondition(MomentumConnectedParameter.parse(nil) == nil)
        print("PASS strict connected URL parameter validation")

        precondition(MomentumDeferredWritePolicy.acceptsDraft(activeControl: nil, requestedControl: "eq-0"))
        precondition(MomentumDeferredWritePolicy.acceptsDraft(activeControl: "eq-0", requestedControl: "eq-0"))
        precondition(!MomentumDeferredWritePolicy.acceptsDraft(activeControl: "eq-0", requestedControl: "eq-1"))
        precondition(!MomentumDeferredWritePolicy.acceptsImmediateAction(activeControl: "eq-0"))
        print("PASS pending debounce ordering policy")

        precondition(MomentumEQBatchPlan.rollbackFailureIndices(
            attemptedIndices: [2, 1, 0],
            writeSucceeded: [true, false, true]
        ) == [1])
        precondition(MomentumEQBatchPlan.rollbackFailureIndices(
            attemptedIndices: [2, 1, 0],
            writeSucceeded: [true, true, true]
        ).isEmpty)
        precondition(MomentumEQBatchPlan.rollbackFailureIndices(
            attemptedIndices: [2, 1, 0],
            writeSucceeded: [true]
        ) == [1, 0])
        print("PASS deterministic EQ rollback outcome policy")

        precondition(MomentumControlRecoveryPolicy.disposition(hasAuthoritativeSnapshot: true) == .applyAuthoritative)
        precondition(MomentumControlRecoveryPolicy.disposition(hasAuthoritativeSnapshot: false) == .keepOptimisticUnknown)
        print("PASS control-error recovery state policy")

        precondition(MomentumLaunchPolicy.shouldShowWindow(launchedAsLoginItem: false))
        precondition(!MomentumLaunchPolicy.shouldShowWindow(launchedAsLoginItem: true))
        precondition(MomentumLaunchPolicy.shouldUseAccessoryActivation(launchedAsLoginItem: false))
        precondition(MomentumLaunchPolicy.shouldUseAccessoryActivation(launchedAsLoginItem: true))
        precondition(!MomentumLaunchPolicy.shouldKeepDockIconAfterWindowCloses)
        print("PASS interactive-versus-login menu bar launch policy")

        precondition(MomentumNoiseControlMode.resolve(ancEnabled: false, adaptiveEnabled: true) == .off)
        precondition(MomentumNoiseControlMode.resolve(ancEnabled: true, adaptiveEnabled: true) == .adaptive)
        precondition(MomentumNoiseControlMode.resolve(ancEnabled: true, adaptiveEnabled: false) == .custom)
        print("PASS authoritative three-mode noise-control selection")

        precondition(MomentumConnectionIndicatorPolicy.style(isSwitching: true, isConnected: false) == .pulsingGreen)
        precondition(MomentumConnectionIndicatorPolicy.style(isSwitching: false, isConnected: true) == .steadyGreen)
        precondition(MomentumConnectionIndicatorPolicy.style(isSwitching: false, isConnected: false) == .steadyGray)
        print("PASS switching/connected status-light policy")
    }
}
