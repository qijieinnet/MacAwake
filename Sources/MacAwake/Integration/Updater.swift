import Foundation
import AppKit

/// 一次可用的更新。
struct ReleaseInfo: Equatable {
    let version: String          // 去掉前缀 v 的版本号，如 "1.3.0"
    let notes: String
    let pageURL: URL
    let assetName: String
    let assetURL: URL
    let assetSize: Int64

    var sizeText: String {
        assetSize > 0
            ? ByteCountFormatter.string(fromByteCount: assetSize, countStyle: .file)
            : ""
    }
}

/// 自动更新：查 GitHub Releases → 下 DMG → 挂载取出 app → 退出自己并原地替换 → 重新打开。
///
/// 为什么不用 Sparkle：本项目没有 Developer ID，产物是 ad-hoc 签名，Sparkle 还要额外维护
/// EdDSA 签名密钥和 appcast.xml，收益不抵成本。GitHub Release 本身就是现成的更新源。
@MainActor
final class Updater: ObservableObject {

    /// owner/repo，跟 git remote 一致
    static let repository = "qijieinnet/MacAwake"

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(Double)      // 0...1，-1 表示总长度未知
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheck: Date?

    /// 当前运行的版本号（CFBundleShortVersionString）
    let currentVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"

    private var task: Task<Void, Never>?
    private let lastCheckKey = "MacAwake.lastUpdateCheck"

