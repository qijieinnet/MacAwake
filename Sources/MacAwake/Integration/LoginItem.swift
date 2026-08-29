import Foundation
import ServiceManagement

/// 开机自启。优先用 SMAppService（会出现在"系统设置 › 通用 › 登录项"里），
/// ad-hoc 签名下 SMAppService 可能被拒绝，自动回退到 LaunchAgent。
enum LoginItem {

    private static let label = "com.macawake.MacAwake.login"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isEnabled() -> Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        if enabled {
            do {
                try SMAppService.mainApp.register()
                return nil
            } catch {
                return writeLaunchAgent() ? nil : "无法写入登录项：\(error.localizedDescription)"
            }
        } else {
            try? SMAppService.mainApp.unregister()
            removeLaunchAgent()
            return nil
        }
    }

    // MARK: - LaunchAgent 回退

    private static func writeLaunchAgent() -> Bool {
        let executable = Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(
                at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
            launchctl(["bootstrap", "gui/\(getuid())", agentURL.path])
            return true
        } catch {
            return false
        }
    }

    private static func removeLaunchAgent() {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return }
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: agentURL)
    }

    private static func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
