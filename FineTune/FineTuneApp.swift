// FineTune/FineTuneApp.swift
import SwiftUI
import UserNotifications
import AppKit
import os

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "App")

// MARK: - Menu Bar Popup Panel

/// Custom NSPanel that replicates FluidMenuBarExtra's popup behavior:
/// appears below the status item, dismisses on resign-key, no dock icon,
/// vibrancy popover material, status-bar level.
final class MenuBarPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(title: String) {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = title
        isMovable = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none
        collectionBehavior = [.stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Direct reference — `NSApp.delegate as? AppDelegate` fails because
    /// `@NSApplicationDelegateAdaptor` wraps the instance in a SwiftUI proxy.
    static weak var shared: AppDelegate?

    var audioEngine: AudioEngine?
    var settingsWindowController: NSWindowController?
    var settingsContentProvider: (() -> AnyView)?

    /// The app's NSStatusItem — created in `applicationDidFinishLaunching`.
    private(set) var statusItem: NSStatusItem?
    /// The popup panel shown below the status item.
    private var popupPanel: MenuBarPopupPanel?
    /// Content builder for the popup panel.
    var popupContentProvider: (() -> AnyView)?
    /// Event monitor for dismiss-on-click-outside behavior.
    private var globalEventMonitor: Any?
    /// Local event monitor for Cmd+, settings shortcut.
    private var localEventMonitor: Any?
    /// Observer for hosting view intrinsic content size changes.
    private var sizeObserver: NSObjectProtocol?
    /// Guards against re-entrant dismiss calls during fade animation.
    private var isDismissing = false
    /// Incremented each time showPopup() starts a new show cycle so the
    /// dismiss animation completion handler can detect a stale cycle.
    private var showCycleID: UInt = 0
    /// Icon to set on the status item once it's created. Stored during init,
    /// applied in applicationDidFinishLaunching when NSApplication is ready.
    var pendingLaunchIcon: NSImage?
    /// Callback fired once the status item's button is ready.
    var onStatusItemReady: ((NSStatusBarButton) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let audioEngine = audioEngine else {
            return
        }
        let urlHandler = URLHandler(audioEngine: audioEngine)

        for url in urls {
            urlHandler.handleURL(url)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    /// LSUIElement agent — closing the Settings window must not terminate the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Close any windows that the WindowGroup scene may auto-open.
        // LSUIElement apps should have zero visible windows at launch.
        for window in NSApp.windows {
            if window !== popupPanel && window !== settingsWindowController?.window {
                window.orderOut(nil)
            }
        }

        // Create the status item now that NSApplication's window server
        // connection is fully initialized (CGSConnectionByID crashes
        // if called from the App struct's init).
        if let icon = pendingLaunchIcon {
            setupStatusItem(icon: icon)
            pendingLaunchIcon = nil
            if let button = statusItem?.button {
                onStatusItemReady?(button)
                onStatusItemReady = nil
            }
        }

        // Cmd+, opens Settings (replaces the SwiftUI Settings scene shortcut).
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "," {
                self?.showSettingsWindow()
                return nil
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeGlobalEventMonitor()
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let observer = sizeObserver {
            NotificationCenter.default.removeObserver(observer)
            sizeObserver = nil
        }
    }

    func showSettingsWindow() {
        if let wc = settingsWindowController {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let contentProvider = settingsContentProvider else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 450),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FineTune Settings"
        window.center()
        window.contentView = NSHostingView(rootView: contentProvider())
        window.isReleasedWhenClosed = false
        let wc = NSWindowController(window: window)
        settingsWindowController = wc
        wc.showWindow(nil)
        NSApp.activate()
    }

    // MARK: - Status Item

    func setupStatusItem(icon: NSImage) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = icon
        item.button?.setAccessibilityTitle("FineTune")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        togglePopup()
    }

    // MARK: - Popup Panel

    func togglePopup() {
        if isDismissing {
            // Dismiss animation in flight — cancel it and re-show.
            cancelDismissAndShow()
            return
        }
        guard let panel = popupPanel else {
            showPopup()
            return
        }
        if panel.isVisible {
            dismissPopup()
        } else {
            showPopup()
        }
    }

    private func cancelDismissAndShow() {
        guard let panel = popupPanel else { return }
        // Cancel the in-flight fade by snapping to fully visible.
        panel.animator().alphaValue = 1
        panel.alphaValue = 1
        isDismissing = false
        showCycleID &+= 1
        panel.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(true)
        NSApp.activate()
        if globalEventMonitor == nil {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismissPopup()
            }
        }
    }

    private func showPopup() {
        guard let button = statusItem?.button,
              let contentProvider = popupContentProvider else { return }

        let panel: MenuBarPopupPanel
        if let existing = popupPanel {
            panel = existing
        } else {
            panel = MenuBarPopupPanel(title: "FineTune")
            panel.delegate = self
            popupPanel = panel

            let hostingView = NSHostingView(rootView: contentProvider())
            hostingView.postsFrameChangedNotifications = true
            sizeObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: hostingView,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { self.updatePanelSize() }
            }
            panel.contentView = hostingView
        }

        updatePanelSize(panel)
        positionPanelBelowButton(panel, button: button)

        // Persist the menu bar in full screen mode (same notification FluidMenuBarExtra used).
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.HIToolbox.beginMenuTrackingNotification"),
            object: nil
        )
        showCycleID &+= 1
        isDismissing = false
        panel.alphaValue = 1
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(true)

