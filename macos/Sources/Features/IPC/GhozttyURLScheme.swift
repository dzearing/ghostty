import Foundation
import OSLog

#if canImport(AppKit)
import AppKit
#endif

/// The `ghoztty://` custom URL scheme — a second, *deliberately tiny* front
/// door onto the same target registry the IPC socket drives.
///
/// It exposes **exactly one capability: focus a window or pane that already
/// exists.** No window creation, no command execution, no input injection, no
/// banners, no viewers. That is not a staging plan; it is the design.
///
/// The reason is the threat model, and it is the whole reason the scope is
/// drawn here. A registered URL scheme is reachable by **any web page the user
/// visits** — no prompt, no gesture beyond a click, no same-origin check, no
/// way for the app to know who asked. Everything the IPC socket can do is
/// safe there because a unix socket at mode 0600 is reachable only by code
/// already running as the user. None of that holds for a link. A scheme that
/// could spawn a shell or type into a pane would be remote code execution
/// behind an `<a href>`. Raising an already-existing window is the one verb
/// whose worst case is a nuisance: a hostile page can make a window it cannot
/// see, name, or read jump to the front.
///
/// So: **do not add a verb here without re-deriving that argument for it.**
/// The parser reads a verb out of the URL rather than hardcoding one shape, so
/// a future verb *can* be added — but wanting a second verb to make something
/// work is a signal to stop and ask, not a signal to add one.
///
/// ## Canonical form
///
/// ```
/// ghoztty://focus/<target>
/// ```
///
/// `<target>` is percent-decoded and handed to the IPC resolver verbatim, so
/// it accepts everything `--target` accepts — a registered window name, an
/// auto-assigned `window-N`, a registered pane name, or a pane id (the UUID in
/// `$GHOZTTY_PANE_ID`, case-insensitive). There is one resolver
/// (`IPCServer.resolveTarget`) and therefore one naming system.
///
/// The path form is canonical over `ghoztty://<target>` (no room for a verb)
/// and over `ghoztty://focus?target=<name>` (a second escaping context for no
/// gain). Everything after the verb is ONE target, so an unencoded `/` in a
/// name is part of the name rather than a second argument.
///
/// ## Which build answers
///
/// A debug build registers **`ghoztty-debug://`** and the release build
/// registers `ghoztty://` (`CFBundleURLTypes` ← the `GHOZTTY_URL_SCHEME` build
/// setting), mirroring the split bundle id and IPC socket. Otherwise
/// LaunchServices would pick between them nondeterministically and the user's
/// links would start landing in a debug build.
///
/// Parsing, by contrast, accepts **both** spellings in **either** build. Links
/// clicked *inside* Ghoztty — a viewer pane, a pane banner — are short-
/// circuited in-process and never touch LaunchServices, so a generated
/// document that hardcodes `ghoztty://` still focuses the right pane when a
/// debug build is the one rendering it.
///
/// ## When it doesn't work
///
/// A link that resolves to nothing says so (`Failure`): a closed window and a
/// link this build doesn't understand are both ordinary situations the user
/// can act on, and a click that appears to do nothing is indistinguishable
/// from a broken app. What the scheme still refuses to do on failure is act:
/// nothing is created and no "closest" window is focused as a consolation.
enum GhozttyURLScheme {
    /// The scheme the RELEASE build registers with LaunchServices.
    static let scheme = "ghoztty"

    /// The scheme the DEBUG build registers, so the two never compete.
    static let debugScheme = "ghoztty-debug"

    /// Everything the scheme can ask for. One case, on purpose — see above.
    enum Command: Equatable {
        /// Raise the window owning `target` and focus the pane within it.
        case focus(target: String)
    }

    /// Whether `url` addresses Ghoztty at all — asked *before* validity, so a
    /// malformed `ghoztty://` link is swallowed rather than leaking out to the
    /// browser or into a viewer pane as a bogus location.
    static func handles(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == Self.scheme || scheme == debugScheme
    }

