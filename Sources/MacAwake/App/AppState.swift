import Foundation
import SwiftUI
import Combine

struct WakeReason: Identifiable, Hashable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    /// 电源断言的名字必须是 ASCII，否则系统会把它丢成空字符串。
    /// 这个名字会出现在电池菜单的"正在阻止睡眠的 App"里。
    let asciiTitle: String

    init(id: String, icon: String, title: String, detail: String, asciiTitle: String) {
        self.id = id
        self.icon = icon
        self.title = title
        self.detail = detail
        self.asciiTitle = asciiTitle
    }

    static func asciiSafe(_ text: String, fallback: String) -> String {
        let filtered = text.unicodeScalars.filter { $0.isASCII && $0.value >= 32 && $0.value < 127 }
        let result = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? fallback : result
    }
}

@MainActor
final class AppState: ObservableObject {

    @Published var settings: AppSettings {
        didSet {
            store.save(settings)
            agentDetector.configure(settings: settings)
            syncAnimationTimer()
            evaluate()
        }
    }

    @Published private(set) var reasons: [WakeReason] = []
    @Published private(set) var isHolding = false
    @Published private(set) var hookStatuses: [HookTarget: HookInstaller.Status] = [:]
    @Published var lastError: String?
    /// 计划已到点但还没执行时，卡在哪个条件上
    @Published private(set) var scheduleBlocker: String?

    private let store = SettingsStore()
    private let assertions = PowerAssertionManager()
    private let agentDetector = AgentDetector()
    private let serviceDetector = ServiceDetector()

    private var tick: Timer?
    private var sleepObserver: NSObjectProtocol?
    let animator = IconAnimator()
    private var lastServiceSample = Date.distantPast
    private let serviceSampleInterval: TimeInterval = 8

