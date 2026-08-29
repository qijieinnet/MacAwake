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
