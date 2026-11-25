import AppKit
import BrokBotCore
import ServiceManagement
import SwiftUI

/// Safely wraps `SMAppService.mainApp` for silent Open-at-Login background registration.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var lastError: String?

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshStatus()
        } catch {
            refreshStatus()
            lastError = "Login item requires running from BrokBot.app bundle (\(error.localizedDescription))."
        }
    }
}

/// Application entry point and AppKit lifecycle coordinator supporting headless `--background` launch,
/// global `Cmd+Shift+B` hotkey, Liquid Glass menu bar popover, and safe local notifications.
@MainActor
@main
final class BrokBotAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var statusContextMenu: NSMenu?
    private var mainWindow: NSWindow?

    private lazy var workspaceViewModel = WorkspaceViewModel()
    private lazy var loginItemController = LoginItemController()
    private lazy var globalHotkeyManager = GlobalHotkeyManager()
    private lazy var localNotificationManager = LocalNotificationManager()

    static func main() {
        let app = NSApplication.shared
        let delegate = BrokBotAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isHeadless = CommandLine.arguments.contains("--background")

        localNotificationManager.onOpenWorkspaceRequested = { [weak self] requestID in
            self?.showMainWindow()
            if let requestID {
                Task { @MainActor [weak self] in
                    await self?.workspaceViewModel.openAttentionRequest(requestID: requestID)
                }
            }
        }
        localNotificationManager.onActionReceived = { [weak self] action, _, userInfo in
            guard let self,
                  let rawID = userInfo["request_id"] ?? userInfo["elicitation_id"],
                  let requestID = UUID(uuidString: rawID) else {
                return
            }
            switch action {
            case .approve:
                self.workspaceViewModel.respondToElicitation(requestID: requestID, action: .accept)
            case .deny:
                self.workspaceViewModel.respondToElicitation(requestID: requestID, action: .decline)
            case .reviewInApp:
                self.showMainWindow()
                Task { @MainActor [weak self] in
                    await self?.workspaceViewModel.openAttentionRequest(requestID: requestID)
                }
            }
        }
        workspaceViewModel.onNotifyAttention = { [weak self] payload in
            guard let self else { return }
            Task {
                _ = await self.localNotificationManager.scheduleNotification(payload)
            }
        }
        workspaceViewModel.onDismissNotification = { [weak self] requestID in
            self?.localNotificationManager.dismissNotification(requestID: requestID)
        }
        localNotificationManager.configureIfBundled()

        globalHotkeyManager.registerCmdShiftB { [weak self] in
            self?.toggleMainWindow()
        }

        setupStatusBarItem()

        if isHeadless {
            // Silent Open-at-Login daemon mode: keep menu bar active, do NOT open main window.
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            showMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotkeyManager.unregister()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    // MARK: - Menu Bar Status Item & Liquid Glass Popover

    private func setupStatusBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let icon = BrokAppResources.loadMenuBarTemplateImage()
            icon.isTemplate = true
            button.image = icon
            button.imagePosition = .imageOnly
            button.toolTip = "Brok Bot (⌘⇧B)"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "Open Brok Bot Workspace",
            action: #selector(openMainWindowAction),
            keyEquivalent: "b"
        )
        openItem.keyEquivalentModifierMask = [.command, .shift]
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Brok Bot",
            action: #selector(quitApplicationAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusContextMenu = menu
        statusItem = item
        configurePopover()
    }

    private func configurePopover() {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentSize = NSSize(width: 336, height: 390)

        let popoverContent = MenuBarPopoverView(
            viewModel: workspaceViewModel,
            notificationManager: localNotificationManager,
            onOpenWorkspace: { [weak self] in
                self?.closePopover()
                self?.showMainWindow()
            },
            onQuit: { [weak self] in
                self?.quitApplicationAction()
            }
        )
        let hostingController = NSHostingController(rootView: popoverContent)
        pop.contentViewController = hostingController
        popover = pop
    }

    @objc private func handleStatusItemClick(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isRightClick {
            closePopover()
            if let menu = statusContextMenu, let statusItem {
                statusItem.menu = menu
                button.performClick(nil)
                statusItem.menu = nil
            }
            return
        }

        togglePopover(relativeTo: button)
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover == nil {
            configurePopover()
        }
        guard let popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func closePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        }
    }

    // MARK: - Window Management

    @objc private func openMainWindowAction() {
        closePopover()
        showMainWindow()
    }

    @objc private func quitApplicationAction() {
        NSApplication.shared.terminate(nil)
    }

    func toggleMainWindow() {
        if let window = mainWindow, window.isVisible, !window.isMiniaturized, NSApp.isActive {
            window.orderOut(nil)
            return
        }
        closePopover()
        showMainWindow()
    }

    func showMainWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        let window = mainWindow ?? buildMainWindow()
        mainWindow = window
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMainWindow() -> NSWindow {
        let initialRect = NSRect(x: 0, y: 0, width: 1020, height: 700)
        let window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Brok Bot"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.center()

        let rootView = MainWorkspaceView(
            viewModel: workspaceViewModel,
            loginItemController: loginItemController,
            notificationManager: localNotificationManager,
            hotkeyManager: globalHotkeyManager
        )
        window.contentView = NSHostingView(rootView: rootView)
        return window
    }
}
