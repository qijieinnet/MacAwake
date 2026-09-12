import SwiftUI

struct ModeSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("", selection: Binding(
                get: { state.settings.mode },
                set: { state.setMode($0) }
            )) {
                ForEach(AwakeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch state.settings.mode {
            case .scheduled:
                scheduleControls
            case .duration:
                durationControls
            case .untilTime:
                timeControls
            case .indefinite, .off:
                EmptyView()
            }

            if let deadline = state.settings.deadline, state.settings.mode != .off {
                HStack(spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("\(Self.formatter.string(from: deadline)) 释放")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("+15 分") { state.extendDeadline(minutes: 15) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                    Button("+1 小时") { state.extendDeadline(minutes: 60) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }

            Toggle("同时保持屏幕常亮", isOn: $state.settings.keepDisplayAwake)
                .toggleStyle(.checkbox).font(.system(size: 12))

            if state.settings.mode != .scheduled {
                Toggle("到点后立即让 Mac 睡眠", isOn: $state.settings.sleepAtDeadline)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .disabled(state.settings.mode == .off || state.settings.mode == .indefinite)
            }
        }
    }

    /// 定时休眠：一组休眠时段，时段外保持唤醒
    private var scheduleControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(state.settings.sleepWindows) { window in
                SleepWindowRow(window: state.binding(for: window),
                               removable: state.settings.sleepWindows.count > 1) {
                    state.removeSleepWindow(window)
                }
            }

            Button {
                state.addSleepWindow()
            } label: {
                Label("添加时段", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            Toggle("锁屏后才休眠", isOn: $state.settings.sleepRequireScreenLocked)
                .toggleStyle(.checkbox).font(.system(size: 12))
        }
    }

    private var durationControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            let columns = [GridItem(.adaptive(minimum: 56), spacing: 6)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(AppSettings.durationPresets, id: \.self) { minutes in
                    Button(Self.durationLabel(minutes)) {
                        state.startDuration(minutes: minutes)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(state.settings.lastDurationMinutes == minutes ? .accentColor : nil)
                }
            }
            HStack(spacing: 6) {
                Text("自定义").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { state.settings.lastDurationMinutes },
                    set: { state.startDuration(minutes: max(1, $0)) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                Text("分钟").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var timeControls: some View {
        HStack(spacing: 6) {
            Text("时段起点").font(.system(size: 11)).foregroundStyle(.secondary)
            Stepper(value: Binding(
                get: { state.settings.untilHour },
                set: { state.startUntilTime(hour: $0, minute: state.settings.untilMinute) }
            ), in: 0...23) {
                Text(String(format: "%02d 时", state.settings.untilHour))
                    .font(.system(size: 12).monospacedDigit())
            }
            Stepper(value: Binding(
                get: { state.settings.untilMinute },
                set: { state.startUntilTime(hour: state.settings.untilHour, minute: $0) }
            ), in: 0...59, step: 5) {
                Text(String(format: "%02d 分", state.settings.untilMinute))
                    .font(.system(size: 12).monospacedDigit())
            }
        }
    }

    private static func durationLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) 分" : "\(minutes / 60) 小时"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}

/// 一条休眠时段：起点 + 长度 + 重复规则
struct SleepWindowRow: View {
    @Binding var window: SleepWindow
    let removable: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Toggle("", isOn: $window.enabled)
                    .toggleStyle(.checkbox).labelsHidden()
                Text(window.rangeText)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Spacer()
                if removable {
                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "minus.circle").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Picker("", selection: $window.repeatRule) {
                    ForEach(SleepWindow.RepeatRule.allCases) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 96)

                if window.repeatRule == .weekly {
                    ForEach(1...7, id: \.self) { weekday in
                        let selected = window.weekdays.contains(weekday)
                        Button(SleepWindow.weekdaySymbols[weekday - 1]) {
                            if selected { window.weekdays.remove(weekday) }
                            else { window.weekdays.insert(weekday) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(selected ? .accentColor : nil)
                    }
                }
            }

            HStack(spacing: 6) {
                Stepper(value: $window.hour, in: 0...23) {
                    Text(String(format: "%02d 时", window.hour))
                        .font(.system(size: 11).monospacedDigit())
                }
                Stepper(value: $window.minute, in: 0...59, step: 5) {
                    Text(String(format: "%02d 分", window.minute))
                        .font(.system(size: 11).monospacedDigit())
                }
                Text("持续").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $window.lengthMinutes) {
                    ForEach(SleepWindow.lengthPresets, id: \.self) { minutes in
                        Text(SleepWindow.lengthLabel(minutes)).tag(minutes)
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 84)
            }
        }
        .padding(7)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .opacity(window.enabled ? 1 : 0.5)
    }
}