    init() {
        settings = store.load()
        // 上次运行若异常退出，可能残留 hook 信号文件，用陈旧判定兜底即可，这里只同步状态
        refreshHookStatus()
        settings.launchAtLogin = LoginItem.isEnabled()
        agentDetector.configure(settings: settings)
        expireDeadlineIfPassed()
        if settings.mode == .scheduled { rebaseSchedule() }
        evaluate()

        tick = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(tick!, forMode: .common)

        // 机器只要睡过一次，挂着的那次计划就算达成了——不管是系统闲置休眠、合盖，
        // 还是我们自己发的 sleepnow。否则唤醒时锁屏 + 智能体已停会当场再睡一次。
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.markScheduleHandledBySleep() }
        }

        syncAnimationTimer()
    }

    // MARK: - 主循环

    func evaluate() {
        var found: [WakeReason] = []

        // 1. 手动 / 定时
        switch settings.mode {
        case .off:
            break
        case .scheduled:
            // 休眠时段之外主动保持唤醒，时段内交还给系统并尝试主动休眠
            if settings.sleepWindows.contains(where: \.isRunnable) && !sleepWindowActive {
                found.append(WakeReason(id: "manual", icon: "calendar", title: "定时休眠",
                                        detail: "休眠时段外保持唤醒", asciiTitle: "outside sleep window"))
            }
        case .indefinite:
            found.append(WakeReason(id: "manual", icon: "infinity", title: "永不休眠",
                                    detail: "手动开启", asciiTitle: "always on"))
        case .duration, .untilTime:
            if let deadline = settings.deadline {
                if Date() < deadline {
                    found.append(WakeReason(id: "manual", icon: "timer",
                                            title: settings.mode == .duration ? "倒计时" : "到点休眠",
                                            detail: "",
                                            asciiTitle: settings.mode == .duration ? "countdown" : "scheduled"))
                } else {
                    handleDeadlineReached()
                }
            } else {
                settings.mode = .off
            }
        }

        // 2. AI 助手
        let agent = agentDetector.evaluate(settings: settings)
        if agent.claudeBusy {
            found.append(WakeReason(id: "claude", icon: "sparkles",
                                    title: "Claude Code 运行中", detail: agent.claudeSource,
                                    asciiTitle: "Claude Code is running"))
        }
        if agent.codexBusy {
            found.append(WakeReason(id: "codex", icon: "chevron.left.forwardslash.chevron.right",
                                    title: "Codex 运行中", detail: agent.codexSource,
                                    asciiTitle: "Codex is running"))
        }

        // 3. 服务（低频采样）
        if Date().timeIntervalSince(lastServiceSample) >= serviceSampleInterval {
            lastServiceSample = Date()
            serviceDetector.sample(rules: settings.services) { [weak self] in
                Task { @MainActor in self?.evaluate() }
            }
        }
        let active = serviceDetector.activeRuleIDs
        for rule in settings.services where rule.enabled && active.contains(rule.id) {
            let asciiName = rule.kind == .port
                ? "port \(rule.port)"
                : WakeReason.asciiSafe(rule.processPattern, fallback: "process")
            found.append(WakeReason(id: rule.id.uuidString, icon: "network",
                                    title: rule.displayName,
                                    detail: rule.kind == .port
                                        ? (rule.requireActiveConnection ? "有活跃连接" : "端口监听中")
                                        : "进程运行中",
                                    asciiTitle: asciiName))
        }

        if reasons != found { reasons = found }
        let wasHolding = isHolding
        let holding = !found.isEmpty
        if isHolding != holding { isHolding = holding; syncAnimationTimer() }

        refreshStatusText()

        assertions.update(
            preventSystemSleep: isHolding,
            preventDisplaySleep: isHolding && settings.keepDisplayAwake,
            reason: found.first.map { "MacAwake: \($0.asciiTitle)" } ?? "MacAwake"
        )

        evaluateSleepSchedule()
    }

    // MARK: - 定时休眠

    /// 时段外主动保持唤醒，时段内交还给系统并尝试主动休眠。
    /// 到点后不立刻睡，而是每秒复查两个门槛：没有任何保持唤醒的理由（智能体会话、
    /// 服务规则），以及屏幕已锁定。都满足才执行；出了时段就作罢，等下一个时段。
    private func evaluateSleepSchedule() {
        guard settings.mode == .scheduled else {
            if scheduleBlocker != nil { scheduleBlocker = nil }
            return
        }

        // 落在某个还没睡过的时段里才动作。多个时段重叠时取第一个。
        let now = Date()
        let pending = settings.sleepWindows.first { window in
            guard let due = Self.currentDue(for: window, at: now) else { return false }
            return due > (window.lastHandled ?? .distantPast)
        }
        guard let pending, let due = Self.currentDue(for: pending, at: now) else {
            if scheduleBlocker != nil { scheduleBlocker = nil }
            return
        }

        if let blocker = reasons.first {
            if scheduleBlocker != blocker.title { scheduleBlocker = blocker.title }
            return
        }
        if settings.sleepRequireScreenLocked && !PowerAssertionManager.screenIsLocked {
            if scheduleBlocker != "等待锁屏" { scheduleBlocker = "等待锁屏" }
            return
        }

        markHandled(pending.id, due: due)
        PowerAssertionManager.sleepNow()
    }

    /// 系统即将休眠：把当前所在时段标记为已执行。
    /// 机器只要睡过一次这个时段就算达成，唤醒后不该又睡一次。
    private func markScheduleHandledBySleep() {
        guard settings.mode == .scheduled else { return }
        let now = Date()
        for window in settings.sleepWindows {
            guard let due = Self.currentDue(for: window, at: now),
                  due > (window.lastHandled ?? .distantPast) else { continue }
            markHandled(window.id, due: due)
        }
    }

    private func markHandled(_ id: UUID, due: Date) {
        scheduleBlocker = nil
        guard let index = settings.sleepWindows.firstIndex(where: { $0.id == id }) else { return }
        settings.sleepWindows[index].lastHandled = due
    }

    /// 当前是否落在任一休眠时段内。纯按时间算，跟"这个时段睡没睡过"无关——
    /// 时段内被手动唤醒后应该继续允许休眠，而不是又开始保持唤醒。
    var sleepWindowActive: Bool {
        settings.sleepWindows.contains { Self.currentDue(for: $0, at: Date()) != nil }
    }

    /// 当前时刻所处时段的起点；不在这个时段内则为 nil。
    static func currentDue(for window: SleepWindow, at now: Date) -> Date? {
        guard window.isRunnable, let due = lastDueDate(for: window, at: now) else { return nil }
        return now.timeIntervalSince(due) <= TimeInterval(window.lengthMinutes * 60) ? due : nil
    }

    /// 距今最近的一次「已经到点」的时段起点，没有则返回 nil。
    static func lastDueDate(for window: SleepWindow, at now: Date) -> Date? {
        occurrence(for: window, from: now, forward: false)
    }

    /// 下一次将要到点的时段起点。
    static func nextDueDate(for window: SleepWindow, at now: Date) -> Date? {
        occurrence(for: window, from: now, forward: true)
    }

    private static func occurrence(for window: SleepWindow, from now: Date, forward: Bool) -> Date? {
        let calendar = Calendar.current
        for offset in 0...8 {
            let day = calendar.date(byAdding: .day, value: forward ? offset : -offset, to: now)
            guard let day else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = window.hour
            components.minute = window.minute
            components.second = 0
            guard let candidate = calendar.date(from: components) else { continue }
            guard forward ? candidate > now : candidate <= now else { continue }
            if window.matches(weekday: calendar.component(.weekday, from: candidate)) { return candidate }
        }
        return nil
    }

    // MARK: - 时段编辑

    func addSleepWindow() {
        var window = SleepWindow.makeDefault()
        // 新加的默认排在已有时段之后，减少一上来就重叠
        if let last = settings.sleepWindows.last {
            window.hour = (last.hour + 1) % 24
            window.minute = last.minute
            window.lengthMinutes = 60
        }
        window.lastHandled = Self.lastDueDate(for: window, at: Date())
        settings.sleepWindows.append(window)
    }

    func removeSleepWindow(_ window: SleepWindow) {
        settings.sleepWindows.removeAll { $0.id == window.id }
    }

    func binding(for window: SleepWindow) -> Binding<SleepWindow> {
        Binding(
            get: { self.settings.sleepWindows.first(where: { $0.id == window.id }) ?? window },
            set: { updated in
                guard let index = self.settings.sleepWindows.firstIndex(where: { $0.id == window.id }) else { return }
                let old = self.settings.sleepWindows[index]
                var next = updated
                let timingChanged = old.hour != next.hour
                    || old.minute != next.minute
                    || old.lengthMinutes != next.lengthMinutes
                    || old.repeatRule != next.repeatRule
                    || old.weekdays != next.weekdays
                    || (!old.enabled && next.enabled)
                // 改时刻 / 刚启用时把"已执行"标记推到当下，否则本来就落在新时段里会当场触发
                if timingChanged { next.lastHandled = Self.lastDueDate(for: next, at: Date()) }
                self.settings.sleepWindows[index] = next
            }
        )
    }

    /// 切进定时休眠模式时，把所有时段的"已执行"标记推到当下，避免立刻补触发。
    func rebaseSchedule() {
        let now = Date()
        for index in settings.sleepWindows.indices {
            settings.sleepWindows[index].lastHandled =
                Self.lastDueDate(for: settings.sleepWindows[index], at: now)
        }
    }

    /// 面板上的一行状态：说清楚现在是在保持唤醒，还是已进时段、卡在哪一步。
    var scheduleStatusText: String {
        let runnable = settings.sleepWindows.filter(\.isRunnable)
        guard !runnable.isEmpty else { return "没有生效的时段" }
        if let blocker = scheduleBlocker { return "等待中（\(blocker)）" }
        if sleepWindowActive { return "条件满足即休眠" }
        let now = Date()
        let next = runnable.compactMap { Self.nextDueDate(for: $0, at: now) }.min()
        guard let next else { return "不会触发" }
        return "\(Self.scheduleFormatter.string(from: next)) 起可休眠"
    }

    private static let scheduleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    private func handleDeadlineReached() {
        let shouldSleep = settings.sleepAtDeadline
        settings.mode = .off
        settings.deadline = nil
        if shouldSleep { PowerAssertionManager.sleepNow() }
    }

    private func expireDeadlineIfPassed() {
        if let deadline = settings.deadline, Date() >= deadline {
            settings.mode = .off
            settings.deadline = nil
        }
    }

    // MARK: - 模式操作

    func setMode(_ mode: AwakeMode) {
        switch mode {
        case .off, .indefinite:
            settings.deadline = nil
            settings.mode = mode
        case .scheduled:
            settings.deadline = nil
            rebaseSchedule()
            settings.mode = mode
        case .duration:
            startDuration(minutes: settings.lastDurationMinutes)
        case .untilTime:
            startUntilTime(hour: settings.untilHour, minute: settings.untilMinute)
        }
    }

    func startDuration(minutes: Int) {
        settings.lastDurationMinutes = minutes
        settings.deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        settings.mode = .duration
    }

    func startUntilTime(hour: Int, minute: Int) {
        settings.untilHour = hour
        settings.untilMinute = minute
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        components.second = 0
        var target = Calendar.current.date(from: components) ?? Date()
        if target <= Date() { target = target.addingTimeInterval(24 * 3600) } // 已过则算明天
        settings.deadline = target
        settings.mode = .untilTime
    }

    func extendDeadline(minutes: Int) {
        let base = max(settings.deadline ?? Date(), Date())
        settings.deadline = base.addingTimeInterval(TimeInterval(minutes * 60))
        if settings.mode == .off { settings.mode = .duration }
    }

    // MARK: - 服务规则

    func addService() {
        settings.services.append(ServiceRule())
    }

    func removeService(_ rule: ServiceRule) {
        settings.services.removeAll { $0.id == rule.id }
    }

    func binding(for rule: ServiceRule) -> Binding<ServiceRule> {
        Binding(
            get: { self.settings.services.first(where: { $0.id == rule.id }) ?? rule },
            set: { updated in
                guard let index = self.settings.services.firstIndex(where: { $0.id == rule.id }) else { return }
                self.settings.services[index] = updated
            }
        )
    }

    // MARK: - Hook

    func refreshHookStatus() {
        var statuses: [HookTarget: HookInstaller.Status] = [:]
        for target in HookTarget.allCases {
            statuses[target] = HookInstaller(target: target).status()
        }
        hookStatuses = statuses
    }

    func hookStatus(_ target: HookTarget) -> HookInstaller.Status {
        hookStatuses[target] ?? .notInstalled
    }

    func installHooks(_ target: HookTarget) {
        do { try HookInstaller(target: target).install(); lastError = nil }
        catch { lastError = "安装 \(target.displayName) hook 失败：\(error.localizedDescription)" }
        refreshHookStatus()
    }

    func uninstallHooks(_ target: HookTarget) {
        do { try HookInstaller(target: target).uninstall(); lastError = nil }
        catch { lastError = "移除 \(target.displayName) hook 失败：\(error.localizedDescription)" }
        refreshHookStatus()
    }

    func resetAgentSignals() {
        AgentDetector.clearSignals()
        evaluate()
    }

    // MARK: - 登录项

    func setLaunchAtLogin(_ enabled: Bool) {
        if let error = LoginItem.set(enabled) {
            lastError = error
        } else {
            lastError = nil
        }
        settings.launchAtLogin = LoginItem.isEnabled()
    }

    // MARK: - 展示

    /// 只在有任务时才跑动画，空闲时完全停掉
    private func syncAnimationTimer() {
        animator.setRunning(isHolding && settings.animateIcon && settings.iconStyle.animates,
                            style: settings.iconStyle)
    }

    var iconName: String {
        isHolding ? settings.iconStyle.staticSymbol : "moon.zzz"
    }

    /// 有任务但没开动画时显示的静止宠物（咖啡造型走 iconName 的 SF Symbol）
    var staticPetImage: NSImage? {
        guard isHolding, settings.iconStyle.animates else { return nil }
        return PetIcon.image(style: settings.iconStyle, pose: .resting)
    }



    @Published private(set) var statusText: String? = nil

    private func refreshStatusText() {
        guard settings.showStatusText,
              let deadline = settings.deadline,
              settings.mode != .off,
              Date() < deadline else {
            if statusText != nil { statusText = nil }
            return
        }
        let text = Self.countdownText(to: deadline)
        if statusText != text { statusText = text }
    }

    /// 定时休眠模式白天不持断言，电源行为等同「跟随系统」，
    /// 但计划是挂着的，标题要说清楚，否则看起来像没生效。
    var headline: String {
        if settings.mode == .scheduled { return sleepWindowActive ? "休眠时段内" : "保持唤醒中" }
        return isHolding ? "保持唤醒中" : "允许休眠"
    }

    var summary: String {
        if settings.mode == .scheduled, reasons.count <= 1 { return scheduleStatusText }
        if isHolding {
            if reasons.count == 1 { return reasons[0].title }
            return "\(reasons.count) 项保持唤醒"
        }
        return "当前没有生效的保持唤醒条件"
    }

    static func countdownText(to date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    func shutdown() {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        tick?.invalidate()
        animator.stop()
        assertions.releaseAll()
    }
}
