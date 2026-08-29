import Foundation

/// 会话文件的 turn 状态。
enum TurnState {
    case active     // 任务进行中
    case idle       // 任务已结束，在等用户输入
    case unknown    // 尾部信息不足以判断
}

/// 监控 AI 助手的会话记录目录，并解析出「当前是否有任务在跑」。
///
/// 比只看文件 mtime 精确得多：
///  - mtime 法在模型长思考 / 长工具调用时会出现超过宽限期的空档，导致任务中途释放断言；
///  - turn 状态法直接读会话记录里的 turn 开始 / 结束事件，任务跑多久都不会误释放，
///    而且任务一结束就能立刻释放，不用干等宽限期。
///
/// FSEvents 会告诉我们「哪些文件」变了，所以只需要重读那几个文件的尾部，开销很小。
final class SessionActivityWatcher {

    enum Kind {
        case codex
        case claude
    }

    private let kind: Kind
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.macawake.session-watcher")
    private let lock = NSLock()

    /// 最近有写入的会话文件 -> 最后一次事件时间
    private var recentFiles: [String: Date] = [:]
    /// 增量解析进度。会话文件在任务期间每秒都在追加，
    /// 每次都重读 256KB 全量解析的话 CPU 会非常难看，只解析新追加的字节。
    private struct Progress {
        var parsedUpTo: UInt64   // 已解析到的字节偏移（一定落在换行边界上）
        var size: Int            // 上次看到的文件大小
        var state: TurnState
    }
    private var progress: [String: Progress] = [:]

    private(set) var watchedPaths: [String] = []

    init(kind: Kind) { self.kind = kind }

    // MARK: - 生命周期

