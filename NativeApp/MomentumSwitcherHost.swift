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
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
    private var statusItem: NSStatusItem?
    private var controlPanel: MenuPanel?
    private var outsideClickMonitor: Any?
    private var pendingPanelShow: DispatchWorkItem?
    private var mainViewModel: MomentumMainViewModel?
    private var widgetActionQueueWatcher: MomentumWidgetActionQueueWatcher?

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenuBarItem()
        _ = NSApp.setActivationPolicy(.accessory)
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
        if MomentumLaunchPolicy.shouldShowWindow(launchedAsLoginItem: launchedAsLoginItem) {
            showControlPanel(activatingApplication: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingPanelShow?.cancel()
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
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
        showControlPanel(activatingApplication: true)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "momentum-switcher" {
            Task { await handle(url) }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? MenuPanel,
              panel === controlPanel else { return }
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible, !panel.isKeyWindow else { return }
            self.closeControlPanel()
        }
    }

    private func installMenuBarItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "headphones",
                accessibilityDescription: "M4 Companion"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "M4 Companion"
            button.target = self
            button.action = #selector(toggleControlPanel)
        }
        statusItem = item
    }

    @objc private func toggleControlPanel() {
        if controlPanel?.isVisible == true {
            closeControlPanel()
        } else {
            showControlPanel(activatingApplication: false)
        }
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

    private func showControlPanel(activatingApplication: Bool, retryCount: Int = 0) {
        pendingPanelShow?.cancel()
        pendingPanelShow = nil
        guard let button = statusItem?.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen else {
            retryShowControlPanel(
                activatingApplication: activatingApplication,
                retryCount: retryCount
            )
            return
        }
        let anchorRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screenFrame = screen.visibleFrame
        guard anchorRect.width > 0,
              anchorRect.height > 0,
              screenFrame.contains(NSPoint(x: anchorRect.midX, y: screenFrame.midY)),
              anchorRect.minY >= screenFrame.maxY - 2 else {
            retryShowControlPanel(
                activatingApplication: activatingApplication,
                retryCount: retryCount
            )
            return
        }

        let viewModel: MomentumMainViewModel
        if let existing = mainViewModel {
            viewModel = existing
        } else {
            viewModel = MomentumMainViewModel(client: client) { [weak self] snapshot in
                self?.cache(snapshot)
            }
            mainViewModel = viewModel
        }

        if controlPanel == nil {
            let controller = NSHostingController(rootView: MomentumMainView(
                model: viewModel,
                checkForUpdates: { [weak self] in self?.checkForUpdates() },
                quit: { NSApp.terminate(nil) }
            ))
            let panelSize = NSSize(width: 390, height: 700)
            let panel = MenuPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentViewController = controller
            panel.setContentSize(panelSize)
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = 14
            panel.contentView?.layer?.cornerCurve = .continuous
            panel.contentView?.layer?.masksToBounds = true
            // Set these after isFloatingPanel/contentViewController, which otherwise
            // reset the level and resize the panel to the SwiftUI intrinsic size.
            panel.level = .popUpMenu
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .ignoresCycle,
                .stationary,
                .transient,
            ]
            panel.delegate = self
            controlPanel = panel
        }

        guard let controlPanel else { return }
        if activatingApplication {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !controlPanel.isVisible {
            let size = controlPanel.frame.size
            let unclampedX = anchorRect.midX - size.width / 2
            let x = min(max(unclampedX, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
            let y = max(screenFrame.minY + 8, anchorRect.minY - size.height - 6)
            controlPanel.setFrameOrigin(NSPoint(x: x, y: y))
            controlPanel.makeKeyAndOrderFront(nil)
            installOutsideClickMonitor()
        }
        Task { [weak controlPanel] in
            await viewModel.refresh()
            guard controlPanel?.isVisible == true else { return }
            viewModel.startAutomaticSync()
        }
    }

    private func retryShowControlPanel(activatingApplication: Bool, retryCount: Int) {
        guard retryCount < 20 else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.showControlPanel(
                activatingApplication: activatingApplication,
                retryCount: retryCount + 1
            )
        }
        pendingPanelShow = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: workItem)
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closeControlPanel()
            }
        }
    }

    private func closeControlPanel() {
        pendingPanelShow?.cancel()
        pendingPanelShow = nil
        controlPanel?.orderOut(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        mainViewModel?.stopAutomaticSync()
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
            showControlPanel(activatingApplication: true)
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
