import SwiftUI

/// The post-install "What's New" window body. Tabs between client/app notes and
/// agent/session notes — both bundled offline and partitioned by the version
/// the user last ran. Reuses `WhatsNewNotesContent` for each tab.
struct WhatsNewWindowView: View {
    let clientNew: [VersionNotes]
    let clientInstalled: [VersionNotes]
    let agentNew: [VersionNotes]
    let agentInstalled: [VersionNotes]

    var body: some View {
        TabView {
            tab(new: clientNew, installed: clientInstalled)
                .tabItem { Text("Client") }
            tab(new: agentNew, installed: agentInstalled)
                .tabItem { Text("Agent") }
        }
        .padding(12)
        .frame(width: 460, height: 380)
    }

    @ViewBuilder
    private func tab(new: [VersionNotes], installed: [VersionNotes]) -> some View {
        ScrollView {
            WhatsNewNotesContent(newNotes: new, installedNotes: installed)
                .padding(16)
        }
    }
}