        // Start global event monitor for clicks outside
        if globalEventMonitor == nil {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismissPopup()
            }
        }
    }

    /// Re-read the hosting view's fitting size and resize the panel + reposition.
    func updatePanelSize(_ panel: MenuBarPopupPanel? = nil) {
        guard let panel = panel ?? popupPanel,
              let hostingView = panel.contentView else { return }
        let fittingSize = hostingView.fittingSize
        if fittingSize.width > 10 && fittingSize.height > 10 {
            panel.setContentSize(fittingSize)
        } else {
            panel.setContentSize(NSSize(width: 360, height: 500))
        }
        if panel.isVisible, let button = statusItem?.button {
            positionPanelBelowButton(panel, button: button)
        }
    }

    private func positionPanelBelowButton(_ panel: NSPanel, button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        var origin = CGPoint(
            x: screenRect.minX,
            y: screenRect.minY - panel.frame.height
        )

        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            if origin.x + panel.frame.width > visibleFrame.maxX {
                origin.x = screenRect.maxX - panel.frame.width
            }
            if origin.x < visibleFrame.minX {
                origin.x = visibleFrame.minX
            }
            if origin.y < visibleFrame.minY {
                origin.y = visibleFrame.minY
            }
        }

        panel.setFrameOrigin(origin)
    }

    func dismissPopup() {
        guard !isDismissing else { return }
        guard let panel = popupPanel, panel.isVisible else { return }
        isDismissing = true

        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.HIToolbox.endMenuTrackingNotification"),
            object: nil
        )

        removeGlobalEventMonitor()

        let cycleAtDismiss = showCycleID
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            // A new show cycle started during the fade — don't hide the panel.
            guard self.showCycleID == cycleAtDismiss else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.statusItem?.button?.highlight(false)
            self.isDismissing = false
        }
    }

    private func removeGlobalEventMonitor() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === popupPanel else { return }
        statusItem?.button?.highlight(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === popupPanel else { return }
        dismissPopup()
    }
}

// MARK: - App