    func start(paths: [String]) {
        stop()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        watchedPaths = existing
        seedRecentFiles(existing)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SessionActivityWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
            watcher.record(paths: paths)
        }

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, flags
        ) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedPaths = []
        lock.lock(); recentFiles = [:]; progress = [:]; lock.unlock()
    }

    deinit { stop() }

    // MARK: - 查询

    /// 是否有任务在跑。
    ///
    /// turn 状态为「进行中」时的判据，按可靠性从高到低：
    ///   1. 会话文件刚写过 —— 正常在跑，不必再查什么；
    ///   2. 文件仍被进程持有 —— 长脚本执行中（Codex 全程持有句柄），任务再久也不误判；
    ///   3. 助手进程还活着 —— Claude 写完就关文件，只能退到这一层，配时间上限兜底；
    ///   4. 都不成立 —— 助手已崩溃/退出，立即释放。
    func isBusy(trailingGrace: TimeInterval, staleCap: TimeInterval, target: HookTarget) -> Bool {
        let now = Date()
        let candidates: [(String, Date)] = {
            lock.lock(); defer { lock.unlock() }
            return recentFiles.map { ($0.key, $0.value) }
        }()

        let softWindow: TimeInterval = 60
        var alive: Bool? = nil   // 惰性求值，常见路径不需要执行 ps

        for (path, lastEvent) in candidates {
            let age = now.timeIntervalSince(lastEvent)

            switch turnState(of: path) {
            case .active:
                if age < softWindow { return true }
                if Self.holdsOpen(path) { return true }
                if alive == nil { alive = AgentLiveness.isAlive(target) }
                switch alive {
                case .some(true):  if age < staleCap { return true }
                case .some(false): break            // 助手已退出，这个会话是死的
                case .none:        if age < staleCap { return true }   // 查不出来就退回时间上限
                }
            case .idle, .unknown:
                if age < trailingGrace { return true }
            }
        }
        return false
    }

    /// lsof 有进程创建开销，缓存 3 秒，避免每次 tick 都调用
    private static let holdLock = NSLock()
    private static var holdCache: [String: (checkedAt: Date, held: Bool)] = [:]

    private static func holdsOpen(_ path: String) -> Bool {
        holdLock.lock()
        if let cached = holdCache[path], Date().timeIntervalSince(cached.checkedAt) < 10 {
            holdLock.unlock(); return cached.held
        }
        holdLock.unlock()

        let held = AgentLiveness.isFileHeldOpen(path)

        holdLock.lock()
        if holdCache.count > 32 { holdCache = [:] }
        holdCache[path] = (Date(), held)
        holdLock.unlock()
        return held
    }

    /// 供 UI 展示：最近一次会话写入时间
    var lastActivity: Date? {
        lock.lock(); defer { lock.unlock() }
        return recentFiles.values.max()
    }

    // MARK: - 事件记录

    private func record(paths: [String]) {
        let now = Date()
        let interesting = paths.filter { $0.hasSuffix(".jsonl") }
        guard !interesting.isEmpty else { return }
        lock.lock()
        for path in interesting { recentFiles[path] = now }
        // 只保留最近半小时的条目，防止长时间运行后无限增长
        let cutoff = now.addingTimeInterval(-1800)
        recentFiles = recentFiles.filter { $0.value > cutoff }
        if progress.count > 64 { progress = [:] }
        lock.unlock()
    }

    /// 启动时补一次扫描，避免刚启动就漏掉正在进行的任务
    private func seedRecentFiles(_ roots: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-1800)
            var found: [String: Date] = [:]
            for root in roots {
                guard let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                var scanned = 0
                for case let url as URL in enumerator {
                    scanned += 1
                    if scanned > 8000 { break }
                    guard url.pathExtension == "jsonl",
                          let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                          values.isRegularFile == true,
                          let modified = values.contentModificationDate,
                          modified > cutoff else { continue }
                    found[url.path] = modified
                }
            }
            guard !found.isEmpty else { return }
            self.lock.lock()
            for (k, v) in found where self.recentFiles[k] == nil { self.recentFiles[k] = v }
            self.lock.unlock()
        }
    }

    // MARK: - turn 状态解析

    /// 首次见到一个文件时最多回读这么多字节；之后都是增量续读
    private static let tailBytes = 256 * 1024

    private func turnState(of path: String) -> TurnState {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int else { return .unknown }

        lock.lock()
        let existing = progress[path]
        lock.unlock()

        // 大小没变 = 内容没变，直接用上次的结论，一次读都不做
        if let existing, existing.size == size { return existing.state }

        guard let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? handle.close() }

        var state: TurnState
        var startOffset: UInt64
        var skipFirstLine = false

        if let existing, existing.size <= size, existing.parsedUpTo <= UInt64(size) {
            // 续读：从上次停下的换行边界开始
            state = existing.state
            startOffset = existing.parsedUpTo
        } else {
            // 首次见到，或文件被截断/轮转过 —— 退回读尾部
            state = .unknown
            startOffset = UInt64(max(0, size - Self.tailBytes))
            skipFirstLine = startOffset > 0
        }

        if startOffset > 0 { try? handle.seek(toOffset: startOffset) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return state }

        // 只解析到最后一个换行为止，避免吃到写了一半的行
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return state }
        let complete = data[..<lastNewline]
        let consumed = startOffset + UInt64(data.distance(from: data.startIndex, to: lastNewline)) + 1

        var lines = complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if skipFirstLine, !lines.isEmpty { lines.removeFirst() }

        switch kind {
        case .codex:  state = Self.codexState(lines: lines, current: state)
        case .claude: state = Self.claudeState(lines: lines, current: state)
        }

        lock.lock()
        if progress.count > 64 { progress = [:] }
        progress[path] = Progress(parsedUpTo: consumed, size: size, state: state)
        lock.unlock()
        return state
    }

    /// Codex 的 rollout 文件里有显式的 turn 边界事件，判断是确定性的。
    private static func codexState(lines: [Data.SubSequence], current: TurnState) -> TurnState {
        let starts: Set<String> = ["task_started"]
        let ends: Set<String> = ["task_complete", "turn_aborted", "turn_failed", "shutdown_complete"]

        var state = current
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            if starts.contains(type) { state = .active }
            else if ends.contains(type) { state = .idle }
        }
        return state
    }

    /// Claude 的 transcript 没有显式 turn 事件，用最后一条消息推断：
    /// 助手发了纯文本 = 说完了；助手还挂着 tool_use，或最后一条是 user = 还在跑。
    private static func claudeState(lines: [Data.SubSequence], current: TurnState) -> TurnState {
        var state = current
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "assistant":
                let message = object["message"] as? [String: Any]
                state = Self.hasToolUse(message) ? .active : .idle
            case "user":
                state = .active
            default:
                continue
            }
        }
        return state
    }

    private static func hasToolUse(_ message: [String: Any]?) -> Bool {
        guard let content = message?["content"] as? [[String: Any]] else { return false }
        return content.contains { $0["type"] as? String == "tool_use" }
    }
}
