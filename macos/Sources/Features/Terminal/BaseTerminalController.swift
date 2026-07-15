import Cocoa
import SwiftUI
import Combine
import GhosttyKit

/// A base class for windows that can contain Ghostty windows. This base class implements
/// the bare minimum functionality that every terminal window in Ghostty should implement.
///
/// Usage: Specify this as the base class of your window controller for the window that contains
/// a terminal. The window controller must also be the window delegate OR the window delegate
/// functions on this base class must be called by your own custom delegate. For the terminal
/// view the TerminalView SwiftUI view must be used and this class is the view model and
/// delegate.
///
/// Special considerations to implement:
///
///   - Fullscreen: you must manually listen for the right notification and implement the
///   callback that calls toggleFullscreen on this base class.
///
/// Notably, things this class does NOT implement (not exhaustive):
///
///   - Tabbing, because there are many ways to get tabbed behavior in macOS and we
///   don't want to be opinionated about it.
///   - Window restoration or save state
///   - Window visual styles (such as titlebar colors)
///
/// The primary idea of all the behaviors we don't implement here are that subclasses may not
/// want these behaviors.
class BaseTerminalController: NSWindowController,
                              NSWindowDelegate,
                              TerminalViewDelegate,
                              TerminalViewModel,
                              ClipboardConfirmationViewDelegate,
                              FullscreenDelegate {
    /// The app instance that this terminal view will represent.
    let ghostty: Ghostty.App

    /// The currently focused surface.
    var focusedSurface: Ghostty.SurfaceView? {
        didSet { syncFocusToSurfaceTree() }
    }

    /// The tree of splits within this terminal window.
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init() {
        didSet { surfaceTreeDidChange(from: oldValue, to: surfaceTree) }
    }

    let heroModeState = HeroModeState()
    private var heroSelectionCancellable: AnyCancellable?

    /// This can be set to show/hide the command palette.
    @Published var commandPaletteIsShowing: Bool = false

    /// Set if the terminal view should show the update overlay.
    @Published var updateOverlayIsVisible: Bool = false

    /// True when any surface in this controller currently has an active bell.
    @Published private(set) var bell: Bool = false

    /// Whether the terminal surface should focus when the mouse is over it.
    var focusFollowsMouse: Bool {
        self.derivedConfig.focusFollowsMouse
    }

    /// Non-nil when an alert is active so we don't overlap multiple.
    private var alert: NSAlert?

    /// The clipboard confirmation window, if shown.
    private var clipboardConfirmation: ClipboardConfirmationController?

    /// Fullscreen state management.
    private(set) var fullscreenStyle: FullscreenStyle?

    /// Event monitor (see individual events for why)
    private var eventMonitor: Any?

    /// The previous frame information from the window
    private var savedFrame: SavedFrame?

    /// Cache previously applied appearance to avoid unnecessary updates
    private var appliedColorScheme: ghostty_color_scheme_e?

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private var derivedConfig: DerivedConfig

    /// Track whether background is forced opaque (true) or using config transparency (false)
    var isBackgroundOpaque: Bool = false

    /// The cancellables related to our focused surface.
    private var focusedSurfaceCancellables: Set<AnyCancellable> = []

    /// Cancellable for aggregating bell state across all surfaces in this controller.
    private var bellStateCancellable: AnyCancellable?

    /// Cancellable for aggregating activity state across all surfaces in this controller.
    private var activityStateCancellable: AnyCancellable?

    /// An override title for the tab/window set by the user via prompt_tab_title.
    /// When set, this takes precedence over the computed title from the terminal.
    var titleOverride: String? {
        didSet {
            applyTitleToWindow()

            // Relay remote windows persist the user-set title in the restore
            // manifest so a restored window (relaunch, or sign-out → sign-in)
            // comes back under the same rename. Synced here — at the single
            // choke point every user rename path funnels through (Change
            // Title prompt, inline tab-title editor, IPC set-title, keybind
            // action) — so the persisted title stays correct even if the app
            // crashes before a clean quit. Shell OSC titles never touch this
            // property, so transient titles are never persisted.
            if let remoteManifestEntryID {
                RemoteSessionManifest.shared.updateWindowTitle(
                    remoteManifestEntryID, windowTitle: titleOverride)
            }

            // Session persistence (T05): same contract for local
            // agent-backed windows in the layout manifest.
            if let sessionLayoutEntryID {
                SessionLayoutManifest.shared.updateWindowTitle(
                    sessionLayoutEntryID, windowTitle: titleOverride)
            }
        }
    }

    var windowName: String = "window-\(BaseTerminalController.nextWindowId())"

    /// The remote machine this window's terminals run on, if any. When set, the
    /// window title is suffixed with the machine name and new splits/tabs inherit
    /// the same machine + connection.
    var remoteMachine: Machine? {
        didSet {
            // Publish the machine to the window so it can render the titlebar
            // hostname pill and expose the `AXGhosttyMachine` accessibility
            // attribute. Local windows leave this nil.
            (window as? TerminalWindow)?.remoteMachine = remoteMachine
            applyTitleToWindow()
        }
    }

    /// Strong owner of the shared remote connection handle for this window. Held
    /// here so the handle outlives every surface/split in the window; freed
    /// (exactly once) when this controller is deallocated. See `RemoteConnection`.
    /// A successful WP-D1 reconnect REPLACES this with a freshly-dialed
    /// connection (the old one is released once its last surface deallocates).
    var remoteConnection: RemoteConnection? {
        didSet {
            bindRemoteConnectionStateObserver()
            registerSessionLayoutIfNeeded()
        }
    }

    /// WP-D1: this window's connection status (reconnect state machine output).
    /// Drives the titlebar pill dot (green/yellow/red). Main-thread only.
    var remoteConnectionState: RemoteWindowConnectionState = .connected {
        didSet {
            guard remoteConnectionState != oldValue else { return }
            (window as? TerminalWindow)?.remoteConnectionState = remoteConnectionState
        }
    }

    /// Observer token for the current `remoteConnection`'s link-state
    /// notifications (rebound whenever `remoteConnection` changes).
    private var remoteLinkObserver: NSObjectProtocol?

    /// Monotonic generation for the reconnect retry loop. Bumped to cancel:
    /// any queued attempt/completion that observes a stale generation no-ops
    /// (and frees any connection it dialed).
    private var remoteReconnectGeneration: Int = 0

    /// WP-D1: whether the current `.disconnected` state may self-heal. True
    /// when we gave up because the AGENT was unreachable (retries exhausted /
    /// every dial failed) but the window's own connection object is still
    /// alive-and-retrying underneath — if its transport later recovers (e.g. a
    /// long-frozen agent thaws), the link transition back to `.connected` is
    /// authoritative and the window resumes. False for the terminal tiers
    /// (session gone, evicted, signed out): those never self-heal.
    private var remoteDisconnectMaySelfHeal: Bool = false

    /// Debug-only: true while a forced reconnect swap (the
    /// `/tmp/ghoztty-debug-force-reconnect-swap` hook) is in flight, so the
    /// abandoned original connection's self-recovery is ignored until the
    /// replacement dial resolves. Never set in release builds. See
    /// `debugShouldForceReconnectSwap`.
    private var debugForcingReconnectSwap: Bool = false

    /// Poisoned-session circuit breaker: when the most recent reconnect swap
    /// completed (`completeRemoteReconnect` succeeded). Nil when no swap is
    /// pending judgment. Used with `remoteQuickSwapDeaths` to detect a session
    /// that probes ALIVE but kills the link every time we ATTACH to it (seen
    /// live: a stale session created by an older client build; every swap
    /// "succeeded" and then the link died within ~300ms, looping forever).
    private var remoteSwapCompletedAt: Date?

    /// Consecutive swaps that completed and then had their link die within
    /// `remoteSwapPoisonWindow`. Reset by a swap that stays up longer than the
    /// window or by any genuine link recovery. At `remoteSwapPoisonLimit` the
    /// fast reconnect ladder STOPS (the session is treated as poisoned) instead
    /// of dial/probe/swap-looping every couple of seconds forever.
    private var remoteQuickSwapDeaths: Int = 0

    /// A post-swap link death within this many seconds counts as a
    /// quick-death cycle for the poisoned-session circuit breaker. Chosen well
    /// above the observed ~300ms death and above the 5s post-swap verify, but
    /// short enough that a genuinely working session (interactive use easily
    /// exceeds it) always resets the counter.
    private static let remoteSwapPoisonWindow: TimeInterval = 10

    /// Consecutive quick-death cycles before the session is declared poisoned.
    private static let remoteSwapPoisonLimit = 3

    /// WP-D2: this window's entry in the `RemoteSessionManifest`, when it is a
    /// relay-backed remote window tracked for restore-on-relaunch. A clean
    /// close removes the entry (see `windowWillClose`); app quit leaves it so
    /// the window is restored (re-`ATTACH`ed) on the next launch.
    var remoteManifestEntryID: UUID?

    /// Session persistence (T05): this window's entry in the
    /// `SessionLayoutManifest`, when it is a LOCAL-agent-backed persistent
    /// window tracked for restore-on-relaunch. Registered in
    /// `remoteConnection`'s didSet (the one choke point every persistent
    /// window/tab passes through); a clean close removes the entry (see
    /// `windowWillClose`); app quit leaves it so T06 can rebuild the window.
    var sessionLayoutEntryID: UUID?

    private static var _nextWindowId: Int = 0
    private static func nextWindowId() -> Int {
        _nextWindowId += 1
        return _nextWindowId
    }

    /// The last computed title from the focused surface (without the override).
    private var lastComputedTitle: String = "👻"

    /// The time that undo/redo operations that contain running ptys are valid for.
    var undoExpiration: Duration {
        ghostty.config.undoTimeout
    }

    /// The undo manager for this controller is the undo manager of the window,
    /// which we set via the delegate method.
    override var undoManager: ExpiringUndoManager? {
        // This should be set via the delegate method windowWillReturnUndoManager
        if let result = window?.undoManager as? ExpiringUndoManager {
            return result
        }

        // If the window one isn't set, we fallback to our global one.
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            return appDelegate.undoManager
        }

        return nil
    }

    struct SavedFrame {
        let window: NSRect
        let screen: NSRect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    init(_ ghostty: Ghostty.App,
         baseConfig base: Ghostty.SurfaceConfiguration? = nil,
         surfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil
    ) {
        self.ghostty = ghostty
        self.derivedConfig = DerivedConfig(ghostty.config)

        super.init(window: nil)

        // Initialize our initial surface, injecting the window name env var.
        guard let ghostty_app = ghostty.app else { preconditionFailure("app must be loaded") }
        var initialConfig = base ?? Ghostty.SurfaceConfiguration()
        if let existingName = initialConfig.environmentVariables["GHOZTTY_WINDOW_NAME"] {
            self.windowName = existingName
        } else {
            initialConfig.environmentVariables["GHOZTTY_WINDOW_NAME"] = windowName
        }
        self.surfaceTree = tree ?? .init(view: Ghostty.SurfaceView(ghostty_app, baseConfig: initialConfig))

        // Setup our bell state for the window
        setupBellNotificationPublisher()

        // Setup activity state aggregation for the window
        setupActivityStatePublisher()

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onConfirmClipboardRequest),
            name: Ghostty.Notification.confirmClipboard,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(didChangeScreenParametersNotification),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChangeBase(_:)),
            name: .ghosttyConfigDidChange,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyCommandPaletteDidToggle(_:)),
            name: .ghosttyCommandPaletteDidToggle,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyMaximizeDidToggle(_:)),
            name: .ghosttyMaximizeDidToggle,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyMachineDidRename(_:)),
            name: .ghosttyMachineDidRename,
            object: nil)
        // WP-D1: a reconnect that ran (and failed) during a DARK wake —
        // display off, surface allocation can fail — must self-heal promptly
        // at REAL wake: reset the backoff and kick a fresh attempt.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil)
        // WP-D1: same idea for the network path — a reconnect that burned its
        // retry budget while Wi-Fi was down (lid closed, cable out) must kick
        // a fresh attempt the moment the network comes back instead of
        // waiting out backoff timers or the slow re-dial cadence.
        center.addObserver(
            self,
            selector: #selector(networkPathDidBecomeSatisfied(_:)),
            name: .ghosttyNetworkPathDidBecomeSatisfied,
            object: nil)

        // Splits
        center.addObserver(
            self,
            selector: #selector(ghosttyDidCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidNewSplit(_:)),
            name: Ghostty.Notification.ghosttyNewSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidEqualizeSplits(_:)),
            name: Ghostty.Notification.didEqualizeSplits,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidFocusSplit(_:)),
            name: Ghostty.Notification.ghosttyFocusSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidSwapSplit(_:)),
            name: Ghostty.Notification.ghosttySwapSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidToggleSplitZoom(_:)),
            name: Ghostty.Notification.didToggleSplitZoom,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidToggleHeroMode(_:)),
            name: Ghostty.Notification.didToggleHeroMode,
            object: nil)

        heroSelectionCancellable = heroModeState.$selectedIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newIndex in
                self?.heroSelectionDidChange(to: newIndex)
            }

        center.addObserver(
            self,
            selector: #selector(ghosttyDidResizeSplit(_:)),
            name: Ghostty.Notification.didResizeSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidPresentTerminal(_:)),
            name: Ghostty.Notification.ghosttyPresentTerminal,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttySurfaceDragEndedNoTarget(_:)),
            name: .ghosttySurfaceDragEndedNoTarget,
            object: nil)

        // Listen for local events that we need to know of outside of
        // single surface handlers.
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in self?.localEventHandler(event) }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        undoManager?.removeAllActions(withTarget: self)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    // MARK: Methods

    /// Create a new split.
    @discardableResult
    func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil,
        ratio: Double = 0.5,
        onCreate: ((Ghostty.SurfaceView) -> Void)? = nil
    ) -> Ghostty.SurfaceView? {
        // We can only create new splits for surfaces in our tree.
        guard surfaceTree.root?.node(view: oldView) != nil else { return nil }

        // Inherit and shift the parent's background color for visual depth.
        // Use explicit tint if set, otherwise fall back to the terminal's
        // actual background color from the config.
        var effectiveConfig = config ?? Ghostty.SurfaceConfiguration()
        let hasExplicitTint = effectiveConfig.backgroundTint != nil
        if !hasExplicitTint {
            let parentNSColor = oldView.backgroundTintNSColor
                ?? NSColor(oldView.derivedConfig.backgroundColor).resolvedSRGB
            let shifted = Self.shiftedTint(parentNSColor)
            effectiveConfig.backgroundTint = Color(shifted)
            effectiveConfig.backgroundTintNSColor = shifted
        }

        // Inject the window name env var.
        if effectiveConfig.environmentVariables["GHOZTTY_WINDOW_NAME"] == nil {
            effectiveConfig.environmentVariables["GHOZTTY_WINDOW_NAME"] = windowName
        }

        // Remote inheritance: if this window is bound to a remote machine, new
        // splits open on the SAME machine over the SAME shared connection. The
        // incoming config (e.g. from a keybind notification) won't carry these,
        // so we inject them here. The handle is owned by `remoteConnection`
        // (this controller) and shared, never freed per-surface.
        //
        // The new split also inherits the parent pane's COMMAND (re-run it; nil ⇒
        // agent default shell) and its CWD. The cwd is a blocking agent RPC, so we
        // must NOT resolve it on the main thread (it would beachball on a slow or
        // wedged agent). We snapshot the command + session id cheaply, then resolve
        // the cwd OFF the main thread and finish the split in the completion. This
        // means the remote split is created asynchronously (a few ms on a healthy
        // agent); callers that need the new view should use the keybind/notification
        // path (which ignores the return) — the synchronous return is preserved for
        // LOCAL splits only.
        if let remoteConnection, effectiveConfig.remoteConnection == nil {
            effectiveConfig.remoteMachine = remoteConnection.machine
            effectiveConfig.remoteConnection = remoteConnection.handle
            // Keep the connection owner alive across the new surface's deferred free
            // (channel detach). See SurfaceConfiguration.connectionKeepAlive.
            effectiveConfig.connectionKeepAlive = remoteConnection
            // session_id stays nil: each split opens a fresh remote session on
            // the same machine/connection.
            if effectiveConfig.command == nil,
               let parentCommand = Self.remoteInheritance(of: oldView).command {
                effectiveConfig.command = parentCommand
                // `wait-after-command` makes libghostty forward this as an EXPLICIT
                // remote command in the OPEN (otherwise it's treated as a default
                // shell and dropped). Matches the explicit `-e`/`--command` path.
                effectiveConfig.waitAfterCommand = true
            }
            // The split OPENs a fresh session on the same machine, so the
            // per-host default SHELL applies (the working directory instead
            // inherits from the parent pane below — a per-host default cwd
            // must not yank a split away from where its parent is).
            if effectiveConfig.remoteShell == nil {
                effectiveConfig.remoteShell = remoteConnection.machine.settings.shell
            }

            let alreadyHasCwd = effectiveConfig.remoteWorkingDirectory != nil
            Self.resolveRemoteInheritance(
                from: oldView,
                on: remoteConnection.handle
            ) { [weak self] _, cwd in
                guard let self else { return }
                var cfg = effectiveConfig
                if !alreadyHasCwd, let cwd { cfg.remoteWorkingDirectory = cwd }
                if let newView = self.finishSplit(
                    config: cfg,
                    at: oldView,
                    direction: direction,
                    ratio: ratio,
                    hasExplicitTint: hasExplicitTint) {
                    onCreate?(newView)
                }
            }
            return nil
        }

        let newView = finishSplit(
            config: effectiveConfig,
            at: oldView,
            direction: direction,
            ratio: ratio,
            hasExplicitTint: hasExplicitTint)
        if let newView { onCreate?(newView) }
        return newView
    }

    /// Build the new surface, insert it into the tree, and finalize focus/undo.
    /// Split out of `newSplit` so the remote path can call it AFTER an off-main
    /// cwd query, while the local path calls it synchronously.
    @discardableResult
    private func finishSplit(
        config effectiveConfig: Ghostty.SurfaceConfiguration,
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        ratio: Double,
        hasExplicitTint: Bool
    ) -> Ghostty.SurfaceView? {
        // The parent may have been removed from the tree while we were resolving
        // the remote cwd off the main thread.
        guard surfaceTree.root?.node(view: oldView) != nil else { return nil }

        // Create a new surface view
        guard let ghostty_app = ghostty.app else { return nil }
        let newView = Ghostty.SurfaceView(ghostty_app, baseConfig: effectiveConfig)

        // Do the split
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(
                view: newView,
                at: oldView,
                direction: direction,
                ratio: ratio)
        } catch {
            // If splitting fails for any reason (it should not), then we just log
            // and return. The new view we created will be deinitialized and its
            // no big deal.
            Ghostty.logger.warning("failed to insert split: \(error)")
            return nil
        }

        replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: "New Split")

        // Only adjust the terminal palette for explicit IPC --color flags.
        // Auto-shifted splits use the SwiftUI overlay for visual depth
        // without touching the terminal (which may still be initializing).
        if hasExplicitTint, let nsColor = newView.backgroundTintNSColor {
            DispatchQueue.main.async {
                newView.applyPaletteForColor(nsColor)
            }
        }

        return newView
    }

    /// Resolve the REMOTE working directory to seed a new split/tab with, by
    /// asking the agent for the parent remote pane's current child cwd (§WP4).
    /// Returns nil if `parent` is not a (resolved) remote surface or the query
    /// fails — the caller then opens the new pane in the agent's default cwd.
    ///
    /// This is an on-demand RPC: get the parent surface's live remote session id,
    /// then `GET_CWD` it over the shared connection. The agent reads the child
    /// process's actual cwd from the OS, so it works even for shells that emit no
    /// OSC 7 (e.g. cmd.exe).
    static func queryRemoteCwd(
        of parent: Ghostty.SurfaceView,
        on connection: ghostty_remote_connection_t
    ) -> String? {
        guard let surface = parent.surface else { return nil }

        let sid = Ghostty.AllocatedString(
            ghostty_surface_remote_session_id(surface)).string
        guard !sid.isEmpty else { return nil }

        let cwd = sid.withCString { cSid in
            Ghostty.AllocatedString(
                ghostty_remote_connection_query_cwd(connection, cSid)).string
        }
        return cwd.isEmpty ? nil : cwd
    }

    /// The remote inheritance to seed a new window/tab/split from a parent remote
    /// frame (§WP4): the parent pane's COMMAND (so the new frame re-runs it; nil
    /// ⇒ the agent default shell) and its live SESSION ID (so we can query its
    /// cwd off the main thread). These are cheap, non-blocking snapshots read
    /// directly from the surface — no network. The cwd itself is resolved
    /// separately/asynchronously by `queryRemoteCwd(sessionId:on:)` because it is
    /// a blocking agent RPC that must NEVER run on the main thread.
    struct RemoteInheritance {
        let command: String?
        let sessionId: String?
    }

    /// Snapshot the parent remote frame's command + session id without blocking.
    static func remoteInheritance(of parent: Ghostty.SurfaceView) -> RemoteInheritance {
        guard let surface = parent.surface else {
            return RemoteInheritance(command: nil, sessionId: nil)
        }
        let command = Ghostty.AllocatedString(
            ghostty_surface_remote_command(surface)).string
        let sid = Ghostty.AllocatedString(
            ghostty_surface_remote_session_id(surface)).string
        return RemoteInheritance(
            command: command.isEmpty ? nil : command,
            sessionId: sid.isEmpty ? nil : sid)
    }

    /// Resolve a remote pane's child cwd from an already-snapshotted `sessionId`.
    /// This is a bounded agent RPC (default `timeoutMs`) that takes a plain
    /// session id so it can be called from a BACKGROUND queue (the surface pointer
    /// is not touched here). Returns nil on any failure (the new frame then opens
    /// in the agent's default cwd). MUST be called off the main thread.
    static func queryRemoteCwd(
        sessionId: String,
        on connection: ghostty_remote_connection_t,
        timeoutMs: UInt32 = remoteCwdQueryTimeoutMs
    ) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let cwd = sessionId.withCString { cSid in
            Ghostty.AllocatedString(
                ghostty_remote_connection_query_cwd_timeout(
                    connection, cSid, timeoutMs)).string
        }
        return cwd.isEmpty ? nil : cwd
    }

    /// Tight bound (ms) for an on-demand cwd query that seeds a new remote frame.
    /// A healthy agent replies in single-digit ms; this caps the wait on the
    /// BACKGROUND queue so a slow/wedged agent only delays the new frame briefly
    /// (it then opens in the agent's default cwd) instead of stalling for 10s.
    static let remoteCwdQueryTimeoutMs: UInt32 = 1500

    /// Resolve the remote inheritance for a new frame OFF the main thread, then
    /// invoke `build` on the main thread with the resolved `command` + `cwd`.
    ///
    /// This is the single non-blocking entry point used by the new
    /// window/tab/split paths (§WP4). The COMMAND is a cheap synchronous snapshot;
    /// the CWD is a blocking agent RPC, so we hop to a background queue for it and
    /// only return to the main thread to build the frame. The UI never blocks. If
    /// the parent surface has no live remote session, `build` runs immediately on
    /// the main thread with a nil cwd (the agent's default).
    @MainActor
    static func resolveRemoteInheritance(
        from parent: Ghostty.SurfaceView,
        on connection: ghostty_remote_connection_t,
        build: @escaping @MainActor (_ command: String?, _ cwd: String?) -> Void
    ) {
        let inherit = remoteInheritance(of: parent)
        guard let sessionId = inherit.sessionId else {
            // No resolved remote session: nothing to query, build immediately.
            build(inherit.command, nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let cwd = queryRemoteCwd(sessionId: sessionId, on: connection)
            DispatchQueue.main.async {
                build(inherit.command, cwd)
            }
        }
    }

    /// Move focus to a surface view.
    func focusSurface(_ view: Ghostty.SurfaceView) {
        // Check if target surface is in our tree
        guard surfaceTree.contains(view) else { return }

        // Move focus to the target surface and activate the window/app
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: view)
            view.window?.makeKeyAndOrderFront(nil)
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Called when the surfaceTree variable changed.
    ///
    /// Subclasses should call super first.
    func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        // If our surface tree becomes empty then we have no focused surface.
        if to.isEmpty {
            focusedSurface = nil
        }

        // Session persistence (T05): the split topology is the heart of the
        // layout manifest — re-sync on every tree change (new split, close,
        // resize-equalize, ...). Debounced; each sync also restarts the
        // per-leaf session-id capture for freshly-opened panes.
        if sessionLayoutEntryID != nil {
            SessionLayoutManifest.shared.scheduleSync(self)
        }

        if heroModeState.isActive {
            let oldLeaves = from.root?.leaves() ?? []
            let newLeaves = to.root?.leaves() ?? []
            if newLeaves.count <= 1 {
                heroModeState.deactivate()
            } else {
                let oldSet = Set(oldLeaves.map { ObjectIdentifier($0) })
                let addedLeaves = newLeaves.filter { !oldSet.contains(ObjectIdentifier($0)) }
                if let addedLeaf = addedLeaves.first,
                   let newIndex = newLeaves.firstIndex(of: addedLeaf) {
                    heroModeState.select(newIndex, leafCount: newLeaves.count)
                } else {
                    heroModeState.clampIndex(newLeaves.count)
                }
            }
        }
    }

    /// Update all surfaces with the focus state. This ensures that libghostty has an accurate view about
    /// what surface is focused. This must be called whenever a surface OR window changes focus.
    func syncFocusToSurfaceTree() {
        for surfaceView in surfaceTree {
            // Our focus state requires that this window is key and our currently
            // focused surface is the surface in this view.
            let focused: Bool = (window?.isKeyWindow ?? false) &&
                surfaceView == focusedSurface &&
                surfaceView.isFirstResponder
            surfaceView.focusDidChange(focused)
        }
    }

    // Call this whenever the frame changes
    private func windowFrameDidChange() {
        // We need to update our saved frame information in case of monitor
        // changes (see didChangeScreenParameters notification).
        savedFrame = nil

        // Session persistence (T05): a persistent window's frame is part of
        // its restore manifest (debounced — drags fire this continuously).
        if sessionLayoutEntryID != nil {
            SessionLayoutManifest.shared.scheduleSync(self)
        }

        guard let window, let screen = window.screen else { return }
        savedFrame = .init(window: window.frame, screen: screen.visibleFrame)
    }

    /// Session persistence (T05): start tracking this window in the
    /// `SessionLayoutManifest` the moment it binds to the LOCAL agent's
    /// connection — the one choke point every persistent window passes
    /// through (fresh window in `TerminalController.init`, tab and
    /// new-window-from-parent inheritance). Gated on the config flag so
    /// flag-off behavior is untouched (a manual loopback remote window must
    /// not suddenly persist), and on the machine being local so relay/remote
    /// windows keep using `RemoteSessionManifest`. A reconnect replaces
    /// `remoteConnection` on an already-tracked window: entry stays.
    private func registerSessionLayoutIfNeeded() {
        guard sessionLayoutEntryID == nil,
              self is TerminalController,
              let remoteConnection,
              remoteConnection.machine.isLocalMachine,
              ghostty.config.sessionPersistence
        else { return }
        sessionLayoutEntryID = SessionLayoutManifest.shared.register()
        SessionLayoutManifest.shared.scheduleSync(self)
    }

    func confirmClose(
        messageText: String,
        informativeText: String,
        completion: @escaping () -> Void
    ) {
        // If we already have an alert, we need to wait for that one.
        guard alert == nil else { return }

        // If there is no window to attach the modal then we assume success
        // since we'll never be able to show the modal.
        guard let window else {
            completion()
            return
        }

        // If we need confirmation by any, show one confirmation for all windows
        // in the tab group.
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { response in
            let alertWindow = alert.window
            self.alert = nil
            if response == .alertFirstButtonReturn {
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alertWindow.orderOut(nil)
                completion()
            }
        }

        // Store our alert so we only ever show one.
        self.alert = alert
    }

    /// Prompt the user to change the tab/window title.
    func promptTabTitle() {
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "Change Tab Title"
        alert.informativeText = "Leave blank to restore the default."
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = titleOverride ?? window.title
        alert.accessoryView = textField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }

            let newTitle = textField.stringValue
            if newTitle.isEmpty {
                self.titleOverride = nil
            } else {
                self.titleOverride = newTitle
            }
        }
    }

    /// Close a surface from a view.
    func closeSurface(
        _ view: Ghostty.SurfaceView,
        withConfirmation: Bool = true
    ) {
        guard let node = surfaceTree.root?.node(view: view) else { return }
        closeSurface(node, withConfirmation: withConfirmation)
    }

    /// Close a surface node (which may contain splits), requesting confirmation if necessary.
    ///
    /// This will also insert the proper undo stack information in.
    func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // This node must be part of our tree
        guard surfaceTree.contains(node) else { return }

        // If the child process is not alive, then we exit immediately
        guard withConfirmation else {
            removeSurfaceNode(node)
            return
        }

        // Confirm close. We use an NSAlert instead of a SwiftUI confirmationDialog
        // due to SwiftUI bugs (see Ghostty #560). To repeat from #560, the bug is that
        // confirmationDialog allows the user to Cmd-W close the alert, but when doing
        // so SwiftUI does not update any of the bindings to note that window is no longer
        // being shown, and provides no callback to detect this.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) { [weak self] in
            if let self {
                self.removeSurfaceNode(node)
            }
        }
    }

    // MARK: Split Tree Management

    /// Find the next surface to focus when a node is being closed.
    /// Goes to previous split unless we're the leftmost leaf, then goes to next.
    private func findNextFocusTargetAfterClosing(node: SplitTree<Ghostty.SurfaceView>.Node) -> Ghostty.SurfaceView? {
        guard let root = surfaceTree.root else { return nil }

        // If we're the leftmost, then we move to the next surface after closing.
        // Otherwise, we move to the previous.
        if root.leftmostLeaf() == node.leftmostLeaf() {
            return surfaceTree.focusTarget(for: .next, from: node)
        } else {
            return surfaceTree.focusTarget(for: .previous, from: node)
        }
    }

    /// Remove a node from the surface tree and move focus appropriately.
    ///
    /// This also updates the undo manager to support restoring this node.
    ///
    /// This does no confirmation and assumes confirmation is already done.
    private func removeSurfaceNode(_ node: SplitTree<Ghostty.SurfaceView>.Node) {
        // Move focus if the closed surface was focused and we have a next target
        let nextFocus: Ghostty.SurfaceView? = if node.contains(
            where: { $0 == focusedSurface }
        ) {
            findNextFocusTargetAfterClosing(node: node)
        } else {
            nil
        }

        replaceSurfaceTree(
            surfaceTree.removing(node),
            moveFocusTo: nextFocus,
            moveFocusFrom: focusedSurface,
            undoAction: "Close Terminal"
        )
    }

    func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // Setup our new split tree
        let oldTree = surfaceTree
        surfaceTree = newTree
        if let newView {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: newView, from: oldView)
            }
        }

        // Setup our undo
        guard let undoManager else { return }
        if let undoAction {
            undoManager.setActionName(undoAction)
        }

        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            target.surfaceTree = oldTree
            if let oldView {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: oldView, from: target.focusedSurface)
                }
            }

            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration
            ) { target in
                target.replaceSurfaceTree(
                    newTree,
                    moveFocusTo: newView,
                    moveFocusFrom: target.focusedSurface,
                    undoAction: undoAction)
            }
        }
    }

    // MARK: Notifications

    @objc private func didChangeScreenParametersNotification(_ notification: Notification) {
        // If we have a window that is visible and it is outside the bounds of the
        // screen then we clamp it back to within the screen.
        guard let window else { return }
        guard window.isVisible else { return }

        // We ignore fullscreen windows because macOS automatically resizes
        // those back to the fullscreen bounds.
        guard !window.styleMask.contains(.fullScreen) else { return }

        guard let screen = window.screen else { return }
        let visibleFrame = screen.visibleFrame
        var newFrame = window.frame

        // Clamp width/height
        if newFrame.size.width > visibleFrame.size.width {
            newFrame.size.width = visibleFrame.size.width
        }
        if newFrame.size.height > visibleFrame.size.height {
            newFrame.size.height = visibleFrame.size.height
        }

        // Ensure the window is on-screen. We only do this if the previous frame
        // was also on screen. If a user explicitly wanted their window off screen
        // then we let it stay that way.
        x: if newFrame.origin.x < visibleFrame.origin.x {
            if let savedFrame, savedFrame.window.origin.x < savedFrame.screen.origin.x {
                break x
            }

            newFrame.origin.x = visibleFrame.origin.x
        }
        y: if newFrame.origin.y < visibleFrame.origin.y {
            if let savedFrame, savedFrame.window.origin.y < savedFrame.screen.origin.y {
                break y
            }

            newFrame.origin.y = visibleFrame.origin.y
        }

        // Apply the new window frame
        window.setFrame(newFrame, display: true)
    }

    @objc private func ghosttyConfigDidChangeBase(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a
        // surface-specific one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // Update our derived config
        self.derivedConfig = DerivedConfig(config)
    }

    @objc private func ghosttyCommandPaletteDidToggle(_ notification: Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        toggleCommandPalette(nil)
    }

    @objc private func ghosttyMaximizeDidToggle(_ notification: Notification) {
        guard let window else { return }
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        window.zoom(nil)
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let node = surfaceTree.root?.node(view: target) else { return }
        let processAlive = (notification.userInfo?["process_alive"] as? Bool) ?? false
        Ghostty.logger.warning("ghosttyDidCloseSurface processAlive=\(processAlive)")
        closeSurface(node, withConfirmation: processAlive)
    }

    @objc private func ghosttyDidNewSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let oldView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.root?.node(view: oldView) != nil else { return }

        // Notification must contain our base config
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration

        // Determine our desired direction
        guard let directionAny = notification.userInfo?["direction"] else { return }
        guard let direction = directionAny as? ghostty_action_split_direction_e else { return }
        let splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: splitDirection = .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: splitDirection = .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: splitDirection = .down
        case GHOSTTY_SPLIT_DIRECTION_UP: splitDirection = .up
        default: return
        }

        newSplit(at: oldView, direction: splitDirection, baseConfig: config)
    }

    @objc private func ghosttyDidEqualizeSplits(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }

        // Check if target surface is in current controller's tree
        guard surfaceTree.contains(target) else { return }

        // Equalize the splits
        surfaceTree = surfaceTree.equalized()
    }

    @objc private func ghosttyDidFocusSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.root?.node(view: target) != nil else { return }

        // Intercept navigation when hero mode is active
        if heroModeState.isActive {
            let leaves = surfaceTree.root?.leaves() ?? []
            guard let directionValue = notification.userInfo?[Ghostty.Notification.SplitDirectionKey] as? Ghostty.SplitFocusDirection else { return }
            switch directionValue {
            case .previous, .up, .left:
                heroModeState.selectPrevious(leafCount: leaves.count)
            case .next, .down, .right:
                heroModeState.selectNext(leafCount: leaves.count)
            }
            return
        }

        // Get the direction from the notification
        guard let directionAny = notification.userInfo?[Ghostty.Notification.SplitDirectionKey] else { return }
        guard let direction = directionAny as? Ghostty.SplitFocusDirection else { return }

        // Find the node for the target surface
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Find the next surface to focus
        guard let nextSurface = surfaceTree.focusTarget(for: direction.toSplitTreeFocusDirection(), from: targetNode) else {
            return
        }

        if surfaceTree.zoomed != nil {
            if derivedConfig.splitPreserveZoom.contains(.navigation) {
                surfaceTree = SplitTree(
                    root: surfaceTree.root,
                    zoomed: surfaceTree.root?.node(view: nextSurface))
            } else {
                surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
            }
        }

        // Move focus to the next surface
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: nextSurface, from: target)
        }
    }

    @objc private func ghosttyDidSwapSplit(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.root?.node(view: target) != nil else { return }

        guard let directionAny = notification.userInfo?[Ghostty.Notification.SwapSplitDirectionKey] else { return }
        guard let direction = directionAny as? Ghostty.SplitFocusDirection else { return }

        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        let focusDirection: SplitTree<Ghostty.SurfaceView>.FocusDirection = direction.toSplitTreeFocusDirection()
        guard let neighborView = surfaceTree.focusTarget(for: focusDirection, from: targetNode) else {
            return
        }

        guard let neighborNode = surfaceTree.root?.node(view: neighborView) else { return }

        do {
            surfaceTree = try surfaceTree.swapping(targetNode, with: neighborNode)
        } catch {
            return
        }

        DispatchQueue.main.async {
            Ghostty.moveFocus(to: target)
        }
    }

    @objc private func ghosttyDidToggleSplitZoom(_ notification: Notification) {
        // Exit hero mode if active (mutually exclusive)
        if heroModeState.isActive {
            heroModeState.deactivate()
        }

        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Toggle the zoomed state
        if surfaceTree.zoomed == targetNode {
            // Already zoomed, unzoom it
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
        } else {
            // We require that the split tree have splits
            guard surfaceTree.isSplit else { return }

            // Not zoomed or different node zoomed, zoom this node
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: targetNode)
        }

        // Move focus to our window. Importantly this ensures that if we click the
        // reset zoom button in a tab bar of an unfocused tab that we become focused.
        window?.makeKeyAndOrderFront(nil)

        // Ensure focus stays on the target surface. We lose focus when we do
        // this so we need to grab it again.
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: target)
        }
    }

    @objc private func ghosttyDidToggleHeroMode(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.root?.node(view: target) != nil else { return }

        if heroModeState.isActive {
            let previousSurface = heroSurfaceForCurrentSelection()
            heroModeState.deactivate()
            if let surface = previousSurface {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: surface)
                }
            }
        } else {
            // Exit zoom if active
            if surfaceTree.zoomed != nil {
                surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
            }

            let leaves = surfaceTree.root?.leaves() ?? []
            guard leaves.count > 1 else { return }

            let focusedIndex = leaves.firstIndex(where: { $0 === target }) ?? 0
            heroModeState.activate(focusedIndex: focusedIndex, leafCount: leaves.count)
        }

        window?.makeKeyAndOrderFront(nil)
    }

    private func heroSurfaceForCurrentSelection() -> Ghostty.SurfaceView? {
        let leaves = surfaceTree.root?.leaves() ?? []
        guard heroModeState.selectedIndex < leaves.count else { return nil }
        return leaves[heroModeState.selectedIndex]
    }

    private func heroSelectionDidChange(to index: Int) {
        guard heroModeState.isActive else { return }
        if let surface = heroSurfaceForCurrentSelection() {
            Ghostty.moveFocus(to: surface)
        }
    }

    @objc private func ghosttyDidResizeSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Extract direction and amount from notification
        guard let directionAny = notification.userInfo?[Ghostty.Notification.ResizeSplitDirectionKey] else { return }
        guard let direction = directionAny as? Ghostty.SplitResizeDirection else { return }

        guard let amountAny = notification.userInfo?[Ghostty.Notification.ResizeSplitAmountKey] else { return }
        guard let amount = amountAny as? UInt16 else { return }

        // Convert Ghostty.SplitResizeDirection to SplitTree.Spatial.Direction
        let spatialDirection: SplitTree<Ghostty.SurfaceView>.Spatial.Direction
        switch direction {
        case .up: spatialDirection = .up
        case .down: spatialDirection = .down
        case .left: spatialDirection = .left
        case .right: spatialDirection = .right
        }

        // Use viewBounds for the spatial calculation bounds
        let bounds = CGRect(origin: .zero, size: surfaceTree.viewBounds())

        // Perform the resize using the new SplitTree resize method
        do {
            surfaceTree = try surfaceTree.resizing(node: targetNode, by: amount, in: spatialDirection, with: bounds)
        } catch {
            Ghostty.logger.warning("failed to resize split: \(error)")
        }
    }

    @objc private func ghosttyDidPresentTerminal(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }

        // Bring the window to front and focus the surface.
        window?.makeKeyAndOrderFront(nil)

        // We use a small delay to ensure this runs after any UI cleanup
        // (e.g., command palette restoring focus to its original surface).
        Ghostty.moveFocus(to: target)
        Ghostty.moveFocus(to: target, delay: 0.1)

        // Show a brief highlight to help the user locate the presented terminal.
        target.highlight()
    }

    @objc private func ghosttySurfaceDragEndedNoTarget(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // If our tree isn't split, then we never create a new window, because
        // it is already a single split.
        guard surfaceTree.isSplit else { return }

        // If we are removing our focused surface then we move it. We need to
        // keep track of our old one so undo sends focus back to the right place.
        let oldFocusedSurface = focusedSurface
        if focusedSurface == target {
            focusedSurface = findNextFocusTargetAfterClosing(node: targetNode)
        }

        // Remove the surface from our tree
        let removedTree = surfaceTree.removing(targetNode)

        // Create a new tree with the dragged surface and open a new window
        let newTree = SplitTree<Ghostty.SurfaceView>(view: target)

        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Split")
        defer {
            undoManager?.endUndoGrouping()
        }

        replaceSurfaceTree(removedTree, moveFocusFrom: oldFocusedSurface)
        _ = TerminalController.newWindow(
            ghostty,
            tree: newTree,
            position: notification.userInfo?[Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey] as? NSPoint,
            confirmUndo: false)
    }

    // MARK: Local Events

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        return switch event.type {
        case .flagsChanged:
            localEventFlagsChanged(event)

        default:
            event
        }
    }

    private func localEventFlagsChanged(_ event: NSEvent) -> NSEvent? {
        var surfaces: [Ghostty.SurfaceView] = surfaceTree.map { $0 }

        // If we're the main window receiving key input, then we want to avoid
        // calling this on our focused surface because that'll trigger a double
        // flagsChanged call.
        if NSApp.mainWindow == window {
            surfaces = surfaces.filter { $0 != focusedSurface }
        }

        for surface in surfaces {
            surface.flagsChanged(with: event)
        }

        return event
    }

    // MARK: TerminalViewDelegate

    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        let lastFocusedSurface = focusedSurface
        focusedSurface = to

        // Important to cancel any prior subscriptions
        focusedSurfaceCancellables = []

        // Setup our title listener. If we have a focused surface we always use that.
        // Otherwise, we try to use our last focused surface. In either case, we only
        // want to care if the surface is in the tree so we don't listen to titles of
        // closed surfaces.
        if let titleSurface = focusedSurface ?? lastFocusedSurface,
           surfaceTree.contains(titleSurface) {
            // If we have a surface, we want to listen for title changes.
            titleSurface.$title
                .combineLatest(titleSurface.$bell)
                .map { [weak self] in self?.computeTitle(title: $0, bell: $1) ?? "" }
                .sink { [weak self] in self?.titleDidChange(to: $0) }
                .store(in: &focusedSurfaceCancellables)
        } else {
            // There is no surface to listen to titles for.
            titleDidChange(to: "👻")
        }
    }

    private func computeTitle(title: String, bell: Bool) -> String {
        var result = title
        if bell && ghostty.config.bellFeatures.contains(.title) {
            result = "🔔 \(result)"
        }

        return result
    }

    private func titleDidChange(to: String) {
        lastComputedTitle = to
        applyTitleToWindow()
    }

    private func applyTitleToWindow() {
        guard let window else { return }

        var title: String
        if let titleOverride {
            title = computeTitle(
                title: titleOverride,
                bell: focusedSurface?.bell ?? false)
        } else {
            title = lastComputedTitle
        }

        if let termWindow = window as? TerminalWindow,
           termWindow.activityState != .idle {
            title += " (\(termWindow.activityState.rawValue))"
        }

        // The remote machine name is shown as a titlebar pill (see
        // TerminalWindow.machinePillAccessory / MachinePillView) rather than a
        // plain title suffix, so it is intentionally not appended here.

        window.title = title
    }

    func pwdDidChange(to: URL?) {
        guard let window else { return }

        if derivedConfig.macosTitlebarProxyIcon == .visible {
            // Use the 'to' URL directly
            window.representedURL = to
        } else {
            window.representedURL = nil
        }
    }

    func cellSizeDidChange(to: NSSize) {
        guard derivedConfig.windowStepResize else { return }
        // Stage manager can sometimes present windows in such a way that the
        // cell size is temporarily zero due to the window being tiny. We can't
        // set content resize increments to this value, so avoid an assertion failure.
        guard to.width > 0 && to.height > 0 else { return }
        self.window?.contentResizeIncrements = to
    }

    func performSplitAction(_ action: TerminalSplitOperation) {
        switch action {
        case .resize(let resize):
            splitDidResize(node: resize.node, to: resize.ratio)
        case .drop(let drop):
            splitDidDrop(source: drop.payload, destination: drop.destination, zone: drop.zone)
        }
    }

    private func splitDidResize(node: SplitTree<Ghostty.SurfaceView>.Node, to newRatio: Double) {
        let resizedNode = node.resizing(to: newRatio)
        do {
            surfaceTree = try surfaceTree.replacing(node: node, with: resizedNode)
        } catch {
            Ghostty.logger.warning("failed to replace node during split resize: \(error)")
        }
    }

    private func splitDidDrop(
        source: Ghostty.SurfaceView,
        destination: Ghostty.SurfaceView,
        zone: TerminalSplitDropZone
    ) {
        // Map drop zone to split direction
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }

        // Check if source is in our tree
        if let sourceNode = surfaceTree.root?.node(view: source) {
            // Source is in our tree - same window move
            let treeWithoutSource = surfaceTree.removing(sourceNode)
            let newTree: SplitTree<Ghostty.SurfaceView>
            do {
                newTree = try treeWithoutSource.inserting(view: source, at: destination, direction: direction)
            } catch {
                Ghostty.logger.warning("failed to insert surface during drop: \(error)")
                return
            }

            replaceSurfaceTree(
                newTree,
                moveFocusTo: source,
                moveFocusFrom: focusedSurface,
                undoAction: "Move Split")
            return
        }

        // Source is not in our tree - search other windows
        var sourceController: BaseTerminalController?
        var sourceNode: SplitTree<Ghostty.SurfaceView>.Node?
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            guard controller !== self else { continue }
            if let node = controller.surfaceTree.root?.node(view: source) {
                sourceController = controller
                sourceNode = node
                break
            }
        }

        guard let sourceController, let sourceNode else {
            Ghostty.logger.warning("source surface not found in any window during drop")
            return
        }

        // Remove from source controller's tree and add it to our tree.
        // We do this first because if there is an error then we can
        // abort.
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(view: source, at: destination, direction: direction)
        } catch {
            Ghostty.logger.warning("failed to insert surface during cross-window drop: \(error)")
            return
        }

        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Split")
        defer {
            undoManager?.endUndoGrouping()
        }

        // Remove the node from the source.
        sourceController.removeSurfaceNode(sourceNode)

        // Add in the surface to our tree
        replaceSurfaceTree(
            newTree,
            moveFocusTo: source,
            moveFocusFrom: focusedSurface)
    }

    func performAction(_ action: String, on surfaceView: Ghostty.SurfaceView) {
        guard let surface = surfaceView.surface else { return }
        let len = action.utf8CString.count
        if len == 0 { return }
        _ = action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(len - 1))
        }
    }

    // MARK: Appearance

    /// Toggle the background opacity between transparent and opaque states.
    /// Do nothing if the configured background-opacity is >= 1 (already opaque).
    /// Subclasses should override this to add platform-specific checks and sync appearance.
    func toggleBackgroundOpacity() {
        // Do nothing if config is already fully opaque
        guard ghostty.config.backgroundOpacity < 1 else { return }

        // Do nothing if in fullscreen (transparency doesn't apply in fullscreen)
        guard let window, !window.styleMask.contains(.fullScreen) else { return }

        // Toggle between transparent and opaque
        isBackgroundOpaque.toggle()

        // Update our appearance
        syncAppearance()
    }

    /// Override this to resync any appearance related properties. This will be called automatically
    /// when certain window properties change that affect appearance. The list below should be updated
    /// as we add new things:
    ///
    ///  - ``toggleBackgroundOpacity``
    func syncAppearance() {
        // Purposely a no-op. This lets subclasses override this and we can call
        // it virtually from here.
    }

    // MARK: Fullscreen

    /// Toggle fullscreen for the given mode.
    func toggleFullscreen(mode: FullscreenMode) {
        // We need a window to fullscreen
        guard let window = self.window else { return }

        // If we have a previous fullscreen style initialized, we want to check if
        // our mode changed. If it changed and we're in fullscreen, we exit so we can
        // toggle it next time. If it changed and we're not in fullscreen we can just
        // switch the handler.
        var newStyle = mode.style(for: window)
        newStyle?.delegate = self
        old: if let oldStyle = self.fullscreenStyle {
            // If we're not fullscreen, we can nil it out so we get the new style
            if !oldStyle.isFullscreen {
                self.fullscreenStyle = newStyle
                break old
            }

            assert(oldStyle.isFullscreen)

            // We consider our mode changed if the types change (obvious) but
            // also if its nil (not obvious) because nil means that the style has
            // likely changed but we don't support it.
            if newStyle == nil || type(of: newStyle!) != type(of: oldStyle) {
                // Our mode changed. Exit fullscreen (since we're toggling anyways)
                // and then set the new style for future use
                oldStyle.exit()
                self.fullscreenStyle = newStyle

                // We're done
                return
            }

            // Style is the same.
        } else {
            // We have no previous style
            self.fullscreenStyle = newStyle
        }
        guard let fullscreenStyle else { return }

        if fullscreenStyle.isFullscreen {
            fullscreenStyle.exit()
        } else {
            fullscreenStyle.enter()
        }
    }

    func fullscreenDidChange() {
        guard let fullscreenStyle else { return }

        // When we enter fullscreen, we want to show the update overlay so that it
        // is easily visible. For native fullscreen this is visible by showing the
        // menubar but we don't want to rely on that.
        if fullscreenStyle.isFullscreen {
            updateOverlayIsVisible = true
        } else {
            updateOverlayIsVisible = defaultUpdateOverlayVisibility()
        }

        // Always resync our appearance
        syncAppearance()
    }

    // MARK: Clipboard Confirmation

    @objc private func onConfirmClipboardRequest(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let surface = target.surface else { return }

        // We need a window
        guard let window = self.window else { return }

        // Check whether we use non-native fullscreen
        guard let str = notification.userInfo?[Ghostty.Notification.ConfirmClipboardStrKey] as? String else { return }
        guard let state = notification.userInfo?[Ghostty.Notification.ConfirmClipboardStateKey] as? UnsafeMutableRawPointer? else { return }
        guard let request = notification.userInfo?[Ghostty.Notification.ConfirmClipboardRequestKey] as? Ghostty.ClipboardRequest else { return }

        // If we already have a clipboard confirmation view up, we ignore this request.
        // This shouldn't be possible...
        guard self.clipboardConfirmation == nil else {
            Ghostty.App.completeClipboardRequest(surface, data: "", state: state, confirmed: true)
            return
        }

        // Show our paste confirmation
        self.clipboardConfirmation = ClipboardConfirmationController(
            surface: surface,
            contents: str,
            request: request,
            state: state,
            delegate: self
        )
        window.beginSheet(self.clipboardConfirmation!.window!)
    }

    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, _ request: Ghostty.ClipboardRequest) {
        // End our clipboard confirmation no matter what
        guard let cc = self.clipboardConfirmation else { return }
        self.clipboardConfirmation = nil

        // Close the sheet
        if let ccWindow = cc.window {
            window?.endSheet(ccWindow)
        }

        switch request {
        case let .osc_52_write(pasteboard):
            guard case .confirm = action else { break }
            let pb = pasteboard ?? NSPasteboard.general
            pb.declareTypes([.string], owner: nil)
            pb.setString(cc.contents, forType: .string)
        case .osc_52_read, .paste:
            let str: String
            switch action {
            case .cancel:
                str = ""

            case .confirm:
                str = cc.contents
            }

            Ghostty.App.completeClipboardRequest(cc.surface, data: str, state: cc.state, confirmed: true)
        }
    }

    // MARK: NSWindowController

    override func windowDidLoad() {
        super.windowDidLoad()

        // Setup our undo manager.

        // Everything beyond here is setting up the window
        guard let window else { return }

        // We always initialize our fullscreen style to native if we can because
        // initialization sets up some state (i.e. observers). If its set already
        // somehow we don't do this.
        if fullscreenStyle == nil {
            fullscreenStyle = NativeFullscreen(window)
            fullscreenStyle?.delegate = self
        }

        // Set our update overlay state
        updateOverlayIsVisible = defaultUpdateOverlayVisibility()

        // Sync the remote machine to the window (pill + AXGhosttyMachine attr) in
        // case it was set on the controller before the window finished loading.
        if let remoteMachine, let termWindow = window as? TerminalWindow {
            termWindow.remoteMachine = remoteMachine
        }
    }

    func defaultUpdateOverlayVisibility() -> Bool {
        guard let window else { return true }

        // No titlebar we always show the update overlay because it can't support
        // updates in the titlebar
        guard window.styleMask.contains(.titled) else {
            return true
        }

        // If it's a non terminal window we can't trust it has an update accessory,
        // so we always want to show the overlay.
        guard let window = window as? TerminalWindow else {
            return true
        }

        // Show the overlay if the window isn't.
        return !window.supportsUpdateAccessory
    }

    // MARK: NSWindowDelegate

    // This is called when performClose is called on a window (NOT when close()
    // is called directly). performClose is called primarily when UI elements such
    // as the "red X" are pressed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // We must have a window. Is it even possible not to?
        guard let window = self.window else { return true }

        // If we have no surfaces, close.
        if surfaceTree.isEmpty { return true }

        // If we already have an alert, continue with it
        guard alert == nil else { return false }

        // If our surfaces don't require confirmation, close.
        if !surfaceTree.contains(where: { $0.needsConfirmQuit }) { return true }

        // We require confirmation, so show an alert as long as we aren't already.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) {
            window.close()
        }

        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }

        // WP-D1: cancel any in-flight reconnect retry loop and stop observing
        // link-state changes — the window is going away.
        remoteReconnectGeneration += 1
        if let remoteLinkObserver {
            NotificationCenter.default.removeObserver(remoteLinkObserver)
            self.remoteLinkObserver = nil
        }

        // WP-D2: a clean close (user closed the window, or the remote child
        // exited) removes this window from the remote-session restore
        // manifest. App QUIT must NOT — the agent keeps detached sessions
        // alive (detach ≠ terminate), so entries left behind at quit are
        // re-attached on the next launch. Sign-OUT likewise must not: it
        // closes account-backed windows with `isSigningOut` set
        // (`AppDelegate.relayAccountDidSignOut()`) so a later sign-in can
        // restore them through the same manifest replay.
        if let entryID = remoteManifestEntryID {
            let delegate = NSApp.delegate as? AppDelegate
            if delegate?.isQuitting != true && delegate?.isSigningOut != true {
                RemoteSessionManifest.shared.remove(entryID)
            } else {
                // Preserved for restore: make sure the entry carries the
                // window's final user-set title. The `titleOverride` didSet
                // already keeps this in sync on every rename, so this is a
                // last-moment belt-and-braces sync at the preservation point.
                RemoteSessionManifest.shared.updateWindowTitle(
                    entryID, windowTitle: titleOverride)
            }
        }

        // Session persistence (T05): same contract for local agent-backed
        // windows — a clean close removes the layout entry, an app quit
        // preserves it for the T06 launch restore. (Sign-out doesn't apply:
        // local-agent windows aren't account-backed.) No full re-sync here:
        // during a quit, sibling tabs are already closing, so live tab-group
        // state is unreliable — `flushPendingSyncs` at quit-begin captured
        // the faithful snapshot; only the title is belt-and-braces synced.
        if let entryID = sessionLayoutEntryID {
            if (NSApp.delegate as? AppDelegate)?.isQuitting != true {
                SessionLayoutManifest.shared.remove(entryID)
            } else {
                SessionLayoutManifest.shared.updateWindowTitle(
                    entryID, windowTitle: titleOverride)
            }
        }

        // Emit a final bell-state transition so any observers can clear state
        // without separately tracking NSWindow lifecycle events.
        if bell {
            bell = false
            NotificationCenter.default.post(
                name: .terminalWindowBellDidChangeNotification,
                object: self,
                userInfo: [Notification.Name.terminalWindowHasBellKey: false]
            )
        }

        // I don't know if this is required anymore. We previously had a ref cycle between
        // the view and the window so we had to nil this out to break it but I think this
        // may now be resolved. We should verify that no memory leaks and we can remove this.
        window.contentView = nil

        // Make sure we clean up all our undos
        window.undoManager?.removeAllActions(withTarget: self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // If when we become key our first responder is the window itself, then we
        // want to move focus to our focused terminal surface. This works around
        // various weirdness with moving surfaces around.
        if let window, window.firstResponder == window, let focusedSurface {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusedSurface)
            }
        }

        // Becoming key can race with responder updates when activating a window.
        // Sync on the next runloop so split focus has settled first.
        DispatchQueue.main.async {
            self.syncFocusToSurfaceTree()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // When the color panel is open, the terminal should still appear focused
        // so the user sees accurate colors while picking.
        if NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible {
            return
        }

        // Becoming/losing key means we have to notify our surface(s) that we have focus
        // so things like cursors blink, pty events are sent, etc.
        self.syncFocusToSurfaceTree()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = self.window?.occlusionState.contains(.visible) ?? false
        for view in surfaceTree {
            if let surface = view.surface {
                ghostty_surface_set_occlusion(surface, visible)
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowDidMove(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        return appDelegate.undoManager
    }

    // MARK: Remote Reconnect (WP-D1)

    /// Backoff delays (seconds) before each reconnect attempt: ~30s total
    /// across 5 attempts, per remote-machines spec §5.1 (jitter omitted — a
    /// single GUI client retrying one host doesn't need thundering-herd
    /// protection).
    private static let remoteReconnectDelays: [TimeInterval] = [1, 2, 4, 8, 15]

    /// (Re)bind the transport link-state observer to the CURRENT
    /// `remoteConnection`. Called from `remoteConnection`'s didSet, so a
    /// reconnect swap automatically stops listening to the dead connection and
    /// starts listening to its replacement.
    private func bindRemoteConnectionStateObserver() {
        if let remoteLinkObserver {
            NotificationCenter.default.removeObserver(remoteLinkObserver)
            self.remoteLinkObserver = nil
        }
        guard let connection = remoteConnection else { return }
        // This window is (now) remote: make sure the app-wide network path
        // monitor is running so `networkPathDidBecomeSatisfied` can fire.
        NetworkPathMonitor.shared.start()
        remoteLinkObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyRemoteConnectionLinkDidChange,
            object: connection,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let connection = notification.object as? RemoteConnection else { return }
            self.remoteLinkStateDidChange(connection)
        }
        // Evaluate the CURRENT state too: a link that dropped before this
        // controller adopted the connection (its transition already fired, or
        // was seeded at RemoteConnection init) would otherwise never be seen.
        if connection.linkState != .connected {
            DispatchQueue.main.async { [weak self] in
                guard let self, connection === self.remoteConnection else { return }
                self.remoteLinkStateDidChange(connection)
            }
        }
    }

    /// The transport link state changed on this window's connection (main
    /// thread). Maps the Zig FSM (spec §5.1) onto the per-window reconnect
    /// state machine:
    ///
    ///   connected ──link drops──► reconnecting(1..N) ──dial+re-ATTACH ok──► connected
    ///                                    │
    ///                                    ├─ retries exhausted ─► disconnected (window kept)
    ///                                    └─ session gone/evicted ─► disconnected
    private func remoteLinkStateDidChange(_ connection: RemoteConnection) {
        guard connection === remoteConnection else { return }
        // This is the FIRST line read when tracing a reconnect: it must persist
        // (.warning maps to OSLog error level) and be readable — os_log redacts
        // string interpolation by default, so every field is tagged .public
        // (link/window state, self-healable, machine name, session id are not
        // secrets and must be greppable in `log show`).
        Ghostty.logger.warning(
            "remote reconnect: link=\(String(describing: connection.linkState), privacy: .public) window-state=\(String(describing: self.remoteConnectionState), privacy: .public) selfHealable=\(self.remoteDisconnectMaySelfHeal, privacy: .public) machine=\(connection.machine.name, privacy: .public) session=\(self.currentRemoteSessionID() ?? "-", privacy: .public)")

        // Debug-only: force a real reconnect SWAP on the next transport wobble
        // (see debug hook docs on `debugShouldFailReconnectSwap`). A loopback
        // agent's ORIGINAL connection self-recovers before any replacement dial
        // completes, so a plain freeze/thaw never exercises the swap path; this
        // abandons the original and dials a replacement immediately.
        if Self.debugShouldForceReconnectSwap(),
           !debugForcingReconnectSwap,
           case .connected = remoteConnectionState,
           connection.linkState != .connected {
            debugForcingReconnectSwap = true
            Ghostty.logger.warning(
                "remote reconnect: debug force-swap hook armed; abandoning original connection machine=\(connection.machine.name, privacy: .public) session=\(self.currentRemoteSessionID() ?? "-", privacy: .public)")
            beginRemoteReconnect()
            return
        }

        switch connection.linkState {
        case .connected, .degraded:
            // A forced swap is in flight (debug hook): ignore the abandoned
            // original's self-recovery so it can't cancel the replacement dial.
            if debugForcingReconnectSwap { break }
            // The link recovered on its own (a heartbeat blip, or a frozen
            // agent thawing after we exhausted retries — possible only while
            // the transport is still alive). Cancel any retry loop. A
            // self-healable `.disconnected` (agent unreachable, window kept)
            // also recovers here: the surfaces still ride THIS connection, so
            // a genuine link-up transition means the window works again.
            switch remoteConnectionState {
            case .reconnecting:
                remoteReconnectGeneration += 1
                remoteConnectionState = .connected
                // A genuine link recovery (no swap involved): clear the
                // poisoned-session circuit breaker so unrelated future wobbles
                // start counting from a clean slate.
                remoteQuickSwapDeaths = 0
                remoteSwapCompletedAt = nil
            case .disconnected where remoteDisconnectMaySelfHeal:
                remoteReconnectGeneration += 1
                remoteConnectionState = .connected
                remoteQuickSwapDeaths = 0
                remoteSwapCompletedAt = nil
            default:
                break
            }
        case .reconnecting, .reattaching:
            beginRemoteReconnect()
        case .dead:
            // Evicted (another client stole the session, §5.3) or the session
            // is gone: terminal. Keep the window, mark it clearly, stop.
            remoteReconnectGeneration += 1
            remoteDisconnectMaySelfHeal = false
            remoteConnectionState = .disconnected
        }
    }

    /// A device was renamed on the relay account (WP-C2). If this window runs
    /// on that device, adopt the new display name: the stored `Machine` (and
    /// the shared connection's snapshot, which new tabs/splits inherit) get the
    /// fresh `name`/`hostname`, and the `remoteMachine` didSet chain refreshes
    /// the titlebar pill, the window-title suffix, and posts the accessibility
    /// value-changed notification for `AXGhosttyMachine` consumers (ztabby).
    @objc private func ghosttyMachineDidRename(_ notification: Notification) {
        guard let renamed = notification.userInfo?[
            MachineRegistry.renamedMachineKey] as? Machine,
              let deviceID = renamed.deviceID else { return }

        // Keep the shared connection's machine snapshot fresh so surfaces
        // opened AFTER the rename (tabs/splits inheriting the connection)
        // start with the new name.
        if let connection = remoteConnection,
           connection.machine.deviceID == deviceID {
            var updated = connection.machine
            if !updated.namePinned { updated.name = renamed.name }
            updated.hostname = renamed.hostname ?? updated.hostname
            connection.updateMachine(updated)
        }

        guard var machine = remoteMachine, machine.deviceID == deviceID else { return }
        // An explicit caller-supplied label (IPC `+new-remote-window
        // --name=mx`) is INTENTIONAL and wins over account renames: the
        // window keeps "mx" while only the agent-reported hostname refreshes
        // (it feeds local-machine pill suppression). Chooser-opened and
        // manifest-restored windows are not pinned and adopt the new name.
        if !machine.namePinned { machine.name = renamed.name }
        machine.hostname = renamed.hostname ?? machine.hostname
        // didSet publishes to the TerminalWindow (pill + AXGhosttyMachine +
        // AX valueChanged post) and re-applies the window title.
        remoteMachine = machine
    }

    /// Kick off the reconnect retry loop: capture the re-ATTACH target (the
    /// window's root pane's agent session UUID — the pane object outlives the
    /// dead transport), then dial + liveness-probe + re-`ATTACH` with backoff
    /// off the main thread. No-op if a loop is already running or the window
    /// is already disconnected/closing.
    private func beginRemoteReconnect() {
        guard case .connected = remoteConnectionState else { return }
        guard let connection = remoteConnection, window != nil else { return }
        // Don't fight app termination: quit closes the transport deliberately;
        // detached sessions are re-attached by WP-D2 restore on next launch.
        if (NSApp.delegate as? AppDelegate)?.isQuitting == true { return }

        // Prefer the live session id straight off the surface; fall back to
        // the WP-D2 restore manifest entry for this window.
        guard let sessionID = currentRemoteSessionID() ?? manifestSessionID() else {
            // Nothing to re-attach to (the session id never resolved).
            remoteDisconnectMaySelfHeal = false
            remoteConnectionState = .disconnected
            return
        }

        // Poisoned-session circuit breaker. If we get here shortly after a
        // reconnect swap completed, that swap's link just died: the dial and
        // the liveness probe keep "succeeding" but every ATTACH onto the
        // session kills the connection (seen live with a stale session from an
        // older client build). Without this, the ladder loops dial, probe,
        // swap, die every ~2.4s forever. Count consecutive quick deaths; at
        // the limit, stop the fast ladder and go terminal (red pill, user
        // action to recover). A swap whose link survived past the window is a
        // genuine recovery and resets the count.
        if let swapAt = remoteSwapCompletedAt {
            remoteSwapCompletedAt = nil // judge each swap at most once
            if Date().timeIntervalSince(swapAt) < Self.remoteSwapPoisonWindow {
                remoteQuickSwapDeaths += 1
            } else {
                remoteQuickSwapDeaths = 0
            }
            if remoteQuickSwapDeaths >= Self.remoteSwapPoisonLimit {
                Ghostty.logger.error(
                    "remote reconnect: session poisoned, \(self.remoteQuickSwapDeaths, privacy: .public) consecutive swaps died within \(Int(Self.remoteSwapPoisonWindow), privacy: .public)s of completing; stopping fast reconnect, disconnected (terminal) machine=\(connection.machine.name, privacy: .public) session=\(sessionID, privacy: .public)")
                remoteQuickSwapDeaths = 0
                remoteReconnectGeneration += 1
                remoteDisconnectMaySelfHeal = false
                remoteConnectionState = .disconnected
                return
            }
        }

        remoteReconnectGeneration += 1
        remoteConnectionState = .reconnecting(attempt: 1)
        scheduleRemoteReconnectAttempt(
            1,
            generation: remoteReconnectGeneration,
            machine: connection.machine,
            sessionID: sessionID)
    }

    /// The system finished a FULL wake (`NSWorkspace.didWakeNotification` —
    /// dark wakes don't post it). A reconnect that ran during sleep or a dark
    /// wake may have burned its retry budget (agent unreachable mid-sleep) or
    /// aborted its swap (surface alloc fails with the display off); with power
    /// back, don't wait out backoff timers or the slow re-dial cadence — reset
    /// and kick a fresh attempt immediately.
    @objc private func workspaceDidWake(_ notification: Notification) {
        kickRemoteReconnect(reason: "full wake")
    }

    /// The network path went unsatisfied → satisfied (`NetworkPathMonitor`):
    /// Wi-Fi re-associated after lid-open, cable plugged back in, VPN up.
    /// Same treatment as a full wake — conditions just changed for the
    /// better, so don't wait out timers.
    @objc private func networkPathDidBecomeSatisfied(_ notification: Notification) {
        kickRemoteReconnect(reason: "network path restored")
    }

    /// Reset the backoff and kick an immediate reconnect attempt, if this
    /// window is in a recoverable degraded tier (retrying, or disconnected
    /// but self-healable). Terminal disconnects (session gone, evicted,
    /// signed out) are NOT kicked — retrying can't fix those; the titlebar
    /// Reconnect button (`manualRemoteReconnect`) is the way back.
    private func kickRemoteReconnect(reason: String) {
        switch remoteConnectionState {
        case .reconnecting:
            break
        case .disconnected where remoteDisconnectMaySelfHeal:
            break
        default:
            return
        }
        guard let connection = remoteConnection, window != nil else { return }
        guard let sessionID = currentRemoteSessionID() ?? manifestSessionID() else { return }
        Ghostty.logger.warning(
            "remote reconnect: \(reason, privacy: .public); resetting backoff, kicking attempt machine=\(connection.machine.name, privacy: .public) session=\(sessionID, privacy: .public)")
        // Bump cancels any pending backoff attempt / background re-dial probe.
        remoteReconnectGeneration += 1
        remoteConnectionState = .reconnecting(attempt: 1)
        scheduleRemoteReconnectAttempt(
            1,
            generation: remoteReconnectGeneration,
            machine: connection.machine,
            sessionID: sessionID)
    }

    /// The user clicked the titlebar "Reconnect" pill on a disconnected
    /// window: reset every breaker and dial immediately. Unlike the automatic
    /// ladder this runs from ANY disconnected tier (terminal included), and —
    /// when the agent answers but the session is gone (idle-TTL reaped, agent
    /// restarted) — falls back to opening a FRESH shell on the same machine
    /// in this window. Replacing the dead grid with a new shell is only okay
    /// because the user explicitly asked; automatic reconnects never do this.
    func manualRemoteReconnect() {
        guard case .disconnected = remoteConnectionState else { return }
        guard let machine = remoteConnection?.machine ?? remoteMachine,
              window != nil else { return }
        if (NSApp.delegate as? AppDelegate)?.isQuitting == true { return }

        let sessionID = currentRemoteSessionID() ?? manifestSessionID()
        Ghostty.logger.warning(
            "remote reconnect: manual reconnect requested machine=\(machine.name, privacy: .public) session=\(sessionID ?? "-", privacy: .public)")
        // A manual retry starts from a clean slate: forget quick-death
        // (poisoned-session) history so the breaker judges fresh evidence.
        remoteQuickSwapDeaths = 0
        remoteSwapCompletedAt = nil
        remoteReconnectGeneration += 1
        remoteConnectionState = .reconnecting(attempt: 1)
        scheduleRemoteReconnectAttempt(
            1,
            generation: remoteReconnectGeneration,
            machine: machine,
            sessionID: sessionID,
            freshSessionOnGone: true,
            immediate: true)
    }

    /// The outcome of one dial+probe cycle (`dialAndProbeRemote`), delivered on
    /// the main thread with the generation already validated.
    private enum RemoteProbeOutcome {
        /// The agent answered and the session is alive (or no probe was
        /// requested): `handle` is a fresh, handshaked connection the
        /// receiver now owns (swap or free it).
        case sessionAlive(ghostty_remote_connection_t)
        /// The agent answered but the session is gone (restart / TTL).
        /// `handle` is the fresh, handshaked connection — the receiver now
        /// owns it (a manual reconnect reuses it for a fresh-shell swap;
        /// automatic paths free it and go terminal).
        case sessionGone(ghostty_remote_connection_t)
        /// The dial failed (unreachable, handshake timeout, 401, ...).
        case unreachable
        /// Relay machine with no bearer token (signed out): terminal until
        /// sign-in restores the window.
        case signedOut
    }

    /// One dial + liveness-probe cycle against `machine` for `sessionID`:
    /// resolve the relay bearer (WP-B2 seam), dial a REPLACEMENT connection
    /// off-main (bounded by the Zig-side handshake deadline), `GET_CWD`-probe
    /// the session (bounded), then deliver the outcome on the main thread.
    /// A nil `sessionID` skips the probe (a bare dial — the manual
    /// fresh-session path has nothing to re-attach to).
    /// A stale `generation` (cancelation: window closed, link recovered, newer
    /// loop) silently frees whatever was dialed and never calls `outcome`.
    private func dialAndProbeRemote(
        generation: Int,
        machine: Machine,
        sessionID: String?,
        outcome: @escaping (BaseTerminalController, RemoteProbeOutcome) -> Void
    ) {
        Task { @MainActor [weak self] in
            // Resolve the relay bearer BEFORE hopping to the dial thread
            // (resolution may await a token refresh; the dial thread stays
            // purely blocking C calls).
            let token: String?
            if machine.isRelay {
                token = await RelayAccount.resolveToken()
            } else {
                token = ""
            }
            guard let self, generation == self.remoteReconnectGeneration else { return }
            guard let token else {
                outcome(self, .signedOut)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                // Dial + probe are blocking; never on the main thread.
                let handle = Self.dialRemoteMachine(machine, relayToken: token)
                var sessionAlive = false
                if let handle {
                    if let sessionID {
                        let cwd = sessionID.withCString { cSid in
                            Ghostty.AllocatedString(
                                ghostty_remote_connection_query_cwd_timeout(
                                    handle, cSid, 5000)).string
                        }
                        sessionAlive = !cwd.isEmpty
                    } else {
                        // No session to probe: the dial itself is the answer.
                        sessionAlive = true
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.remoteReconnectGeneration else {
                        // Canceled while dialing: don't leak the connection.
                        if let handle { ghostty_remote_connection_free(handle) }
                        return
                    }
                    if let handle, sessionAlive {
                        outcome(self, .sessionAlive(handle))
                    } else if let handle {
                        outcome(self, .sessionGone(handle))
                    } else {
                        outcome(self, .unreachable)
                    }
                }
            }
        }
    }

    /// Schedule reconnect attempt `attempt` (1-based) after its backoff delay.
    /// Each attempt dials a REPLACEMENT connection off-main, liveness-probes
    /// the session (`GET_CWD`, bounded), and either completes the reconnect,
    /// gives up (session gone / retries exhausted → slow background re-dial),
    /// or schedules the next attempt. A stale `generation` (cancelation:
    /// window closed, link recovered, newer loop) makes any stage no-op and
    /// free what it dialed.
    ///
    /// `sessionID` nil means there is nothing to re-attach to (manual
    /// reconnect on a window whose session id never resolved): the dial is
    /// bare and a success opens a fresh shell. `freshSessionOnGone` is the
    /// manual-reconnect fallback — when the agent answers but the session is
    /// gone, swap onto a FRESH shell instead of going terminal (automatic
    /// paths must never do this; see `manualRemoteReconnect`). `immediate`
    /// skips the first attempt's backoff delay (a click should dial NOW).
    private func scheduleRemoteReconnectAttempt(
        _ attempt: Int,
        generation: Int,
        machine: Machine,
        sessionID: String?,
        freshSessionOnGone: Bool = false,
        immediate: Bool = false
    ) {
        let delay = (immediate && attempt == 1) ? 0 : Self.remoteReconnectDelays[
            min(attempt, Self.remoteReconnectDelays.count) - 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.remoteReconnectGeneration else { return }

            // Display asleep (system sleep / dark wake): don't dial — the
            // swap can't build its surface anyway (see displayIsAsleep).
            // Re-park this same attempt; a real wake kicks a fresh ladder.
            if Self.displayIsAsleep {
                Ghostty.logger.info(
                    "remote reconnect: display asleep; deferring attempt \(attempt, privacy: .public) machine=\(machine.name, privacy: .public)")
                self.scheduleRemoteReconnectAttempt(
                    attempt,
                    generation: generation,
                    machine: machine,
                    sessionID: sessionID,
                    freshSessionOnGone: freshSessionOnGone)
                return
            }

            self.remoteConnectionState = .reconnecting(attempt: attempt)

            self.dialAndProbeRemote(
                generation: generation,
                machine: machine,
                sessionID: sessionID
            ) { controller, outcome in
                // A forced swap (debug hook) has reached its dial outcome; the
                // replacement is now committing or retrying, so drop the
                // original-recovery suppression regardless of branch.
                controller.debugForcingReconnectSwap = false
                switch outcome {
                case .sessionAlive(let handle):
                    if controller.completeRemoteReconnect(
                        handle: handle, machine: machine, sessionID: sessionID) { return }
                    // Swap-create failed (surface init — e.g. dark-wake OOM):
                    // the old grid is kept; treat exactly like `.unreachable`.
                    controller.remoteReconnectAttemptFailed(
                        attempt,
                        generation: generation,
                        machine: machine,
                        sessionID: sessionID,
                        freshSessionOnGone: freshSessionOnGone)
                case .sessionGone(let handle):
                    if freshSessionOnGone {
                        // Manual reconnect and the session is gone (idle-TTL
                        // reaped / agent restarted): the user explicitly asked
                        // for this window back, so reuse the dialed connection
                        // for a FRESH shell on the same machine.
                        Ghostty.logger.warning(
                            "remote reconnect: manual reconnect, session gone machine=\(machine.name, privacy: .public) session=\(sessionID ?? "-", privacy: .public); opening fresh session")
                        if controller.completeRemoteReconnect(
                            handle: handle, machine: machine, sessionID: nil) { return }
                        // Fresh-shell swap-create failed: retry like unreachable.
                        controller.remoteReconnectAttemptFailed(
                            attempt,
                            generation: generation,
                            machine: machine,
                            sessionID: sessionID,
                            freshSessionOnGone: freshSessionOnGone)
                        return
                    }
                    // Automatic reconnect: retrying won't bring the session
                    // back. Keep the window, mark it. Terminal (the titlebar
                    // Reconnect button is the way back).
                    ghostty_remote_connection_free(handle)
                    Ghostty.logger.error(
                        "remote reconnect: session gone machine=\(machine.name, privacy: .public) session=\(sessionID ?? "-", privacy: .public) attempt=\(attempt, privacy: .public); disconnected (terminal)")
                    controller.remoteDisconnectMaySelfHeal = false
                    controller.remoteConnectionState = .disconnected
                case .signedOut:
                    // Signed out: terminal until sign-in restores the window
                    // (reconnect never alerts; the manifest entry is kept).
                    Ghostty.logger.error(
                        "remote reconnect: signed out machine=\(machine.name, privacy: .public) session=\(sessionID ?? "-", privacy: .public) attempt=\(attempt, privacy: .public); disconnected (terminal until sign-in)")
                    controller.remoteDisconnectMaySelfHeal = false
                    controller.remoteConnectionState = .disconnected
                case .unreachable:
                    controller.remoteReconnectAttemptFailed(
                        attempt,
                        generation: generation,
                        machine: machine,
                        sessionID: sessionID,
                        freshSessionOnGone: freshSessionOnGone)
                }
            }
        }
    }

    /// Attempt `attempt` failed without a terminal verdict (agent unreachable,
    /// or the reconnect swap couldn't build its replacement surface): schedule
    /// the next backoff attempt, or — budget exhausted — drop to the truthful
    /// red pill and arm the slow background re-dial. The window's own
    /// connection keeps heartbeating underneath (its transport may self-heal,
    /// e.g. a frozen agent thaws — see remoteLinkStateDidChange).
    private func remoteReconnectAttemptFailed(
        _ attempt: Int,
        generation: Int,
        machine: Machine,
        sessionID: String?,
        freshSessionOnGone: Bool = false
    ) {
        guard attempt < Self.remoteReconnectDelays.count else {
            Ghostty.logger.error(
                "remote reconnect: retries exhausted machine=\(machine.name, privacy: .public) session=\(sessionID ?? "-", privacy: .public) attempt=\(attempt, privacy: .public); disconnected (self-healable\(sessionID != nil ? ", background re-dial armed" : "", privacy: .public))")
            remoteDisconnectMaySelfHeal = true
            remoteConnectionState = .disconnected
            // The slow background probe only ever RE-ATTACHes: a fresh-shell
            // fallback firing minutes after the click would be a surprise, so
            // the manual fresh-session intent dies with the fast ladder (the
            // Reconnect button stays available). No session, no probe.
            if let sessionID {
                scheduleRemoteRedialProbe(
                    generation: generation,
                    machine: machine,
                    sessionID: sessionID)
            }
            return
        }
        scheduleRemoteReconnectAttempt(
            attempt + 1,
            generation: generation,
            machine: machine,
            sessionID: sessionID,
            freshSessionOnGone: freshSessionOnGone)
    }

    /// Cadence for the slow background re-dial that keeps running after the
    /// fast retry budget is exhausted (window kept, red pill): base interval
    /// plus jitter, forever, until the window closes / the link self-heals /
    /// a probe succeeds / the session is confirmed gone.
    private static let remoteRedialInterval: TimeInterval = 45

    /// True while the display is asleep (system sleep or a dark wake).
    /// Reconnect dials are pointless then and actively harmful: the swap's
    /// `ghostty_surface_new` needs Metal/IOSurface allocations that fail with
    /// the display off (observed live: OutOfMemory → an all-night
    /// dial/probe/swap-fail loop, each cycle also tearing down a connection —
    /// thread joins — on the main thread). Attempts are deferred while this
    /// is true; the full-wake kick (`workspaceDidWake`) restarts them
    /// immediately on a real wake.
    private static var displayIsAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Schedule the next background re-dial probe. Unlike the fast attempts,
    /// this NEVER touches the pill on failure — the window stays truthfully
    /// red "disconnected" until a probe actually finds the agent AND the
    /// session, at which point the normal reconnect swap completes and turns
    /// it green. Canceled by any generation bump (window closed, link
    /// self-healed, sign-out, a fresh reconnect loop).
    private func scheduleRemoteRedialProbe(
        generation: Int,
        machine: Machine,
        sessionID: String
    ) {
        let delay = Self.remoteRedialInterval + TimeInterval.random(in: 0...15)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.remoteReconnectGeneration else { return }
            // Only while still in the self-healable disconnected tier.
            guard case .disconnected = self.remoteConnectionState,
                  self.remoteDisconnectMaySelfHeal else { return }

            // Display asleep (system sleep / dark wake): skip this probe —
            // the swap can't build its surface anyway (see displayIsAsleep).
            // Keep the cadence; a real wake kicks an immediate attempt.
            if Self.displayIsAsleep {
                Ghostty.logger.info(
                    "remote reconnect: display asleep; deferring background re-dial machine=\(machine.name, privacy: .public)")
                self.scheduleRemoteRedialProbe(
                    generation: generation,
                    machine: machine,
                    sessionID: sessionID)
                return
            }

            self.dialAndProbeRemote(
                generation: generation,
                machine: machine,
                sessionID: sessionID
            ) { controller, outcome in
                switch outcome {
                case .sessionAlive(let handle):
                    Ghostty.logger.warning(
                        "remote reconnect: background re-dial probe succeeded machine=\(machine.name, privacy: .public) session=\(sessionID, privacy: .public); swapping")
                    if controller.completeRemoteReconnect(
                        handle: handle, machine: machine, sessionID: sessionID) { return }
                    // Swap-create failed (surface init): the old grid and the
                    // red pill are kept; probe again later like `.unreachable`.
                    controller.scheduleRemoteRedialProbe(
                        generation: generation,
                        machine: machine,
                        sessionID: sessionID)
                case .sessionGone(let handle):
                    // Agent came back without the session: now it IS terminal.
                    ghostty_remote_connection_free(handle)
                    Ghostty.logger.error(
                        "remote reconnect: background re-dial found agent but session gone machine=\(machine.name, privacy: .public) session=\(sessionID, privacy: .public); disconnected (terminal)")
                    controller.remoteDisconnectMaySelfHeal = false
                    controller.remoteConnectionState = .disconnected
                case .signedOut:
                    Ghostty.logger.error(
                        "remote reconnect: background re-dial signed out machine=\(machine.name, privacy: .public) session=\(sessionID, privacy: .public); disconnected (terminal until sign-in)")
                    controller.remoteDisconnectMaySelfHeal = false
                    controller.remoteConnectionState = .disconnected
                case .unreachable:
                    // Still unreachable: keep the red pill, probe again later.
                    controller.scheduleRemoteRedialProbe(
                        generation: generation,
                        machine: machine,
                        sessionID: sessionID)
                }
            }
        }
    }

    /// A replacement connection is up and the session is alive: swap the
    /// window onto it by re-`ATTACH`ing in a fresh root surface (the same
    /// mechanism as WP-D2 window restore — the agent restores the terminal
    /// contents via its snapshot/scrollback replay). The old (dead-transport)
    /// surfaces are released with the old tree; the old `RemoteConnection` is
    /// freed once its last surface deallocates.
    ///
    /// Scope (matches WP-D2): the window is re-attached as a single root pane.
    /// Split panes' sessions stay detached-alive on the agent.
    /// A nil `sessionID` OPENs a fresh shell on the machine instead of
    /// re-attaching (manual reconnect after the old session was reaped).
    /// Returns false when the replacement surface could not be created (the
    /// swap is ABORTED and the old tree kept — see below); the caller must
    /// then treat the attempt like `.unreachable` (retry ladder / background
    /// re-dial). The dialed `handle` is consumed either way (owned by the new
    /// `RemoteConnection`, which frees it if the swap aborts).
    private func completeRemoteReconnect(
        handle: ghostty_remote_connection_t,
        machine: Machine,
        sessionID: String?
    ) -> Bool {
        guard let ghosttyApp = ghostty.app else {
            ghostty_remote_connection_free(handle)
            Ghostty.logger.error(
                "remote reconnect: swap aborted, ghostty app gone machine=\(machine.name, privacy: .public) session=\(sessionID ?? "fresh", privacy: .public)")
            return false
        }

        let newConnection = RemoteConnection(handle: handle, machine: machine)

        var cfg = Ghostty.SurfaceConfiguration()
        cfg.remoteMachine = machine
        cfg.remoteConnection = handle
        cfg.connectionKeepAlive = newConnection
        cfg.remoteSessionId = sessionID
        cfg.environmentVariables["GHOZTTY_WINDOW_NAME"] = windowName

        // Debug-build-only deterministic failure hook: skips creating the
        // real view so the guard below takes the failure path (the orchestrator
        // can't force a real surface-alloc OOM). See debugShouldFailReconnectSwap.
        let newView: Ghostty.SurfaceView? = Self.debugShouldFailReconnectSwap()
            ? nil
            : Ghostty.SurfaceView(ghosttyApp, baseConfig: cfg)

        guard let newView, newView.error == nil else {
            // `ghostty_surface_new` FAILED (seen in production: OutOfMemory
            // allocating Metal/IOSurface during a dark wake). Do NOT swap:
            // the old grid — dead transport but intact contents — beats a
            // SurfaceErrorView. Keep `surfaceTree`/`remoteConnection` as they
            // are; the caller retries like an unreachable attempt.
            //
            // Ownership: `newConnection` is the sole strong owner of `handle`
            // (a failed SurfaceView never constructed its `surfaceModel`, so
            // nothing retains the keep-alive); dropping it here frees the
            // dialed handle exactly once via RemoteConnection.deinit.
            Ghostty.logger.error(
                "remote reconnect: swap-create FAILED (surface init) machine=\(machine.name, privacy: .public) session=\(sessionID ?? "fresh", privacy: .public); keeping old grid, will retry")
            return false
        }

        // The replacement becomes this window's shared connection (new
        // splits/tabs ride it); rebinds the link observer via didSet.
        remoteConnection = newConnection
        surfaceTree = SplitTree(view: newView)
        remoteConnectionState = .connected
        // Stamp the swap for the poisoned-session circuit breaker: if this
        // link dies again within the poison window, `beginRemoteReconnect`
        // counts it as a quick-death cycle (see remoteSwapCompletedAt).
        remoteSwapCompletedAt = Date()
        // .warning maps to OSLog .error level, so this persists too — one
        // breadcrumb pairing every failure trail with its recovery.
        Ghostty.logger.warning(
            "remote reconnect: swap complete machine=\(machine.name, privacy: .public) session=\(sessionID ?? "fresh", privacy: .public)")
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: newView)
        }

        // Post-swap liveness verification: `.connected` above is a CLAIM — the
        // new surface still has to re-`ATTACH` on its termio thread. If that
        // attach fails (session raced away, RPC timeout, ...), the surface
        // publishes no session id and the window would sit wedged behind a
        // healthy pill. Verify the attach actually landed; if not, stop lying.
        let verifyGeneration = remoteReconnectGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self,
                  verifyGeneration == self.remoteReconnectGeneration,
                  case .connected = self.remoteConnectionState,
                  self.remoteConnection === newConnection else { return }
            if self.currentRemoteSessionID() == nil {
                // The re-ATTACH never yielded a live pane. Terminal tier:
                // keep the window, mark it truthfully.
                Ghostty.logger.error(
                    "remote reconnect: post-swap verify FAILED, published no session id machine=\(machine.name, privacy: .public) session=\(sessionID ?? "fresh", privacy: .public); disconnected (terminal)")
                self.remoteDisconnectMaySelfHeal = false
                self.remoteConnectionState = .disconnected
            }
        }
        return true
    }

    // MARK: Debug reconnect-swap hooks
    //
    // Two debug-only (never release) hook files let the orchestrator drive the
    // reconnect swap path deterministically on a loopback agent:
    //
    //   /tmp/ghoztty-debug-force-reconnect-swap — when present, the next
    //     transport wobble (.degraded/.reconnecting) ABANDONS the original
    //     connection and dials a REPLACEMENT + re-ATTACH swap immediately, even
    //     though the original would self-recover. This is what a plain agent
    //     freeze/thaw otherwise fails to exercise (the original TCP link
    //     recovers before any replacement dial completes).
    //
    //   /tmp/ghoztty-debug-fail-reconnect-swap — when present, that swap's
    //     surface creation is treated as FAILED (the deterministic stand-in for
    //     the dark-wake `ghostty_surface_new` OOM), so the abort/guard path
    //     runs: the old grid is kept and the pill stays reconnecting/red.
    //
    // Both are gated on the libghostty build mode (the exact condition behind
    // the "debug build" warning banner in `TerminalView`), so they cannot
    // trigger in release (ReleaseFast) builds regardless of the files.
    private static let debugFailReconnectSwapHookPath =
        "/tmp/ghoztty-debug-fail-reconnect-swap"
    private static let debugForceReconnectSwapHookPath =
        "/tmp/ghoztty-debug-force-reconnect-swap"

    /// Whether debug reconnect-swap hooks are honored at all (debug /
    /// release-safe builds ONLY). Mirrors the `TerminalView` debug banner gate.
    private static var debugReconnectHooksEnabled: Bool {
        Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG
            || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE
    }

    /// Whether the reconnect swap should be forced to fail (debug hook).
    private static func debugShouldFailReconnectSwap() -> Bool {
        guard debugReconnectHooksEnabled else { return false }
        return FileManager.default.fileExists(
            atPath: debugFailReconnectSwapHookPath)
    }

    /// Whether a reconnect swap should be forced on the next transport wobble
    /// (debug hook).
    private static func debugShouldForceReconnectSwap() -> Bool {
        guard debugReconnectHooksEnabled else { return false }
        return FileManager.default.fileExists(
            atPath: debugForceReconnectSwapHookPath)
    }

    /// The agent session UUID of this window's first live remote pane, read
    /// directly off the surface (non-blocking; the termio thread publishes it
    /// after OPEN/ATTACH and the pane outlives a dead transport).
    private func currentRemoteSessionID() -> String? {
        for view in surfaceTree {
            guard let surface = view.surface else { continue }
            let sid = Ghostty.AllocatedString(
                ghostty_surface_remote_session_id(surface)).string
            if !sid.isEmpty { return sid }
        }
        return nil
    }

    /// The session UUID recorded in the WP-D2 restore manifest for this window.
    private func manifestSessionID() -> String? {
        guard let remoteManifestEntryID else { return nil }
        return RemoteSessionManifest.shared.sessionID(for: remoteManifestEntryID)
    }

    /// Dial a replacement connection to `machine` (blocking; call off-main).
    /// Relay machines re-dial through the relay with `relayToken`, which the
    /// caller resolved via the WP-B2 seam (`RelayAccount.resolveToken()` —
    /// the same sourcing as the interactive dial + WP-D2 restore paths); TCP
    /// machines re-dial directly and ignore the token.
    private static func dialRemoteMachine(
        _ machine: Machine,
        relayToken: String
    ) -> ghostty_remote_connection_t? {
        if machine.isRelay, let base = machine.relayBase, let device = machine.deviceID {
            return AppDelegate.dialRelay(base: base, device: device, token: relayToken)
        }
        return machine.host.withCString { hostPtr in
            ghostty_remote_connection_new_tcp(hostPtr, machine.port)
        }
    }

    // MARK: First Responder

    @IBAction func close(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.requestClose(surface: surface)
    }

    @IBAction func closeWindow(_ sender: Any) {
        guard let window = window else { return }
        window.performClose(sender)
    }

    @IBAction func changeTabTitle(_ sender: Any) {
        if let targetWindow = window {
            let inlineHostWindow =
                targetWindow.tabbedWindows?
                    .first(where: { $0.tabBarView != nil }) as? TerminalWindow
                ?? (targetWindow as? TerminalWindow)

            if let inlineHostWindow, inlineHostWindow.beginInlineTabTitleEdit(for: targetWindow) {
                return
            }
        }

        promptTabTitle()
    }

    @IBAction func splitRight(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_RIGHT)
    }

    @IBAction func splitLeft(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_LEFT)
    }

    @IBAction func splitDown(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_DOWN)
    }

    @IBAction func splitUp(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_UP)
    }

    @IBAction func splitZoom(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitToggleZoom(surface: surface)
    }

    @IBAction func splitMoveFocusPrevious(_ sender: Any) {
        splitMoveFocus(direction: .previous)
    }

    @IBAction func splitMoveFocusNext(_ sender: Any) {
        splitMoveFocus(direction: .next)
    }

    @IBAction func splitMoveFocusAbove(_ sender: Any) {
        splitMoveFocus(direction: .up)
    }

    @IBAction func splitMoveFocusBelow(_ sender: Any) {
        splitMoveFocus(direction: .down)
    }

    @IBAction func splitMoveFocusLeft(_ sender: Any) {
        splitMoveFocus(direction: .left)
    }

    @IBAction func splitMoveFocusRight(_ sender: Any) {
        splitMoveFocus(direction: .right)
    }

    @IBAction func equalizeSplits(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitEqualize(surface: surface)
    }

    @IBAction func moveSplitDividerUp(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .up, amount: 10)
    }

    @IBAction func moveSplitDividerDown(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .down, amount: 10)
    }

    @IBAction func moveSplitDividerLeft(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .left, amount: 10)
    }

    @IBAction func moveSplitDividerRight(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .right, amount: 10)
    }

    private func splitMoveFocus(direction: Ghostty.SplitFocusDirection) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitMoveFocus(surface: surface, direction: direction)
    }

    @IBAction func increaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .increase(1))
    }

    @IBAction func decreaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .decrease(1))
    }

    @IBAction func resetFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .reset)
    }

    @IBAction func toggleCommandPalette(_ sender: Any?) {
        commandPaletteIsShowing.toggle()
        if commandPaletteIsShowing {
            // Fix the incorrect focus when toggling from InlineTitleEditor
            // When toggling the command palette from the inline title editor,
            // the first responder state of the surface is changed quickly from true to false.

            // `makeFirstResponder:` is called by the title editor when finishing,
            // but it happens **after** the command palette is shown,
            // so the `focused` is set to `true` while the command palette is shown.
            // (Could be an AppKit issue as well, since the resign is not called after but the command palette is receiving `keyDown`).

            // Since `performKeyEquivalent(with:)` is called on all of the subviews
            // until one of the return `true` so the paste action is consumed by the surface
            // instead of the first responder (command palette).
            _ = focusedSurface?.resignFirstResponder()
        }
    }

    @IBAction func find(_ sender: Any) {
        focusedSurface?.find(sender)
    }

    @IBAction func selectionForFind(_ sender: Any) {
        focusedSurface?.selectionForFind(sender)
    }

    @IBAction func scrollToSelection(_ sender: Any) {
        focusedSurface?.scrollToSelection(sender)
    }

    @IBAction func findNext(_ sender: Any) {
        focusedSurface?.findNext(sender)
    }

    @IBAction func findPrevious(_ sender: Any) {
        focusedSurface?.findNext(sender)
    }

    @IBAction func findHide(_ sender: Any) {
        focusedSurface?.findHide(sender)
    }

    @objc func resetTerminal(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.resetTerminal(surface: surface)
    }

    private struct DerivedConfig {
        let macosTitlebarProxyIcon: Ghostty.MacOSTitlebarProxyIcon
        let windowStepResize: Bool
        let focusFollowsMouse: Bool
        let splitPreserveZoom: Ghostty.Config.SplitPreserveZoom

        init() {
            self.macosTitlebarProxyIcon = .visible
            self.windowStepResize = false
            self.focusFollowsMouse = false
            self.splitPreserveZoom = .init()
        }

        init(_ config: Ghostty.Config) {
            self.macosTitlebarProxyIcon = config.macosTitlebarProxyIcon
            self.windowStepResize = config.windowStepResize
            self.focusFollowsMouse = config.focusFollowsMouse
            self.splitPreserveZoom = config.splitPreserveZoom
        }
    }
}

