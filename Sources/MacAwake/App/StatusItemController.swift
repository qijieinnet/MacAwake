import AppKit
import SwiftUI
import Combine

/// 用 NSStatusItem + NSPopover 取代 SwiftUI 的 MenuBarExtra。
///
/// 换掉它有两个理由：
///  1. MenuBarExtra 每次 label 变化都要重建状态栏项，实测单帧约 11ms，
///     3fps 的走动动画就要 3.4% CPU。直接给 button.image 赋值是亚毫秒操作。
///  2. MenuBarExtra 的面板尺寸不可控 —— ScrollView 在里面会塌成 0 高度，
///     只能靠测量内容再回填 frame。NSPopover 可以直接指定 contentSize。
@MainActor
final class StatusItemController: NSObject {

    static let dryRun = ProcessInfo.processInfo.environment["MACAWAKE_ANIM_DRYRUN"] == "1"

    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // variableLength 每次换图都会触发整条状态栏重排；没有文字时固定宽度，省掉这笔开销
        statusItem.length = 26
        configureButton()
        configurePopover()
        observe()
        refreshStaticIcon()
    }

    // MARK: - 状态栏按钮

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageLeading
    }

    private func configurePopover() {
        let panel = MenuPanel().environmentObject(state)
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            state.refreshHookStatus()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// 供调试验证用：不经过鼠标点击也能确认弹窗能正常显示
    func debugShowPopover() -> String {
        togglePopover()
        let size = popover.contentViewController?.view.fittingSize ?? .zero
        return "isShown=\(popover.isShown) contentSize=\(Int(size.width))x\(Int(size.height))"
    }

    // MARK: - 图标

    private func observe() {
        // 动画帧：直接换图，不经过 SwiftUI
        state.animator.$image
            .receive(on: RunLoop.main)
            .sink { [weak self] image in
                guard let self, let button = self.statusItem.button else { return }
                if let image {
                    if !Self.dryRun { button.image = image }
                } else {
                    self.refreshStaticIcon()
                }
            }
            .store(in: &cancellables)

        state.$isHolding
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStaticIconIfNeeded() }
            .store(in: &cancellables)

        state.$statusText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                self.statusItem.button?.title = text.map { " \($0)" } ?? ""
                self.statusItem.length = text == nil ? 26 : NSStatusItem.variableLength
            }
            .store(in: &cancellables)
    }

    private func refreshStaticIconIfNeeded() {
        guard state.animator.image == nil else { return }
        refreshStaticIcon()
    }

    private func refreshStaticIcon() {
        guard let button = statusItem.button else { return }
        if let pet = state.staticPetImage {
            button.image = pet
        } else {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let image = NSImage(systemSymbolName: state.iconName, accessibilityDescription: "MacAwake")?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = true
            button.image = image
        }
        button.title = state.statusText.map { " \($0)" } ?? ""
    }
}
