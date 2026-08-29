import Foundation
import AppKit
import Combine

/// 菜单栏图标动画：小宠物在键盘上敲一阵、歇一阵。
///
/// 性能上踩过三个坑，按顺序解决的：
///  1. 帧计数放在 AppState 里，每帧整个面板视图树都重算（面板关着也算）—— 17% CPU；
///  2. 拆出独立对象后仍要 5%，因为每帧都让 SwiftUI 做变换 —— 改成预渲染 NSImage；
///  3. 逐项隔离后发现剩下的成本 100% 在 `button.image = image` 这一句：
///     每次赋值约 8ms 的状态栏重绘，是系统固有开销（干跑只要 0.6%）。
///     换算下来菜单栏动画约「每 fps 1% CPU」，躲不掉。
///
/// 所以做成间歇：敲一阵（约 2.6 秒）后歇约 9 秒。
/// 打字本来就是一阵一阵的，这样反而比匀速更自然，均摊 CPU 也压到 1% 左右。
@MainActor
final class IconAnimator: ObservableObject {

    @Published private(set) var image: NSImage? = nil

    private var timer: Timer?
    private var tick = 0
    private var frames: [NSImage] = []
    private var restingImage: NSImage? = nil
    private var builtFor: IconStyle? = nil

    /// 每帧 0.22 秒，一轮 12 帧约 2.6 秒
    private let interval: TimeInterval = 0.22
    /// 歇息帧数：约 9 秒。此期间完全不碰 button.image，也就不产生状态栏重绘
    private let restTicks = 41

    func setRunning(_ running: Bool, style: IconStyle) {
        guard running, style.animates else {
            stopTimer()
            return
        }

        if builtFor != style {
            frames = PetIcon.typingFrames(style: style)
            restingImage = PetIcon.image(style: style, pose: .resting)
            builtFor = style
            tick = 0
        }
        guard !frames.isEmpty else { return }

        if image == nil { image = restingImage }
        guard timer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 有任务但关掉了动画时，仍然显示一只静止的宠物
    func staticPet(style: IconStyle) -> NSImage? {
        guard style.animates else { return nil }
        return PetIcon.image(style: style, pose: .resting)
    }

    func stop() { stopTimer() }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        tick = 0
        if image != nil { image = nil }
    }

    private func advance() {
        guard !frames.isEmpty else { return }
        tick &+= 1
        let cycle = frames.count + restTicks
        let phase = tick % cycle
        if phase < frames.count {
            image = frames[phase]
        } else if phase == frames.count {
            // 敲完这一轮，回到静止姿势，然后整个歇息期不再碰图
            image = restingImage
        }
    }
}
