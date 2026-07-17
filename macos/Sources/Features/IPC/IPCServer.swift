import Cocoa
import Darwin
import GhosttyKit
import OSLog
import SwiftUI

class IPCServer {
    private static let logger = Logger(
        subsystem: Bundle.loggerSubsystem,
        category: String(describing: IPCServer.self)
    )

    private let ghostty: Ghostty.App
    private let socketPath: String
    private var listenSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var sentinelSource: DispatchSourceFileSystemObject?
    private var sentinelDirFd: Int32 = -1
    private let queue = DispatchQueue(label: "com.dzearing.ghoztty.ipc", qos: .utility)
    private var targetRegistry: [String: TargetEntry] = [:]

    private enum TargetEntry {
        case window(WeakRef<TerminalController>)
        case pane(controller: WeakRef<TerminalController>, surface: WeakRef<Ghostty.SurfaceView>)
        case viewerPane(controller: WeakRef<TerminalController>, pane: WeakRef<PaneView>)

        var controller: TerminalController? {
            switch self {
            case .window(let ref): return ref.value
            case .pane(let ref, _): return ref.value
            case .viewerPane(let ref, _): return ref.value
            }
        }

        var surfaceView: Ghostty.SurfaceView? {
            switch self {
            case .window(let ref): return ref.value?.focusedSurface
            case .pane(_, let ref): return ref.value
            case .viewerPane: return nil
            }
        }

        /// The viewer pane wrapper, when this target is a viewer pane.
        var viewerPaneView: PaneView? {
            switch self {
            case .viewerPane(_, let ref): return ref.value
            default: return nil
            }
        }

        var isAlive: Bool {
            switch self {
            case .window(let ref): return ref.value != nil
            case .pane(_, let ref): return ref.value != nil
            case .viewerPane(_, let ref): return ref.value != nil
            }
        }
    }

