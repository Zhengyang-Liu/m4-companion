import AppKit
import MomentumBluetooth
import MomentumCore
import OSLog
import ServiceManagement
import Sparkle
import SwiftUI
import WidgetKit

@main
struct MomentumSwitcherHostApp: App {
    @NSApplicationDelegateAdaptor(HostDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") {
                        delegate.checkForUpdates()
                    }
                }
            }
    }
}

@MainActor
final class HostDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private let logger = Logger(
        subsystem: "com.zhengyangliu.MomentumDeviceSwitcher",
        category: "WidgetAction"
    )
    private let client = MomentumHeadsetClient()
    private let actionToken: String = {
        let cached = (try? MomentumSnapshotStore.loadState())?.actionToken
        if let cached, MomentumActionCapability.isWellFormed(cached) {
            return cached
        }
        return MomentumActionCapability.generate()
    }()
    private var refreshTask: Task<Void, Never>?
    private var isSwitching = false
    private var mainWindow: NSWindow?
    private var mainViewModel: MomentumMainViewModel?
    private var widgetActionQueueWatcher: MomentumWidgetActionQueueWatcher?

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installWidgetActionWatcher()
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
        if let cached = try? MomentumSnapshotStore.loadState(),
           cached.switchingDeviceIndex != nil || cached.actionToken != actionToken {
            cache(cached.snapshot)
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await consumePendingWidgetAction()
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
        // macOS marks the open-application Apple event when launchd starts a registered login item.
        let launchedAsLoginItem = NSAppleEventManager.shared()
            .currentAppleEvent?
            .attributeDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
        if MomentumLaunchPolicy.shouldUseAccessoryActivation(
            launchedAsLoginItem: launchedAsLoginItem
        ) {
            _ = NSApp.setActivationPolicy(.accessory)
        }
        if MomentumLaunchPolicy.shouldShowWindow(launchedAsLoginItem: launchedAsLoginItem) {
            showMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeWidgetActionWatcher()
        refreshTask?.cancel()
        mainViewModel?.stopAutomaticSync()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "momentum-switcher" {
            Task { await handle(url) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        mainViewModel?.stopAutomaticSync()
    }

    private func installWidgetActionWatcher() {
        guard widgetActionQueueWatcher == nil else { return }
        do {
            widgetActionQueueWatcher = try MomentumWidgetActionQueueWatcher(
                queue: DispatchQueue.main
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.logger.info("Detected queued widget action")
                    await self?.consumePendingWidgetAction()
                }
            }
            logger.info("Watching widget action queue")
        } catch {
            logger.error("Widget action queue watcher failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeWidgetActionWatcher() {
        widgetActionQueueWatcher?.cancel()
        widgetActionQueueWatcher = nil
    }

    fileprivate func consumePendingWidgetAction() async {
        guard !isSwitching else { return }
        while !isSwitching,
              let state = try? MomentumSnapshotStore.loadState() {
            let requestWasPresent = MomentumWidgetActionStore.hasPendingRequests()
            guard let request = try? MomentumWidgetActionStore.claimNextAuthorized(
                expectedToken: actionToken,
                snapshot: state.snapshot
            ) else {
                if requestWasPresent, state.switchingDeviceIndex != nil {
                    cache(state.snapshot)
                }
                return
            }
            await performConnectionChange(
                index: request.deviceIndex,
                name: request.expectedName,
                desiredConnected: request.desiredConnected
            )
            logger.info("Finished widget action \(request.id.uuidString, privacy: .public)")
        }
    }

    private func showMainWindow() {
        let viewModel: MomentumMainViewModel
        if let existing = mainViewModel {
            viewModel = existing
        } else {
            viewModel = MomentumMainViewModel(client: client) { [weak self] snapshot in
                self?.cache(snapshot)
            }
            mainViewModel = viewModel
        }

        if mainWindow == nil {
            let controller = NSHostingController(rootView: MomentumMainView(model: viewModel))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "M4 Companion"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.minSize = NSSize(width: 420, height: 560)
            window.maxSize = NSSize(width: 560, height: 900)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = controller
            window.center()
            mainWindow = window
        }

        _ = NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        viewModel.startAutomaticSync()
        Task { await viewModel.refresh() }
    }

    private func cache(_ snapshot: MomentumSnapshot) {
        try? MomentumSnapshotStore.save(MomentumWidgetState(
            snapshot: snapshot,
            actionToken: actionToken
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func refresh(afterOperation: Bool = false) async {
        guard afterOperation || !isSwitching else { return }
        guard let snapshot = try? await client.snapshot() else { return }
        guard afterOperation || !isSwitching else { return }
        cache(snapshot)
    }

    private func handle(_ url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              MomentumActionCapability.isValid(
                  presented: components.queryItems?.first(where: { $0.name == "token" })?.value,
                  expected: actionToken
              ) else {
            return
        }

        if url.host == "open" {
            showMainWindow()
        }
    }

    private func performConnectionChange(
        index: UInt8,
        name: String,
        desiredConnected: Bool
    ) async {
        guard !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        if let cached = try? MomentumSnapshotStore.loadState() {
            try? MomentumSnapshotStore.save(MomentumWidgetState(
                snapshot: cached.snapshot,
                switchingDeviceIndex: index,
                actionToken: actionToken
            ))
            WidgetCenter.shared.reloadAllTimelines()
        }

        do {
            let snapshot: MomentumSnapshot
            if desiredConnected {
                snapshot = try await client.switchPeer(to: index, expectedName: name)
            } else {
                snapshot = try await client.disconnectPeer(index: index, expectedName: name)
            }
            cache(snapshot)
            mainViewModel?.accept(snapshot: snapshot)
        } catch {
            if let cached = try? MomentumSnapshotStore.loadState() {
                cache(cached.snapshot)
            }
            await refresh(afterOperation: true)
        }
    }
}