extension BaseTerminalController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(findHide):
            return focusedSurface?.searchState != nil

        default:
            return true
        }
    }

    // MARK: - Background Tint

    /// Shift a tint color away from the base: lighten dark colors, darken light ones.
    static func shiftedTint(_ color: NSColor) -> NSColor {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        if srgb.isLightColor {
            return srgb.darken(by: 0.05)
        } else {
            return srgb.lighten(by: 0.05)
        }
    }

    // MARK: - Surface Color Scheme

    /// Update the surface tree's color scheme only when it actually changes.
    ///
    /// Calling ``ghostty_surface_set_color_scheme`` triggers
    /// ``syncAppearance(_:)`` via notification,
    /// so we avoid redundant calls.
    func updateColorSchemeForSurfaceTree() {
        /// Derive the target scheme from `window-theme` or system appearance.
        /// We set the scheme on surfaces so they pick the correct theme
        /// and let ``syncAppearance(_:)`` update the window accordingly.
        ///
        /// Using App's effectiveAppearance here to prevent incorrect updates.
        let themeAppearance = NSApplication.shared.effectiveAppearance
        let scheme: ghostty_color_scheme_e
        if themeAppearance.isDark {
            scheme = GHOSTTY_COLOR_SCHEME_DARK
        } else {
            scheme = GHOSTTY_COLOR_SCHEME_LIGHT
        }
        guard scheme != appliedColorScheme else {
            return
        }
        for surfaceView in surfaceTree {
            if let surface = surfaceView.surface {
                ghostty_surface_set_color_scheme(surface, scheme)
            }
        }
        appliedColorScheme = scheme
    }
}