    private class WeakRef<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        let uid = getuid()
        let suffix = Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG
            || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE
            ? "-debug" : ""
        self.socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostty\(suffix)-\(uid).sock").path
    }

    private var sentinelPath: String {
        socketPath + ".reset"
    }

    func start() {
        queue.async { [weak self] in
            self?.bindAndListen()
            self?.startSentinelMonitor()
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            sentinelSource?.cancel()
            sentinelSource = nil
            sentinelDirFd = -1
            if listenSocket >= 0 {
                Darwin.close(listenSocket)
                listenSocket = -1
            }
        }
        unlink(socketPath)
        Self.logger.info("IPC server stopped")
    }

    private func bindAndListen() {
        // Remove stale socket
        unlink(socketPath)

        listenSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenSocket >= 0 else {
            let err = errno
            Self.logger.error("Failed to create IPC socket: \(String(cString: strerror(err))) (\(err))")
            return
        }

        fcntl(listenSocket, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Self.logger.error("IPC socket path too long: \(self.socketPath)")
            Darwin.close(listenSocket)
            listenSocket = -1
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(listenSocket, sockaddrPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Self.logger.error("Failed to bind IPC socket: \(String(cString: strerror(err))) (\(err))")
            Darwin.close(listenSocket)
            listenSocket = -1
            return
        }

        chmod(socketPath, 0o600)

        guard listen(listenSocket, 5) == 0 else {
            let err = errno
            Self.logger.error("Failed to listen on IPC socket: \(String(cString: strerror(err))) (\(err))")
            Darwin.close(listenSocket)
            listenSocket = -1
            return
        }

        Self.logger.info("IPC server listening on \(self.socketPath)")

        let source = DispatchSource.makeReadSource(fileDescriptor: listenSocket, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource = source
        source.resume()
    }

    private func acceptConnection() {
        let clientFd = Darwin.accept(listenSocket, nil, nil)
        guard clientFd >= 0 else { return }

        queue.async { [weak self] in
            self?.handleClient(fd: clientFd)
            Darwin.close(clientFd)
        }
    }

    // MARK: - Sentinel file monitoring

    private func startSentinelMonitor() {
        let dirPath = (socketPath as NSString).deletingLastPathComponent
        sentinelDirFd = Darwin.open(dirPath, O_EVTONLY)
        guard sentinelDirFd >= 0 else {
            Self.logger.warning("IPC: failed to open directory for sentinel monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: sentinelDirFd,
            eventMask: .write,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.checkSentinel()
        }
        source.setCancelHandler { [dirFd = sentinelDirFd] in
            if dirFd >= 0 {
                Darwin.close(dirFd)
            }
        }
        sentinelSource = source
        source.resume()
    }

    private var isResetting = false

    private func checkSentinel() {
        guard FileManager.default.fileExists(atPath: sentinelPath) else { return }
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }

        Self.logger.info("IPC: sentinel file detected, resetting socket")

        // Tear down old listener
        acceptSource?.cancel()
        acceptSource = nil
        let oldFd = listenSocket
        listenSocket = -1
        if oldFd >= 0 {
            Darwin.close(oldFd)
        }

        // Rebind the socket
        bindAndListen()

        // Only remove sentinel if rebind succeeded
        if listenSocket >= 0 {
            unlink(sentinelPath)
            Self.logger.info("IPC: socket reset complete, sentinel removed")
        } else {
            Self.logger.error("IPC: socket rebind failed, sentinel retained")
        }
    }

    private func handleClient(fd: Int32) {
        var lengthBytes: [UInt8] = [0, 0, 0, 0]
        let bytesRead = recv(fd, &lengthBytes, 4, MSG_WAITALL)
        guard bytesRead == 4 else {
            Self.logger.warning("IPC: failed to read message length")
            sendResponse(fd: fd, response: IPCResponse(success: false, error: "invalid message"))
            return
        }

        let length = UInt32(lengthBytes[0]) << 24
            | UInt32(lengthBytes[1]) << 16
            | UInt32(lengthBytes[2]) << 8
            | UInt32(lengthBytes[3])

        guard length > 0, length < 1_048_576 else {
            Self.logger.warning("IPC: invalid message length \(length)")
            sendResponse(fd: fd, response: IPCResponse(success: false, error: "invalid length"))
            return
        }

        var payload = Data(count: Int(length))
        let payloadRead = payload.withUnsafeMutableBytes { buf in
            recv(fd, buf.baseAddress!, Int(length), MSG_WAITALL)
        }
        guard payloadRead == Int(length) else {
            Self.logger.warning("IPC: incomplete message payload")
            sendResponse(fd: fd, response: IPCResponse(success: false, error: "incomplete message"))
            return
        }

        let request: IPCRequest
        do {
            request = try JSONDecoder().decode(IPCRequest.self, from: payload)
        } catch {
            Self.logger.warning("IPC: malformed JSON: \(error)")
            sendResponse(fd: fd, response: IPCResponse(success: false, error: "malformed JSON"))
            return
        }

        Self.logger.info("IPC: received action '\(request.action)'")
        let response = dispatchAction(request)
        sendResponse(fd: fd, response: response)
    }

    private func sendResponse(fd: Int32, response: IPCResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        var length = UInt32(data.count).bigEndian
        let lengthSent = withUnsafeBytes(of: &length) { buf in
            send(fd, buf.baseAddress!, 4, 0)
        }
        if lengthSent != 4 {
            Self.logger.warning("IPC: failed to send response length")
            return
        }
        let dataSent = data.withUnsafeBytes { buf in
            send(fd, buf.baseAddress!, data.count, 0)
        }
        if dataSent != data.count {
            Self.logger.warning("IPC: failed to send response payload")
        }
    }

    func dispatchPendingJson(_ json: String) {
        guard let data = json.data(using: .utf8) else {
            Self.logger.warning("IPC: pending JSON is not valid UTF-8")
            return
        }

        let request: IPCRequest
        do {
            request = try JSONDecoder().decode(IPCRequest.self, from: data)
        } catch {
            Self.logger.warning("IPC: pending JSON is malformed: \(error)")
            return
        }

        Self.logger.info("IPC: processing pending action '\(request.action)'")
        _ = dispatchAction(request)
    }

    private func dispatchAction(_ request: IPCRequest) -> IPCResponse {
        switch request.action {
        case "new-window":
            return handleNewWindow(request)
        case "split":
            return handleSplit(request)
        case "close":
            return handleClose(request)
        case "rename":
            return handleRename(request)
        case "rearrange":
            return handleRearrange(request)
        case "list":
            return handleList()
        case "read":
            return handleRead(request)
        case "send-keys":
            return handleSendKeys(request)
        case "set-state":
            return handleSetState(request)
        case "set-banner":
            return handleSetBanner(request)
        case "new-remote-window":
            return handleNewRemoteWindow(request)
        default:
            return IPCResponse(success: false, error: "unknown action: \(request.action)")
        }
    }

    struct ParsedArguments {
        var config: Ghostty.SurfaceConfiguration
        var splitDirection: String?
        var splitCommand: String?
        var splitColor: String?
        var target: String?
        var name: String?
        var title: String?
        var percent: Int?
        var pane: String?
        var color: String?
        var layout: String?
        var lines: Int?
        var shell: String?
        var state: String?
        var noActivate: Bool = false
        // A path or http(s) URL to open as a viewer pane instead of a terminal
        // (mutually exclusive with command/-e).
        var view: String?
        // When true, `+new-window` mirrors the keyboard/menu "New Window" action:
        // it resolves the focused/preferred window as the parent and inherits its
        // REMOTE host + command + cwd (§WP4). Lets the inheriting path be driven
        // headlessly (the normal IPC path has no parent and never inherits).
        var fromFocused: Bool = false
    }

    private func handleNewWindow(_ request: IPCRequest) -> IPCResponse {
        var parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        // Wrap IPC commands in the user's shell so aliases and PATH are available
        if let command = parsed.config.command {
            parsed.config.command = wrapCommandInShell(command, shell: parsed.shell)
        }
        if let splitCommand = parsed.splitCommand {
            parsed.splitCommand = wrapCommandInShell(splitCommand, shell: parsed.shell)
        }

        // A viewer window has no command; reject the ambiguous combination.
        if parsed.view != nil, parsed.config.command != nil {
            return IPCResponse(success: false, error: "--view cannot be combined with --command/-e")
        }

        // Idempotent: if target exists and window is alive, focus it
        if let target = parsed.target {
            pruneStaleTargets()
            if let entry = resolveTarget(target), let controller = entry.controller {
                if !parsed.noActivate {
                    DispatchQueue.main.async {
                        controller.window?.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                return .ok
            }
        }

        // Inject window/pane name env vars for the main surface
        if let target = parsed.target {
            parsed.config.environmentVariables["GHOZTTY_WINDOW_NAME"] = target
            parsed.config.environmentVariables["GHOZTTY_PANE_NAME"] = target
        }

        // Validate percent if provided
        let ratio: Double
        if let percent = parsed.percent {
            guard (1...99).contains(percent) else {
                return IPCResponse(success: false, error: "percent must be between 1 and 99, got \(percent)")
            }
            ratio = min(0.9, max(0.1, Double(100 - percent) / 100.0))
        } else {
            ratio = 0.5
        }

        // Convert color strings to Color values
        var config = parsed.config
        if let colorStr = parsed.color {
            let nsColor: NSColor? = colorStr == "random"
                ? Self.randomDarkColor()
                : NSColor(hex: colorStr)
            if let nsColor {
                config.backgroundTint = Color(nsColor)
                config.backgroundTintNSColor = nsColor
            }
        }

        // `--from-focused`: mirror the keyboard/menu "New Window" action so the
        // new window inherits the focused window's REMOTE host + command + cwd
        // (§WP4). This is the only IPC path that resolves a parent; it builds the
        // window asynchronously (off-main cwd query) so we can't return its
        // controller for naming/registry — `--from-focused` is for the inheriting
        // case, not for `--target`/`--name` registration.
        if parsed.fromFocused {
            DispatchQueue.main.async { [ghostty = self.ghostty] in
                TerminalController.newWindowInheritingRemote(
                    ghostty,
                    withBaseConfig: config,
                    from: TerminalController.preferredParent?.window)
            }
            return .ok
        }

        // Viewer window: a one-pane tree whose leaf renders the file/URL.
        if let viewLocation = parsed.view {
            DispatchQueue.main.async { [ghostty = self.ghostty, weak self] in
                let pane = PaneView(viewer: ViewerView(location: viewLocation))
                let controller = TerminalController.newWindow(
                    ghostty,
                    tree: SplitTree<PaneView>(root: .leaf(view: pane), zoomed: nil))
                if !parsed.noActivate {
                    NSApp.activate(ignoringOtherApps: true)
                }
                // Window titles track the focused *surface*; a viewer-only
                // window has none, so pin the viewer's title unless the
                // caller chose one.
                controller.titleOverride = parsed.title ?? pane.title
                if let target = parsed.target {
                    // Also adopt the target as the controller's window name so
                    // +list doesn't mint a second "window-N" alias (terminal
                    // windows get this via the GHOZTTY_WINDOW_NAME env var).
                    controller.windowName = target
                    self?.targetRegistry[target] = .window(WeakRef(controller))
                    Self.logger.info("IPC: registered window target '\(target)'")
                }
                if let name = parsed.name {
                    self?.targetRegistry[name] = .viewerPane(
                        controller: WeakRef(controller),
                        pane: WeakRef(pane))
                }
            }
            return .ok
        }

        let windowTint: Color? = config.backgroundTint
        DispatchQueue.main.async { [ghostty = self.ghostty, weak self] in
            let controller = TerminalController.newWindow(ghostty, withBaseConfig: config, activate: !parsed.noActivate)

            if let title = parsed.title, !title.isEmpty {
                // A CLI-set title is a WINDOW title: it pins the titlebar
                // and survives pane focus/title changes.
                controller.setWindowTitle(title)
            }

            // Apply color scheme after the surface has initialized
            if windowTint != nil {
                DispatchQueue.main.async {
                    if let surface = controller.focusedSurface {
                        Self.applyColorScheme(for: windowTint, to: surface)
                    }
                }
            }

            if let target = parsed.target {
                self?.targetRegistry[target] = .window(WeakRef(controller))
                Self.logger.info("IPC: registered window target '\(target)'")
            }

            if let splitDir = parsed.splitDirection,
               let direction = Self.parseSplitDirection(splitDir) {
                DispatchQueue.main.async { [weak self] in
                    guard let surfaceView = controller.focusedSurface else {
                        Self.logger.warning("IPC: no surface view for split")
                        return
                    }

                    var splitConfig = Ghostty.SurfaceConfiguration()
                    if let splitCommand = parsed.splitCommand {
                        splitConfig.command = splitCommand
                    }

                    // Inject window/pane name env vars for the inline split
                    if let target = parsed.target {
                        splitConfig.environmentVariables["GHOZTTY_WINDOW_NAME"] = target
                    }
                    if let name = parsed.name {
                        splitConfig.environmentVariables["GHOZTTY_PANE_NAME"] = name
                    }

                    let splitTint: Color?
                    let splitNSColor: NSColor? = parsed.splitColor.flatMap {
                        $0 == "random" ? Self.randomDarkColor() : NSColor(hex: $0)
                    }
                    if let nsColor = splitNSColor {
                        splitConfig.backgroundTint = Color(nsColor)
                        splitConfig.backgroundTintNSColor = nsColor
                        splitTint = Color(nsColor)
                    } else {
                        splitTint = nil
                    }

                    let newView = controller.newSplit(
                        at: surfaceView,
                        direction: direction,
                        baseConfig: splitConfig,
                        ratio: ratio
                    )

                    if let newView {
                        Self.applyColorScheme(for: splitTint, to: newView)
                    }

                    if let name = parsed.name, let newView {
                        self?.targetRegistry[name] = .pane(
                            controller: WeakRef(controller),
                            surface: WeakRef(newView)
                        )
                        Self.logger.info("IPC: registered pane target '\(name)'")
                    }
                }
            }
        }

        return .ok
    }

    private func handleSplit(_ request: IPCRequest) -> IPCResponse {
        var parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        // A viewer pane has no command; reject the ambiguous combination.
        if parsed.view != nil, parsed.config.command != nil {
            return IPCResponse(success: false, error: "--view cannot be combined with --command/-e")
        }

        // Wrap IPC commands in the user's shell so aliases and PATH are available
        if let command = parsed.config.command {
            parsed.config.command = wrapCommandInShell(command, shell: parsed.shell)
        }
        if let splitCommand = parsed.splitCommand {
            parsed.splitCommand = wrapCommandInShell(splitCommand, shell: parsed.shell)
        }

        // Convert color string to Color
        let tintNSColor: NSColor? = parsed.color.flatMap {
            $0 == "random" ? Self.randomDarkColor() : NSColor(hex: $0)
        }
        let tintColor: Color? = tintNSColor.map { Color($0) }

        // Idempotent: if --name exists and pane is alive, focus it
        if let name = parsed.name {
            pruneStaleTargets()
            if let entry = resolveTarget(name), entry.isAlive {
                DispatchQueue.main.async {
                    if let surface = entry.surfaceView, let controller = entry.controller {
                        controller.focusSurface(surface)
                    } else if let pane = entry.viewerPaneView {
                        pane.window?.makeKeyAndOrderFront(nil)
                    }
                }
                return .ok
            }
        }

        // Validate percent if provided
        let ratio: Double
        if let percent = parsed.percent {
            guard (1...99).contains(percent) else {
                return IPCResponse(success: false, error: "percent must be between 1 and 99, got \(percent)")
            }
            ratio = min(0.9, max(0.1, Double(100 - percent) / 100.0))
        } else {
            ratio = 0.5
        }

        // `--from-focused`: mirror the keyboard/menu split exactly. Resolve the
        // app's focused window + its focused surface and call the REAL
        // `newSplit(at: focusedSurface, ...)` — the same path a Cmd-D split takes.
        // This is the faithful REMOTE-inheriting split: `newSplit` injects the
        // window's shared remote connection + parent command/cwd (BaseTerminal
        // Controller §WP4). Unlike `--target`/`--pane` we pass NO command/cwd of
        // our own, so inheritance is never suppressed. Used to drive rapid remote
        // splits (each opens a fresh session on the same machine/connection).
        if parsed.fromFocused {
            let directionStr = parsed.splitDirection ?? "right"
            guard let direction = Self.parseSplitDirection(directionStr) else {
                return IPCResponse(success: false, error: "invalid direction: \(directionStr)")
            }
            DispatchQueue.main.async {
                guard let controller = TerminalController.preferredParent else {
                    Self.logger.warning("IPC: +split --from-focused: no focused window")
                    return
                }
                guard let surfaceView = controller.focusedSurface else {
                    Self.logger.warning("IPC: +split --from-focused: no focused surface")
                    return
                }
                // Empty config so `newSplit` performs full remote inheritance
                // (connection + parent command + cwd). The tint/name plumbing is
                // intentionally omitted here — this trigger is the inheriting case.
                let splitConfig = Ghostty.SurfaceConfiguration()
                _ = controller.newSplit(
                    at: surfaceView,
                    direction: direction,
                    baseConfig: splitConfig,
                    ratio: ratio
                )
            }
            return .ok
        }

        // Resolve --pane targeting: find the named pane (terminal surface or
        // viewer) and its controller.
        if let paneName = parsed.pane {
            pruneStaleTargets()
            guard let entry = resolveTarget(paneName), entry.isAlive,
                  let controller = entry.controller else {
                return IPCResponse(success: false, error: "pane '\(paneName)' not found")
            }

            let directionStr = parsed.splitDirection ?? "right"
            guard let direction = Self.parseSplitDirection(directionStr) else {
                return IPCResponse(success: false, error: "invalid direction: \(directionStr)")
            }

            DispatchQueue.main.async { [weak self] in
                // Resolve the anchor pane (works for terminal AND viewer targets).
                let anchorPane: PaneView?
                if let surface = entry.surfaceView {
                    anchorPane = controller.surfaceTree.pane(for: surface)
                } else {
                    anchorPane = entry.viewerPaneView
                }
                guard let anchorPane else {
                    Self.logger.warning("IPC: pane '\(paneName)' is no longer in a tree")
                    return
                }

                if let viewLocation = parsed.view {
                    self?.createViewerSplit(
                        controller: controller,
                        atPane: anchorPane,
                        direction: direction,
                        ratio: ratio,
                        location: viewLocation,
                        name: parsed.name)
                    return
                }

                // Terminal split anchored at a viewer pane: no surface to
                // inherit from — build a plain local surface.
                if entry.surfaceView == nil {
                    var splitConfig = Ghostty.SurfaceConfiguration()
                    if let command = parsed.config.command { splitConfig.command = command }
                    if let workingDirectory = parsed.config.workingDirectory {
                        splitConfig.workingDirectory = workingDirectory
                    }
                    splitConfig.backgroundTint = tintColor
                    splitConfig.backgroundTintNSColor = tintNSColor
                    for (key, val) in parsed.config.environmentVariables {
                        splitConfig.environmentVariables[key] = val
                    }
                    if let name = parsed.name {
                        splitConfig.environmentVariables["GHOZTTY_PANE_NAME"] = name
                    }
                    if let newView = controller.newTerminalSplit(
                        atPane: anchorPane,
                        direction: direction,
                        baseConfig: splitConfig,
                        ratio: ratio
                    ) {
                        Self.applyColorScheme(for: tintColor, to: newView)
                        if let name = parsed.name {
                            self?.targetRegistry[name] = .pane(
                                controller: WeakRef(controller),
                                surface: WeakRef(newView))
                        }
                    }
                    return
                }

                guard let surface = entry.surfaceView else { return }

                var splitConfig = Ghostty.SurfaceConfiguration()
                if let splitCommand = parsed.splitCommand {
                    splitConfig.command = splitCommand
                }
                if let command = parsed.config.command {
                    splitConfig.command = command
                }
                if let workingDirectory = parsed.config.workingDirectory {
                    splitConfig.workingDirectory = workingDirectory
                }
                splitConfig.backgroundTint = tintColor
                splitConfig.backgroundTintNSColor = tintNSColor

                for (key, val) in parsed.config.environmentVariables {
                    splitConfig.environmentVariables[key] = val
                }
                if let windowName = self?.windowName(for: controller) {
                    splitConfig.environmentVariables["GHOZTTY_WINDOW_NAME"] = windowName
                }
                if let name = parsed.name {
                    splitConfig.environmentVariables["GHOZTTY_PANE_NAME"] = name
                }

                // Registration happens in `onCreate` (not on the return value)
                // because a remote/agent-backed split is created ASYNCHRONOUSLY
                // (off-main cwd inheritance) and returns nil here.
                _ = controller.newSplit(
                    at: surface,
                    direction: direction,
                    baseConfig: splitConfig,
                    ratio: ratio
                ) { newView in
                    Self.applyColorScheme(for: tintColor, to: newView)
                    if let name = parsed.name {
                        self?.targetRegistry[name] = .pane(
                            controller: WeakRef(controller),
                            surface: WeakRef(newView)
                        )
                        Self.logger.info("IPC: registered pane target '\(name)'")
                    }
                }
            }

            return .ok
        }

        let directionStr = parsed.splitDirection ?? "right"
        guard let direction = Self.parseSplitDirection(directionStr) else {
            return IPCResponse(success: false, error: "invalid direction: \(directionStr)")
        }

        DispatchQueue.main.async { [weak self] in
            let controller: TerminalController?
            if let target = parsed.target {
                self?.pruneStaleTargets()
                controller = self?.resolveTarget(target)?.controller
                if controller == nil {
                    Self.logger.warning("IPC: target '\(target)' not found")
                }
            } else {
                controller = TerminalController.preferredParent
            }

            guard let controller else {
                Self.logger.warning("IPC: no controller found for split")
                return
            }

            guard let surfaceView = controller.focusedSurface else {
                Self.logger.warning("IPC: no focused surface for split")
                return
            }

            if let viewLocation = parsed.view {
                if let anchorPane = controller.surfaceTree.pane(for: surfaceView) {
                    self?.createViewerSplit(
                        controller: controller,
                        atPane: anchorPane,
                        direction: direction,
                        ratio: ratio,
                        location: viewLocation,
                        name: parsed.name)
                }
                return
            }

            var splitConfig = Ghostty.SurfaceConfiguration()
            if let splitCommand = parsed.splitCommand {
                splitConfig.command = splitCommand
            }
            if let command = parsed.config.command {
                splitConfig.command = command
            }
            if let workingDirectory = parsed.config.workingDirectory {
                splitConfig.workingDirectory = workingDirectory
            }
            splitConfig.backgroundTint = tintColor

            for (key, val) in parsed.config.environmentVariables {
                splitConfig.environmentVariables[key] = val
            }
            if let target = parsed.target {
                splitConfig.environmentVariables["GHOZTTY_WINDOW_NAME"] = target
            } else if let windowName = self?.windowName(for: controller) {
                splitConfig.environmentVariables["GHOZTTY_WINDOW_NAME"] = windowName
            }
            if let name = parsed.name {
                splitConfig.environmentVariables["GHOZTTY_PANE_NAME"] = name
            }

            // Registration happens in `onCreate` (not on the return value)
            // because a remote/agent-backed split is created ASYNCHRONOUSLY
            // (off-main cwd inheritance) and returns nil here.
            _ = controller.newSplit(
                at: surfaceView,
                direction: direction,
                baseConfig: splitConfig,
                ratio: ratio
            ) { newView in
                Self.applyColorScheme(for: tintColor, to: newView)
                if let name = parsed.name {
                    self?.targetRegistry[name] = .pane(
                        controller: WeakRef(controller),
                        surface: WeakRef(newView)
                    )
                    Self.logger.info("IPC: registered pane target '\(name)'")
                }
            }
        }

        return .ok
    }

    /// Create a viewer split pane and register its name. Main thread only.
    @MainActor
    private func createViewerSplit(
        controller: TerminalController,
        atPane anchorPane: PaneView,
        direction: SplitTree<PaneView>.NewDirection,
        ratio: Double,
        location: String,
        name: String?
    ) {
        let viewer = ViewerView(location: location)
        guard let pane = controller.newViewerSplit(
            atPane: anchorPane,
            direction: direction,
            viewer: viewer,
            ratio: ratio
        ) else {
            Self.logger.warning("IPC: failed to create viewer split")
            return
        }
        if let name {
            targetRegistry[name] = .viewerPane(
                controller: WeakRef(controller),
                pane: WeakRef(pane))
            Self.logger.info("IPC: registered viewer pane target '\(name)'")
        }
    }

    private func handleClose(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        guard let target = parsed.target else {
            return IPCResponse(success: false, error: "--target is required for +close")
        }

        pruneStaleTargets()

        guard let entry = resolveTarget(target) else {
            // Idempotent: already gone
            return .ok
        }

        DispatchQueue.main.async { [weak self] in
            switch entry {
            case .pane(let controllerRef, let surfaceRef):
                if let controller = controllerRef.value, let surface = surfaceRef.value {
                    controller.closeSurface(surface, withConfirmation: false)
                }
            case .viewerPane(let controllerRef, let paneRef):
                if let controller = controllerRef.value, let pane = paneRef.value,
                   let node = controller.surfaceTree.root?.node(view: pane) {
                    // Viewers never have a running process; close silently.
                    controller.closeSurface(node, withConfirmation: false)
                }
            case .window(let controllerRef):
                controllerRef.value?.closeWindowImmediately()
            }
            self?.targetRegistry.removeValue(forKey: target)
        }

        return .ok
    }

    private func handleRename(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        guard let target = parsed.target else {
            return IPCResponse(success: false, error: "--target is required for +rename")
        }

        guard let newTitle = parsed.title else {
            return IPCResponse(success: false, error: "--title is required for +rename")
        }

        pruneStaleTargets()

        guard let entry = resolveTarget(target) else {
            return IPCResponse(success: false, error: "target '\(target)' not found in registry")
        }

        guard let controller = entry.controller else {
            return IPCResponse(success: false, error: "target '\(target)' is no longer alive")
        }

        DispatchQueue.main.async {
            // A CLI rename is a WINDOW title: it pins the titlebar and
            // survives pane focus/title changes. An empty title clears the
            // pin so the titlebar falls back to the tab/pane title.
            controller.setWindowTitle(newTitle.isEmpty ? nil : newTitle)
        }

        Self.logger.info("IPC: renamed display title for '\(target)' to '\(newTitle)'")

        return .ok
    }

    private func handleSetState(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        guard let target = parsed.target else {
            return IPCResponse(success: false, error: "--target is required for +set-state")
        }

        guard let stateStr = parsed.state else {
            return IPCResponse(success: false, error: "--state is required for +set-state")
        }

        let activityState: Ghostty.ActivityState
        switch stateStr {
        case "idle":
            activityState = .idle
        case "busy":
            activityState = .busy
        case "needs_input":
            activityState = .needsInput
        default:
            return IPCResponse(success: false, error: "invalid state '\(stateStr)': must be idle, busy, or needs_input")
        }

        pruneStaleTargets()

        guard let entry = resolveTarget(target) else {
            return IPCResponse(success: false, error: "target '\(target)' not found in registry")
        }

        guard let controller = entry.controller else {
            return IPCResponse(success: false, error: "target '\(target)' is no longer alive")
        }

        if case .viewerPane = entry {
            return IPCResponse(success: false, error: "target '\(target)' is a viewer pane, not a terminal")
        }

        DispatchQueue.main.async {
            // Set activity state on all surfaces in the window, or just the targeted pane
            switch entry {
            case .pane(_, let surfaceRef):
                if let surface = surfaceRef.value {
                    surface.activityState = activityState
                }
            case .viewerPane:
                break // rejected above
            case .window:
                for pane in controller.surfaceTree {
                    pane.surfaceView?.activityState = activityState
                }
            }
        }

        Self.logger.info("IPC: set activity state for '\(target)' to '\(stateStr)'")

        return .ok
    }

    /// Set or clear the sticky banner of a named pane or window. Banner text
    /// is any non-flag argument (multiple are joined with spaces); `--clear`
    /// or an empty text removes the banner. For a window target the banner
    /// applies to its focused pane (banners are per-pane).
    private func handleSetBanner(_ request: IPCRequest) -> IPCResponse {
        var target: String?
        var clear = false
        var textParts: [String] = []

        for arg in request.arguments ?? [] {
            if let value = arg.dropPrefix("--target=") {
                target = String(value)
            } else if arg == "--clear" {
                clear = true
            } else {
                textParts.append(arg)
            }
        }

        guard let target else {
            return IPCResponse(success: false, error: "--target is required for +set-banner")
        }

        // A literal `\n` in the text becomes a line break so multi-line
        // banners can be set from a single shell argument. Trim so a stray
        // trailing newline doesn't render as a blank line.
        let text = textParts.joined(separator: " ")
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { clear = true }

        pruneStaleTargets()

        guard let entry = resolveTarget(target) else {
            return IPCResponse(success: false, error: "target '\(target)' not found in registry")
        }

        if case .viewerPane = entry {
            return IPCResponse(success: false, error: "target '\(target)' is a viewer pane, not a terminal")
        }

        var setError: String?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            defer { semaphore.signal() }

            guard let surface = entry.surfaceView else {
                setError = "target '\(target)' is no longer alive"
                return
            }
            surface.paneBanner = clear ? nil : text
        }
        semaphore.wait()

        if let setError {
            return IPCResponse(success: false, error: setError)
        }

        Self.logger.info("IPC: \(clear ? "cleared" : "set") banner for '\(target)'")

        return .ok
    }

    /// Open a remote-machine window, dialing the agent at `--host=<h> --port=<p>`.
    ///
    /// This drives the EXACT same code path as the Cmd-Shift-N "New Remote
    /// Window" menu action (`AppDelegate.openRemoteWindow`): the dial + window
    /// open run on the MAIN thread, just like the menu. It exists so the remote
    /// window GUI flow can be triggered headlessly from the shell (macOS blocks
    /// synthesized keystrokes), making it scriptable and test-reproducible.
    ///
    /// We dispatch to main and block this IPC worker on a semaphore so the
    /// reply reflects whether the dial+open succeeded. Note: the dial itself is
    /// synchronous (it completes the handshake) and runs on the main thread —
    /// exactly as the menu does — so this faithfully reproduces any main-thread
    /// stall the menu path would hit.
    private func handleNewRemoteWindow(_ request: IPCRequest) -> IPCResponse {
        guard let arguments = request.arguments else {
            return IPCResponse(success: false, error: "--host and --port are required for +new-remote-window")
        }

        var host: String?
        var port: UInt16?
        var relay: String?
        var device: String?
        var token: String?
        var name: String?
        var workingDirectory: String?
        var shell: String?
        var command: String?
        for arg in arguments {
            if let value = arg.dropPrefix("--host=") {
                host = String(value)
            } else if let value = arg.dropPrefix("--port=") {
                port = UInt16(value)
            } else if let value = arg.dropPrefix("--relay=") {
                relay = String(value)
            } else if let value = arg.dropPrefix("--device=") {
                device = String(value)
            } else if let value = arg.dropPrefix("--token=") {
                token = String(value)
            } else if let value = arg.dropPrefix("--name=") {
                name = String(value)
            } else if let value = arg.dropPrefix("--working-directory=") {
                // REMOTE-native cwd/shell/command: forwarded into the agent
                // OPEN. Explicit flags override the machine's per-host
                // defaults (Machine.applyOpenDefaults). Empty values are
                // treated as absent so `--shell=` can't forward "".
                workingDirectory = value.isEmpty ? nil : String(value)
            } else if let value = arg.dropPrefix("--shell=") {
                shell = value.isEmpty ? nil : String(value)
            } else if let value = arg.dropPrefix("--command=") {
                command = value.isEmpty ? nil : String(value)
            }
        }

        // Relay path: --relay + --device dial through a rendezvous relay. Takes
        // precedence over the direct host:port path when both are present.
        let useRelay = (relay?.isEmpty == false) && (device?.isEmpty == false)
        if !useRelay {
            guard host?.isEmpty == false else {
                return IPCResponse(success: false, error: "--host is required (or use --relay + --device) for +new-remote-window")
            }
            guard let port, port != 0 else {
                return IPCResponse(success: false, error: "--port is required (or use --relay + --device) for +new-remote-window")
            }
            _ = port
        }

        var errorMessage: String?
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            defer { semaphore.signal() }
            guard let appDelegate = NSApp.delegate as? AppDelegate else {
                errorMessage = "app delegate unavailable"
                return
            }
            if useRelay {
                // An explicit --token wins; otherwise resolve through the
                // WP-B2 seam (signed-in Google account's ID token, dev env
                // token fallback) — same sourcing as the Cmd-Shift-N dial.
                var resolvedToken = token ?? ""
                if resolvedToken.isEmpty {
                    resolvedToken = await RelayAccount.resolveToken() ?? ""
                }
                // Signed out (and no dev token, no explicit --token): refuse
                // BEFORE dialing — a tokenless relay dial is a guaranteed
                // 401. The CLI gets this as the command's error output; no
                // GUI alert from the IPC path.
                guard !resolvedToken.isEmpty else {
                    errorMessage = "not signed in: sign in via New Remote Window (Cmd-Shift-N) or pass --token= to open relay windows"
                    return
                }
                errorMessage = appDelegate.openRemoteWindow(
                    relay: relay!,
                    device: device!,
                    token: resolvedToken,
                    name: name,
                    // An explicit --name is a caller-supplied label: pin it so
                    // account renames don't overwrite it (Machine.namePinned).
                    namePinned: name != nil,
                    // Persist the registry name in the manifest entry so a
                    // restored window is re-registered under it (the restore
                    // path calls registerRestoredRemoteWindow).
                    ipcName: name,
                    workingDirectory: workingDirectory,
                    shell: shell,
                    command: command,
                    onOpen: { [weak self] controller in
                        // Register the window under its friendly name so
                        // +send-keys / +read / +close can target it (mirrors the
                        // +new-window --target path). The pill shows the
                        // machine's display name (the caller-supplied --name
                        // here, falling back to the agent-reported hostname);
                        // the registry key stays the --name for scriptability.
                        if let target = name {
                            self?.targetRegistry[target] = .window(WeakRef(controller))
                            Self.logger.info("IPC: registered remote window target '\(target)'")
                        }
                    })
            } else {
                errorMessage = appDelegate.openRemoteWindow(
                    host: host!,
                    port: port!,
                    name: name,
                    workingDirectory: workingDirectory,
                    shell: shell,
                    command: command,
                    onOpen: { [weak self] controller in
                        // Same registration as the relay path above: expose
                        // the window under its friendly name so +send-keys /
                        // +read / +close can target TCP remote windows too.
                        if let target = name {
                            self?.targetRegistry[target] = .window(WeakRef(controller))
                            Self.logger.info("IPC: registered remote window target '\(target)'")
                        }
                    })
            }
        }
        semaphore.wait()

        if let errorMessage {
            return IPCResponse(success: false, error: errorMessage)
        }
        return .ok
    }

    private func handleRead(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        guard let name = parsed.name else {
            return IPCResponse(success: false, error: "--name is required for +read")
        }

        let lineCount = parsed.lines ?? 50

        pruneStaleTargets()

        guard let entry = resolveTarget(name) else {
            return IPCResponse(success: false, error: "pane '\(name)' not found in registry")
        }

        if case .viewerPane = entry {
            return IPCResponse(success: false, error: "pane '\(name)' is a viewer pane, not a terminal")
        }

        guard let surfaceView = entry.surfaceView else {
            return IPCResponse(success: false, error: "pane '\(name)' is no longer alive")
        }

        var resultText = ""
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            defer { semaphore.signal() }

            guard let surface = surfaceView.surface else { return }

            var text = ghostty_text_s()
            let sel = ghostty_selection_s(
                top_left: ghostty_point_s(
                    tag: GHOSTTY_POINT_SCREEN,
                    coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                    x: 0,
                    y: 0),
                bottom_right: ghostty_point_s(
                    tag: GHOSTTY_POINT_SCREEN,
                    coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                    x: 0,
                    y: 0),
                rectangle: false)

            guard ghostty_surface_read_text(surface, sel, &text) else { return }
            defer { ghostty_surface_free_text(surface, &text) }

            let fullText = String(cString: text.text)
            let allLines = fullText.components(separatedBy: "\n")

            // Take the last N lines, dropping any trailing empty line from the split
            let trimmed = allLines.last == "" ? Array(allLines.dropLast()) : allLines
            let lastLines = trimmed.suffix(lineCount)
            resultText = lastLines.joined(separator: "\n")
        }

        semaphore.wait()

        if resultText.isEmpty {
            return IPCResponse(success: false, error: "failed to read terminal content from '\(name)'")
        }

        let data = IPCData.readResult(IPCData.ReadResultData(text: resultText))
        return IPCResponse(success: true, data: data)
    }

    private func handleSendKeys(_ request: IPCRequest) -> IPCResponse {
        guard let arguments = request.arguments, !arguments.isEmpty else {
            return IPCResponse(success: false, error: "arguments required for +send-keys")
        }

        var target: String?
        var text: String?

        for arg in arguments {
            if let value = arg.dropPrefix("--target=") {
                target = String(value)
            } else if let value = arg.dropPrefix("--keys=") {
                text = String(value)
            }
        }

        guard let target else {
            return IPCResponse(success: false, error: "--target is required for +send-keys")
        }

        guard let text, !text.isEmpty else {
            return IPCResponse(success: false, error: "text is required for +send-keys")
        }

        pruneStaleTargets()

        guard let entry = resolveTarget(target) else {
            return IPCResponse(success: false, error: "target '\(target)' not found")
        }

        if case .viewerPane = entry {
            return IPCResponse(success: false, error: "target '\(target)' is a viewer pane, not a terminal")
        }

        var sendError: String?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            defer { semaphore.signal() }

            guard let surface = entry.surfaceView else {
                sendError = "target '\(target)' is no longer alive"
                return
            }
            guard let surfaceModel = surface.surfaceModel else {
                sendError = "target '\(target)' has no surface model"
                return
            }
            surfaceModel.writePtyRaw(text)
        }
        semaphore.wait()

        if let sendError {
            return IPCResponse(success: false, error: sendError)
        }
        return .ok
    }

    // MARK: - Rearrange

    private final class LayoutNode: Decodable {
        let pane: String?
        let direction: String?
        let ratio: Double?
        let left: LayoutNode?
        let right: LayoutNode?
    }

    private func handleRearrange(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        guard let layoutJSON = parsed.layout else {
            return IPCResponse(success: false, error: "--layout is required for +rearrange")
        }

        guard let layoutData = layoutJSON.data(using: .utf8) else {
            return IPCResponse(success: false, error: "invalid UTF-8 in layout JSON")
        }

        let layout: LayoutNode
        do {
            layout = try JSONDecoder().decode(LayoutNode.self, from: layoutData)
        } catch {
            return IPCResponse(success: false, error: "invalid layout JSON: \(error.localizedDescription)")
        }

        // Collect all pane names referenced in the layout
        var layoutPaneNames: [String] = []
        if let err = collectPaneNames(layout, into: &layoutPaneNames) {
            return err
        }

        // Check for duplicates
        let nameSet = Set(layoutPaneNames)
        if nameSet.count != layoutPaneNames.count {
            let dupes = layoutPaneNames.filter { name in
                layoutPaneNames.filter { $0 == name }.count > 1
            }
            return IPCResponse(success: false, error: "duplicate pane name in layout: '\(Set(dupes).first ?? "")'")
        }

        // Must have at least one pane
        if layoutPaneNames.isEmpty {
            return IPCResponse(success: false, error: "layout must contain at least one pane")
        }

        var result: IPCResponse = .ok
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async { [weak self] in
            defer { semaphore.signal() }

            MainActor.assumeIsolated {
                guard let self else {
                    result = IPCResponse(success: false, error: "IPC server no longer available")
                    return
                }

                self.pruneStaleTargets()

                // Resolve target controller
                let controller: TerminalController?
                if let target = parsed.target {
                    controller = self.resolveTarget(target)?.controller
                    if controller == nil {
                        result = IPCResponse(success: false, error: "target window '\(target)' not found")
                        return
                    }
                } else {
                    controller = TerminalController.preferredParent
                    if controller == nil {
                        result = IPCResponse(success: false, error: "no focused window found")
                        return
                    }
                }

                guard let controller else { return }

                // Resolve all pane names to panes in this controller's tree.
                // We reuse the EXISTING PaneView wrappers so leaf identity (and
                // therefore SwiftUI structural identity) is preserved across the
                // rearrange.
                var panesByName: [String: PaneView] = [:]
                for name in layoutPaneNames {
                    guard let entry = self.resolveTarget(name) else {
                        result = IPCResponse(success: false, error: "pane '\(name)' not found in registry")
                        return
                    }
                    guard let surface = entry.surfaceView else {
                        result = IPCResponse(success: false, error: "pane '\(name)' is no longer alive")
                        return
                    }
                    guard let pane = controller.surfaceTree.pane(for: surface) else {
                        result = IPCResponse(success: false, error: "pane '\(name)' is not in the target window")
                        return
                    }
                    panesByName[name] = pane
                }

                // Build the new split tree from the layout
                let newRoot: SplitTree<PaneView>.Node
                do {
                    newRoot = try self.buildSplitNode(from: layout, panes: panesByName)
                } catch {
                    result = IPCResponse(success: false, error: "failed to build layout: \(error)")
                    return
                }

                // Collect all current panes in the tree
                let currentPanes = Set(controller.surfaceTree.map { $0 })
                let keptPanes = Set(panesByName.values)
                let removedPanes = currentPanes.subtracting(keptPanes)

                // Remember the currently focused surface
                let focusedSurface = controller.focusedSurface
                let newFocus: Ghostty.SurfaceView? = if let focusedSurface,
                    keptPanes.contains(where: { $0.surfaceView === focusedSurface }) {
                    focusedSurface
                } else {
                    newRoot.leftmostLeaf().surfaceView
                }

                // Replace the tree
                let newTree = SplitTree<PaneView>(root: newRoot, zoomed: nil)
                controller.replaceSurfaceTree(
                    newTree,
                    moveFocusTo: newFocus,
                    moveFocusFrom: focusedSurface,
                    undoAction: "Rearrange Layout"
                )

                // Remove registry entries for panes no longer in the tree
                for pane in removedPanes {
                    for (name, entry) in self.targetRegistry {
                        if case .pane(_, let surfaceRef) = entry, surfaceRef.value === pane.surfaceView {
                            self.targetRegistry.removeValue(forKey: name)
                            break
                        }
                    }
                }

                Self.logger.info("IPC: rearranged layout with \(layoutPaneNames.count) panes")
            }
        }

        semaphore.wait()
        return result
    }

    private func collectPaneNames(_ node: LayoutNode, into names: inout [String]) -> IPCResponse? {
        if let pane = node.pane {
            names.append(pane)
            return nil
        }

        guard node.direction != nil else {
            return IPCResponse(success: false, error: "layout node must have either 'pane' or 'direction'")
        }
        guard let left = node.left else {
            return IPCResponse(success: false, error: "split node must have 'left' child")
        }
        guard let right = node.right else {
            return IPCResponse(success: false, error: "split node must have 'right' child")
        }

        if let err = collectPaneNames(left, into: &names) { return err }
        if let err = collectPaneNames(right, into: &names) { return err }
        return nil
    }

    @MainActor
    private func buildSplitNode(
        from layout: LayoutNode,
        panes: [String: PaneView]
    ) throws -> SplitTree<PaneView>.Node {
        if let paneName = layout.pane {
            guard let pane = panes[paneName] else {
                throw RearrangeError.paneNotFound(paneName)
            }
            return .leaf(view: pane)
        }

        guard let dirStr = layout.direction else {
            throw RearrangeError.invalidNode
        }

        let direction: SplitTree<PaneView>.Direction = switch dirStr.lowercased() {
        case "horizontal": .horizontal
        case "vertical": .vertical
        default: throw RearrangeError.invalidDirection(dirStr)
        }

        guard let leftLayout = layout.left, let rightLayout = layout.right else {
            throw RearrangeError.missingSplitChildren
        }

        let ratioPercent = layout.ratio ?? 50
        let clampedRatio = min(0.9, max(0.1, ratioPercent / 100.0))

        let leftNode = try buildSplitNode(from: leftLayout, panes: panes)
        let rightNode = try buildSplitNode(from: rightLayout, panes: panes)

        return .split(.init(
            direction: direction,
            ratio: clampedRatio,
            left: leftNode,
            right: rightNode
        ))
    }

    private enum RearrangeError: Error, CustomStringConvertible {
        case paneNotFound(String)
        case invalidNode
        case invalidDirection(String)
        case missingSplitChildren

        var description: String {
            switch self {
            case .paneNotFound(let name): return "pane '\(name)' not found"
            case .invalidNode: return "node must have 'pane' or 'direction'"
            case .invalidDirection(let dir): return "invalid direction '\(dir)' (expected 'horizontal' or 'vertical')"
            case .missingSplitChildren: return "split node must have 'left' and 'right' children"
            }
        }
    }

    private func handleList() -> IPCResponse {
        var windowsData: [IPCData.WindowData] = []
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async { [weak self] in
            defer { semaphore.signal() }

            MainActor.assumeIsolated {
                guard let self else { return }

                self.pruneStaleTargets()

                let scriptWindows = NSApp.scriptWindows
                let frontWindow = scriptWindows.first

                for scriptWindow in scriptWindows {
                    let isFocused = scriptWindow.stableID == frontWindow?.stableID

                    var tabsData: [IPCData.TabData] = []
                    for tab in scriptWindow.tabs {
                        guard let controller = tab.parentController else { continue }

                        let windowName = controller.windowName
                        self.ensureWindowRegistered(name: windowName, controller: controller)

                        let splitsData = self.buildSplitNodeData(
                            node: controller.surfaceTree.root,
                            focusedSurface: controller.focusedSurface,
                            controller: controller
                        )

                        tabsData.append(IPCData.TabData(
                            id: tab.idValue,
                            title: tab.title,
                            index: tab.index,
                            selected: tab.selected,
                            splits: splitsData
                        ))
                    }

                    let windowName = scriptWindow.preferredController?.windowName
                    windowsData.append(IPCData.WindowData(
                        id: scriptWindow.stableID,
                        title: scriptWindow.title,
                        target: windowName,
                        focused: isFocused,
                        tabs: tabsData
                    ))
                }
            }
        }

        semaphore.wait()

        let data = IPCData.listState(IPCData.ListStateData(windows: windowsData))
        return IPCResponse(success: true, data: data)
    }

    /// Re-register a RESTORED remote window under the IPC target name
    /// persisted in its `RemoteSessionManifest` entry, so `+read` /
    /// `+send-keys` / `+close --target=<name>` keep working across a
    /// quit/relaunch. If the name is already taken by a live target (the
    /// user opened a new window under the same name meanwhile), the existing
    /// registration wins — consistent with the CLI's idempotent named-target
    /// semantics — and the restored window is simply not re-registered.
    @MainActor
    func registerRestoredRemoteWindow(name: String, controller: TerminalController) {
        pruneStaleTargets()
        guard targetRegistry[name] == nil else {
            Self.logger.info("IPC: restored remote window not re-registered — target '\(name)' already in use")
            return
        }
        targetRegistry[name] = .window(WeakRef(controller))
        // Adopt the name as the controller's display name too so +list shows
        // the persisted target instead of a fresh "window-N" alias.
        controller.windowName = name
        Self.logger.info("IPC: re-registered restored remote window target '\(name)'")
    }

    /// Re-register a RESTORED pane under the IPC target name persisted in
    /// its `SessionLayoutManifest` leaf (T06), so `+read` / `+send-keys` /
    /// `+close --target=<name>` keep working across a quit/relaunch. Same
    /// idempotent semantics as `registerRestoredRemoteWindow`: a live target
    /// already holding the name wins and the restored pane is skipped.
    @MainActor
    func registerRestoredPane(name: String, controller: TerminalController, surface: Ghostty.SurfaceView) {
        pruneStaleTargets()
        guard targetRegistry[name] == nil else {
            Self.logger.info("IPC: restored pane not re-registered — target '\(name)' already in use")
            return
        }
        targetRegistry[name] = .pane(controller: WeakRef(controller), surface: WeakRef(surface))
        Self.logger.info("IPC: re-registered restored pane target '\(name)'")
    }

    @MainActor
    private func ensureWindowRegistered(name: String, controller: BaseTerminalController) {
        if targetRegistry[name] == nil, let tc = controller as? TerminalController {
            targetRegistry[name] = .window(WeakRef(tc))
        }
    }

    @MainActor
    private func ensurePaneRegistered(name: String, controller: BaseTerminalController, surface: Ghostty.SurfaceView) {
        if targetRegistry[name] == nil, let tc = controller as? TerminalController {
            targetRegistry[name] = .pane(controller: WeakRef(tc), surface: WeakRef(surface))
        }
    }

    @MainActor
    private func ensureViewerPaneRegistered(name: String, controller: BaseTerminalController, pane: PaneView) {
        if targetRegistry[name] == nil, let tc = controller as? TerminalController {
            targetRegistry[name] = .viewerPane(controller: WeakRef(tc), pane: WeakRef(pane))
        }
    }

    @MainActor
    private func paneNameForViewerPane(_ pane: PaneView) -> String {
        for (name, entry) in targetRegistry {
            if case .viewerPane(_, let paneRef) = entry, paneRef.value === pane {
                return name
            }
        }
        return pane.id.uuidString
    }

    @MainActor
    private func paneNameForSurface(_ view: Ghostty.SurfaceView) -> String {
        for (name, entry) in targetRegistry {
            if case .pane(_, let surfaceRef) = entry, surfaceRef.value === view {
                return name
            }
        }
        return view.id.uuidString
    }

    @MainActor
    private func buildSplitNodeData(
        node: SplitTree<PaneView>.Node?,
        focusedSurface: Ghostty.SurfaceView?,
        controller: BaseTerminalController
    ) -> IPCData.SplitNodeData {
        guard let node else {
            return .leaf(IPCData.TerminalData(
                id: "",
                title: "",
                working_directory: "",
                pid: 0,
                tty: "",
                name: nil,
                focused: false,
                exit_code: nil
            ))
        }

        switch node {
        case .leaf(let pane):
            if let viewer = pane.viewerView {
                let paneName = paneNameForViewerPane(pane)
                ensureViewerPaneRegistered(name: paneName, controller: controller, pane: pane)
                return .leaf(IPCData.TerminalData(
                    id: pane.id.uuidString,
                    title: pane.title,
                    working_directory: "",
                    pid: 0,
                    tty: "",
                    name: paneName,
                    focused: false,
                    exit_code: nil,
                    pane_type: "viewer",
                    url: viewer.location
                ))
            }
            guard let view = pane.surfaceView else {
                return .leaf(IPCData.TerminalData(
                    id: pane.id.uuidString,
                    title: pane.title,
                    working_directory: "",
                    pid: 0,
                    tty: "",
                    name: nil,
                    focused: false,
                    exit_code: nil
                ))
            }
            let paneName = paneNameForSurface(view)
            ensurePaneRegistered(name: paneName, controller: controller, surface: view)

            return .leaf(IPCData.TerminalData(
                id: view.id.uuidString,
                title: view.title,
                working_directory: view.pwd ?? "",
                pid: view.surfaceModel?.foregroundPID ?? 0,
                tty: view.surfaceModel?.ttyName ?? "",
                name: paneName,
                focused: view === focusedSurface,
                exit_code: view.exitCode.map { Int($0) }
            ))
        case .split(let split):
            let direction: String = switch split.direction {
            case .horizontal: "horizontal"
            case .vertical: "vertical"
            }
            return .split(
                direction: direction,
                ratio: split.ratio,
                left: buildSplitNodeData(
                    node: split.left,
                    focusedSurface: focusedSurface,
                    controller: controller
                ),
                right: buildSplitNodeData(
                    node: split.right,
                    focusedSurface: focusedSurface,
                    controller: controller
                )
            )
        }
    }

    private func pruneStaleTargets() {
        targetRegistry = targetRegistry.filter { $0.value.isAlive }
    }

    /// Resolve a `--target`/`--name` argument: the name registry first, then —
    /// when the string parses as a UUID — a scan of every live pane for a
    /// matching STABLE surface uuid (wp3 pane identity: the `+list` leaf `id`
    /// and the pane's own `$GHOZTTY_PANE_ID`). UUID parsing normalizes case, so
    /// the env value matches regardless of casing. A uuid hit is registered on
    /// the way out so later lookups are O(1). This makes the pane id targetable
    /// even before any `+list` auto-registration has run, and independent of
    /// (renameable) registry names.
    ///
    /// Callable from the IPC queue OR the main thread (handlers are split
    /// across both): the window scan touches AppKit state, so it hops to main
    /// synchronously when needed — the same bounded main-thread round-trip
    /// `handleList` already performs per request.
    private func resolveTarget(_ target: String) -> TargetEntry? {
        if let entry = targetRegistry[target], entry.isAlive { return entry }
        guard let uuid = UUID(uuidString: target) else { return nil }
        let scan = { () -> TargetEntry? in
            MainActor.assumeIsolated {
                for scriptWindow in NSApp.scriptWindows {
                    for tab in scriptWindow.tabs {
                        guard let controller = tab.parentController as? TerminalController else { continue }
                        for view in controller.surfaceTree.root?.leaves() ?? [] where view.id == uuid {
                            let entry = TargetEntry.pane(
                                controller: WeakRef(controller),
                                surface: WeakRef(view))
                            self.targetRegistry[view.id.uuidString] = entry
                            return entry
                        }
                    }
                }
                return nil
            }
        }
        if Thread.isMainThread { return scan() }
        return DispatchQueue.main.sync(execute: scan)
    }

    private func windowName(for controller: TerminalController) -> String? {
        for (name, entry) in targetRegistry {
            if case .window(let ref) = entry, ref.value === controller {
                return name
            }
        }
        return nil
    }

    /// The registered window-target name for a controller, if any (session
    /// layout manifest: a restored window must stay addressable under the
    /// name `+new-window --target=` registered). Main-thread, like every
    /// registry write.
    @MainActor
    func registeredWindowName(forController controller: TerminalController) -> String? {
        windowName(for: controller)
    }

    /// The registered pane-target name for a surface, if any — nil when the
    /// pane was never named (unlike `paneNameForSurface`, which falls back
    /// to the surface UUID for `+list` display).
    @MainActor
    func registeredPaneName(forSurface view: Ghostty.SurfaceView) -> String? {
        for (name, entry) in targetRegistry {
            if case .pane(_, let surfaceRef) = entry, surfaceRef.value === view {
                return name
            }
        }
        return nil
    }

    @MainActor
    func registeredPaneName(forViewerPane pane: PaneView) -> String? {
        for (name, entry) in targetRegistry {
            if case .viewerPane(_, let paneRef) = entry, paneRef.value === pane {
                return name
            }
        }
        return nil
    }

    /// Re-register a RESTORED viewer pane under its persisted IPC name.
    /// Same idempotent semantics as `registerRestoredPane`.
    @MainActor
    func registerRestoredViewerPane(name: String, controller: TerminalController, pane: PaneView) {
        pruneStaleTargets()
        guard targetRegistry[name] == nil else {
            Self.logger.info("IPC: restored viewer pane not re-registered — target '\(name)' already in use")
            return
        }
        targetRegistry[name] = .viewerPane(controller: WeakRef(controller), pane: WeakRef(pane))
        Self.logger.info("IPC: re-registered restored viewer pane target '\(name)'")
    }

    private static func randomDarkColor() -> NSColor {
        let hue = CGFloat.random(in: 0...1)
        let saturation = CGFloat.random(in: 0.2...0.3)
        let brightness = CGFloat.random(in: 0.1...0.15)
        return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private static func applyColorScheme(for tintColor: Color?, to surfaceView: Ghostty.SurfaceView) {
        guard let tintColor, let surface = surfaceView.surface else { return }
        let resolved = NSColor(tintColor).resolvedSRGB

        // Set terminal background color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        ghostty_surface_set_color(surface, 2, 0,
            UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))

        // Set foreground for contrast
        let fg: (UInt8, UInt8, UInt8) = resolved.isLightColor
            ? (0, 0, 0) : (255, 255, 255)
        ghostty_surface_set_color(surface, 1, 0, fg.0, fg.1, fg.2)

        // Adjust ANSI palette for contrast
        Ghostty.SurfaceView.adjustPaletteForContrast(surface: surface, background: resolved)
    }

    private static func parseSplitDirection(_ value: String) -> SplitTree<PaneView>.NewDirection? {
        switch value.lowercased() {
        case "right": return .right
        case "down": return .down
        case "left": return .left
        case "up": return .up
        default: return nil
        }
    }

    private func parseArguments(_ arguments: [String]) -> ParsedArguments {
        var result = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        var eFlag = false
        var commandParts: [String] = []

        for arg in arguments {
            if eFlag {
                commandParts.append(arg)
                continue
            }

            if arg == "-e" {
                eFlag = true
                continue
            }

            if let value = arg.dropPrefix("--working-directory=") {
                result.config.workingDirectory = String(value)
                continue
            }

            if let value = arg.dropPrefix("--command=") {
                result.config.command = String(value)
                continue
            }

            if let value = arg.dropPrefix("--view=") {
                result.view = String(value)
                continue
            }

            if let value = arg.dropPrefix("--split=") {
                result.splitDirection = String(value)
                continue
            }

            if let value = arg.dropPrefix("--split-command=") {
                result.splitCommand = String(value)
                continue
            }

            if let value = arg.dropPrefix("--target=") {
                result.target = String(value)
                continue
            }

            if let value = arg.dropPrefix("--direction=") {
                result.splitDirection = String(value)
                continue
            }

            if let value = arg.dropPrefix("--name=") {
                result.name = String(value)
                continue
            }

            if let value = arg.dropPrefix("--title=") {
                result.title = String(value)
                continue
            }

            if let value = arg.dropPrefix("--state=") {
                result.state = String(value)
                continue
            }

            if let value = arg.dropPrefix("--percent=") {
                result.percent = Int(value) ?? -1
                continue
            }

            if let value = arg.dropPrefix("--split-percent=") {
                result.percent = Int(value) ?? -1
                continue
            }

            if let value = arg.dropPrefix("--pane=") {
                result.pane = String(value)
                continue
            }

            if let value = arg.dropPrefix("--env=") {
                let envStr = String(value)
                if let eqIdx = envStr.firstIndex(of: "=") {
                    let key = String(envStr[envStr.startIndex..<eqIdx])
                    let val = String(envStr[envStr.index(after: eqIdx)...])
                    result.config.environmentVariables[key] = val
                }
                continue
            }

            if let value = arg.dropPrefix("--color=") {
                result.color = String(value)
                continue
            }

            if let value = arg.dropPrefix("--lines=") {
                result.lines = Int(value)
                continue
            }

            if let value = arg.dropPrefix("--split-color=") {
                result.splitColor = String(value)
                continue
            }

            if let value = arg.dropPrefix("--layout=") {
                result.layout = String(value)
                continue
            }

            if let value = arg.dropPrefix("--shell=") {
                result.shell = String(value)
                continue
            }

            if arg == "--no-activate" {
                result.noActivate = true
                continue
            }

            if arg == "--from-focused" {
                result.fromFocused = true
                continue
            }
        }

        if !commandParts.isEmpty {
            result.config.command = commandParts.joined(separator: " ")
        }

        return result
    }

    private func resolveShell(explicit: String?) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let configShell = ghostty.config.commandShell { return configShell }
        if let envShell = ProcessInfo.processInfo.environment["SHELL"], !envShell.isEmpty { return envShell }
        return "/bin/zsh"
    }

    private func wrapCommandInShell(_ command: String, shell: String?) -> String {
        let shellPath = resolveShell(explicit: shell)
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        return "\(shellPath) -lic '\(escaped); exec \(shellPath) -li'"
    }
}

private extension StringProtocol {
    func dropPrefix(_ prefix: String) -> SubSequence? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count)
    }
}
