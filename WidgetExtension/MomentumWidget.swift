import AppIntents
import MomentumBluetooth
import MomentumCore
import SwiftUI
@preconcurrency import WidgetKit

struct MomentumEntry: TimelineEntry {
    let date: Date
    let state: MomentumWidgetState?

    var snapshot: MomentumSnapshot? { state?.snapshot }

    static let placeholder = MomentumEntry(
        date: .now,
        state: MomentumWidgetState(snapshot: MomentumSnapshot(
            devices: [
                MomentumDevice(index: 0, priority: 0, isConnected: true, name: "This Mac"),
                MomentumDevice(index: 1, priority: 1, isConnected: true, name: "Phone"),
                MomentumDevice(index: 2, priority: 2, isConnected: false, name: "Computer"),
                MomentumDevice(index: 3, priority: 3, isConnected: false, name: "Tablet")
            ],
            ownIndex: 0,
            maxConnections: 2,
            batteryPercentage: 70
        ))
    )
}

private final class CompletionBox<Value>: @unchecked Sendable {
    private let completion: (Value) -> Void
    init(_ completion: @escaping (Value) -> Void) { self.completion = completion }
    func callAsFunction(_ value: Value) { completion(value) }
}

struct MomentumProvider: TimelineProvider {
    func placeholder(in context: Context) -> MomentumEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (MomentumEntry) -> Void) {
        guard !context.isPreview else {
            completion(.placeholder)
            return
        }
        load(completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MomentumEntry>) -> Void) {
        let completion = CompletionBox(completion)
        load { entry in
            completion(Timeline(
                entries: [entry],
                policy: .after(.now.addingTimeInterval(15 * 60))
            ))
        }
    }

    private func load(_ completion: @escaping (MomentumEntry) -> Void) {
        completion(MomentumEntry(date: .now, state: try? MomentumSnapshotStore.loadState()))
    }
}

struct ToggleMomentumDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle MOMENTUM 4 Device"
    static let description = IntentDescription("Connects or disconnects a remembered MOMENTUM 4 peer without opening M4 Companion.")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Device index") var deviceIndex: Int
    @Parameter(title: "Device name") var expectedName: String
    @Parameter(title: "Desired connection state") var desiredConnected: Bool

    init() {}

    init(device: MomentumDevice) {
        deviceIndex = Int(device.index)
        expectedName = device.name
        desiredConnected = !device.isConnected
    }

    func perform() async throws -> some IntentResult {
        guard let index = UInt8(exactly: deviceIndex),
              let state = try? MomentumSnapshotStore.loadState(),
              let token = state.actionToken,
              MomentumActionCapability.isWellFormed(token) else {
            return .result()
        }
        let request = MomentumWidgetActionRequest(
            deviceIndex: index,
            expectedName: expectedName,
            desiredConnected: desiredConnected,
            actionToken: token
        )
        guard MomentumWidgetActionValidator.isAuthorized(
            request,
            expectedToken: token,
            snapshot: state.snapshot
        ) else {
            return .result()
        }

        let switchingState = MomentumWidgetState(
            snapshot: state.snapshot,
            switchingDeviceIndex: index,
            actionToken: token
        )
        do {
            try MomentumSnapshotStore.save(switchingState)
            try MomentumWidgetActionStore.enqueue(request)
        } catch {
            try? MomentumSnapshotStore.save(MomentumWidgetState(
                snapshot: state.snapshot,
                actionToken: token
            ))
            WidgetCenter.shared.reloadAllTimelines()
            throw error
        }
        WidgetCenter.shared.reloadAllTimelines()
        MomentumWidgetActionNotification.post()
        return .result()
    }
}

struct MomentumWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MomentumEntry

    private var tileHeight: CGFloat { family == .systemLarge ? 74 : 46 }

    private var openURL: URL? {
        guard let token = entry.state?.actionToken else { return nil }
        var components = URLComponents()
        components.scheme = "momentum-switcher"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    var body: some View {
        VStack(spacing: family == .systemLarge ? 14 : 7) {
            HStack(spacing: 7) {
                Image(systemName: "headphones")
                    .font(.headline)
                Text("MOMENTUM 4")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                if let snapshot = entry.snapshot {
                    if let battery = snapshot.batteryPercentage {
                        Label("\(battery)%", systemImage: batterySymbol(battery))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    connectionDots(snapshot)
                }
            }

            if let snapshot = entry.snapshot {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: family == .systemLarge ? 12 : 6
                ) {
                    ForEach(snapshot.devices) { device in
                        deviceTile(
                            device,
                            ownIndex: snapshot.ownIndex,
                            switchingIndex: entry.state?.switchingDeviceIndex,
                            actionToken: entry.state?.actionToken
                        )
                    }
                }
            } else {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(family == .systemLarge ? 18 : 12)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(openURL)
    }

    private func connectionDots(_ snapshot: MomentumSnapshot) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<Int(snapshot.maxConnections), id: \.self) { index in
                Circle()
                    .fill(index < snapshot.devices.filter(\.isConnected).count ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
        }
    }

    @ViewBuilder
    private func deviceTile(
        _ device: MomentumDevice,
        ownIndex: UInt8,
        switchingIndex: UInt8?,
        actionToken: String?
    ) -> some View {
        let content = tileContent(device, isSwitching: device.index == switchingIndex)
        if device.index == ownIndex {
            content
        } else if MomentumActionCapability.isWellFormed(actionToken) {
            Button(intent: ToggleMomentumDeviceIntent(device: device)) {
                content
            }
            .buttonStyle(.plain)
            .allowsHitTesting(switchingIndex == nil)
        }
    }

    private func tileContent(_ device: MomentumDevice, isSwitching: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: device.name))
                .frame(width: 18)
            Text(device.name)
                .font(family == .systemLarge ? .body.weight(.medium) : .caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 2)
            switch MomentumConnectionIndicatorPolicy.style(
                isSwitching: isSwitching,
                isConnected: device.isConnected
            ) {
            case .pulsingGreen:
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .phaseAnimator([false, true]) { content, bright in
                        content
                            .opacity(bright ? 1 : 0.25)
                            .scaleEffect(bright ? 1.2 : 0.8)
                    } animation: { _ in
                        .easeInOut(duration: 0.55)
                    }
            case .steadyGreen:
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
            case .steadyGray:
                Circle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 8, height: 8)
            }
        }
        .foregroundStyle(device.isConnected ? .primary : .secondary)
        .padding(.horizontal, family == .systemLarge ? 14 : 9)
        .frame(maxWidth: .infinity, minHeight: tileHeight)
        .background(
            device.isConnected ? Color.green.opacity(0.12) : Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: family == .systemLarge ? 14 : 9)
        )
    }

    private func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("iphone") || lower.contains("phone") { return "iphone" }
        if lower == "mac" || lower.contains("this mac") { return "macbook" }
        if lower.contains("tablet") || lower.contains("ipad") { return "ipad" }
        return "desktopcomputer"
    }

    private func batterySymbol(_ percentage: UInt8) -> String {
        switch percentage {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        case 1...25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

struct MomentumWidget: Widget {
    static let kind = "MomentumDeviceSwitcher.NativeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: MomentumProvider()) { entry in
            MomentumWidgetView(entry: entry)
        }
        .configurationDisplayName("M4 Companion")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct MomentumWidgetBundle: WidgetBundle {
    var body: some Widget { MomentumWidget() }
}
