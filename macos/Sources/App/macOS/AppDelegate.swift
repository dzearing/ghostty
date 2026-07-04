import AppKit
import SwiftUI
import UserNotifications
import OSLog
import Sparkle
import GhosttyKit

class AppDelegate: NSObject,
                    ObservableObject,
                    NSApplicationDelegate,
                    UNUserNotificationCenterDelegate,
                    GhosttyAppDelegate {
    // The application logger. We should probably move this at some point to a dedicated
    // class/struct but for now it lives here! 🤷‍♂️
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: AppDelegate.self)
    )

    /// Various menu items so that we can programmatically sync the keyboard shortcut with the Ghostty config
    @IBOutlet private var menuAbout: NSMenuItem?
    @IBOutlet private var menuServices: NSMenu?
    @IBOutlet private var menuCheckForUpdates: NSMenuItem?
    @IBOutlet private var menuOpenConfig: NSMenuItem?
    @IBOutlet private var menuReloadConfig: NSMenuItem?
    @IBOutlet private var menuSecureInput: NSMenuItem?
    @IBOutlet private var menuQuit: NSMenuItem?

    @IBOutlet private var menuNewWindow: NSMenuItem?
    @IBOutlet private var menuNewTab: NSMenuItem?
    @IBOutlet private var menuSplitRight: NSMenuItem?
    @IBOutlet private var menuSplitLeft: NSMenuItem?
    @IBOutlet private var menuSplitDown: NSMenuItem?
    @IBOutlet private var menuSplitUp: NSMenuItem?
    @IBOutlet private var menuClose: NSMenuItem?
    @IBOutlet private var menuCloseTab: NSMenuItem?
    @IBOutlet private var menuCloseWindow: NSMenuItem?
    @IBOutlet private var menuCloseAllWindows: NSMenuItem?

    @IBOutlet private var menuUndo: NSMenuItem?
    @IBOutlet private var menuRedo: NSMenuItem?
    @IBOutlet private var menuCopy: NSMenuItem?
    @IBOutlet private var menuPaste: NSMenuItem?
    @IBOutlet private var menuPasteSelection: NSMenuItem?
    @IBOutlet private var menuSelectAll: NSMenuItem?
    @IBOutlet private var menuFindParent: NSMenuItem?
    @IBOutlet private var menuFind: NSMenuItem?
    @IBOutlet private var menuSelectionForFind: NSMenuItem?
    @IBOutlet private var menuScrollToSelection: NSMenuItem?
    @IBOutlet private var menuFindNext: NSMenuItem?
    @IBOutlet private var menuFindPrevious: NSMenuItem?
    @IBOutlet private var menuHideFindBar: NSMenuItem?

    @IBOutlet private var menuToggleVisibility: NSMenuItem?
    @IBOutlet private var menuToggleFullScreen: NSMenuItem?
    @IBOutlet private var menuBringAllToFront: NSMenuItem?
    @IBOutlet private var menuZoomSplit: NSMenuItem?
    @IBOutlet private var menuPreviousSplit: NSMenuItem?
    @IBOutlet private var menuNextSplit: NSMenuItem?
    @IBOutlet private var menuSelectSplitAbove: NSMenuItem?
    @IBOutlet private var menuSelectSplitBelow: NSMenuItem?
    @IBOutlet private var menuSelectSplitLeft: NSMenuItem?
    @IBOutlet private var menuSelectSplitRight: NSMenuItem?
    @IBOutlet private var menuReturnToDefaultSize: NSMenuItem?
    @IBOutlet private var menuFloatOnTop: NSMenuItem?
    @IBOutlet private var menuUseAsDefault: NSMenuItem?
    @IBOutlet private var menuSetAsDefaultTerminal: NSMenuItem?

    @IBOutlet private var menuIncreaseFontSize: NSMenuItem?
    @IBOutlet private var menuDecreaseFontSize: NSMenuItem?
    @IBOutlet private var menuResetFontSize: NSMenuItem?
    @IBOutlet private var menuChangeTitle: NSMenuItem?
    @IBOutlet private var menuChangeTabTitle: NSMenuItem?
    @IBOutlet private var menuReadonly: NSMenuItem?
    @IBOutlet private var menuQuickTerminal: NSMenuItem?
    @IBOutlet private var menuTerminalInspector: NSMenuItem?
    @IBOutlet private var menuCommandPalette: NSMenuItem?

    @IBOutlet private var menuEqualizeSplits: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerUp: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerDown: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerLeft: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerRight: NSMenuItem?

    /// The dock menu
    private var dockMenu: NSMenu = NSMenu()

    /// This is only true before application has become active.
    private var applicationHasBecomeActive: Bool = false

    /// WP-D2: true while the app is quitting. Window-close teardown checks
    /// this so remote windows closed BY THE QUIT keep their entries in the
    /// `RemoteSessionManifest` (they are restored, i.e. re-`ATTACH`ed, on the
    /// next launch); only a user-initiated close removes an entry.
    private(set) var isQuitting: Bool = false

    /// WP-B2: true while sign-out is closing account-backed (relay) remote
    /// windows. Same contract as `isQuitting`: `windowWillClose` preserves
    /// those windows' `RemoteSessionManifest` entries so a later sign-in can
    /// restore (re-`ATTACH`) them. See `relayAccountDidSignOut()`.
    private(set) var isSigningOut: Bool = false

    /// This is set in applicationDidFinishLaunching with the system uptime so we can determine the
    /// seconds since the process was launched.
    private var applicationLaunchTime: TimeInterval = 0

    /// This is the current configuration from the Ghostty configuration that we need.
    private var derivedConfig: DerivedConfig = DerivedConfig()

    private lazy var ipcServer = IPCServer(ghostty: ghostty)
    private var hasPendingIpc = false

    /// The ghostty global state. Only one per process.
    let ghostty: Ghostty.App

    /// The global undo manager for app-level state such as window restoration.
    lazy var undoManager = ExpiringUndoManager()

    /// The current state of the quick terminal.
    private var quickTerminalControllerState: QuickTerminalState = .uninitialized

    /// Our quick terminal. This starts out uninitialized and only initializes if used.
    var quickController: QuickTerminalController {
        switch quickTerminalControllerState {
        case .initialized(let controller):
            return controller

        case .pendingRestore(let state):
            let controller = QuickTerminalController(
                ghostty,
                position: derivedConfig.quickTerminalPosition,
                baseConfig: state.baseConfig,
                restorationState: state
            )
            quickTerminalControllerState = .initialized(controller)
            return controller

        case .uninitialized:
            let controller = QuickTerminalController(
                ghostty,
                position: derivedConfig.quickTerminalPosition,
                restorationState: nil
            )
            quickTerminalControllerState = .initialized(controller)
            return controller
        }
    }

    /// Manages updates
    let updateController = UpdateController()
    var updateViewModel: UpdateViewModel {
        updateController.viewModel
    }

    /// The elapsed time since the process was started
    var timeSinceLaunch: TimeInterval {
        return ProcessInfo.processInfo.systemUptime - applicationLaunchTime
    }

    /// Tracks the windows that we hid for toggleVisibility.
    private(set) var hiddenState: ToggleVisibilityState?

    /// The observer for the app appearance.
    private var appearanceObserver: NSKeyValueObservation?

    /// Signals
    private var signals: [DispatchSourceSignal] = []

    private let appIconUpdater = AppIconUpdater()

    @MainActor private lazy var menuShortcutManager = Ghostty.MenuShortcutManager()

    override init() {
#if DEBUG
        ghostty = Ghostty.App(configPath: ProcessInfo.processInfo.environment["GHOSTTY_CONFIG_PATH"])
#else
        ghostty = Ghostty.App()
#endif
        super.init()

        ghostty.delegate = self
    }

    // MARK: - NSApplicationDelegate

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if
            let suite = UserDefaults.ghosttySuite,
            let clear = ProcessInfo.processInfo.environment["GHOSTTY_CLEAR_USER_DEFAULTS"],
            (clear as NSString).boolValue {
            UserDefaults.ghostty.removePersistentDomain(forName: suite)
        }
        #endif
        UserDefaults.ghostty.register(defaults: [
            // Disable the automatic full screen menu item because we handle
            // it manually.
            "NSFullScreenMenuItemEverywhere": false,

            // On macOS 26 RC1, the autofill heuristic controller causes unusable levels
            // of slowdowns and CPU usage in the terminal window under certain [unknown]
            // conditions. We don't know exactly why/how. This disables the full heuristic
            // controller.
            //
            // Practically, this means things like SMS autofill don't work, but that is
            // a desirable behavior to NOT have happen for a terminal, so this is a win.
            // Manual autofill via the `Edit => AutoFill` menu item still work as expected.
            "NSAutoFillHeuristicControllerEnabled": false,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // System settings overrides
        UserDefaults.ghostty.register(defaults: [
            // Disable this so that repeated key events make it through to our terminal views.
            "ApplePressAndHoldEnabled": false,
        ])

        // Store our start time
        applicationLaunchTime = ProcessInfo.processInfo.systemUptime

        // Check if secure input was enabled when we last quit.
        if UserDefaults.ghostty.bool(forKey: "SecureInput") != SecureInput.shared.enabled {
            toggleSecureInput(self)
        }

        // Initial config loading
        ghosttyConfigDidChange(config: ghostty.config)

        // Start our update checker.
        updateController.startUpdater()

        // Register our service provider. This must happen after everything is initialized.
        NSApp.servicesProvider = ServiceProvider()

        // This registers the Ghostty => Services menu to exist.
        NSApp.servicesMenu = menuServices

        ipcServer.start()

        if let jsonPtr = ghostty_pending_ipc_json() {
            let json = String(cString: jsonPtr)
            ghostty_consume_pending_ipc_json()
            hasPendingIpc = true
            ipcServer.dispatchPendingJson(json)
        }

        // WP-D2: re-attach any relay remote windows that were open when the
        // app last quit (background dials; failures never alert).
        restoreRemoteWindows()

        // Setup a local event monitor for app-level keyboard shortcuts. See
        // localEventHandler for more info why.
        _ = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown],
            handler: localEventHandler)

        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quickTerminalDidChangeVisibility),
            name: .quickTerminalDidChangeVisibility,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyBellDidRing(_:)),
            name: .ghosttyBellDidRing,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalWindowHasBell(_:)),
            name: .terminalWindowBellDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyNewWindow(_:)),
            name: Ghostty.Notification.ghosttyNewWindow,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyNewTab(_:)),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)

        // Configure user notifications
        let actions = [
            UNNotificationAction(identifier: Ghostty.userNotificationActionShow, title: "Show")
        ]

        let center = UNUserNotificationCenter.current()

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Ghostty.userNotificationCategory,
                actions: actions,
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        ])
        center.delegate = self

        // Observe our appearance so we can report the correct value to libghostty.
        self.appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance,
             options: [.new, .initial]
        ) { _, change in
            guard let appearance = change.newValue else { return }
            guard let app = self.ghostty.app else { return }
            let scheme: ghostty_color_scheme_e
            if appearance.isDark {
                scheme = GHOSTTY_COLOR_SCHEME_DARK
            } else {
                scheme = GHOSTTY_COLOR_SCHEME_LIGHT
            }

            ghostty_app_set_color_scheme(app, scheme)
        }

        // Setup our menu
        setupMenuImages()

        // Setup signal handlers
        setupSignals()

        switch Ghostty.launchSource {
        case .app:
            // Don't have to do anything.
            break

        case .zig_run, .cli:
            // Part of launch services (clicking an app, using `open`, etc.) activates
            // the application and brings it to the front. When using the CLI we don't
            // get this behavior, so we have to do it manually.

            // This never gets called until we click the dock icon. This forces it
            // activate immediately.
            applicationDidBecomeActive(.init(name: NSApplication.didBecomeActiveNotification))

            // We run in the background, this forces us to the front.
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.unhide(nil)
                NSApp.arrangeInFront(nil)
            }
        }
    }

    func applicationDidHide(_ notification: Notification) {
        // Keep track of our hidden state to restore properly
        self.hiddenState = .init()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // If we're back manually then clear the hidden state because macOS handles it.
        self.hiddenState = nil

        // First launch stuff
        if !applicationHasBecomeActive {
            applicationHasBecomeActive = true

            // Let's launch our first window. We only do this if we have no other windows. It
            // is possible to have other windows in a few scenarios:
            //   - if we're opening a URL since `application(_:openFile:)` is called before this.
            //   - if we're restoring from persisted state
            if TerminalController.all.isEmpty && derivedConfig.initialWindow && !hasPendingIpc {
                undoManager.disableUndoRegistration()
                _ = TerminalController.newWindow(ghostty)
                undoManager.enableUndoRegistration()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return derivedConfig.shouldQuitAfterLastWindowClosed
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // WP-D2: assume the quit proceeds so remote windows torn down by it
        // keep their restore-manifest entries. Reset on the (single) cancel
        // path below.
        isQuitting = true

        let windows = NSApplication.shared.windows
        if windows.isEmpty { return .terminateNow }

        // If we've already accepted to install an update, then we don't need to
        // confirm quit. The user is already expecting the update to happen.
        if updateController.isInstalling {
            return .terminateNow
        }

        // This probably isn't fully safe. The isEmpty check above is aspirational, it doesn't
        // quite work with SwiftUI because windows are retained on close. So instead we check
        // if there are any that are visible. I'm guessing this breaks under certain scenarios.
        //
        // NOTE(mitchellh): I don't think we need this check at all anymore. I'm keeping it
        // here because I don't want to remove it in a patch release cycle but we should
        // target removing it soon.
        if (windows.allSatisfy { !$0.isVisible }) {
            return .terminateNow
        }

        // If the user is shutting down, restarting, or logging out, we don't confirm quit.
        why: if let event = NSAppleEventManager.shared().currentAppleEvent {
            // If all Ghostty windows are in the background (i.e. you Cmd-Q from the Cmd-Tab
            // view), then this is null. I don't know why (pun intended) but we have to
            // guard against it.
            guard let keyword = AEKeyword("why?") else { break why }

            if let why = event.attributeDescriptor(forKeyword: keyword) {
                switch why.typeCodeValue {
                case kAEShutDown, kAERestart, kAEReallyLogOut:
                    return .terminateNow

                default:
                    break
                }
            }
        }

        // If our app says we don't need to confirm, we can exit now.
        if !ghostty.needsConfirmQuit { return .terminateNow }

        // We have some visible window. Show an app-wide modal to confirm quitting.
        let alert = NSAlert()
        alert.messageText = "Quit Ghoztty?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close Ghoztty")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .terminateNow

        default:
            // Quit cancelled: subsequent window closes are user-initiated
            // again and must remove their restore-manifest entries.
            isQuitting = false
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // We have no notifications we want to persist after death,
        // so remove them all now. In the future we may want to be
        // more selective and only remove surface-targeted notifications.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()

        ipcServer.stop()
    }

    /// This is called when the application is already open and someone double-clicks the icon
    /// or clicks the dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If we have visible windows then we allow macOS to do its default behavior
        // of focusing one of them.
        guard !flag else { return true }

        // If we have any windows in our terminal manager we don't do anything.
        // This is possible with flag set to false if there a race where the
        // window is still initializing and is not visible but the user clicked
        // the dock icon.
        guard TerminalController.all.isEmpty else { return true }

        // If the application isn't active yet then we don't want to process
        // this because we're not ready. This happens sometimes in Xcode runs
        // but I haven't seen it happen in releases. I'm unsure why.
        guard applicationHasBecomeActive else { return true }

        // No visible windows, open a new one.
        _ = TerminalController.newWindow(ghostty)
        return false
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Ghostty will validate as well but we can avoid creating an entirely new
        // surface by doing our own validation here. We can also show a useful error
        // this way.

        var isDirectory = ObjCBool(true)
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDirectory) else { return false }

        // Set to true if confirmation is required before starting up the
        // new terminal.
        var requiresConfirm: Bool = false

        // Initialize the surface config which will be used to create the tab or window for the opened file.
        var config = Ghostty.SurfaceConfiguration()

        if isDirectory.boolValue {
            // When opening a directory, check the configuration to decide
            // whether to open in a new tab or new window.
            config.workingDirectory = filename
        } else {
            // Unconditionally require confirmation in the file execution case.
            // In the future I have ideas about making this more fine-grained if
            // we can not inherit of unsandboxed state. For now, we need to confirm
            // because there is a sandbox escape possible if a sandboxed application
            // somehow is tricked into `open`-ing a non-sandboxed application.
            requiresConfirm = true

            // When opening a file, we want to execute the file. To do this, we
            // don't override the command directly, because it won't load the
            // profile/rc files for the shell, which is super important on macOS
            // due to things like Homebrew. Instead, we set the command to
            // `<filename>; exit` which is what Terminal and iTerm2 do.
            config.initialInput = "\(Ghostty.Shell.quote(filename)); exit\n"

            // For commands executed directly, we want to ensure we wait after exit
            // because in most cases scripts don't block on exit and we don't want
            // the window to just flash closed once complete.
            config.waitAfterCommand = true

            // Set the parent directory to our working directory so that relative
            // paths in scripts work.
            config.workingDirectory = (filename as NSString).deletingLastPathComponent
        }

        if requiresConfirm {
            // Confirmation required. We use an app-wide NSAlert for now. In the future we
            // may want to show this as a sheet on the focused window (especially if we're
            // opening a tab). I'm not sure.
            let alert = NSAlert()
            alert.messageText = "Allow Ghoztty to execute \"\(filename)\"?"
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                break

            default:
                return false
            }
        }

        switch ghostty.config.macosDockDropBehavior {
        case .new_tab:
            _ = TerminalController.newTab(
                ghostty,
                from: TerminalController.preferredParent?.window,
                withBaseConfig: config
            )
        case .new_window: _ = TerminalController.newWindow(ghostty, withBaseConfig: config)
        }

        return true
    }

    /// Setup signal handlers
    private func setupSignals() {
        // Register a signal handler for config reloading. It appears that all
        // of this is required. I've commented each line because its a bit unclear.
        // Warning: signal handlers don't work when run via Xcode. They have to be
        // run on a real app bundle.

        // We need to ignore signals we register with makeSignalSource or they
        // don't seem to handle.
        signal(SIGUSR2, SIG_IGN)

        // Make the signal source and register our event handle. We keep a weak
        // ref to ourself so we don't create a retain cycle.
        let sigusr2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        sigusr2.setEventHandler { [weak self] in
            guard let self else { return }
            Ghostty.logger.info("reloading configuration in response to SIGUSR2")
            self.ghostty.reloadConfig()
        }

        // The signal source starts unactivated, so we have to resume it once
        // we setup the event handler.
        sigusr2.resume()

        // We need to keep a strong reference to it so it isn't disabled.
        signals.append(sigusr2)
    }

    // MARK: Notifications and Events

    /// This handles events from the NSEvent.addLocalEventMonitor. We use this so we can get
    /// events without any terminal windows open.
    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        return switch event.type {
        case .keyDown:
            localEventKeyDown(event)

        default:
            event
        }
    }

    private func localEventKeyDown(_ event: NSEvent) -> NSEvent? {
        // If the tab overview is visible and escape is pressed, close it.
        // This can't POSSIBLY be right and is probably a FirstResponder problem
        // that we should handle elsewhere in our program. But this works and it
        // is guarded by the tab overview currently showing.
        if event.keyCode == 0x35, // Escape key
           let window = NSApp.keyWindow,
           let tabGroup = window.tabGroup,
           tabGroup.isOverviewVisible {
            window.toggleTabOverview(nil)
            return nil
        }

        // If we have a main window then we don't process any of the keys
        // because we let it capture and propagate.
        guard NSApp.mainWindow == nil else { return event }

        // If this event as-is would result in a key binding then we send it.
        if let app = ghostty.app, let config = ghostty.config.config {
            var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            let match = (event.characters ?? "").withCString { ptr in
                ghosttyEvent.text = ptr
                if !ghostty_config_key_is_binding(config, ghosttyEvent) {
                    return false
                }

                return ghostty_app_key(app, ghosttyEvent)
            }

            // If the key was handled by Ghostty we stop the event chain. If
            // the key wasn't handled then we let it fall through and continue
            // processing. This is important because some bindings may have no
            // affect at this scope.
            if match {
                return nil
            }
        }

        // If this event would be handled by our menu then we do nothing.
        if let mainMenu = NSApp.mainMenu,
           mainMenu.performKeyEquivalent(with: event) {
            return nil
        }

        // If we reach this point then we try to process the key event
        // through the Ghostty key mechanism.

        // Ghostty must be loaded
        guard let ghostty = self.ghostty.app else { return event }

        // Build our event input and call ghostty
        if ghostty_app_key(ghostty, event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)) {
            // The key was used so we want to stop it from going to our Mac app
            Ghostty.logger.debug("local key event handled event=\(event)")
            return nil
        }

        return event
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        syncFloatOnTopMenu(notification.object as? NSWindow)
    }

    @objc private func quickTerminalDidChangeVisibility(_ notification: Notification) {
        guard let quickController = notification.object as? QuickTerminalController else { return }
        self.menuQuickTerminal?.state = if quickController.visible { .on } else { .off }
    }

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a surface one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        ghosttyConfigDidChange(config: config)
    }

    @objc private func ghosttyBellDidRing(_ notification: Notification) {
        if ghostty.config.bellFeatures.contains(.system) {
            NSSound.beep()
        }

        if ghostty.config.bellFeatures.contains(.audio) {
            if let configPath = ghostty.config.bellAudioPath,
               let sound = NSSound(contentsOfFile: configPath.path, byReference: false) {
                sound.volume = ghostty.config.bellAudioVolume
                sound.play()
            }
        }

        if ghostty.config.bellFeatures.contains(.attention) {
            // Bounce the dock icon if we're not focused.
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    @objc private func terminalWindowHasBell(_ notification: Notification) {
        guard notification.object is BaseTerminalController else { return }
        syncDockBadge()
    }

    private func requestBadgeAuthorizationAndSet(_ center: UNUserNotificationCenter) {
        center.requestAuthorization(options: [.badge]) { granted, error in
            if let error = error {
                Self.logger.warning("Error requesting badge authorization: \(error)")
                return
            }

            // Permission granted, set the badge
            if granted {
                DispatchQueue.main.async {
                    self.setDockBadge()
                }
            }
        }
    }

    private func syncDockBadge() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized:
                // If we're authorized and allow badges, then set the badge.
                if settings.badgeSetting == .enabled {
                    DispatchQueue.main.async {
                        self.setDockBadge()
                    }
                } else if settings.badgeSetting == .notSupported {
                    // If badge setting is not supported, we may be in a sandbox that doesn't allow it.
                    // We can still attempt to set the badge and hope for the best, but we should also
                    // request authorization just in case it is a permissions issue.
                    self.requestBadgeAuthorizationAndSet(center)
                }

            case .notDetermined:
                // Not determined yet, request authorization for badge
                self.requestBadgeAuthorizationAndSet(center)

            case .denied, .provisional, .ephemeral:
                // In these known non-authorized states, do not attempt to set the badge.
                break

            @unknown default:
                // Handle future unknown states by doing nothing.
                break
            }
        }
    }

    @objc private func ghosttyNewWindow(_ notification: Notification) {
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration

        // Resolve the parent window so a "new window" from a REMOTE frame inherits
        // the same host + command + cwd (§WP4). The notification's object is the
        // originating surface view (for a key-bound new-window); fall back to the
        // preferred/key window otherwise.
        let parent = (notification.object as? Ghostty.SurfaceView)?.window
            ?? TerminalController.preferredParent?.window
        TerminalController.newWindowInheritingRemote(
            ghostty, withBaseConfig: config, from: parent)
    }

    @objc private func ghosttyNewTab(_ notification: Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard let window = surfaceView.window else { return }

        // We only want to listen to new tabs if the focused parent is
        // a regular terminal controller.
        guard window.windowController is TerminalController else { return }

        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration

        _ = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
    }

    private func setDockBadge() {
        let bellCount = NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .reduce(0) { $0 + ($1.bell ? 1 : 0) }
        let wantsBadge = ghostty.config.bellFeatures.contains(.attention) && bellCount > 0
        let label = wantsBadge ? (bellCount > 99 ? "99+" : String(bellCount)) : nil
        NSApp.dockTile.badgeLabel = label
        NSApp.dockTile.display()
    }

    private func ghosttyConfigDidChange(config: Ghostty.Config) {
        // Update the config we need to store
        self.derivedConfig = DerivedConfig(config)

        // Depending on the "window-save-state" setting we have to set the NSQuitAlwaysKeepsWindows
        // configuration. This is the only way to carefully control whether macOS invokes the
        // state restoration system.
        switch config.windowSaveState {
        case "never": UserDefaults.ghostty.setValue(false, forKey: "NSQuitAlwaysKeepsWindows")
        case "always": UserDefaults.ghostty.setValue(true, forKey: "NSQuitAlwaysKeepsWindows")
        case "default": fallthrough
        default: UserDefaults.ghostty.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
        }

        // Sync our auto-update settings. If SUEnableAutomaticChecks (in our Info.plist) is
        // explicitly false (NO), auto-updates are disabled. Otherwise, we use the behavior
        // defined by our "auto-update" configuration (if set) or fall back to Sparkle
        // user-based defaults.
        if Bundle.main.infoDictionary?["SUEnableAutomaticChecks"] as? Bool == false {
            updateController.updater.automaticallyChecksForUpdates = false
            updateController.updater.automaticallyDownloadsUpdates = false
        } else if let autoUpdate = config.autoUpdate {
            updateController.updater.automaticallyChecksForUpdates =
                autoUpdate == .check || autoUpdate == .download
            updateController.updater.automaticallyDownloadsUpdates =
                autoUpdate == .download
            /*
             To test `auto-update` easily, uncomment the line below and
             delete `SUEnableAutomaticChecks` in Ghostty-Info.plist.

             Note: When `auto-update = download`, you may need to
             `Clean Build Folder` if a background install has already begun.
             */
            // updateController.updater.checkForUpdatesInBackground()
        }

        // Config could change keybindings, so update everything that depends on that
        DispatchQueue.main.async {
            self.syncMenuShortcuts(config)
        }
        TerminalController.all.forEach { $0.relabelTabs() }

        // Update our badge since config can change what we show.
        syncDockBadge()

        // Config could change window appearance. We wrap this in an async queue because when
        // this is called as part of application launch it can deadlock with an internal
        // AppKit mutex on the appearance.
        DispatchQueue.main.async { self.syncAppearance(config: config) }

        // Decide whether to hide/unhide app from dock and app switcher
        switch config.macosHidden {
        case .never:
            NSApp.setActivationPolicy(.regular)

        case .always:
            NSApp.setActivationPolicy(.accessory)
        }

        // If we have configuration errors, we need to show them.
        let c = ConfigurationErrorsController.sharedInstance
        c.errors = config.errors
        if c.errors.count > 0 {
            if c.window == nil || !c.window!.isVisible {
                c.showWindow(self)
            }
        }

        // We need to handle our global event tap depending on if there are global
        // events that we care about in Ghostty.
        if ghostty_app_has_global_keybinds(ghostty.app!) {
            if timeSinceLaunch > 5 {
                // If the process has been running for awhile we enable right away
                // because no windows are likely to pop up.
                GlobalEventTap.shared.enable()
            } else {
                // If the process just started, we wait a couple seconds to allow
                // the initial windows and so on to load so our permissions dialog
                // doesn't get buried.
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
                    GlobalEventTap.shared.enable()
                }
            }
        } else {
            GlobalEventTap.shared.disable()
        }

        updateAppIcon(from: config)
    }

    /// Sync the appearance of our app with the theme specified in the config.
    private func syncAppearance(config: Ghostty.Config) {
        NSApplication.shared.appearance = .init(ghosttyConfig: config)
    }

    private func updateAppIcon(from config: Ghostty.Config) {
        Task.detached {
            await self.appIconUpdater.update(icon: AppIcon(config: config))
        }
    }

    // MARK: - Restorable State

    /// We support NSSecureCoding for restorable state. Required as of macOS Sonoma (14) but a good idea anyways.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
        guard ghostty.config.windowSaveState != "never" else { return }

        // Encode our quick terminal state if we have it.
        switch quickTerminalControllerState {
        case .initialized(let controller) where controller.restorable:
            let data = QuickTerminalRestorableState(from: controller)
            data.encode(with: coder)

        case .pendingRestore(let state):
            state.encode(with: coder)

        default:
            break
        }
    }

    func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
        Self.logger.debug("application will restore window state")

        // Decode our quick terminal state.
        if ghostty.config.windowSaveState != "never",
            let state = QuickTerminalRestorableState(coder: coder) {
            quickTerminalControllerState = .pendingRestore(state)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive: UNNotificationResponse,
        withCompletionHandler: () -> Void
    ) {
        ghostty.handleUserNotification(response: didReceive)
        withCompletionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent: UNNotification,
        withCompletionHandler: (UNNotificationPresentationOptions) -> Void
    ) {
        let shouldPresent = ghostty.shouldPresentNotification(notification: willPresent)
        let options: UNNotificationPresentationOptions = shouldPresent ? [.banner, .sound] : []
        withCompletionHandler(options)
    }

    // MARK: - GhosttyAppDelegate

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        for c in TerminalController.all {
            for view in c.surfaceTree where view.id == uuid {
                return view
            }
        }

        return nil
    }

    // MARK: - Global State

    func setSecureInput(_ mode: Ghostty.SetSecureInput) {
        let input = SecureInput.shared
        switch mode {
        case .on:
            input.global = true

        case .off:
            input.global = false

        case .toggle:
            input.global.toggle()
        }
        self.menuSecureInput?.state = if input.global { .on } else { .off }
        UserDefaults.ghostty.set(input.global, forKey: "SecureInput")
    }

    // MARK: - IB Actions

    @IBAction func openConfig(_ sender: Any?) {
        ghostty.openConfig()
    }

    @IBAction func reloadConfig(_ sender: Any?) {
        ghostty.reloadConfig()
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        updateController.checkForUpdates()
        // UpdateSimulator.happyPath.simulate(with: updateViewModel)
    }

    @IBAction func newWindow(_ sender: Any?) {
        _ = TerminalController.newWindow(ghostty)
    }

    /// New Window with target picker (Cmd-Shift-N): always shows a chooser
    /// listing "Local" plus every registered remote machine whenever at least
    /// one machine is registered (even a single machine — no auto-skip).
    /// Selecting "Local" opens a normal local window; selecting a machine dials
    /// it over TCP and opens a window whose terminal runs on that machine
    /// (splits/tabs inherit the same machine + connection). With zero machines
    /// registered, this just opens a local window.
    @IBAction func newRemoteWindow(_ sender: Any?) {
        let registry = MachineRegistry.shared

        // Nothing remote to choose — no registered machine, no relay account,
        // AND no Google client to sign in with — so just open a normal local
        // window. The Google-client check matters when SIGNED OUT at zero
        // machines: the chooser is the only sign-in surface, so it must open
        // (showing just "Local" + the sign-in footer) or sign-in is
        // unreachable from the UI.
        guard !registry.machines.isEmpty || registry.hasRelayAccount
            || RelayAccount.isConfigured
        else {
            _ = TerminalController.newWindow(ghostty)
            return
        }

        MachineChooser.present(registry: registry) { [weak self] selected in
            guard let self, let target = selected else { return }
            switch target {
            case .local:
                _ = TerminalController.newWindow(self.ghostty)
            case .remote(let machine):
                // Relay machines dial through the rendezvous relay; the bearer
                // comes from the WP-B2 token-resolution seam (signed-in Google
                // account first, dev env token fallback — never hardcoded).
                // TCP machines use the direct host:port dial.
                if let base = machine.relayBase, let device = machine.deviceID {
                    Task { @MainActor in
                        // Check the token seam BEFORE dialing: signed out with
                        // no dev token ⇒ one clear refusal instead of a
                        // tokenless dial into a guaranteed 401 that would
                        // surface as the misleading "couldn't connect" modal.
                        guard let token = await RelayAccount.resolveToken() else {
                            Self.presentSignInRequiredAlert()
                            return
                        }
                        self.openRemoteWindow(relay: base, device: device, token: token, name: machine.name)
                    }
                } else {
                    self.openRemoteWindow(on: machine)
                }
            case .restoreRemote(let machine):
                // Chooser's contextual "Restore": replay ONLY this machine's
                // recoverable manifest entries through the same restore path
                // as launch/sign-in. Same token pre-check as the dial path —
                // signed out gets one clear refusal, not a silent no-op.
                guard let base = machine.relayBase, let device = machine.deviceID else { return }
                Task { @MainActor in
                    guard await RelayAccount.resolveToken() != nil else {
                        Self.presentSignInRequiredAlert()
                        return
                    }
                    self.restoreRemoteWindows { entry in
                        entry.relayBase == base && entry.deviceID == device
                    }
                }
            }
        }
    }

    /// Open a remote window for an ad-hoc `host:port` (used by the
    /// `+new-remote-window` IPC trigger). Mirrors the menu flow exactly: it
    /// builds a `Machine` and routes through `openRemoteWindow(on:)`, which
    /// dials and opens the window on the main thread. Returns nil on success or
    /// an error message on failure (e.g. the dial failed).
    ///
    /// `name` and `onOpen` mirror the relay overload: a caller-supplied
    /// friendly name wins as the display name, and `onOpen` receives the
    /// created controller so the IPC path can register it as a named target.
    @MainActor
    func openRemoteWindow(
        host: String,
        port: UInt16,
        name: String? = nil,
        onOpen: ((TerminalController) -> Void)? = nil
    ) -> String? {
        // Resolve a friendly NAME from the registry so an IPC-opened window's
        // title matches the menu flow (e.g. `maximushome` instead of the raw
        // IP). A caller-supplied --name wins; otherwise match the registry on
        // host+port first, then host alone; fall back to the host string when
        // the machine is unknown.
        let registry = MachineRegistry.shared.machines
        let known = registry.first { $0.host == host && $0.port == port }
            ?? registry.first { $0.host == host }
        let machine = Machine(
            name: name ?? known?.name ?? host,
            host: host,
            port: port,
            namePinned: name != nil)
        return openRemoteWindow(on: machine, onOpen: onOpen)
    }

    /// Opens a remote window by dialing a remote agent THROUGH a rendezvous
    /// relay (`--relay=<base> --device=<id> [--token=<tok>]`). Mirrors the
    /// host/port flow exactly, but dials with `ghostty_remote_connection_new_relay`
    /// instead of the direct TCP dial. The `relay` base URL is used as the
    /// machine's display "host" and the port is 0 (no TCP port for the relay
    /// path). Returns nil on success or an error message on failure.
    @MainActor
    @discardableResult
    func openRemoteWindow(
        relay: String,
        device: String,
        token: String,
        name: String? = nil,
        namePinned: Bool = false,
        onOpen: ((TerminalController) -> Void)? = nil
    ) -> String? {
        // Defense in depth for the signed-out case: every caller resolves the
        // WP-B2 token seam before calling, but an empty bearer must never
        // reach the dial — it would 401 and surface as the misleading
        // "couldn't connect" alert. Refuse with the sign-in message instead.
        guard !token.isEmpty else {
            Self.presentSignInRequiredAlert()
            return "not signed in: sign in (or set GHOSTTY_RELAY_TOKEN) to open relay windows"
        }

        // Dial the agent through the relay. This blocks through the handshake and
        // returns a connection handle, or NULL on failure.
        guard let handle = Self.dialRelay(base: relay, device: device, token: token) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't connect to \(device)"
            alert.informativeText = "Failed to reach \(device) via the relay. Make sure the Ghoztty agent is running and the relay is reachable."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return "failed to reach \(device) via relay \(relay): the agent is not running or not reachable"
        }

        let controller = presentRemoteWindow(
            handle: handle,
            relay: relay,
            device: device,
            fallbackName: name,
            namePinned: namePinned,
            sessionID: nil)
        onOpen?(controller)
        return nil
    }

    /// Dial a `ghoztty-agent` through the relay: WebSocket + mux + HELLO
    /// handshake, blocking until connected. Returns nil on any failure. Pure C
    /// call with no app state — safe off the main thread (the restore path
    /// dials on a background queue so a slow/unreachable relay can't beachball
    /// launch). Internal (not private) so the WP-D1 reconnect path in
    /// `BaseTerminalController` re-dials through the same seam.
    static func dialRelay(
        base: String,
        device: String,
        token: String
    ) -> ghostty_remote_connection_t? {
        base.withCString { basePtr in
            device.withCString { devicePtr in
                token.withCString { tokenPtr in
                    ghostty_remote_connection_new_relay(basePtr, devicePtr, tokenPtr)
                }
            }
        }
    }

    /// Build and show the terminal window for an already-dialed relay
    /// connection. Shared by the interactive dial path (`sessionID` nil ⇒ OPEN
    /// a fresh agent session) and the WP-D2 restore path (`sessionID` set ⇒
    /// re-`ATTACH` to the persisted session). Registers the window in the
    /// `RemoteSessionManifest` so it can be restored after a quit.
    @MainActor
    @discardableResult
    private func presentRemoteWindow(
        handle: ghostty_remote_connection_t,
        relay: String,
        device: String,
        fallbackName: String?,
        namePinned: Bool = false,
        sessionID: String?,
        windowTitle: String? = nil
    ) -> TerminalController {
        // The relay path has no TCP port. The DISPLAY NAME wins: prefer the
        // account's friendly name for the device (`fallbackName` — the chooser
        // row / manifest entry name, which follows renames), then the machine's
        // own hostname reported by the agent in its HELLO, then the device id
        // (headless CLI/IPC path with no --name, old agent). The agent-reported
        // hostname is carried separately in `hostname` so local-machine pill
        // suppression still recognizes a renamed local device. Carry the relay
        // base + device id so the Machine is a proper relay machine.
        // `namePinned` marks an EXPLICIT caller-supplied name (IPC `--name=`):
        // account renames must not overwrite it (see Machine.namePinned).
        let reportedHostname: String? = ghostty_remote_connection_hostname(handle)
            .flatMap { String(cString: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let machine = Machine(
            name: fallbackName ?? reportedHostname ?? device,
            host: relay,
            port: 0,
            relayBase: relay,
            deviceID: device,
            hostname: reportedHostname,
            namePinned: namePinned && fallbackName != nil)

        // Wrap the handle in a strong owner; the controller below holds the only
        // strong reference and frees it (once) when the window is deallocated.
        let connection = RemoteConnection(handle: handle, machine: machine)

        // Build the base surface config that puts the first surface on the
        // remote machine (session_id nil ⇒ OPEN new; non-nil ⇒ ATTACH).
        var cfg = Ghostty.SurfaceConfiguration()
        cfg.remoteMachine = machine
        cfg.remoteConnection = handle
        // Retain the connection owner on the surface so it outlives the surface's
        // deferred free (channel detach). See SurfaceConfiguration.connectionKeepAlive.
        cfg.connectionKeepAlive = connection
        cfg.remoteSessionId = sessionID

        let controller = TerminalController.newWindow(ghostty, withBaseConfig: cfg)
        controller.remoteMachine = machine
        controller.remoteConnection = connection

        // WP-D2: track this window for restore-on-relaunch and capture its
        // agent session UUID once the termio thread has opened/attached the
        // session (published async; for an ATTACH the id is already known but
        // the capture confirms it against the live pane either way).
        let entryID = RemoteSessionManifest.shared.register(
            relayBase: relay,
            deviceID: device,
            name: machine.name,
            sessionID: sessionID,
            windowTitle: windowTitle,
            namePinned: machine.namePinned)
        controller.remoteManifestEntryID = entryID
        RemoteSessionManifest.captureSessionID(of: controller, entryID: entryID)

        // Re-apply the user-set window title preserved in the manifest entry
        // (restore path). Applied through `titleOverride` — the same property
        // a manual rename sets — AFTER the window/surface is built, so it
        // takes precedence over later shell OSC title updates exactly like
        // the original rename did.
        if let windowTitle, !windowTitle.isEmpty {
            controller.titleOverride = windowTitle
        }

        return controller
    }

    /// WP-D2: restore relay remote windows recorded in the manifest by a
    /// previous run (quit with remote windows open). Runs at launch: each
    /// entry is re-dialed through the relay on a BACKGROUND queue (no
    /// beachball, no modal alerts — this is the restore path, not the
    /// interactive dial) and, if its agent session is still alive, the window
    /// is reopened re-`ATTACH`ed to that session.
    ///
    /// Failure handling, per entry:
    /// - no session UUID was ever captured → dropped (nothing to attach to)
    /// - relay/agent unreachable (dial fails) → entry is KEPT for the next
    ///   launch (the machine may simply be offline right now)
    /// - session gone on the agent (probe fails; expired TTL, agent restart)
    ///   → dropped silently
    ///
    /// `matching` scopes WHICH entries are replayed: the default (all) is the
    /// launch/sign-in behavior; the machine chooser's contextual "Restore"
    /// passes a per-machine filter. Entries outside the filter are put back
    /// untouched (reinstated), exactly like entries bound to open windows.
    private func restoreRemoteWindows(
        matching filter: @escaping (RemoteSessionManifest.Entry) -> Bool = { _ in true }
    ) {
        let entries = RemoteSessionManifest.shared.takeAll()
        guard !entries.isEmpty else { return }

        Task { @MainActor [weak self] in
            // Same token-resolution seam as the interactive dial path (WP-B2):
            // signed-in account's ID token, dev env token fallback. Resolved
            // ONCE up front (may await a token refresh), then the blocking
            // dials run on a background queue as before.
            //
            // Signed out with no dev token ⇒ NO dial at all: put every entry
            // back untouched and skip silently (the restore path never
            // alerts). A later sign-in replays them via
            // `relayAccountDidSignIn()`; a later launch retries the same way.
            guard let token = await RelayAccount.resolveToken() else {
                for entry in entries { RemoteSessionManifest.shared.reinstate(entry) }
                return
            }

            // Double-restore guard: an entry still bound to an OPEN window
            // (its controller carries the entry id) must not be re-attached —
            // a second ATTACH to the same session would evict the live window
            // (spec §5.3). Put those straight back; restore only the rest.
            let openEntryIDs = Set(TerminalController.all.compactMap(\.remoteManifestEntryID))
            let (candidates, reinstate) = RemoteSessionManifest.partitionForRestore(
                entries, openEntryIDs: openEntryIDs)
            // Entries outside the requested scope (per-machine Restore from
            // the chooser) also go straight back, untouched.
            let restore = candidates.filter(filter)
            let skipped = candidates.filter { !filter($0) }
            for entry in reinstate + skipped { RemoteSessionManifest.shared.reinstate(entry) }
            guard !restore.isEmpty else { return }
            self?.restoreRemoteWindows(entries: restore, token: token)
        }
    }

    // MARK: Relay account lifecycle (WP-B2 sign-out/sign-in window handling)

    /// Sign-out hook, called by `RelayAccount.signOut()` AFTER the credentials
    /// are cleared: close every account-backed remote window. "Account-backed"
    /// means the window's machine is a RELAY machine (`remoteMachine.isRelay`)
    /// — direct-TCP remote windows are not account resources and stay open.
    ///
    /// Closing runs with `isSigningOut` set, which — exactly like the
    /// `isQuitting` quit path — preserves each window's
    /// `RemoteSessionManifest` entry through `windowWillClose`, so a later
    /// sign-in can restore (re-`ATTACH`) the windows. The agent keeps the
    /// detached sessions alive (detach ≠ terminate — nothing is terminated
    /// here). `windowWillClose` also cancels the window's WP-D1 reconnect
    /// loop (generation bump + observer removal) before anything can re-dial.
    func relayAccountDidSignOut() {
        isSigningOut = true
        defer { isSigningOut = false }
        for controller in TerminalController.all {
            guard controller.remoteMachine?.isRelay == true else { continue }
            // close() (not performClose): no close-confirmation prompt — the
            // remote session persists on the agent, nothing is being killed.
            controller.window?.close()
        }
    }

    /// Sign-in hook, called by `RelayAccount.signIn()` on success: replay the
    /// manifest entries preserved at sign-out through the SAME restore path
    /// as launch (`restoreRemoteWindows()` — dial + liveness-probe +
    /// re-`ATTACH` on a background queue; sessions that died meanwhile drop
    /// their entries silently).
    ///
    /// Deferred until no modal session is running: sign-in happens from the
    /// app-modal machine chooser, and restored windows shouldn't fight the
    /// modal panel for key status while it's still up.
    func relayAccountDidSignIn() {
        restoreRemoteWindowsAfterModal()
    }

    /// Run `restoreRemoteWindows()` once `NSApp` has no modal session (polls
    /// on the main queue; delivered during the modal session because the
    /// modal panel run-loop mode is a common mode). The chooser typically
    /// closes within seconds of a sign-in; if some modal session is still
    /// running after ~60s, restore anyway (windows just open behind it).
    private func restoreRemoteWindowsAfterModal(attempt: Int = 0) {
        if NSApp.modalWindow == nil || attempt >= 120 {
            restoreRemoteWindows()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restoreRemoteWindowsAfterModal(attempt: attempt + 1)
        }
    }

    /// The single "you're signed out" refusal for account-backed dial paths
    /// (chooser dial, remote-window/tab inheritance, defensive dial guard).
    /// One small informational alert; the visibility guard keeps concurrent
    /// refusals from stacking into a modal storm (extra requests are simply
    /// dropped while it's up).
    private static var signInRequiredAlertVisible = false
    @MainActor
    static func presentSignInRequiredAlert() {
        guard !signInRequiredAlertVisible else { return }
        signInRequiredAlertVisible = true
        defer { signInRequiredAlertVisible = false }
        let alert = NSAlert()
        alert.messageText = "Sign in to open remote windows"
        alert.informativeText = "Remote machines belong to your account. Use New Remote Window (⇧⌘N) → Sign In with Google, then try again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Second half of `restoreRemoteWindows()`: dial + probe + reopen each
    /// manifest entry on a background queue using the already-resolved token.
    private func restoreRemoteWindows(
        entries: [RemoteSessionManifest.Entry],
        token: String
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for entry in entries {
                guard let sessionID = entry.sessionID, !sessionID.isEmpty else {
                    Self.logger.info("remote restore: dropping \(entry.deviceID, privacy: .public) — no session id was captured")
                    continue
                }

                guard let handle = Self.dialRelay(
                    base: entry.relayBase,
                    device: entry.deviceID,
                    token: token
                ) else {
                    // Relay or agent unreachable: keep the entry so the next
                    // launch retries; never alert from the restore path.
                    Self.logger.warning("remote restore: relay dial failed for \(entry.deviceID, privacy: .public); keeping entry for next launch")
                    RemoteSessionManifest.shared.reinstate(entry)
                    continue
                }

                // Liveness probe before opening any window: GET_CWD by session
                // id answers ok=false for a dead/unknown session (bounded
                // timeout). A gone session is dropped silently — no window,
                // no alert.
                let cwd = sessionID.withCString { cSid in
                    Ghostty.AllocatedString(
                        ghostty_remote_connection_query_cwd_timeout(handle, cSid, 5000)).string
                }
                guard !cwd.isEmpty else {
                    Self.logger.info("remote restore: session \(sessionID, privacy: .public) on \(entry.deviceID, privacy: .public) is gone; dropping entry")
                    ghostty_remote_connection_free(handle)
                    continue
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        ghostty_remote_connection_free(handle)
                        return
                    }
                    self.presentRemoteWindow(
                        handle: handle,
                        relay: entry.relayBase,
                        device: entry.deviceID,
                        fallbackName: entry.name,
                        namePinned: entry.namePinned == true,
                        sessionID: sessionID,
                        windowTitle: entry.windowTitle)
                }
            }
        }
    }

    /// Dials `machine` and opens a remote window on success. Shows an alert on
    /// connection failure. Returns nil on success, or an error message string
    /// on failure (callers that drive this headlessly use the return value;
    /// the interactive menu path also surfaces an alert).
    @MainActor
    @discardableResult
    private func openRemoteWindow(
        on machine: Machine,
        onOpen: ((TerminalController) -> Void)? = nil
    ) -> String? {
        // Dial the agent over TCP. This blocks through the handshake and returns
        // a connection handle, or NULL on failure.
        let handle: ghostty_remote_connection_t? = machine.host.withCString { hostPtr in
            ghostty_remote_connection_new_tcp(hostPtr, machine.port)
        }

        guard let handle else {
            let alert = NSAlert()
            alert.messageText = "Couldn't connect to \(machine.name)"
            alert.informativeText = "Failed to reach \(machine.endpoint). Make sure the Ghoztty agent is running and reachable."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return "failed to reach \(machine.endpoint): the agent is not running or not reachable"
        }

        // Wrap the handle in a strong owner; the controller below holds the only
        // strong reference and frees it (once) when the window is deallocated.
        let connection = RemoteConnection(handle: handle, machine: machine)

        // Build the base surface config that puts the first surface on the
        // remote machine (new session: session_id stays nil).
        var cfg = Ghostty.SurfaceConfiguration()
        cfg.remoteMachine = machine
        cfg.remoteConnection = handle
        // Retain the connection owner on the surface so it outlives the surface's
        // deferred free (channel detach). See SurfaceConfiguration.connectionKeepAlive.
        cfg.connectionKeepAlive = connection
        cfg.remoteSessionId = nil

        let controller = TerminalController.newWindow(ghostty, withBaseConfig: cfg)
        controller.remoteMachine = machine
        controller.remoteConnection = connection
        onOpen?(controller)
        return nil
    }

    @IBAction func newTab(_ sender: Any?) {
        _ = TerminalController.newTab(
            ghostty,
            from: TerminalController.preferredParent?.window
        )
    }

    @IBAction func closeAllWindows(_ sender: Any?) {
        TerminalController.closeAllWindows()
        AboutController.shared.hide()
    }

    @IBAction func showAbout(_ sender: Any?) {
        AboutController.shared.show()
    }

    @IBAction func showHelp(_ sender: Any) {
        guard let url = URL(string: "https://ghostty.org/docs") else { return }
        NSWorkspace.shared.open(url)
    }

    @IBAction func toggleSecureInput(_ sender: Any) {
        setSecureInput(.toggle)
    }

    @IBAction func toggleQuickTerminal(_ sender: Any) {
        quickController.toggle()
    }

    /// Toggles visibility of all Ghosty Terminal windows. When hidden, activates Ghostty as the frontmost application
    @IBAction func toggleVisibility(_ sender: Any) {
        // If we have focus, then we hide all windows.
        if NSApp.isActive {
            // Toggle visibility doesn't do anything if the focused window is native
            // fullscreen. This is only relevant if Ghostty is active.
            guard let keyWindow = NSApp.keyWindow,
                  !keyWindow.styleMask.contains(.fullScreen) else { return }

            NSApp.hide(nil)
            return
        }

        // If we're not active, we want to become active
        NSApp.activate(ignoringOtherApps: true)

        // Bring all windows to the front. Note: we don't use NSApp.unhide because
        // that will unhide ALL hidden windows. We want to only bring forward the
        // ones that we hid.
        hiddenState?.restore()
        hiddenState = nil
    }

    @IBAction func bringAllToFront(_ sender: Any) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        NSApplication.shared.arrangeInFront(sender)
    }

    @IBAction func undo(_ sender: Any?) {
        undoManager.undo()
    }

    @IBAction func redo(_ sender: Any?) {
        undoManager.redo()
    }

    private struct DerivedConfig {
        let initialWindow: Bool
        let shouldQuitAfterLastWindowClosed: Bool
        let quickTerminalPosition: QuickTerminalPosition

        init() {
            self.initialWindow = true
            self.shouldQuitAfterLastWindowClosed = false
            self.quickTerminalPosition = .top
        }

        init(_ config: Ghostty.Config) {
            self.initialWindow = config.initialWindow
            self.shouldQuitAfterLastWindowClosed = config.shouldQuitAfterLastWindowClosed
            self.quickTerminalPosition = config.quickTerminalPosition
        }
    }

    struct ToggleVisibilityState {
        let hiddenWindows: [Weak<NSWindow>]
        let keyWindow: Weak<NSWindow>?

        fileprivate init() {
            // We need to know the key window so that we can bring focus back to the
            // right window if it was hidden.
            self.keyWindow = if let keyWindow = NSApp.keyWindow {
                .init(keyWindow)
            } else {
                nil
            }

            // We need to keep track of the windows that were visible because we only
            // want to bring back these windows if we remove the toggle.
            //
            // We also ignore fullscreen windows because they don't hide anyways.
            var visibleWindows = [Weak<NSWindow>]()
            NSApp.windows.filter {
                $0.isVisible &&
                !$0.styleMask.contains(.fullScreen)
            }.forEach { window in
                // We only keep track of selectedWindow if it's in a tabGroup,
                // so we can keep its selection state when restoring
                let windowToHide = window.tabGroup?.selectedWindow ?? window
                if !visibleWindows.contains(where: { $0.value === windowToHide }) {
                    visibleWindows.append(Weak(windowToHide))
                }
            }
            self.hiddenWindows = visibleWindows
        }

        func restore() {
            hiddenWindows.forEach { $0.value?.orderFrontRegardless() }
            keyWindow?.value?.makeKey()
        }
    }
}

