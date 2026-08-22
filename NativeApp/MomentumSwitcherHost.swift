import AppKit
import MomentumBluetooth
import MomentumCore
import ServiceManagement
import SwiftUI
import WidgetKit

@main
struct MomentumSwitcherHostApp: App {
    @NSApplicationDelegateAdaptor(HostDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class HostDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
        if let cached = try? MomentumSnapshotStore.loadState(),
           cached.switchingDeviceIndex != nil || cached.actionToken != actionToken {
            cache(cached.snapshot)
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
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
            return
        }

        guard !isSwitching,
              url.host == "toggle",
              let indexText = components.queryItems?.first(where: { $0.name == "index" })?.value,
              let index = UInt8(indexText),
              let name = components.queryItems?.first(where: { $0.name == "name" })?.value,
              let connectedText = components.queryItems?.first(where: { $0.name == "connected" })?.value,
              let wasConnected = MomentumConnectedParameter.parse(connectedText) else {
            return
        }

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
            if wasConnected {
                snapshot = try await client.disconnectPeer(index: index, expectedName: name)
            } else {
                snapshot = try await client.switchPeer(to: index, expectedName: name)
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
