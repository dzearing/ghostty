import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// Presentation rules for the release notes and the window that hosts them.
///
/// The notes body is shared by three hosts — the What's New window, the update
/// popover, and the agent-restart alert's accessory view — so its typography and
/// spacing live in a value type (`WhatsNewNotesContent.Density`) that both the
/// view and these tests can read. That is what keeps the window's generous
/// layout from leaking into the two small hosts.
@MainActor
struct WhatsNewPresentationTests {
    // MARK: - Notes density

    @Test func windowDropsTheHeadingThatDuplicatesItsWindowTitle() {
        #expect(WhatsNewNotesContent.Density.spacious.metrics.showsHeading == false)
    }

    @Test func smallHostsKeepTheirHeading() {
        // The popover and the agent-restart alert have no "What's New in
        // Ghoztty" titlebar above them, so the in-content heading is the only
        // label the notes get there.
        #expect(WhatsNewNotesContent.Density.compact.metrics.showsHeading)
    }

    @Test func versionIsTheProminentHeadingOfItsReleaseBlock() {
        let m = WhatsNewNotesContent.Density.spacious.metrics
        #expect(pointSize(m.versionTextStyle) > pointSize(m.itemTextStyle))
        #expect(pointSize(m.versionTextStyle) > pointSize(m.headingTextStyle))
    }

    @Test func consecutiveReleasesReadAsDistinctBlocks() {
        let spacious = WhatsNewNotesContent.Density.spacious.metrics
        #expect(spacious.releaseSpacing > spacious.itemSpacing)
        #expect(spacious.releaseSpacing > spacious.sectionSpacing)
        #expect(spacious.releaseSpacing
                > WhatsNewNotesContent.Density.compact.metrics.releaseSpacing)
    }

    @Test func bulletsAreDrawnLargerThanTheTextTheyMark() {
        for density in [WhatsNewNotesContent.Density.compact, .spacious] {
            let m = density.metrics
            #expect(pointSize(m.bulletTextStyle) > pointSize(m.itemTextStyle))
        }
    }

    @Test func singleSectionReleaseHidesItsRedundantSectionTitle() {
        // Every shipped release carries exactly one section ("Fork Changes" /
        // "Session persistence"), which only restates the tab it is under.
        #expect(WhatsNewNotesContent.showsSectionTitles(notes(sectionTitles: ["Fork Changes"])) == false)
    }

    @Test func multiSectionReleaseKeepsItsSectionTitles() {
        #expect(WhatsNewNotesContent.showsSectionTitles(notes(sectionTitles: ["Fork Changes", "Fixes"])))
    }

    @Test func alreadyInstalledReleasesAreIntroducedByALabelledRule() {
        #expect(WhatsNewNotesContent.installedDividerLabel == "Changes already installed")
    }

    // MARK: - Window chrome

    @Test func windowIsResizable() {
        #expect(makeWindow().styleMask.contains(.resizable))
    }

    @Test func windowOpensMeaningfullyLargerThanThePopoverSizedFrame() {
        // It used to open at a hard-coded 460×380 — a popover blown up to
        // window size. "Meaningfully bigger" = at least twice the area.
        let old = NSSize(width: 460, height: 380)
        let window = makeWindow()
        let size = contentSize(of: window)
        #expect(size.width > old.width)
        #expect(size.height > old.height)
        #expect(size.width * size.height >= old.width * old.height * 2)

        // And it STAYS there. A hosting controller left on its default
        // `.preferredContentSize` sizing pushes the SwiftUI content's own ideal
        // size back onto the window a layout pass later, silently undoing this.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        #expect(contentSize(of: window) == size)
    }

    @Test func windowCanBeResizedSmallerThanItOpens() {
        let window = makeWindow()
        let size = contentSize(of: window)
        #expect(window.contentMinSize.width < size.width)
        #expect(window.contentMinSize.height < size.height)
    }

    @Test func windowOpensCenteredOnItsScreen() throws {
        let screen = try #require(NSScreen.main)
        let frame = makeWindow(screen: screen).frame
        #expect(abs(frame.midX - screen.visibleFrame.midX) < 1)
        #expect(abs(frame.midY - screen.visibleFrame.midY) < 1)
    }

    @Test func openingFrameIsCenteredInTheVisibleArea() {
        let visible = NSRect(x: 100, y: 50, width: 1000, height: 800)
        let frame = WhatsNewWindowView.openingFrame(
            size: NSSize(width: 400, height: 300), in: visible)
        #expect(frame == NSRect(x: 400, y: 300, width: 400, height: 300))
    }

    @Test func openingFrameNeverOverflowsAShortScreen() {
        // A window taller than the display would otherwise open with its
        // bottom (and its scroll view) hanging off the screen.
        let visible = NSRect(x: 0, y: 0, width: 640, height: 480)
        let frame = WhatsNewWindowView.openingFrame(
            size: NSSize(width: 900, height: 900), in: visible)
        #expect(frame == visible)
    }

    // MARK: - Helpers

    private func notes(sectionTitles: [String]) -> VersionNotes {
        VersionNotes(version: "1.28.0", sections: sectionTitles.map {
            ReleaseNoteSection(title: $0, items: [ReleaseNote(title: "Thing", text: "does X")])
        })
    }

    private func makeWindow(screen: NSScreen? = NSScreen.main) -> NSWindow {
        WhatsNewWindowView.makeWindow(
            WhatsNewWindowView(
                clientNew: [notes(sectionTitles: ["Fork Changes"])],
                clientInstalled: [],
                agentNew: [],
                agentInstalled: []),
            screen: screen)
    }

    private func contentSize(of window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    /// The resolved point size SwiftUI draws `style` at, so size relationships
    /// (bullet vs. item, version vs. heading) can be asserted without pinning
    /// down exact fonts.
    private func pointSize(_ style: Font.TextStyle) -> CGFloat {
        let mapped: NSFont.TextStyle = switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
        return NSFont.preferredFont(forTextStyle: mapped).pointSize
    }
}
