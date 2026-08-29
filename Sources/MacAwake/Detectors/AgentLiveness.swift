import Foundation

/// 判断助手是不是还活着。
///
/// 为什么需要它：光看「会话文件多久没写了」会误杀长任务 —— 助手跑一个 40 分钟的构建脚本时，
/// 会话文件全程不写，但任务确实在跑。时间阈值解决不了这个问题，进程是否存活才是正确判据。
enum AgentLiveness {

    /// macOS 上 pgrep -f 匹配不到 Claude Code / Codex 这类进程（参数串会被截断），
    /// 用 ps 的 comm 字段（完整可执行路径）匹配才可靠。
    private static let cacheInterval: TimeInterval = 5

    private static let lock = NSLock()
    private static var cachedAt: Date = .distantPast
    private static var cachedComms: [String]? = nil

    private static func comms() -> [String]? {
        lock.lock()
        if Date().timeIntervalSince(cachedAt) < cacheInterval, let cached = cachedComms {
            lock.unlock(); return cached
        }
        lock.unlock()

        let result = run("/bin/ps", ["-Ao", "comm="])
        let list = result?.split(separator: "\n").map(String.init)

        lock.lock(); cachedAt = Date(); cachedComms = list; lock.unlock()
        return list
    }

    /// 返回 nil 表示查不出来（调用方应退回时间阈值判断）
    static func isAlive(_ target: HookTarget) -> Bool? {
        guard let comms = comms() else { return nil }
        switch target {
        case .claude:
            return comms.contains { $0.contains("claude-code/") || $0.hasSuffix("/claude") }
        case .codex:
            return comms.contains { $0.hasSuffix("/codex") || $0.hasSuffix("/Codex") }
        }
    }

    /// 会话文件是否仍被某个进程打开着。
    /// Codex 在整个 turn 期间都持有文件句柄，所以这是它最精确的存活信号，长脚本也不会误判。
    /// Claude Code 写完就关文件，对它无效。
    static func isFileHeldOpen(_ path: String) -> Bool {
        guard let output = run("/usr/sbin/lsof", ["-t", "--", path]) else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 匹配任意进程（供服务监控使用，替代不可靠的 pgrep -f）
    static func processMatches(_ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        guard let output = run("/bin/ps", ["-Axo", "pid=,comm=,args="]) else { return false }
        let ownPID = String(ProcessInfo.processInfo.processIdentifier)
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            let pid = String(trimmed[..<space])
            if pid == ownPID { continue }
            if trimmed.contains("MacAwake") { continue }
            if trimmed.range(of: pattern, options: [.caseInsensitive]) != nil { return true }
        }
        return false
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
