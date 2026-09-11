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
    private var hosting: NSHostingController<AnyView>?
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // variableLength 每次换图都会触发整条状态栏重排；没有文字时固定宽度，省掉这笔开销
        statusItem.length = 26
        configureButton()
        syncPanelMaxHeight()
        configurePopover()
        observe()
        refreshStaticIcon()

        // 接显示器 / 改分辨率 / Dock 变化都会改可用高度
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncPanelMaxHeight),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// 面板高度必须按**状态栏按钮所在那块屏**来算：NSScreen.main 是键窗口那块屏，
    /// 多屏时会算错。面板一旦比屏幕高，NSPopover 就会放弃 .maxY 换到侧边弹，
    /// 箭头对不上按钮。留 24pt 给箭头和上下边距。
    @objc private func syncPanelMaxHeight() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        guard let screen else { return }
        let available = max(320, screen.visibleFrame.height - 24)
        if state.panelMaxHeight != available { state.panelMaxHeight = available }
    }

    // MARK: - 状态栏按钮

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageLeading
    }

    private func configurePopover() {
        let hosting = NSHostingController(rootView: AnyView(MenuPanel().environmentObject(state)))
        hosting.sizingOptions = [.preferredContentSize]
        self.hosting = hosting
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        // 先把视图载进来并跑一遍布局。NSHostingController 的 view 是懒加载的，
        // 不预热的话第一次 show 时内容还没定尺寸，AppKit 会按临时尺寸定位，
        // 等内容涨起来再 resize —— 窗口和箭头就对不上状态栏按钮了。
        prepareContentSize()
    }

    /// 用内容的真实尺寸喂给 popover，保证 show 之前 contentSize 已经是最终值。
    /// 再按屏幕硬夹一次：布局万一还是超了，宁可裁掉几点，也不能让 popover 换边。
    private func prepareContentSize() {
        guard let hosting else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        let size = NSSize(width: fitting.width,
                          height: min(fitting.height, state.panelMaxHeight))
        if popover.contentSize != size { popover.contentSize = size }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            state.refreshHookStatus()
            syncPanelMaxHeight()
            prepareContentSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// 供调试验证用：不经过鼠标点击也能确认弹窗能正常显示
    func debugShowPopover() -> String {
        togglePopover()
        let size = popover.contentViewController?.view.fittingSize ?? .zero
        let buttonRect = statusItem.button.flatMap { b in
            b.window?.convertToScreen(b.convert(b.bounds, to: nil))
        } ?? .zero
        let popRect = popover.contentViewController?.view.window?.frame ?? .zero
        return "isShown=\(popover.isShown) fitting=\(Int(size.width))x\(Int(size.height))"
            + " popoverContentSize=\(Int(popover.contentSize.width))x\(Int(popover.contentSize.height))"
            + " button=\(buttonRect) popWindow=\(popRect)"
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
