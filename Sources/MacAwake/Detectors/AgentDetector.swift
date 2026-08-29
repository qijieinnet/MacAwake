import Foundation

/// 检测 Claude Code / Codex 是否「正在跑任务」。
///
/// 两路信号，OR 关系：
///  1. Hook 信号文件 —— 由助手的 hooks 写入，最精确；
///  2. 会话 turn 状态 —— 直接读会话记录里的 turn 开始 / 结束，免配置，精度接近 hook。
final class AgentDetector {

    struct Result {
        var claudeBusy = false
        var codexBusy = false
        var claudeSource = ""
        var codexSource = ""
    }

    /// hook 信号文件超过这个时间未刷新就视为失效，防止助手异常退出后 Mac 永不休眠。
    private let staleSignalInterval: TimeInterval = 30 * 60

    private let claudeWatcher = SessionActivityWatcher(kind: .claude)
    private let codexWatcher = SessionActivityWatcher(kind: .codex)

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var claudeTranscriptPath: String { home.appendingPathComponent(".claude/projects").path }
    var codexSessionPath: String { home.appendingPathComponent(".codex/sessions").path }

    static var claudeSignalFile: URL { HookTarget.claude.signalFile }
    static var codexSignalFile: URL { HookTarget.codex.signalFile }

    func configure(settings: AppSettings) {
        // 只为「勾选了会话状态检测」的助手启动 FSEvents 监控
        let wantClaude = settings.agentEnabled && settings.watchClaude && settings.claudeUseSessionState
        let wantCodex  = settings.agentEnabled && settings.watchCodex  && settings.codexUseSessionState

        if wantClaude {
            if claudeWatcher.watchedPaths.isEmpty { claudeWatcher.start(paths: [claudeTranscriptPath]) }
        } else if !claudeWatcher.watchedPaths.isEmpty {
            claudeWatcher.stop()
        }

        if wantCodex {
            if codexWatcher.watchedPaths.isEmpty { codexWatcher.start(paths: [codexSessionPath]) }
        } else if !codexWatcher.watchedPaths.isEmpty {
            codexWatcher.stop()
        }
    }

    func evaluate(settings: AppSettings) -> Result {
        var result = Result()
        guard settings.agentEnabled else { return result }

        let grace = TimeInterval(settings.agentGraceSeconds)
        let staleCap = TimeInterval(settings.agentStaleCapMinutes * 60)

        if settings.watchClaude {
            if settings.claudeUseHook, signalIsLive(Self.claudeSignalFile, target: .claude) {
                result.claudeBusy = true
                result.claudeSource = "Hook"
            } else if settings.claudeUseSessionState,
                      claudeWatcher.isBusy(trailingGrace: grace, staleCap: staleCap, target: .claude) {
                result.claudeBusy = true
                result.claudeSource = "会话状态"
            }
        }

        if settings.watchCodex {
            if settings.codexUseHook, signalIsLive(Self.codexSignalFile, target: .codex) {
                result.codexBusy = true
                result.codexSource = "Hook"
            } else if settings.codexUseSessionState,
                      codexWatcher.isBusy(trailingGrace: grace, staleCap: staleCap, target: .codex) {
                result.codexBusy = true
                result.codexSource = "会话状态"
            }
        }

        return result
    }

    /// hook 信号是否有效。
    /// 不能只看信号文件多久没刷新 —— 助手跑长脚本时，PreToolUse 之后可能几十分钟不再触发 hook。
    /// 助手进程还活着就一直认，进程没了立刻失效。
    private func signalIsLive(_ url: URL, target: HookTarget) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        switch AgentLiveness.isAlive(target) {
        case .some(true):
            return true
        case .some(false):
            // 助手已退出，信号文件是残留，顺手清掉
            try? FileManager.default.removeItem(at: url)
            return false
        case .none:
            return Date().timeIntervalSince(modified) < staleSignalInterval
        }
    }

    /// 清理可能残留的信号文件（用户手动重置时调用）。
    static func clearSignals() {
        try? FileManager.default.removeItem(at: claudeSignalFile)
        try? FileManager.default.removeItem(at: codexSignalFile)
    }
}
