import SwiftUI

struct PreferencesSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(icon: "gearshape", title: "偏好")

            Toggle("开机自动启动", isOn: Binding(
                get: { state.settings.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox).font(.system(size: 12))

            Toggle("在菜单栏显示倒计时", isOn: $state.settings.showStatusText)
                .toggleStyle(.checkbox).font(.system(size: 12))

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

            Text("合盖仍会正常休眠；电量过低时系统也会强制休眠。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
