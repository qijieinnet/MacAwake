import Foundation

/// 支持 hook 的 AI 助手。两者的 hooks 文件结构完全一致，只是路径和信号文件名不同。
enum HookTarget: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        }
    }

    /// Claude 的 hooks 混在 settings.json 里；Codex 有独立的 hooks.json，
    /// 所以不需要动 config.toml（那里的 notify 是单值，改了会覆盖用户已有配置）。
    var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex:  return home.appendingPathComponent(".codex/hooks.json")
        }
    }

    var signalFile: URL {
        SettingsStore.signalDirectory.appendingPathComponent("\(rawValue).busy")
    }

    /// Codex 的 hooks 必须在交互式会话里人工授信一次才会执行。
    var requiresTrust: Bool { self == .codex }
}

/// 在 AI 助手的 hooks 配置里安装 / 卸载 MacAwake 的条目。
/// 只增删带 MacAwake 标记的条目，用户已有的其他 hooks 原样保留，首次修改前自动备份。
struct HookInstaller {

    static let marker = "# MacAwake"

    let target: HookTarget

    enum Status { case notInstalled, installed, partial }

    private var busyCommand: String {
        let dir = "$HOME/Library/Application Support/MacAwake/signals"
        return "/bin/mkdir -p \"\(dir)\" && /usr/bin/touch \"\(dir)/\(target.rawValue).busy\" \(Self.marker)"
    }

    private var clearCommand: String {
        let dir = "$HOME/Library/Application Support/MacAwake/signals"
        return "/bin/rm -f \"\(dir)/\(target.rawValue).busy\" \(Self.marker)"
    }

    private var plan: [(event: String, command: String, matcher: String?)] {
        [
            ("UserPromptSubmit", busyCommand,  nil),
            ("PreToolUse",       busyCommand,  "*"),
            ("Stop",             clearCommand, nil),
            ("SessionEnd",       clearCommand, nil),
        ]
    }

    // MARK: - 对外接口

    func status() -> Status {
        guard let hooks = loadRoot()["hooks"] as? [String: Any] else { return .notInstalled }
        var installed = 0
        for entry in plan where Self.containsMarker(hooks[entry.event]) { installed += 1 }
        if installed == 0 { return .notInstalled }
        return installed == plan.count ? .installed : .partial
    }

    func install() throws {
        backupIfNeeded()
        var root = loadRoot()
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for entry in plan {
            var groups = (hooks[entry.event] as? [[String: Any]]) ?? []
            groups.removeAll { Self.groupHasMarker($0) }
            var group: [String: Any] = ["hooks": [["type": "command", "command": entry.command]]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[entry.event] = groups
        }

        root["hooks"] = hooks
        try write(root)
    }

    func uninstall() throws {
        var root = loadRoot()
        guard var hooks = root["hooks"] as? [String: Any] else { return }

        for entry in plan {
            guard var groups = hooks[entry.event] as? [[String: Any]] else { continue }
            groups.removeAll { Self.groupHasMarker($0) }
            if groups.isEmpty { hooks.removeValue(forKey: entry.event) } else { hooks[entry.event] = groups }
        }

        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        // Codex 的 hooks.json 只承载 hooks，全空了就把文件删掉，别留个空壳
        if target == .codex, root.isEmpty {
            try? FileManager.default.removeItem(at: target.configURL)
        } else {
            try write(root)
        }
        try? FileManager.default.removeItem(at: target.signalFile)
    }

    // MARK: - 私有

    private func loadRoot() -> [String: Any] {
        guard let data = try? Data(contentsOf: target.configURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return [:] }
        return dictionary
    }

    private func write(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: target.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: target.configURL, options: .atomic)
    }

    private func backupIfNeeded() {
        let url = target.configURL
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".macawake-backup")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) else { return }
        try? fm.copyItem(at: url, to: backup)
    }

    private static func containsMarker(_ value: Any?) -> Bool {
        guard let groups = value as? [[String: Any]] else { return false }
        return groups.contains { groupHasMarker($0) }
    }

    private static func groupHasMarker(_ group: [String: Any]) -> Bool {
        guard let entries = group["hooks"] as? [[String: Any]] else { return false }
        return entries.contains { ($0["command"] as? String)?.contains(marker) == true }
    }
}
