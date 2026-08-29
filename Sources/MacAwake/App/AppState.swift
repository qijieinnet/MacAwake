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

    private let store = SettingsStore()
    private let assertions = PowerAssertionManager()
    private let agentDetector = AgentDetector()
    private let serviceDetector = ServiceDetector()

    private var tick: Timer?
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
        evaluate()

        tick = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(tick!, forMode: .common)
        syncAnimationTimer()
    }

    // MARK: - 主循环

    func evaluate() {
        var found: [WakeReason] = []

        // 1. 手动 / 定时
        switch settings.mode {
        case .off:
            break
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
    }

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

    var summary: String {
        guard isHolding else { return "当前没有生效的保持唤醒条件" }
        if reasons.count == 1 { return reasons[0].title }
        return "\(reasons.count) 项保持唤醒"
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
        tick?.invalidate()
        animator.stop()
        assertions.releaseAll()
    }
}
