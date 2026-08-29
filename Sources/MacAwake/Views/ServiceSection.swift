import SwiftUI

struct ServiceSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionHeader(icon: "network", title: "服务运行时不休眠")
                Spacer()
                Button {
                    state.addService()
                } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.borderless)
            }

            if state.settings.services.isEmpty {
                Text("添加一条规则，比如开发服务器监听 3000 端口时不让 Mac 睡眠。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(state.settings.services) { rule in
                    ServiceRuleRow(rule: state.binding(for: rule))
                        .environmentObject(state)
                }
            }
        }
    }
}

struct ServiceRuleRow: View {
    @EnvironmentObject private var state: AppState
    @Binding var rule: ServiceRule
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Toggle("", isOn: $rule.enabled)
                    .toggleStyle(.checkbox).labelsHidden()
                Image(systemName: rule.kind == .port ? "app.connected.to.app.below.fill" : "gearshape.2")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(rule.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if state.reasons.contains(where: { $0.id == rule.id.uuidString }) {
                    Text("运行中")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer()
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                Button {
                    state.removeService(rule)
                } label: {
                    Image(systemName: "trash").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("名称（可选）", text: $rule.name)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))

                    Picker("", selection: $rule.kind) {
                        ForEach(ServiceRule.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    if rule.kind == .port {
                        HStack(spacing: 6) {
                            Text("端口").font(.system(size: 11)).foregroundStyle(.secondary)
                            TextField("", value: $rule.port, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).frame(width: 70)
                        }
                        Toggle("仅在有活跃连接时保持唤醒", isOn: $rule.requireActiveConnection)
                            .toggleStyle(.checkbox).font(.system(size: 11))
                    } else {
                        TextField("进程匹配（同 pgrep -f）", text: $rule.processPattern)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }
}
