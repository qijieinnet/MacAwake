import Foundation

/// 检测被监控的端口 / 进程是否在运行。
/// 在后台队列以较低频率采样（服务场景不需要秒级精度，系统闲置休眠本身就有分钟级门槛）。
final class ServiceDetector {

    private let queue = DispatchQueue(label: "com.macawake.services")
    private let lock = NSLock()
    private var _activeRuleIDs: Set<UUID> = []
    private var sampling = false

    var activeRuleIDs: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return _activeRuleIDs
    }

    func sample(rules: [ServiceRule], completion: @escaping () -> Void) {
        let enabled = rules.filter { $0.enabled }
        guard !enabled.isEmpty else {
            lock.lock(); _activeRuleIDs = []; lock.unlock()
            completion(); return
        }
        lock.lock()
        if sampling { lock.unlock(); return }
        sampling = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            var active: Set<UUID> = []

            let needsSockets = enabled.contains { $0.kind == .port }
            let sockets = needsSockets ? Self.socketSnapshot() : SocketSnapshot()

            for rule in enabled {
                switch rule.kind {
                case .port:
                    if rule.requireActiveConnection {
                        if sockets.established.contains(rule.port) { active.insert(rule.id) }
                    } else if sockets.listening.contains(rule.port) || sockets.established.contains(rule.port) {
                        active.insert(rule.id)
                    }
                case .process:
                    if !rule.processPattern.isEmpty, Self.processMatches(rule.processPattern) {
                        active.insert(rule.id)
                    }
                }
            }

            self.lock.lock()
            self._activeRuleIDs = active
            self.sampling = false
            self.lock.unlock()
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - 端口

    struct SocketSnapshot {
        var listening: Set<Int> = []
        var established: Set<Int> = []
    }

    /// 解析 `netstat -an -p tcp`。无需任何权限，且能看到所有用户的监听端口。
    static func socketSnapshot() -> SocketSnapshot {
        var snapshot = SocketSnapshot()
        guard let output = run("/usr/sbin/netstat", ["-an", "-p", "tcp"]) else { return snapshot }

        for line in output.split(separator: "\n") {
            guard line.hasPrefix("tcp") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 5, let state = fields.last else { continue }
            let localAddress = String(fields[3])
            guard let separator = localAddress.lastIndex(of: "."),
                  let port = Int(localAddress[localAddress.index(after: separator)...]) else { continue }

            if state == "LISTEN" {
                snapshot.listening.insert(port)
            } else if state == "ESTABLISHED" {
                snapshot.established.insert(port)
            }
        }
        return snapshot
    }

    // MARK: - 进程

    /// macOS 上 pgrep -f 匹配不到长路径进程（Claude Code / Codex 都匹配不到），统一走 ps。
    static func processMatches(_ pattern: String) -> Bool {
        AgentLiveness.processMatches(pattern)
    }

    // MARK: - 工具

    @discardableResult
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
