import AppKit

// macOS 图标规范：1024 画布里，圆角方形占 824，圆角半径约 0.2237 倍边长
let CANVAS: CGFloat = 1024
let PLATE: CGFloat = 824
let RADIUS: CGFloat = PLATE * 0.2237

func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

/// 苹果图标用的是连续曲率方形，不是普通圆角矩形。
/// 用超椭圆 |x/a|^n + |y/b|^n = 1 近似，n≈5 时非常接近。
func squircle(in rect: NSRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width/2, b = rect.height/2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let theta = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(theta), st = sin(theta)
        let x = cx + a * pow(abs(ct), 2/n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2/n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!
    ctx.imageInterpolation = .high
    let s = size / CANVAS
    let t = NSAffineTransform(); t.scaleX(by: s, yBy: s); t.concat()

    let plate = NSRect(x: (CANVAS-PLATE)/2, y: (CANVAS-PLATE)/2, width: PLATE, height: PLATE)

    ctx.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    NSColor.black.setFill()
    squircle(in: plate).fill()
    ctx.restoreGraphicsState()
    let platePath = squircle(in: plate)

    // 背景：深夜蓝紫渐变
    NSGradient(colors: [rgb(104, 88, 200), rgb(52, 48, 118), rgb(24, 24, 62)],
               atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: platePath, angle: -90)

    ctx.saveGraphicsState()
    platePath.setClip()

    // 屏幕暖光：从键盘后方漫出来
    let glowCenter = NSPoint(x: CANVAS/2, y: 385)
    NSGradient(colors: [rgb(255, 198, 104).withAlphaComponent(0.40),
                        rgb(255, 176, 80).withAlphaComponent(0.10),
                        rgb(255, 170, 80).withAlphaComponent(0.0)],
               atLocations: [0, 0.42, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: glowCenter.x-620, y: glowCenter.y-620, width: 1240, height: 1240),
              relativeCenterPosition: .zero)

    let cream = rgb(255, 246, 232)
    let keyCap = rgb(255, 214, 130)

    // 猫（正面坐姿，剪影用米色）
    cream.setFill()
    let bodyBottom: CGFloat = 430
    NSBezierPath(roundedRect: NSRect(x: 372, y: bodyBottom, width: 280, height: 210),
                 xRadius: 96, yRadius: 96).fill()

    // 手臂 + 爪子：左爪按下、右爪抬起，和菜单栏动画同一个姿势
    func arm(pawX: CGFloat, shoulderX: CGFloat, pawY: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: shoulderX, y: bodyBottom + 128))
        p.line(to: NSPoint(x: pawX, y: pawY + 34))
        p.lineWidth = 56; p.lineCapStyle = .round
        cream.setStroke(); p.stroke()
        NSBezierPath(ovalIn: NSRect(x: pawX-46, y: pawY, width: 92, height: 80)).fill()
    }
    arm(pawX: 300, shoulderX: 420, pawY: 372)
    arm(pawX: 724, shoulderX: 604, pawY: 410)

    // 头
    let headR: CGFloat = 132
    let head = NSPoint(x: CANVAS/2, y: bodyBottom + 232)
    NSBezierPath(ovalIn: NSRect(x: head.x-headR, y: head.y-headR, width: headR*2, height: headR*2)).fill()

    // 耳朵
    for sign in [CGFloat(-1), 1] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: head.x + sign*36,  y: head.y + 88))
        p.line(to: NSPoint(x: head.x + sign*100, y: head.y + 184))
        p.line(to: NSPoint(x: head.x + sign*108, y: head.y + 60))
        p.close(); p.fill()
    }

    // 眼睛（闭着但精神——两道上扬的弧，表示专注）
    rgb(46, 42, 86).setStroke()
    for sign in [CGFloat(-1), 1] {
        let e = NSBezierPath()
        e.move(to: NSPoint(x: head.x + sign*76, y: head.y + 6))
        e.curve(to: NSPoint(x: head.x + sign*26, y: head.y + 6),
                controlPoint1: NSPoint(x: head.x + sign*62, y: head.y + 42),
                controlPoint2: NSPoint(x: head.x + sign*40, y: head.y + 42))
        e.lineWidth = 17; e.lineCapStyle = .round; e.stroke()
    }

    // 键盘
    let kb = NSBezierPath(roundedRect: NSRect(x: 214, y: 300, width: 596, height: 104),
                          xRadius: 34, yRadius: 34)
    cream.setFill(); kb.fill()
    keyCap.setFill()
    for i in 0..<7 {
        NSBezierPath(roundedRect: NSRect(x: 256 + CGFloat(i)*76, y: 332, width: 52, height: 38),
                     xRadius: 12, yRadius: 12).fill()
    }

    ctx.restoreGraphicsState()

    // 内描边，让边缘更利落
    NSColor.white.withAlphaComponent(0.16).setStroke()
    let inner = squircle(in: plate.insetBy(dx: 3, dy: 3))
    inner.lineWidth = 5; inner.stroke()

    img.unlockFocus()
    return img
}

func png(_ img: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.compositingOperation = .copy
    NSColor.clear.setFill(); NSRect(x:0,y:0,width:px,height:px).fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    drawIcon(size: CGFloat(px)).draw(in: NSRect(x:0,y:0,width:px,height:px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, px) in sizes {
    try! png(NSImage(), px).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
try! png(NSImage(), 1024).write(to: URL(fileURLWithPath: "\(outDir)/icon-1024.png"))
print("已生成 \(iconset) 与 icon-1024.png")
