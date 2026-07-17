import Foundation

struct IPCRequest: Decodable {
    let action: String
    let arguments: [String]?
}

struct IPCResponse: Encodable {
    let success: Bool
    let error: String?
    let data: IPCData?

    init(success: Bool, error: String? = nil, data: IPCData? = nil) {
        self.success = success
        self.error = error
        self.data = data
    }

    static let ok = IPCResponse(success: true)
}

enum IPCData: Encodable {
    case listState(ListStateData)
    case readResult(ReadResultData)

    struct ListStateData: Encodable {
        let windows: [WindowData]
    }

    struct WindowData: Encodable {
        let id: String
        let title: String
        let target: String?
        let focused: Bool
        let tabs: [TabData]
    }

    struct TabData: Encodable {
        let id: String
        let title: String
        let index: Int
        let selected: Bool
        let splits: SplitNodeData
    }

    indirect enum SplitNodeData: Encodable {
        case leaf(TerminalData)
        case split(direction: String, ratio: Double, left: SplitNodeData, right: SplitNodeData)

        private enum CodingKeys: String, CodingKey {
            case type, terminal, direction, ratio, left, right
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .leaf(let terminal):
                try container.encode("leaf", forKey: .type)
                try container.encode(terminal, forKey: .terminal)
            case .split(let direction, let ratio, let left, let right):
                try container.encode("split", forKey: .type)
                try container.encode(direction, forKey: .direction)
                try container.encode(ratio, forKey: .ratio)
                try container.encode(left, forKey: .left)
                try container.encode(right, forKey: .right)
            }
        }
    }

    struct TerminalData: Encodable {
        let id: String
        let title: String
        let working_directory: String
        let pid: Int
        let tty: String
        let name: String?
        let focused: Bool
        let exit_code: Int?
        /// Pane kind: "terminal" or "viewer".
        var pane_type: String = "terminal"
        /// The viewed file path or URL (viewer panes only).
        var url: String? = nil

        private enum CodingKeys: String, CodingKey {
            case id, title, working_directory, pid, tty, name, focused, exit_code
            case pane_type = "type"
            case url
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(working_directory, forKey: .working_directory)
            try container.encode(pid, forKey: .pid)
            try container.encode(tty, forKey: .tty)
            try container.encode(name, forKey: .name)
            try container.encode(focused, forKey: .focused)
            try container.encode(exit_code, forKey: .exit_code)
            try container.encode(pane_type, forKey: .pane_type)
            try container.encode(url, forKey: .url)
        }
    }

    struct ReadResultData: Encodable {
        let text: String
    }

    private enum CodingKeys: String, CodingKey {
        case windows
        case text
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .listState(let data):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(data.windows, forKey: .windows)
        case .readResult(let data):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(data.text, forKey: .text)
        }
    }
}
