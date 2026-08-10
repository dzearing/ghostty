import Foundation
import Testing
@testable import Ghostty

/// The `ghoztty://` scheme is reachable by any web page the user visits, with
/// no prompt and no same-origin check, so what it *can't* express matters as
/// much as what it can. These pin both halves: the one canonical shape that
/// resolves to `focus`, and the many near-misses that must resolve to nothing
/// rather than to a lenient guess.
struct GhozttyURLSchemeTests {
    private func parse(_ string: String) -> GhozttyURLScheme.Command? {
        guard let url = URL(string: string) else { return nil }
        return GhozttyURLScheme.parse(url)
    }

    // MARK: - The canonical form

    @Test func canonicalFormParsesToFocus() {
        #expect(parse("ghoztty://focus/dev") == .focus(target: "dev"))
    }

    @Test func theDebugSchemeParsesIdentically() {
        // Both builds accept BOTH spellings in-process. Only LaunchServices
        // cares which one a build registered; a document that hardcodes
        // `ghoztty://` must still work when a debug build renders it.
        #expect(parse("ghoztty-debug://focus/dev") == .focus(target: "dev"))
    }

    @Test func aPaneIDIsJustAnotherTarget() {
        // The target grammar is the IPC `--target` grammar — window name, auto
        // name, pane name, or pane id — because `resolveTarget` is the resolver.
        let id = "8B1F1A2C-3D4E-4F50-9A6B-7C8D9E0F1A2B"
        #expect(parse("ghoztty://focus/\(id)") == .focus(target: id))
    }

    @Test func theVerbIsCaseInsensitive() {
        // A URL host is lowercased by some producers en route; the verb must
        // not depend on which one delivered the link.
        #expect(parse("ghoztty://FOCUS/dev") == .focus(target: "dev"))
    }

    @Test func theSchemeIsCaseInsensitive() {
        #expect(parse("GHOZTTY://focus/dev") == .focus(target: "dev"))
    }

    // MARK: - Escaping

    @Test func theTargetIsPercentDecoded() {
        #expect(parse("ghoztty://focus/my%20window") == .focus(target: "my window"))
    }

    @Test func anEncodedSlashSurvivesIntoTheTarget() {
        // The path form takes EVERYTHING after the verb as one target, so a
        // name with a slash in it round-trips instead of being truncated.
        #expect(parse("ghoztty://focus/feat%2Flogin") == .focus(target: "feat/login"))
    }

    @Test func aTargetSpanningPathSegmentsStaysWhole() {
        // Same rule seen from the other side: an unencoded slash is part of
        // the name, not a second argument.
        #expect(parse("ghoztty://focus/a/b") == .focus(target: "a/b"))
    }

    @Test func aTrailingSlashIsNotPartOfTheTarget() {
        #expect(parse("ghoztty://focus/dev/") == .focus(target: "dev"))
    }

    // MARK: - Everything that must parse to nothing

    @Test func anEmptyTargetIsNotACommand() {
        // Focusing "whichever window is closest" is exactly the behavior a
        // hostile page would want; there is no such fallback.
        #expect(parse("ghoztty://focus") == nil)
        #expect(parse("ghoztty://focus/") == nil)
    }

    @Test func anUnknownVerbIsNotACommand() {
        // The parser reads a verb rather than assuming one so a second verb
        // *could* be added, but only `focus` exists — `send-keys` and friends
        // are deliberately absent, not merely unimplemented.
        #expect(parse("ghoztty://send-keys/dev") == nil)
        #expect(parse("ghoztty://new-window/dev") == nil)
    }

    @Test func aBareTargetWithNoVerbIsNotACommand() {
        // `ghoztty://dev` reads as verb "dev" with no target. It must not
        // silently mean "focus dev" — one shape, so links stay greppable.
        #expect(parse("ghoztty://dev") == nil)
    }

    @Test func aForeignSchemeIsNeverOurs() {
        #expect(parse("https://focus/dev") == nil)
        #expect(parse("ghoztty-viewer://focus/dev") == nil)
        #expect(parse("file:///focus/dev") == nil)
    }

    // MARK: - Failure reporting

    @Test func aMissingTargetNamesItselfInTheAlert() {
        // "Nothing happened" is indistinguishable from a broken app, so the
        // dialog has to say WHICH link failed — a dashboard can hold dozens.
        let failure = GhozttyURLScheme.Failure.targetNotFound("worktree-3")
        #expect(failure.messageText.contains("worktree-3"))
        #expect(failure.informativeText.contains("closed"))
    }

    @Test func anUnsupportedLinkQuotesTheURLAndTheOneSupportedForm() {
        // This one is aimed at whoever GENERATED the document, so it has to
        // carry the offending URL and the shape that would have worked.
        let failure = GhozttyURLScheme.Failure.unsupportedLink("ghoztty://send-keys/dev")
        #expect(failure.informativeText.contains("ghoztty://send-keys/dev"))
        #expect(failure.informativeText.contains("ghoztty://focus/"))
    }

    // MARK: - handles(_:)

    @Test func handlesRecognizesOurSchemesRegardlessOfPayload() {
        // The link routers ask "is this ours?" before "is it valid?", so a
        // malformed ghoztty:// link is still swallowed rather than leaking out
        // to the browser or a viewer pane.
        #expect(GhozttyURLScheme.handles(URL(string: "ghoztty://nope")!))
        #expect(GhozttyURLScheme.handles(URL(string: "ghoztty-debug://nope")!))
        #expect(!GhozttyURLScheme.handles(URL(string: "https://example.com")!))
        #expect(!GhozttyURLScheme.handles(URL(fileURLWithPath: "/tmp/a.md")))
    }
}
