import Foundation

enum AwakeMode: String, Codable, CaseIterable, Identifiable {
    case off        // 交给系统 / 仅条件触发
    case indefinite // 永不休眠
    case duration   // 多久之后休眠
    case untilTime  // 到某个时刻休眠

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:        return "跟随系统"
        case .indefinite: return "永不休眠"
        case .duration:   return "倒计时"
        case .untilTime:  return "到点"
        }
    }
}

struct ServiceRule: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case port
        case process
        var id: String { rawValue }
        var title: String { self == .port ? "端口" : "进程" }
    }

    var id: UUID = UUID()
    var enabled: Bool = true
    var name: String = ""
    var kind: Kind = .port
    var port: Int = 3000
    /// true = 仅当端口上存在活跃连接时才保持唤醒；false = 端口处于监听状态即保持唤醒
    var requireActiveConnection: Bool = false
    var processPattern: String = ""

    var displayName: String {
        if !name.isEmpty { return name }
        switch kind {
        case .port:    return "端口 \(port)"
        case .process: return processPattern.isEmpty ? "未命名进程" : processPattern
        }
    }
}

struct AppSettings: Codable {
    // 手动 / 定时
    var mode: AwakeMode = .off
    var deadline: Date? = nil
    var lastDurationMinutes: Int = 60
    var untilHour: Int = 22
    var untilMinute: Int = 0
    var keepDisplayAwake: Bool = false
    var sleepAtDeadline: Bool = false

    // AI 助手
    var agentEnabled: Bool = true
    var agentGraceSeconds: Int = 60
    var agentStaleCapMinutes: Int = 30

    // 每个助手独立选信号源。
    // 默认 Claude 走 hook：它的会话状态只能靠启发式推断，而 hook 一键装完立即生效、无需授信。
    // 默认 Codex 走会话状态：它的 turn 边界是显式事件，判断是确定性的，
    // 而且桌面版 Codex app 根本没有 hook 授信入口。
    var watchClaude: Bool = true
    var claudeUseHook: Bool = true
    var claudeUseSessionState: Bool = false

    var watchCodex: Bool = true
    var codexUseHook: Bool = false
    var codexUseSessionState: Bool = true

    // 服务
    var services: [ServiceRule] = []

    // 偏好
    var launchAtLogin: Bool = false
    var showStatusText: Bool = false
    var iconStyle: IconStyle = .cat
    var animateIcon: Bool = true

    func usesHook(_ target: HookTarget) -> Bool {
        target == .claude ? claudeUseHook : codexUseHook
    }

    func usesSessionState(_ target: HookTarget) -> Bool {
        target == .claude ? claudeUseSessionState : codexUseSessionState
    }

    func watches(_ target: HookTarget) -> Bool {
        target == .claude ? watchClaude : watchCodex
    }

    /// 宽容解码：缺字段用默认值，而不是整份配置解码失败被丢掉。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        mode = v(.mode, d.mode)
        deadline = try? c.decodeIfPresent(Date.self, forKey: .deadline)
        lastDurationMinutes = v(.lastDurationMinutes, d.lastDurationMinutes)
        untilHour = v(.untilHour, d.untilHour)
        untilMinute = v(.untilMinute, d.untilMinute)
        keepDisplayAwake = v(.keepDisplayAwake, d.keepDisplayAwake)
        sleepAtDeadline = v(.sleepAtDeadline, d.sleepAtDeadline)
        agentEnabled = v(.agentEnabled, d.agentEnabled)
        agentGraceSeconds = v(.agentGraceSeconds, d.agentGraceSeconds)
        agentStaleCapMinutes = v(.agentStaleCapMinutes, d.agentStaleCapMinutes)
        watchClaude = v(.watchClaude, d.watchClaude)
        claudeUseHook = v(.claudeUseHook, d.claudeUseHook)
        claudeUseSessionState = v(.claudeUseSessionState, d.claudeUseSessionState)
        watchCodex = v(.watchCodex, d.watchCodex)
        codexUseHook = v(.codexUseHook, d.codexUseHook)
        codexUseSessionState = v(.codexUseSessionState, d.codexUseSessionState)
        services = v(.services, d.services)
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
        showStatusText = v(.showStatusText, d.showStatusText)
        iconStyle = v(.iconStyle, d.iconStyle)
        animateIcon = v(.animateIcon, d.animateIcon)
    }

    static let durationPresets: [Int] = [15, 30, 60, 120, 240, 480]
}

/// 配置持久化到 ~/Library/Application Support/MacAwake/settings.json
final class SettingsStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacAwake", isDirectory: true)
    }()

    static var signalDirectory: URL { directory.appendingPathComponent("signals", isDirectory: true) }

    private var url: URL { Self.directory.appendingPathComponent("settings.json") }

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.signalDirectory, withIntermediateDirectories: true)
    }

    func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    func save(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
