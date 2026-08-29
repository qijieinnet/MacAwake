import SwiftUI

struct AgentSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionHeader(icon: "sparkles", title: "AI 助手运行时不休眠")
                Spacer()
                Toggle("", isOn: $state.settings.agentEnabled)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }

            if state.settings.agentEnabled {
                AgentRow(target: .claude)
                AgentRow(target: .codex)

                HStack(spacing: 6) {
                    Text("任务结束后再保持").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("", value: $state.settings.agentGraceSeconds, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 48)
                    Text("秒").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("会话卡住超过").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("", value: $state.settings.agentStaleCapMinutes, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 48)
                    Text("分钟视为已结束").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 单个助手：开关 + 信号源选择 + hook 安装状态
struct AgentRow: View {
    @EnvironmentObject private var state: AppState
    let target: HookTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Toggle("", isOn: watchBinding).toggleStyle(.checkbox).labelsHidden()
                Text(target.displayName).font(.system(size: 12, weight: .medium))
                if isBusy {
                    Text("运行中")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer()
            }

            if watchBinding.wrappedValue {
                HStack(spacing: 12) {
                    Toggle("Hook", isOn: hookBinding)
                        .toggleStyle(.checkbox).font(.system(size: 11))
                    Toggle("会话状态", isOn: sessionBinding)
                        .toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer()
                }
                .padding(.leading, 20)

                if hookBinding.wrappedValue {
                    hookStatusRow.padding(.leading, 20)
                }
                if !hookBinding.wrappedValue && !sessionBinding.wrappedValue {
                    Text("没有选任何信号源，这个助手不会触发保持唤醒")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }

    private var hookStatusRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(hookColor).frame(width: 6, height: 6)
                Text("hooks \(hookText)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                switch state.hookStatus(target) {
                case .installed:
                    Button("移除") { state.uninstallHooks(target) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                case .notInstalled, .partial:
                    Button("安装") { state.installHooks(target) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if target.requiresTrust, state.hookStatus(target) == .installed {
                Text("桌面版 Codex app 无授信入口，需在终端跑 codex 后用 /hooks 审批一次")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 绑定

    private var watchBinding: Binding<Bool> {
        target == .claude ? $state.settings.watchClaude : $state.settings.watchCodex
    }
    private var hookBinding: Binding<Bool> {
        target == .claude ? $state.settings.claudeUseHook : $state.settings.codexUseHook
    }
    private var sessionBinding: Binding<Bool> {
        target == .claude ? $state.settings.claudeUseSessionState : $state.settings.codexUseSessionState
    }

    private var isBusy: Bool {
        state.reasons.contains { $0.id == target.rawValue }
    }

    private var hookColor: Color {
        switch state.hookStatus(target) {
        case .installed:    return .green
        case .partial:      return .orange
        case .notInstalled: return .secondary
        }
    }

    private var hookText: String {
        switch state.hookStatus(target) {
        case .installed:    return "已安装"
        case .partial:      return "不完整"
        case .notInstalled: return "未安装"
        }
    }
}
