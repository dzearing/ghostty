import AppKit

/// A non-terminal pane content view that renders a markdown file, a text/code
/// file, or a website. This is the stub shell for the viewer feature: the
/// WKWebView engine lands in a later task (T04); for now it only carries the
/// viewer's identity (location + title) so PaneView and the split tree can
/// host viewer leaves end-to-end.
final class ViewerView: NSView, Codable {
    /// The viewed location: an absolute file path or an http(s) URL.
    let location: String

    /// Display title: the file's name, or the URL until a page title is known.
    @Published private(set) var title: String

    /// True when location is a web URL (network allowed) rather than a file.
    var isWebURL: Bool {
        location.hasPrefix("http://") || location.hasPrefix("https://")
    }

    init(location: String) {
        self.location = location
        self.title = Self.initialTitle(for: location)
        super.init(frame: .zero)

        // Temporary placeholder chrome until the WKWebView engine lands (T04):
        // a centered label so viewer panes are visibly present in the split.
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let label = NSTextField(labelWithString: "Viewer\n\(location)")
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    private static func initialTitle(for location: String) -> String {
        if location.hasPrefix("http://") || location.hasPrefix("https://") {
            return URL(string: location)?.host ?? location
        }
        return (location as NSString).lastPathComponent
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case location
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(location: try container.decode(String.self, forKey: .location))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(location, forKey: .location)
    }
}

extension ViewerView: ObservableObject {}