// MARK: Menu

extension AppDelegate {
    /// This is called for the dock right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return dockMenu
    }

    private func reloadDockMenu() {
        let newWindow = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "")
        let newTab = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "")

        dockMenu.removeAllItems()
        dockMenu.addItem(newWindow)
        dockMenu.addItem(newTab)
    }

    /// Setup all the images for our menu items.
    private func setupMenuImages() {
        // Note: This COULD Be done all in the xib file, but I find it easier to
        // modify this stuff as code.
        self.menuAbout?.setImageIfDesired(systemSymbolName: "info.circle")
        self.menuCheckForUpdates?.setImageIfDesired(systemSymbolName: "square.and.arrow.down")
        self.menuOpenConfig?.setImageIfDesired(systemSymbolName: "gear")
        self.menuReloadConfig?.setImageIfDesired(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90")
        self.menuSecureInput?.setImageIfDesired(systemSymbolName: "lock.display")
        self.menuNewWindow?.setImageIfDesired(systemSymbolName: "macwindow.badge.plus")
        self.menuNewTab?.setImageIfDesired(systemSymbolName: "macwindow")
        self.menuSplitRight?.setImageIfDesired(systemSymbolName: "rectangle.righthalf.inset.filled")
        self.menuSplitLeft?.setImageIfDesired(systemSymbolName: "rectangle.leadinghalf.inset.filled")
        self.menuSplitUp?.setImageIfDesired(systemSymbolName: "rectangle.tophalf.inset.filled")
        self.menuSplitDown?.setImageIfDesired(systemSymbolName: "rectangle.bottomhalf.inset.filled")
        self.menuClose?.setImageIfDesired(systemSymbolName: "xmark")
        self.menuPasteSelection?.setImageIfDesired(systemSymbolName: "doc.on.clipboard.fill")
        self.menuIncreaseFontSize?.setImageIfDesired(systemSymbolName: "textformat.size.larger")
        self.menuResetFontSize?.setImageIfDesired(systemSymbolName: "textformat.size")
        self.menuDecreaseFontSize?.setImageIfDesired(systemSymbolName: "textformat.size.smaller")
        self.menuCommandPalette?.setImageIfDesired(systemSymbolName: "filemenu.and.selection")
        self.menuQuickTerminal?.setImageIfDesired(systemSymbolName: "apple.terminal")
        self.menuChangeTabTitle?.setImageIfDesired(systemSymbolName: "pencil.line")
        self.menuTerminalInspector?.setImageIfDesired(systemSymbolName: "scope")
        self.menuReadonly?.setImageIfDesired(systemSymbolName: "eye.fill")
        self.menuSetAsDefaultTerminal?.setImageIfDesired(systemSymbolName: "star.fill")
        self.menuToggleFullScreen?.setImageIfDesired(systemSymbolName: "square.arrowtriangle.4.outward")
        self.menuToggleVisibility?.setImageIfDesired(systemSymbolName: "eye")
        self.menuZoomSplit?.setImageIfDesired(systemSymbolName: "arrow.up.left.and.arrow.down.right")
        self.menuPreviousSplit?.setImageIfDesired(systemSymbolName: "chevron.backward.2")
        self.menuNextSplit?.setImageIfDesired(systemSymbolName: "chevron.forward.2")
        self.menuEqualizeSplits?.setImageIfDesired(systemSymbolName: "inset.filled.topleft.topright.bottomleft.bottomright.rectangle")
        self.menuSelectSplitLeft?.setImageIfDesired(systemSymbolName: "arrow.left")
        self.menuSelectSplitRight?.setImageIfDesired(systemSymbolName: "arrow.right")
        self.menuSelectSplitAbove?.setImageIfDesired(systemSymbolName: "arrow.up")
        self.menuSelectSplitBelow?.setImageIfDesired(systemSymbolName: "arrow.down")
        self.menuMoveSplitDividerUp?.setImageIfDesired(systemSymbolName: "arrow.up.to.line")
        self.menuMoveSplitDividerDown?.setImageIfDesired(systemSymbolName: "arrow.down.to.line")
        self.menuMoveSplitDividerLeft?.setImageIfDesired(systemSymbolName: "arrow.left.to.line")
        self.menuMoveSplitDividerRight?.setImageIfDesired(systemSymbolName: "arrow.right.to.line")
        self.menuFloatOnTop?.setImageIfDesired(systemSymbolName: "square.filled.on.square")
        self.menuFindParent?.setImageIfDesired(systemSymbolName: "text.page.badge.magnifyingglass")
    }

    /// Sync all of our menu item keyboard shortcuts with the Ghostty configuration.
    @MainActor private func syncMenuShortcuts(_ config: Ghostty.Config) {
        guard ghostty.readiness == .ready else { return }

        menuShortcutManager.reset()

        syncMenuShortcut(config, action: "check_for_updates", menuItem: self.menuCheckForUpdates)
        syncMenuShortcut(config, action: "open_config", menuItem: self.menuOpenConfig)
        syncMenuShortcut(config, action: "reload_config", menuItem: self.menuReloadConfig)
        syncMenuShortcut(config, action: "quit", menuItem: self.menuQuit)

        syncMenuShortcut(config, action: "new_window", menuItem: self.menuNewWindow)
        syncMenuShortcut(config, action: "new_tab", menuItem: self.menuNewTab)
        syncMenuShortcut(config, action: "close_surface", menuItem: self.menuClose)
        syncMenuShortcut(config, action: "close_tab", menuItem: self.menuCloseTab)
        syncMenuShortcut(config, action: "close_window", menuItem: self.menuCloseWindow)
        syncMenuShortcut(config, action: "close_all_windows", menuItem: self.menuCloseAllWindows)
        syncMenuShortcut(config, action: "new_split:right", menuItem: self.menuSplitRight)
        syncMenuShortcut(config, action: "new_split:left", menuItem: self.menuSplitLeft)
        syncMenuShortcut(config, action: "new_split:down", menuItem: self.menuSplitDown)
        syncMenuShortcut(config, action: "new_split:up", menuItem: self.menuSplitUp)

        syncMenuShortcut(config, action: "undo", menuItem: self.menuUndo)
        syncMenuShortcut(config, action: "redo", menuItem: self.menuRedo)
        syncMenuShortcut(config, action: "copy_to_clipboard", menuItem: self.menuCopy)
        syncMenuShortcut(config, action: "paste_from_clipboard", menuItem: self.menuPaste)
        syncMenuShortcut(config, action: "paste_from_selection", menuItem: self.menuPasteSelection)
        syncMenuShortcut(config, action: "select_all", menuItem: self.menuSelectAll)
        syncMenuShortcut(config, action: "start_search", menuItem: self.menuFind)
        syncMenuShortcut(config, action: "end_search", menuItem: self.menuHideFindBar)
        syncMenuShortcut(config, action: "search_selection", menuItem: self.menuSelectionForFind)
        syncMenuShortcut(config, action: "scroll_to_selection", menuItem: self.menuScrollToSelection)
        syncMenuShortcut(config, action: "navigate_search:next", menuItem: self.menuFindNext)
        syncMenuShortcut(config, action: "navigate_search:previous", menuItem: self.menuFindPrevious)

        syncMenuShortcut(config, action: "toggle_split_zoom", menuItem: self.menuZoomSplit)
        syncMenuShortcut(config, action: "goto_split:previous", menuItem: self.menuPreviousSplit)
        syncMenuShortcut(config, action: "goto_split:next", menuItem: self.menuNextSplit)
        syncMenuShortcut(config, action: "goto_split:up", menuItem: self.menuSelectSplitAbove)
        syncMenuShortcut(config, action: "goto_split:down", menuItem: self.menuSelectSplitBelow)
        syncMenuShortcut(config, action: "goto_split:left", menuItem: self.menuSelectSplitLeft)
        syncMenuShortcut(config, action: "goto_split:right", menuItem: self.menuSelectSplitRight)
        syncMenuShortcut(config, action: "resize_split:up,10", menuItem: self.menuMoveSplitDividerUp)
        syncMenuShortcut(config, action: "resize_split:down,10", menuItem: self.menuMoveSplitDividerDown)
        syncMenuShortcut(config, action: "resize_split:right,10", menuItem: self.menuMoveSplitDividerRight)
        syncMenuShortcut(config, action: "resize_split:left,10", menuItem: self.menuMoveSplitDividerLeft)
        syncMenuShortcut(config, action: "equalize_splits", menuItem: self.menuEqualizeSplits)
        syncMenuShortcut(config, action: "reset_window_size", menuItem: self.menuReturnToDefaultSize)

        syncMenuShortcut(config, action: "increase_font_size:1", menuItem: self.menuIncreaseFontSize)
        syncMenuShortcut(config, action: "decrease_font_size:1", menuItem: self.menuDecreaseFontSize)
        syncMenuShortcut(config, action: "reset_font_size", menuItem: self.menuResetFontSize)
        syncMenuShortcut(config, action: "prompt_surface_title", menuItem: self.menuChangeTitle)
        syncMenuShortcut(config, action: "prompt_tab_title", menuItem: self.menuChangeTabTitle)
        syncMenuShortcut(config, action: "toggle_quick_terminal", menuItem: self.menuQuickTerminal)
        syncMenuShortcut(config, action: "toggle_visibility", menuItem: self.menuToggleVisibility)
        syncMenuShortcut(config, action: "toggle_window_float_on_top", menuItem: self.menuFloatOnTop)
        syncMenuShortcut(config, action: "inspector:toggle", menuItem: self.menuTerminalInspector)
        syncMenuShortcut(config, action: "toggle_command_palette", menuItem: self.menuCommandPalette)

        syncMenuShortcut(config, action: "toggle_secure_input", menuItem: self.menuSecureInput)

        // This menu item is NOT synced with the configuration because it disables macOS
        // global fullscreen keyboard shortcut. The shortcut in the Ghostty config will continue
        // to work but it won't be reflected in the menu item.
        //
        // syncMenuShortcut(config, action: "toggle_fullscreen", menuItem: self.menuToggleFullScreen)

        // Dock menu
        reloadDockMenu()
    }

    @MainActor private func syncMenuShortcut(_ config: Ghostty.Config, action: String, menuItem: NSMenuItem?) {
        menuShortcutManager.syncMenuShortcut(config, action: action, menuItem: menuItem)
    }

    @MainActor func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool {
        menuShortcutManager.performGhosttyBindingMenuKeyEquivalent(with: event)
    }
}

