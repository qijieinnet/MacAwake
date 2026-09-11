import Foundation

/// 合盖休眠（clamshell sleep）是硬件事件触发的强制休眠，IOKit 的
/// kIOPMAssertionTypePreventUserIdleSystemSleep 只挡闲置休眠，拦不住它。
/// 系统里唯一的开关是 `pmset -a disablesleep`，需要 root，所以只能借 osascript 的
/// `with administrator privileges` 弹一次系统自带的管理员授权框。
///
/// 注意这是**系统级**设置：写进去之后会一直留在系统里，MacAwake 退出、甚至重启之后
/// 依然生效，直到显式关掉。所以启动时必须以系统实际状态为准回填开关，不能只信配置文件。
enum LidGuard {

    enum Failure: LocalizedError {
        case userCancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .userCancelled:     return "已取消授权，盒盖不休眠未改变。"
            case .failed(let text):  return "设置盒盖不休眠失败：\(text)"
            }
        }
    }

    /// 系统当前是否已禁用休眠。disablesleep 为 1 时 `pmset -g` 会多出一行 SleepDisabled。
    static var isActive: Bool {
        guard let output = capture("/usr/bin/pmset", ["-g"]) else { return false }
        for line in output.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(separator: " ").last.map { $0 == "1" } ?? false
        }
        return false
    }

    /// 切到目标状态，弹系统管理员密码框。已经是目标状态就直接返回，不打扰用户。
    /// NSAppleScript 的授权框要求在主线程运行。
    @MainActor
    static func set(_ enabled: Bool) throws {
        guard isActive != enabled else { return }

        let script = NSAppleScript(source:
            "do shell script \"/usr/bin/pmset -a disablesleep \(enabled ? 1 : 0)\""
            + " with administrator privileges")
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            // -128 是用户点了「取消」，不是故障
            if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure.userCancelled }
            throw Failure.failed(errorInfo[NSAppleScript.errorMessage] as? String ?? "未知错误")
        }

        // 授权框走完不代表一定写进去了，回读一次确认
        guard isActive == enabled else {
            throw Failure.failed("pmset 已执行但系统状态未变化")
        }
    }

    private static func capture(_ path: String, _ arguments: [String]) -> String? {
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
