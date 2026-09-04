import Foundation

enum AwakeMode: String, Codable, CaseIterable, Identifiable {
    case off        // 交给系统 / 仅条件触发
    case scheduled  // 每天 / 每周定时休眠
    case indefinite // 永不休眠
    case duration   // 多久之后休眠
    case untilTime  // 到某个时刻休眠

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:        return "跟随系统"
        case .scheduled:  return "定时休眠"
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

/// 一个休眠时段。可以有多个，时段之间互不影响。
/// 时段外主动保持唤醒；时段内不再持断言，并持续复查——没有任何保持唤醒的理由、
/// 且屏幕已锁定，就让 Mac 睡下去。整体是否启用由 AwakeMode.scheduled 决定。
struct SleepWindow: Codable, Identifiable, Hashable {
    enum RepeatRule: String, Codable, CaseIterable, Identifiable {
        case daily
        case weekly
        var id: String { rawValue }
        var title: String { self == .daily ? "每天" : "每周" }
    }

    var id: UUID = UUID()
    var enabled: Bool = true
    /// 时段起点
    var hour: Int = 23
    var minute: Int = 0
    /// 时段长度。起点 + 这个长度就是终点，终点之后重新回到保持唤醒。
    var lengthMinutes: Int = 480
    var repeatRule: RepeatRule = .daily
    /// Calendar 的 weekday 取值：1 = 周日 … 7 = 周六。仅 repeatRule == .weekly 时生效。
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    /// 已执行过的最近一次时段起点，防止同一个时段内反复休眠。
    var lastHandled: Date? = nil

    func matches(weekday: Int) -> Bool {
        repeatRule == .daily || weekdays.contains(weekday)
    }

    /// 星期一个都没选就永远不会触发，UI 上要提示出来。
    var isRunnable: Bool {
        enabled && (repeatRule == .daily || !weekdays.isEmpty)
    }

    /// "21:00 – 次日 09:00"
    var rangeText: String {
        let end = hour * 60 + minute + lengthMinutes
        let wrapped = end % (24 * 60)
        return String(format: "%02d:%02d – \(end >= 24 * 60 ? "次日 " : "")%02d:%02d",
                      hour, minute, wrapped / 60, wrapped % 60)
    }

    static let lengthPresets: [Int] = [30, 60, 120, 180, 240, 360, 480, 600, 720]

    static func lengthLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时"
    }

    static let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    /// 默认给一条 23:00 起 8 小时
    static func makeDefault() -> SleepWindow { SleepWindow() }
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

    // 定期休眠
    var sleepWindows: [SleepWindow] = [SleepWindow.makeDefault()]
    /// 只在屏幕已锁定时才休眠，避免把正在用电脑的人直接睡掉。对所有时段生效。
    var sleepRequireScreenLocked: Bool = true

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
        sleepWindows = v(.sleepWindows, d.sleepWindows)
        sleepRequireScreenLocked = v(.sleepRequireScreenLocked, d.sleepRequireScreenLocked)
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
