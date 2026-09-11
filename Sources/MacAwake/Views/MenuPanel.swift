import SwiftUI
import AppKit

/// ScrollView 在 MenuBarExtra 的自适应窗口里没有固有高度，会塌成 0。
/// 先测量内容真实高度，再显式给 ScrollView 一个 frame。
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 头尾两栏的实测高度之和。面板整体高度不能超过屏幕，否则 NSPopover 会放弃
/// preferredEdge 换到侧边去，箭头就对不上状态栏按钮了——所以要把留给
/// ScrollView 的高度算准，而不是减一个拍脑袋的常数。
private struct ChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private struct MeasureHeight: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geometry in
                Color.clear.preference(key: ChromeHeightKey.self, value: geometry.size.height)
            }
        )
    }
}

struct MenuPanel: View {
    @EnvironmentObject private var state: AppState
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    /// 一直用到屏幕底部才出滚动条。可用高度由 StatusItemController 按
    /// 状态栏按钮所在那块屏算好塞进来（NSScreen.main 是键窗口那块屏，多屏时是错的），
    /// 这里再扣掉实测的头尾两栏。
    private var maxScrollHeight: CGFloat {
        max(160, state.panelMaxHeight - chromeHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.modifier(MeasureHeight())
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ModeSection()
                    Divider()
                    AgentSection()
                    Divider()
                    ServiceSection()
                    Divider()
                    PreferencesSection()
                }
                .padding(14)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
                    }
                )
            }
            .frame(height: min(max(contentHeight, 160), maxScrollHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            Divider()
            footer.modifier(MeasureHeight())
        }
        .frame(width: 380)
        // 头尾两栏是 ScrollView 的兄弟节点，preference 只沿自己子树上冒，
        // 所以这个观察必须挂在外层 VStack 上，挂 ScrollView 上永远收到 0。
        .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
        .onAppear {
            state.refreshHookStatus()
            state.syncLidGuardState()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(state.isHolding ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: state.isHolding
                      ? state.iconName
                      : (state.settings.mode == .scheduled ? "calendar" : state.iconName))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(state.isHolding ? Color.accentColor : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.headline)
                    .font(.system(size: 13, weight: .semibold))
                Text(state.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isHolding {
                Button("全部停止") {
                    state.settings.mode = .off
                    state.settings.deadline = nil
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)

    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !state.reasons.isEmpty {
                ForEach(state.reasons) { reason in
                    HStack(spacing: 6) {
                        Image(systemName: reason.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 14)
                        Text(reason.title).font(.system(size: 11))
                        Text(reason.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Divider()
            }
            if state.lidGuardActive {
                HStack(spacing: 6) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.orange)
                        .frame(width: 14)
                    Text("盒盖不休眠").font(.system(size: 11))
                    Text("系统级，需手动关闭")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Divider()
            }
            if let error = state.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("MacAwake")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("退出") {
                    state.shutdown()
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// 统一的分区标题
struct SectionHeader: View {
    let icon: String
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.secondary)
    }
}
