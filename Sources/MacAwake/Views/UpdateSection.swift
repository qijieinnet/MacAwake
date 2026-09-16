import SwiftUI
import AppKit

struct UpdateSection: View {
    @EnvironmentObject private var state: AppState

    private var updater: Updater { state.updater }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("版本 \(updater.currentVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                trailingControl
            }

            switch updater.phase {
            case .available(let release):
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                        Text("发现新版本 \(release.version)")
                            .font(.system(size: 11, weight: .medium))
                        if !release.sizeText.isEmpty {
                            Text(release.sizeText)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Text("下载后会自动替换当前应用并重新启动。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("查看更新说明") { NSWorkspace.shared.open(release.pageURL) }
                            .buttonStyle(.borderless).font(.system(size: 10))
                        Button("暂不更新") { updater.dismiss() }
                            .buttonStyle(.borderless).font(.system(size: 10))
                        Spacer()
                    }
                }

            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 4) {
                    if fraction < 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        ProgressView(value: fraction).controlSize(.small)
                        Text("正在下载 \(Int(fraction * 100))%")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

            case .installing:
                Text("正在安装，完成后会自动重新启动 MacAwake…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

            case .upToDate:
                Text("已是最新版本。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text("更新失败：\(message)")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("到发布页手动下载") {
                        NSWorkspace.shared.open(
                            URL(string: "https://github.com/\(Updater.repository)/releases/latest")!)
                    }
                    .buttonStyle(.borderless).font(.system(size: 10))
                }

            case .idle, .checking:
                EmptyView()
            }

            Toggle("自动检查更新", isOn: $state.settings.autoCheckUpdates)
                .toggleStyle(.checkbox).font(.system(size: 11))
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch updater.phase {
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("检查中…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .available:
            Button("立即更新") { updater.installUpdate() }
                .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
        case .downloading, .installing:
            EmptyView()
        default:
            Button("检查更新") { updater.check() }
                .buttonStyle(.borderless).font(.system(size: 11))
        }
    }
}