    /// Parse `url` into a command, or nil if it isn't one. Strict by design:
    /// an unknown verb, a missing target, and a bare `ghoztty://<name>` all
    /// yield nil rather than a lenient guess, because the caller is untrusted.
    static func parse(_ url: URL) -> Command? {
        guard handles(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let verb = components.host?.lowercased()
        else { return nil }

        // Everything after the verb is one target: leading separator off, and
        // a trailing one dropped so `focus/dev/` and `focus/dev` agree.
        var target = components.path
        if target.hasPrefix("/") { target.removeFirst() }
        while target.hasSuffix("/") { target.removeLast() }
        guard !target.isEmpty else { return nil }

        switch verb {
        case "focus": return .focus(target: target)
        default: return nil
        }
    }
}

#if canImport(AppKit)
extension GhozttyURLScheme {
    private static let logger = Logger(
        subsystem: Bundle.loggerSubsystem,
        category: "GhozttyURLScheme"
    )

    /// Why a link did nothing. A clicked link that appears to do nothing at
    /// all is indistinguishable from a broken app, so each of these is shown
    /// to the user rather than only logged — the failures are ordinary (the
    /// window was closed; the document is older than this build) and the user
    /// is the one who can act on them.
    ///
    /// Split out from the presenter so the wording is testable; building an
    /// `NSAlert` is not.
    enum Failure: Equatable {
        /// The URL is one of ours but not a command this build understands.
        case unsupportedLink(String)
        /// A well-formed focus, but nothing open answers to that name.
        case targetNotFound(String)

        var messageText: String {
            switch self {
            case .unsupportedLink: return "Unsupported Ghoztty link"
            case .targetNotFound(let target): return "Can’t focus “\(target)”"
            }
        }

        var informativeText: String {
            switch self {
            case .unsupportedLink(let url):
                return "\(url) isn’t a link this version of Ghoztty understands. "
                    + "The only supported form is ghoztty://focus/<window-or-pane>."
            case .targetNotFound:
                return "No open Ghoztty window or pane has that name. It may have been "
                    + "closed, or it may belong to a different Ghoztty instance."
            }
        }
    }

    /// True while a failure alert is on screen, so a burst of links produces
    /// ONE dialog instead of one per link. This matters more here than for a
    /// normal alert: a URL scheme is reachable by any web page, and
    /// `application(_:open:)` can be handed a whole array at once.
    @MainActor
    private static var isPresentingFailure = false

    /// Tell the user why the link did nothing.
    ///
    /// This deliberately stops short of anything a page could weaponize
    /// further: no window is created, no "closest" window is focused as a
    /// consolation, and repeats while a dialog is already up are dropped.
    @MainActor
    static func present(_ failure: Failure) {
        guard !isPresentingFailure else { return }
        isPresentingFailure = true

        let alert = NSAlert()
        alert.messageText = failure.messageText
        alert.informativeText = failure.informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        // A sheet on the window the user is looking at reads as "that link
        // failed" rather than as an app-wide problem. With no window — the
        // link just launched us — there is nothing to attach to.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { _ in isPresentingFailure = false }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            isPresentingFailure = false
        }
    }

    /// Run `url` if it is a valid command. The single execution site: the
    /// LaunchServices callback (`application(_:open:)`), viewer-pane link
    /// clicks, and banner link clicks all land here.
    ///
    /// Returns whether the focus actually landed. A URL that isn't ours at all
    /// is ignored silently (nobody clicked a Ghoztty link); the two ways OUR
    /// link can fail are reported — see `Failure`.
    @MainActor
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard handles(url) else {
            logger.info("URL scheme: not ours, ignoring \(url.absoluteString, privacy: .public)")
            return false
        }
        guard let command = parse(url) else {
            logger.info("URL scheme: unsupported link \(url.absoluteString, privacy: .public)")
            present(.unsupportedLink(url.absoluteString))
            return false
        }

        switch command {
        case .focus(let target):
            guard let server = (NSApp.delegate as? AppDelegate)?.ipcServer else { return false }
            guard server.focusTarget(target) else {
                // Also the cold-launch case: the link LAUNCHED the app, so
                // nothing is registered yet. A focus link must not create a
                // window as a side effect — that would smuggle window creation
                // back into the scheme's surface — so the honest answer is to
                // say the target isn't open.
                logger.info("URL scheme: focus target '\(target, privacy: .public)' not found")
                present(.targetNotFound(target))
                return false
            }
            return true
        }
    }
}
#endif