// MARK: Floating Windows

extension AppDelegate {
    func syncFloatOnTopMenu(_ window: NSWindow?) {
        guard let window = (window ?? NSApp.keyWindow) as? TerminalWindow else {
            // If some other window became key we always turn this off
            self.menuFloatOnTop?.state = .off
            return
        }

        self.menuFloatOnTop?.state = window.level == .floating ? .on : .off
    }

    @IBAction func floatOnTop(_ menuItem: NSMenuItem) {
        menuItem.state = menuItem.state == .on ? .off : .on
        guard let window = NSApp.keyWindow else { return }
        window.level = menuItem.state == .on ? .floating : .normal
    }

    @IBAction func useAsDefault(_ sender: NSMenuItem) {
        let ud = UserDefaults.ghostty
        let key = TerminalWindow.defaultLevelKey
        if menuFloatOnTop?.state == .on {
            ud.set(NSWindow.Level.floating, forKey: key)
        } else {
            ud.removeObject(forKey: key)
        }
    }

    @IBAction func setAsDefaultTerminal(_ sender: NSMenuItem) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .unixExecutable) { error in
            guard let error else { return }
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Failed to Set Default Terminal"
                alert.informativeText = """
                Ghostty could not be set as the default terminal application.

                Error: \(error.localizedDescription)
                """
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

// MARK: NSMenuItemValidation

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setAsDefaultTerminal(_:)):
            return NSWorkspace.shared.defaultTerminal != Bundle.main.bundleURL

        case #selector(floatOnTop(_:)),
            #selector(useAsDefault(_:)):
            // Float on top items only active if the key window is a primary
            // terminal window (not quick terminal).
            return NSApp.keyWindow is TerminalWindow

        case #selector(undo(_:)):
            if undoManager.canUndo {
                item.title = "Undo \(undoManager.undoActionName)"
            } else {
                item.title = "Undo"
            }
            return undoManager.canUndo

        case #selector(redo(_:)):
            if undoManager.canRedo {
                item.title = "Redo \(undoManager.redoActionName)"
            } else {
                item.title = "Redo"
            }
            return undoManager.canRedo

        default:
            return true
        }
    }
}

/// Represents the state of the quick terminal controller.
private enum QuickTerminalState {
    /// Controller has not been initialized and has no pending restoration state.
    case uninitialized
    /// Restoration state is pending; controller will use this when first accessed.
    case pendingRestore(QuickTerminalRestorableState)
    /// Controller has been initialized.
    case initialized(QuickTerminalController)
}
