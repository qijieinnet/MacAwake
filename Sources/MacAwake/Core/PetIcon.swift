import Foundation
import AppKit

/// 菜单栏图标造型。有任务在跑时，小宠物趴在键盘上打字。
enum IconStyle: String, Codable, CaseIterable, Identifiable {
    case cat
    case bunny
    case bear
    case coffee   // 静态咖啡杯，不做动画

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cat:    return "小猫"
        case .bunny:  return "小兔"
        case .bear:   return "小熊"
        case .coffee: return "咖啡"
        }
    }

    var animates: Bool { self != .coffee }

    /// 不做动画时用的静态符号
    var staticSymbol: String { "cup.and.saucer.fill" }
}

/// 手绘小宠物打字图标。
///
/// 为什么不用 SF Symbols：没有「动物在键盘上打字」这种组合，
/// 而把两个符号叠在 22×16pt 里会糊成一团（试过，读起来像雪人站在桌子上）。
enum PetIcon {

    static let size = NSSize(width: 22, height: 16)

    /// 一帧的姿势：哪只爪子按下去，以及头部下压的幅度
    struct Pose {
        let leftDown: Bool
        let rightDown: Bool
        let dip: CGFloat

        static let resting = Pose(leftDown: false, rightDown: false, dip: 0)

        /// 打字节奏：左、抬、右、抬 …… 循环
        static let typing: [Pose] = [
            Pose(leftDown: true,  rightDown: false, dip: 0),
            Pose(leftDown: false, rightDown: false, dip: 0.5),
            Pose(leftDown: false, rightDown: true,  dip: 0),
            Pose(leftDown: false, rightDown: false, dip: 0.5),
        ]
    }

    static func image(style: IconStyle, pose: Pose) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        draw(style: style, pose: pose)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// 打字一轮需要的所有帧，按节奏重复几遍构成一个「敲一阵」的爆发
    static func typingFrames(style: IconStyle, bursts: Int = 3) -> [NSImage] {
        var frames: [NSImage] = []
        for _ in 0..<bursts {
            for pose in Pose.typing { frames.append(image(style: style, pose: pose)) }
        }
        return frames
    }

    // MARK: - 绘制

    private static func draw(style: IconStyle, pose: Pose) {
        NSColor.black.setFill()
        NSColor.black.setStroke()

        drawKeyboard()

        let bodyBottom: CGFloat = 4.1 - pose.dip

        // 身体，头会压在上面融成一体
        NSBezierPath(roundedRect: NSRect(x: 7.6, y: bodyBottom, width: 6.8, height: 5.2),
                     xRadius: 2.4, yRadius: 2.4).fill()

        drawArm(down: pose.leftDown,  pawX: 6.3,  shoulderX: 11 - 2.6, bodyBottom: bodyBottom)
        drawArm(down: pose.rightDown, pawX: 15.7, shoulderX: 11 + 2.6, bodyBottom: bodyBottom)

        let headRadius: CGFloat = 3.3
        let head = NSPoint(x: 11, y: bodyBottom + 6.0)
        NSBezierPath(ovalIn: NSRect(x: head.x - headRadius, y: head.y - headRadius,
                                    width: headRadius * 2, height: headRadius * 2)).fill()

        drawEars(style: style, head: head)
    }

    /// 键盘：一整条路径 + 镂空键位，用 even-odd 让孔真的透出来
    private static func drawKeyboard() {
        let path = NSBezierPath()
        path.append(NSBezierPath(roundedRect: NSRect(x: 0.8, y: 0.5, width: 20.4, height: 2.5),
                                 xRadius: 0.8, yRadius: 0.8))
        for index in 0..<6 {
            path.append(NSBezierPath(
                roundedRect: NSRect(x: 2.2 + CGFloat(index) * 3.05, y: 1.25, width: 1.9, height: 0.9),
                xRadius: 0.3, yRadius: 0.3))
        }
        path.windingRule = .evenOdd
        path.fill()
    }

    private static func drawArm(down: Bool, pawX: CGFloat, shoulderX: CGFloat, bodyBottom: CGFloat) {
        let pawY: CGFloat = down ? 2.8 : 3.7

        let arm = NSBezierPath()
        arm.move(to: NSPoint(x: shoulderX, y: bodyBottom + 3.2))
        arm.line(to: NSPoint(x: pawX, y: pawY + 1.5))
        arm.lineWidth = 1.5
        arm.lineCapStyle = .round
        arm.stroke()

        NSBezierPath(ovalIn: NSRect(x: pawX - 1.35, y: pawY, width: 2.7, height: 2.4)).fill()
    }

    /// 耳朵起点埋进头里，避免出现接缝
    private static func drawEars(style: IconStyle, head: NSPoint) {
        for sign in [CGFloat(-1), 1] {
            switch style {
            case .cat:
                let path = NSBezierPath()
                path.move(to: NSPoint(x: head.x + sign * 0.9, y: head.y + 2.2))
                path.line(to: NSPoint(x: head.x + sign * 2.5, y: head.y + 4.6))
                path.line(to: NSPoint(x: head.x + sign * 3.2, y: head.y + 1.6))
                path.close()
                path.fill()
            case .bunny:
                let path = NSBezierPath(
                    roundedRect: NSRect(x: head.x + sign * 1.5 - 0.7, y: head.y + 1.4,
                                        width: 1.4, height: 4.0),
                    xRadius: 0.7, yRadius: 0.7)
                let transform = NSAffineTransform()
                transform.translateX(by: head.x, yBy: head.y)
                transform.rotate(byDegrees: -sign * 14)
                transform.translateX(by: -head.x, yBy: -head.y)
                path.transform(using: transform as AffineTransform)
                path.fill()
            case .bear:
                NSBezierPath(ovalIn: NSRect(x: head.x + sign * 2.3 - 1.15, y: head.y + 1.9,
                                            width: 2.3, height: 2.3)).fill()
            case .coffee:
                return
            }
        }
    }
}
