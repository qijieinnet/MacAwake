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

struct MenuPanel: View {
    @EnvironmentObject private var state: AppState
    @State private var contentHeight: CGFloat = 0

    /// 一直用到屏幕底部才出滚动条。visibleFrame 已经排除了菜单栏和 Dock，
    /// 再减去面板自己的头尾两栏和一点余量。
    private var maxPanelHeight: CGFloat {
        guard let screen = NSScreen.main else { return 540 }
        return max(320, screen.visibleFrame.height - 130)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
            .frame(height: min(max(contentHeight, 200), maxPanelHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { state.refreshHookStatus() }
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