// MARK: Combine Methods

extension BaseTerminalController {
    /// Publishes an app-wide notification whenever this terminal window's aggregate
    /// bell state changes.
    private func setupBellNotificationPublisher() {
        bellStateCancellable = surfaceValuesPublisher(valueKeyPath: \.bell, publisherKeyPath: \.$bell)
            .map { $0.values.contains(true) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasBell in
                guard let self else { return }
                bell = hasBell
                NotificationCenter.default.post(
                    name: .terminalWindowBellDidChangeNotification,
                    object: self,
                    userInfo: [Notification.Name.terminalWindowHasBellKey: hasBell]
                )
            }
    }

    /// Aggregates activity state across all surfaces and sets the AX attribute on the window.
    /// Triggers requestUserAttention when the window transitions to needs_input.
    private func setupActivityStatePublisher() {
        activityStateCancellable = surfaceValuesPublisher(
            valueKeyPath: \.activityState,
            publisherKeyPath: \.$activityState
        )
        .map { values -> Ghostty.ActivityState in
            if values.values.contains(.needsInput) { return .needsInput }
            if values.values.contains(.busy) { return .busy }
            return .idle
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] newState in
            guard let self else { return }

            let previousState = (self.window as? TerminalWindow)?.activityState ?? .idle

            if let termWindow = self.window as? TerminalWindow {
                termWindow.activityState = newState
            }

            self.applyTitleToWindow()

            if newState == .needsInput && previousState != .needsInput {
                if !(self.window?.isKeyWindow ?? false) {
                    NSApp.requestUserAttention(.informationalRequest)
                }
            }
        }
    }

    /// Creates a publisher for values on all surfaces in this controller's tree.
    ///
    /// The publisher emits a dictionary of surface IDs to values whenever the tree changes
    /// or any surface publishes a new value for the key path.
    func surfaceValuesPublisher<Value>(
        valueKeyPath: KeyPath<Ghostty.SurfaceView, Value>,
        publisherKeyPath: KeyPath<Ghostty.SurfaceView, Published<Value>.Publisher>
    ) -> AnyPublisher<[Ghostty.SurfaceView.ID: Value], Never> {
        // `surfaceTree` can be replaced entirely when splits are added/removed/closed.
        // For each tree snapshot we build a fresh publisher that watches all surfaces
        // in that snapshot.
        $surfaceTree
            .map { tree in
                tree.valuesPublisher(
                    valueKeyPath: valueKeyPath,
                    publisherKeyPath: publisherKeyPath
                )
            }
            // Keep only the latest tree publisher active. This automatically cancels
            // subscriptions for old/removed surfaces when the tree changes.
            .switchToLatest()
            .eraseToAnyPublisher()
    }
}

// MARK: Notifications

extension Notification.Name {
    /// Terminal window aggregate bell state changed.
    static let terminalWindowBellDidChangeNotification = Notification.Name("com.dzearing.ghoztty.terminalWindowBellDidChange")
    static let terminalWindowHasBellKey = terminalWindowBellDidChangeNotification.rawValue + ".hasBell"
}
