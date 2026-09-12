import AppKit
import SwiftUI
import Combine

/// 用 NSStatusItem + 自管的 MenuBarPanel 取代 SwiftUI 的 MenuBarExtra。
///
/// 不用 MenuBarExtra：每次 label 变化都要重建状态栏项，实测单帧约 11ms，
/// 3fps 的走动动画就要 3.4% CPU。直接给 button.image 赋值是亚毫秒操作。
///
/// 也不用 NSPopover：去不掉顶部箭头，而且位置由它自己决定——内容比屏幕高时
/// 会放弃 preferredEdge 改从侧边弹。面板位置这里全部自己算。
@MainActor
final class StatusItemController: NSObject {

    static let dryRun = ProcessInfo.processInfo.environment["MACAWAKE_ANIM_DRYRUN"] == "1"

    /// 和 NSPopover 的圆角对齐
    static let cornerRadius: CGFloat = 10

    private let state: AppState
    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private var hosting: NSHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    /// 面板显示期间才挂：全局点击用来点外面关掉，本地按键用来吃 Esc
    private var outsideClickMonitor: Any?
    private var escMonitor: Any?
    /// 面板可见时的水平位置基准，resize 后要照着它重新贴回菜单栏下沿
    private var isPanelVisible: Bool { panel.isVisible }

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = MenuBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()

        // variableLength 每次换图都会触发整条状态栏重排；没有文字时固定宽度，省掉这笔开销
        statusItem.length = 26
        configureButton()
        syncPanelMaxHeight()
        configurePanel()
        observe()
        refreshStaticIcon()

        // 接显示器 / 改分辨率 / Dock 变化都会改可用高度
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncPanelMaxHeight),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // 内容变高时 AppKit 保持窗口左下角不动，会把顶边顶到菜单栏里去，
        // 所以每次 resize 都要重新贴一次
        NotificationCenter.default.addObserver(
            self, selector: #selector(repositionPanel),
            name: NSWindow.didResizeNotification, object: panel)
    }

    /// 面板高度必须按**状态栏按钮所在那块屏**来算：NSScreen.main 是键窗口那块屏，
    /// 多屏时会算错。visibleFrame 已经排除了菜单栏和 Dock，顶边正好贴菜单栏下沿，
    /// 只需要再给底部留一点余量。
    @objc private func syncPanelMaxHeight() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        guard let screen else { return }
        let available = max(320, screen.visibleFrame.height - 8)
        if state.panelMaxHeight != available { state.panelMaxHeight = available }
    }

    // MARK: - 状态栏按钮

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
        button.imagePosition = .imageLeading
    }

    // MARK: - 面板

    private func configurePanel() {
        // SwiftUI 侧不画背景，毛玻璃由这层提供，圆角靠 maskImage。
        // 材质必须用 .popover：.menu 在浅色外观下几乎不透明，看起来就是块白板；
        // .popover 才是 NSPopover 原来那种通透带背景色调的效果。
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = .roundedMask(radius: Self.cornerRadius)

        let host = NSHostingView(rootView: AnyView(MenuPanel().environmentObject(state)))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        hosting = host

        // NSPopover 自带一圈细描边，没有它边缘会糊在背景上
        let border = BorderOverlayView(radius: Self.cornerRadius)
        border.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            border.topAnchor.constraint(equalTo: effect.topAnchor),
            border.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 和状态栏菜单同级，压住普通窗口
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    @objc private func togglePanel() {
        isPanelVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        // NSPopover 每次 show/close 都会把视图挂上/摘下窗口，onAppear 因此每次都触发；
        // 自管面板只是 orderOut，视图一直挂着，onAppear 只会触发一次，
        // 所以每次开面板要刷新的状态得在这里主动调。
        state.refreshHookStatus()
        state.syncLidGuardState()
        syncPanelMaxHeight()
        // NSHostingView 的尺寸要先跑一遍布局才算得准，否则第一次定位会用到临时尺寸
        panel.layoutIfNeeded()
        repositionPanel()
        panel.makeKeyAndOrderFront(nil)
        // 成为 key window 时 AppKit 会把第一响应者指派给第一个可聚焦控件，
        // 于是「任务结束后再保持」那个输入框一开面板就被选中了。
        // 交还给窗口本身，等用户自己点进去再聚焦。
        panel.makeFirstResponder(nil)
        statusItem.button?.highlight(true)
        installMonitors()
    }

    private func hidePanel() {
        removeMonitors()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }

    /// 水平对齐状态栏按钮中心，顶边贴 visibleFrame 上沿（也就是菜单栏正下方）。
    /// 按钮靠近屏幕左右边缘时把面板夹回屏内，留 8pt 边距。
    @objc private func repositionPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let minX = visible.minX + 8
        let maxX = max(minX, visible.maxX - size.width - 8)
        let x = min(max(anchor.midX - size.width / 2, minX), maxX)
        let origin = NSPoint(x: x, y: visible.maxY - size.height)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    // MARK: - 关闭时机

    private func installMonitors() {
        // 全局监视只收得到**别的 App**的点击，我们自己的面板和状态栏按钮都不会触发，
        // 所以不用额外判断点在哪，也不会出现「点按钮先关再开」的抖动
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in self?.hidePanel() }
            }
        }
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }   // Esc
                Task { @MainActor in self?.hidePanel() }
                return nil
            }
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        outsideClickMonitor = nil
        escMonitor = nil
    }

    /// 供调试验证用：不经过鼠标点击也能确认面板位置
    func debugShowPopover() -> String {
        togglePanel()
        let anchor = statusItem.button.flatMap { b in
            b.window?.convertToScreen(b.convert(b.bounds, to: nil))
        } ?? .zero
        let visible = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let responder = panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "isShown=\(panel.isVisible) button=\(anchor) panel=\(panel.frame)"
            + " visibleFrameMaxY=\(visible.maxY) firstResponder=\(responder)"
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