@main
struct FineTuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var audioEngine: AudioEngine
    @State private var accessibility: AccessibilityPermissionService
    @State private var mediaKeyStatus: MediaKeyStatus
    @State private var popupVisibility: PopupVisibilityService
    @State private var hudController: HUDWindowController
    @State private var mediaKeyMonitor: MediaKeyMonitor
    @State private var iconCoordinator: MenuBarIconCoordinator
    @State private var menuBarPopupController: MenuBarPopupController
    @State private var shortcutsRegistry: ShortcutsRegistry
    @State private var resolver: TargetAppResolver
    @StateObject private var updateManager = UpdateManager()

    var body: some Scene {
        // Minimal scene that satisfies the `some Scene` requirement without
        // triggering the macOS 14 / Xcode 15 `Settings { EmptyView() }` crash.
        // The WindowGroup never actually shows — applicationDidFinishLaunching
        // closes it, and applicationShouldTerminateAfterLastWindowClosed keeps
        // the agent app alive.
        WindowGroup(id: "finetune-hidden") {
            EmptyView()
                .frame(width: 0, height: 0)
                .hidden()
        }
    }

    init() {
        // Install crash handler to clean up aggregate devices on abnormal exit
        CrashGuard.install()
        // Destroy any orphaned aggregate devices from previous crashes
        OrphanedTapCleanup.destroyOrphanedDevices()

        let settings = SettingsManager()
        let profileManager = AutoEQProfileManager()
        let permission = AudioRecordingPermission()
        let engine = AudioEngine(permission: permission, settingsManager: settings, autoEQProfileManager: profileManager)
        _audioEngine = State(initialValue: engine)

        // Media keys / HUD services — instantiated at app scope so the tap
        // and HUD panel outlive popup open/close cycles.
        let accessibilityService = AccessibilityPermissionService()
        let statusService = MediaKeyStatus()
        let popupService = PopupVisibilityService()
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: statusService, popupVisibility: popupService)

        // Wire the interactive Tahoe slider back to the device volume monitor.
        // Mirrors the mute semantics applied for media-key drags (auto-unmute
        // when ramping above 0 from muted; auto-mute when dragging down to 0)
        // so the HUD slider and F11/F12 behave identically.
        hud.volumeWriter = { [weak engine] sliderFraction in
            guard let engine else { return }
            let volumeMonitor = engine.deviceVolumeMonitor
            let deviceID = volumeMonitor.defaultDeviceID
            guard deviceID.isValid else { return }
            let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
            let currentMute = volumeMonitor.muteStates[deviceID] ?? false
            let willBeSilent = sliderFraction <= 0.001
            if currentMute && !willBeSilent {
                volumeMonitor.setMute(for: deviceID, to: false)
            } else if !currentMute && willBeSilent {
                volumeMonitor.setMute(for: deviceID, to: true)
            }
            let gain = VolumeMapping.systemGain(forSliderFraction: sliderFraction, tier: tier)
            volumeMonitor.setVolume(for: deviceID, to: gain)
        }

        let monitor = MediaKeyMonitor(
            decoder: IOKitMediaKeyDecoder(),
            audioEngine: engine,
            settingsManager: settings,
            accessibility: accessibilityService,
            hudController: hud,
            popupVisibility: popupService,
            mediaKeyStatus: statusService
        )
        _accessibility = State(initialValue: accessibilityService)
        _mediaKeyStatus = State(initialValue: statusService)
        _popupVisibility = State(initialValue: popupService)
        _hudController = State(initialValue: hud)
        _mediaKeyMonitor = State(initialValue: monitor)

        let coordinator = MenuBarIconCoordinator(deviceVolumeMonitor: engine.deviceVolumeMonitor as! DeviceVolumeMonitor, settings: settings)
        monitor.iconCoordinator = coordinator
        _iconCoordinator = State(initialValue: coordinator)

        // Render the status item's first frame with the user's chosen style instead of a generic
        // placeholder, so non-speaker styles don't briefly flash a speaker icon at launch.
        let launchVolumeMonitor = engine.deviceVolumeMonitor
        let launchID = launchVolumeMonitor.defaultDeviceID
        let launchState = MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: launchVolumeMonitor.volumes[launchID] ?? 1.0,
            muted: launchVolumeMonitor.muteStates[launchID] ?? false
        )
        let launchIconImage = launchState.image.nsImage()
            ?? NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "FineTune")!

        // Defer status item creation to applicationDidFinishLaunching —
        // NSStatusBar.system.statusItem crashes with a CGSConnectionByID
        // assertion if called before NSApplication is fully bootstrapped.
        _appDelegate.wrappedValue.pendingLaunchIcon = launchIconImage
        _appDelegate.wrappedValue.onStatusItemReady = { [weak coordinator] button in
            coordinator?.statusButton = button
            coordinator?.start()
        }

        // Start Accessibility polling immediately so `isTrustedCached` is live
        // before the user first opens Settings. The trust-flip callback wires
        // the monitor to reconcile its tap state whenever trust changes — this
        // is the single source of truth for retroactive start/stop (a `.onChange`
        // inside MenuBarPopupView would miss flips when the popup is closed).
        accessibilityService.onTrustChanged = { [weak monitor] _ in
            monitor?.reconcile()
        }
        accessibilityService.start()
        monitor.reconcile()

        // Global hotkeys (KeyboardShortcuts SPM, Carbon-backed; no Accessibility
        // permission required for the hotkey itself).
        let popupController = MenuBarPopupController()
        let resolver = TargetAppResolver(
            ownBundleID: Bundle.main.bundleIdentifier ?? "com.finetuneapp.FineTune"
        )
        resolver.start()
        let registry = ShortcutsRegistry(
            settings: settings,
            popupController: popupController,
            resolver: resolver,
            audioEngine: engine,
            hud: hud
        )
        _menuBarPopupController = State(initialValue: popupController)
        _shortcutsRegistry = State(initialValue: registry)
        _resolver = State(initialValue: resolver)

        // Wire the popup controller to the AppDelegate's toggle method.
        popupController.appDelegate = _appDelegate.wrappedValue

        // Pass engine to AppDelegate
        _appDelegate.wrappedValue.audioEngine = engine
        _appDelegate.wrappedValue.settingsContentProvider = { [weak engine, weak accessibilityService, weak statusService, weak monitor, weak registry, updateManager] in
            guard let engine, let accessibilityService, let statusService, let monitor, let registry else {
                return AnyView(EmptyView())
            }
            return AnyView(
                SettingsRootView(
                    settings: engine.settingsManager,
                    audioEngine: engine,
                    deviceVolumeMonitor: engine.deviceVolumeMonitor as! DeviceVolumeMonitor,
                    accessibility: accessibilityService,
                    mediaKeyStatus: statusService,
                    mediaKeyMonitor: monitor,
                    shortcutsRegistry: registry,
                    updateManager: updateManager
                )
            )
        }

        // Build the popup content provider for the menu bar panel.
        _appDelegate.wrappedValue.popupContentProvider = { [weak engine, weak accessibilityService, weak statusService, weak popupService, weak hud, weak monitor, weak registry, updateManager] in
            guard let engine, let accessibilityService, let statusService, let popupService, let hud, let monitor else {
                return AnyView(EmptyView())
            }
            return AnyView(
                MenuBarPopupView(
                    audioEngine: engine,
                    deviceVolumeMonitor: engine.deviceVolumeMonitor as! DeviceVolumeMonitor,
                    updateManager: updateManager,
                    permission: engine.permission,
                    accessibility: accessibilityService,
                    mediaKeyStatus: statusService,
                    popupVisibility: popupService,
                    hudController: hud,
                    mediaKeyMonitor: monitor
                )
                .task {
                    registry?.start()
                }
            )
        }

        if permission.status == .unknown {
            permission.request()
        }

        // DeviceVolumeMonitor is now created and started inside AudioEngine
        // This ensures proper initialization order: deviceMonitor.start() -> deviceVolumeMonitor.start()

        // Set delegate before requesting authorization so willPresent is called
        UNUserNotificationCenter.current().delegate = _appDelegate.wrappedValue

        // Request notification authorization (for device disconnect alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
            // If not granted, notifications will silently not appear - acceptable behavior
        }

        // Flush debounced settings + tear down the CGEventTap before dealloc.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [settings, monitor, accessibilityService, hud, coordinator] _ in
            MainActor.assumeIsolated {
                coordinator.stop()
                monitor.stop()
                accessibilityService.stop()
                hud.shutdown()
            }
            settings.flushSync()
        }
    }
}
