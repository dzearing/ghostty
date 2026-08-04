import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) var openURL

    /// The one place the repo lives. Every link that points into it (the GitHub
    /// button, the commit link, the release-notes link) derives from this, so
    /// they can't drift apart. `static` so the nested `VersionConfig` can reach it.
    private static let githubURL = URL(string: "https://github.com/dzearing/ghoztty")
    private let docsURL = URL(string: "https://dzearing.github.io/ghoztty/")

    /// Read the commit from the bundle.
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? { Bundle.main.infoDictionary?["GhosttyCommit"] as? String }
    private var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    private enum VersionConfig {
        case stable(version: String)
        case tip(commit: String?)
        case other(String)
        case none

        init(version: String?) {
            guard let version else { self = .none; return }
            if version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
                self = .stable(version: version)
                return
            }
            if version.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil {
                self = .tip(commit: version)
                return
            }
            self = .other(version)
        }

        var url: URL? {
            switch self {
            case .stable(let version):
                return AboutView.githubURL?.appendingPathComponent("/releases/tag/v\(version)")
            default:
                return nil
            }
        }
    }

    private var versionConfig: VersionConfig { VersionConfig(version: version) }

    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    // The "About My Mac"-style backdrop comes from the shared
    // `VisualEffectBackground` in Helpers/GlassCard.swift — this view used to
    // carry its own private copy of the same NSViewRepresentable.

    var body: some View {
        VStack(alignment: .center) {
            CyclingIconView()

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text("Ghoztty")
                        .bold()
                        .font(.title)
                    Text("Fast, native, feature-rich terminal \nemulator pushing modern features.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    switch versionConfig {
                    case .stable(let version):
                        PropertyRow(label: "Version", text: version, url: versionConfig.url)
                    case .tip:
                        PropertyRow(label: "Version", text: "Tip Release")
                    case .other(let v):
                        PropertyRow(label: "Version", text: v)
                    case .none:
                        EmptyView()
                    }
                    if let build {
                        PropertyRow(label: "Build", text: build)
                    }
                    if let commit, commit != "",
                       let url = Self.githubURL?.appendingPathComponent("/commits/\(commit)") {
                        PropertyRow(label: "Commit", text: commit, url: url)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = docsURL {
                        Button("Docs") {
                            openURL(url)
                        }
                    }
                    if let url = Self.githubURL {
                        Button("GitHub") {
                            openURL(url)
                        }
                    }
                }

                if let copy = self.copyright {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 256)
        #if os(macOS)
        .background(VisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
        #endif
    }

    private struct PropertyRow: View {
        private let label: String
        private let text: String
        private let url: URL?

        init(label: String, text: String, url: URL? = nil) {
            self.label = label
            self.text = text
            self.url = url
        }

        @ViewBuilder private var textView: some View {
            Text(text)
                .frame(width: 125, alignment: .leading)
                .padding(.leading, 2)
                .tint(.secondary)
                .opacity(0.8)
                .monospaced()
        }

        var body: some View {
            HStack(spacing: 4) {
                Text(label)
                    .frame(width: 126, alignment: .trailing)
                    .padding(.trailing, 2)
                if let url {
                    Link(destination: url) {
                        textView
                    }
                } else {
                    textView
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
        }
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}
