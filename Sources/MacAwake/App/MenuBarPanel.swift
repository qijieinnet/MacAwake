import AppKit

/// 无边框、不激活 App 的面板，用来替代 NSPopover。
///
/// 换掉 NSPopover 的理由：它没有公开 API 去掉顶部箭头，位置也由它自己决定——
/// 内容一旦比屏幕高就会放弃 preferredEdge 改从侧边弹。这里位置完全自己算：
/// 水平对齐状态栏按钮，顶边贴菜单栏下沿。
///
/// borderless 窗口默认不能成为 key window，SwiftUI 的输入控件就没法用，
/// 所以必须显式放开 canBecomeKey；同时不当 main window，避免抢走前台 App 的焦点。
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension NSImage {
    /// 给 NSVisualEffectView 当 maskImage 用的圆角矩形。
    /// behindWindow 混合模式下直接设 layer.cornerRadius 不可靠，maskImage 才是正路。
    /// capInsets + stretch 让这张小图能拉伸到任意尺寸而不糊掉圆角。
    static func roundedMask(radius: CGFloat) -> NSImage {
        let diameter = radius * 2 + 1
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 只画一圈描边的透明覆盖层。NSPopover 自带这圈线，少了边缘会糊在背景上。
final class BorderOverlayView: NSView {
    private let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 描边盖在内容之上，但不能挡住底下控件的点击
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset,
                                xRadius: radius - 0.5, yRadius: radius - 0.5)
        path.lineWidth = 1
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}
