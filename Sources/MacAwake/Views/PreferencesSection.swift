import SwiftUI

struct PreferencesSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("开机自动启动", isOn: Binding(
                get: { state.settings.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox).font(.system(size: 12))

            Toggle("锁屏后才休眠", isOn: $state.settings.sleepRequireScreenLocked)
                .toggleStyle(.checkbox).font(.system(size: 12))

            Toggle("同时保持屏幕常亮", isOn: $state.settings.keepDisplayAwake)
                .toggleStyle(.checkbox).font(.system(size: 12))

            // 只有倒计时和到点两种模式才有「到点」这回事，其余模式下置灰
            Toggle("到点后立即让 Mac 睡眠", isOn: $state.settings.sleepAtDeadline)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .disabled(state.settings.mode != .duration && state.settings.mode != .untilTime)

            Toggle("在菜单栏显示倒计时", isOn: $state.settings.showStatusText)
                .toggleStyle(.checkbox).font(.system(size: 12))

            Toggle("盒盖不休眠", isOn: Binding(
                get: { state.lidGuardActive },
                set: { state.setLidGuard($0) }
            ))
            .toggleStyle(.checkbox).font(.system(size: 12))

            Text(state.lidGuardActive
                 ? "已生效：合盖后 Mac 保持运行。这是系统级设置，退出 MacAwake 甚至重启后依然有效，要手动关掉。注意散热和耗电。"
                 : "合盖是硬件强制休眠，普通的保持唤醒拦不住它，只能改系统的 pmset disablesleep。开关时会弹一次系统管理员授权框。")
                .font(.system(size: 10))
                .foregroundStyle(state.lidGuardActive ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text("图标").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $state.settings.iconStyle) {
                    ForEach(IconStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden().frame(width: 110)
                Toggle("运行时打字", isOn: $state.settings.animateIcon)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                    .disabled(!state.settings.iconStyle.animates)
            }

            HStack {
                Button("重置 AI 信号") { state.resetAgentSignals() }
                    .buttonStyle(.borderless).font(.system(size: 11))
                Spacer()
            }

            Text("电量过低时系统仍会强制休眠。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
