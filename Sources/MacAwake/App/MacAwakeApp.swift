import SwiftUI
import AppKit

@main
struct MacAwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 纯菜单栏应用，不需要任何窗口场景；面板由 StatusItemController 的 NSPopover 承载
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let state = AppState()
        self.state = state
        self.controller = StatusItemController(state: state)

        // 调试用：跑一遍完整的更新流程（检查 → 下载 → 替换 → 重启），日志走 stderr
        if ProcessInfo.processInfo.environment["MACAWAKE_DEBUG_UPDATE"] == "1" {
            Task { @MainActor in
                func log(_ text: String) {
                    FileHandle.standardError.write(Data(("UPDATE " + text + "\n").utf8))
                }
                log("current=\(state.updater.currentVersion)")
                state.updater.check()
                for _ in 0..<600 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    log("phase=\(state.updater.phase)".prefix(160).description)
                    if case .available = state.updater.phase {
                        log("installing")
                        state.updater.installUpdate()
                    }
                    if case .upToDate = state.updater.phase { break }
                    if case .failed = state.updater.phase { break }
                }
            }
        }

        if ProcessInfo.processInfo.environment["MACAWAKE_DEBUG_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let result = self?.controller?.debugShowPopover() else { return }
                FileHandle.standardError.write(Data(("POPOVER " + result + "\n").utf8))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.shutdown()
    }
}