    init() {
        lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: - 检查

    /// 距上次检查够久才查，用于启动时的静默自动检查。
    func checkIfDue(interval: TimeInterval = 24 * 3600) {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < interval { return }
        check(silent: true)
    }

    func check(silent: Bool = false) {
        guard !isBusy else { return }
        if !silent { phase = .checking }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await Self.fetchLatest()
                await MainActor.run {
                    self.lastCheck = Date()
                    UserDefaults.standard.set(self.lastCheck, forKey: self.lastCheckKey)
                    if let release, Self.compare(release.version, self.currentVersion) == .orderedDescending {
                        self.phase = .available(release)
                    } else if !silent {
                        self.phase = .upToDate
                    } else {
                        self.phase = .idle
                    }
                }
            } catch is CancellationError {
                // 忽略
            } catch {
                await MainActor.run {
                    if !silent { self.phase = .failed(Self.describe(error)) }
                }
            }
        }
    }

    /// 下载并安装，完成后自动重启应用。
    func installUpdate() {
        guard case .available(let release) = phase else { return }
        phase = .downloading(0)
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Self.assertInstallable()
                let dmg = try await Self.download(release) { progress in
                    Task { @MainActor in
                        if case .downloading = self.phase { self.phase = .downloading(progress) }
                    }
                }
                await MainActor.run { self.phase = .installing }
                let staged = try Self.extractApp(fromDMG: dmg)
                try Self.scheduleSwapAndRelaunch(staged: staged)
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
            } catch is CancellationError {
                // 忽略
            } catch {
                await MainActor.run { self.phase = .failed(Self.describe(error)) }
            }
        }
    }

    func dismiss() {
        task?.cancel()
        phase = .idle
    }

    // MARK: - GitHub API

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int64
        }
        let tag_name: String
        let html_url: URL
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    private static func fetchLatest() async throws -> ReleaseInfo? {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacAwake", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // 404 = 还没有任何 Release，不算故障
            if http.statusCode == 404 { return nil }
            throw Failure.http(http.statusCode)
        }
        let release = try JSONDecoder().decode(APIRelease.self, from: data)
        if release.draft == true || release.prerelease == true { return nil }

        let version = release.tag_name.hasPrefix("v")
            ? String(release.tag_name.dropFirst())
            : release.tag_name

        guard let asset = pickAsset(release.assets) else { return nil }
        return ReleaseInfo(version: version,
                           notes: release.body ?? "",
                           pageURL: release.html_url,
                           assetName: asset.name,
                           assetURL: asset.browser_download_url,
                           assetSize: asset.size)
    }

    /// 优先 Universal，其次跟当前架构对得上的，最后随便一个 dmg。
    private static func pickAsset(_ assets: [APIRelease.Asset]) -> APIRelease.Asset? {
        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        if let universal = dmgs.first(where: { $0.name.lowercased().contains("universal") }) { return universal }
        #if arch(arm64)
        let slice = "arm64"
        #else
        let slice = "x86_64"
        #endif
        return dmgs.first(where: { $0.name.contains(slice) }) ?? dmgs.first
    }

    // MARK: - 版本号比较

    /// 语义化比较。"1.10.0" > "1.9.0"；带后缀的按预发布处理："1.3.0-dev.abc" < "1.3.0"。
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func split(_ text: String) -> (core: [Int], hasSuffix: Bool) {
            let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
            let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (core, parts.count > 1 && !parts[1].isEmpty)
        }
        let a = split(lhs), b = split(rhs)
        for i in 0..<max(a.core.count, b.core.count) {
            let x = i < a.core.count ? a.core[i] : 0
            let y = i < b.core.count ? b.core[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        if a.hasSuffix == b.hasSuffix { return .orderedSame }
        return a.hasSuffix ? .orderedAscending : .orderedDescending
    }

    // MARK: - 下载与安装

    enum Failure: LocalizedError {
        case http(Int)
        case notInBundle
        case notWritable(String)
        case shell(String, String)

        var errorDescription: String? {
            switch self {
            case .http(let code):          return "服务器返回 \(code)"
            case .notInBundle:             return "当前不是从 .app 运行，无法自动更新"
            case .notWritable(let path):   return "没有写入权限：\(path)，请手动把新版本拖进「应用程序」"
            case .shell(let cmd, let out): return "\(cmd) 失败：\(out)"
            }
        }
    }

    private static var bundleURL: URL { Bundle.main.bundleURL }

    private static func assertInstallable() throws {
        let app = bundleURL
        guard app.pathExtension == "app" else { throw Failure.notInBundle }
        let parent = app.deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: app.path) else {
            throw Failure.notWritable(parent.path)
        }
    }

    private static func download(_ release: ReleaseInfo,
                                 progress: @escaping (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(expected: release.assetSize, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: release.assetURL)
        request.setValue("MacAwake", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let temporary: URL
        let response: URLResponse
        (temporary, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let task = session.downloadTask(with: request)
                delegate.task = task
                task.resume()
            }
        } onCancel: {
            delegate.task?.cancel()
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.http(http.statusCode)
        }

        // 代理回调返回后系统就会删掉临时文件，先挪到自己的位置
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAwake-update-\(UUID().uuidString).dmg")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        progress(1)
        return target
    }

    /// downloadTask 的进度回调 + 完成回调。URLSession 的 async/await 版本拿不到进度。
    /// 可变状态都在锁里（continuation）或只在主流程里写一次（task），所以标 @unchecked。
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        typealias Continuation = CheckedContinuation<(URL, URLResponse), Error>

        weak var task: URLSessionDownloadTask?
        private let expected: Int64
        private let progress: (Double) -> Void
        private var lastReported = -1.0
        /// 完成与失败两个回调可能先后到达，用锁保证 continuation 只被 resume 一次
        private let lock = NSLock()
        private var pending: Continuation?

        var continuation: Continuation? {
            get { lock.lock(); defer { lock.unlock() }; return pending }
            set { lock.lock(); pending = newValue; lock.unlock() }
        }

        private func take() -> Continuation? {
            lock.lock(); defer { lock.unlock() }
            let value = pending
            pending = nil
            return value
        }

        init(expected: Int64, progress: @escaping (Double) -> Void) {
            self.expected = expected
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
            guard total > 0 else { progress(-1); return }
            let fraction = min(1, Double(totalBytesWritten) / Double(total))
            guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
            lastReported = fraction
            progress(fraction)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // 回调一返回文件就没了，这里先搬到一个自己管的位置再交出去
            let holding = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacAwake-dl-\(UUID().uuidString).dmg")
            guard let continuation = take() else { return }
            do {
                try FileManager.default.moveItem(at: location, to: holding)
                continuation.resume(returning: (holding, downloadTask.response ?? URLResponse()))
            } catch {
                continuation.resume(throwing: error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }   // 成功的情况已经在上面 resume 过了
            take()?.resume(throwing: error)
        }
    }

    /// 挂载 DMG，把里面的 MacAwake.app 拷到临时目录，再卸载。
    private static func extractApp(fromDMG dmg: URL) throws -> URL {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("MacAwake-mnt-\(UUID().uuidString)")
        let stage = fm.temporaryDirectory.appendingPathComponent("MacAwake-stage-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)

        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify",
                                     "-mountpoint", mount.path, dmg.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path])
            try? fm.removeItem(at: dmg)
        }

        let name = bundleURL.lastPathComponent          // MacAwake.app
        let source = mount.appendingPathComponent(name)
        guard fm.fileExists(atPath: source.path) else {
            throw Failure.shell("读取 DMG", "镜像里没有 \(name)")
        }
        let staged = stage.appendingPathComponent(name)
        try run("/usr/bin/ditto", [source.path, staged.path])
        // 从网上下的 DMG 带隔离属性，不清掉换上去之后首次启动会被 Gatekeeper 拦
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// 起一个脱离本进程的脚本：等我退出 → 换掉 app bundle → 重新打开。
    /// 自己替换自己做不到（正在运行的 bundle 不能原地覆盖），所以必须交给外部进程。
    private static func scheduleSwapAndRelaunch(staged: URL) throws {
        let target = bundleURL
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAwake-swap-\(UUID().uuidString).sh")

        func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

        let body = """
        #!/bin/sh
        PID=\(ProcessInfo.processInfo.processIdentifier)
        TARGET=\(quote(target.path))
        STAGED=\(quote(staged.path))
        STAGEDIR=\(quote(staged.deletingLastPathComponent().path))
        SELF=\(quote(script.path))

        # 等旧进程真正退出，最多等 20 秒
        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done
        sleep 0.3

        BACKUP="$TARGET.macawake-old"
        rm -rf "$BACKUP"
        if mv "$TARGET" "$BACKUP" 2>/dev/null; then
          if /usr/bin/ditto "$STAGED" "$TARGET"; then
            rm -rf "$BACKUP"
          else
            # 换新失败就把旧的放回去，绝不留下一个没有 app 的目录
            rm -rf "$TARGET"
            mv "$BACKUP" "$TARGET"
          fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        rm -rf "$STAGEDIR"
        /usr/bin/open "$TARGET"
        rm -f "$SELF"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        try process.run()    // 不 wait，父进程马上就要退出
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw Failure.shell((path as NSString).lastPathComponent,
                                output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.errorDescription ?? "更新失败" }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "网络不可用"
            case .timedOut:                                       return "连接超时"
            default:                                              return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
