import SwiftUI

/// 外观: light / dark / system, the one optional brand colour, and the soft background lights.
struct AppearanceSettingsView: View {
    @AppStorage(AccentChoice.modeKey) private var mode: AppearanceMode = .system
    @AppStorage(AccentChoice.storageKey) private var accentChoice: AccentChoice = .glass
    @AppStorage(AccentChoice.glowKey) private var glow = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section("显示") {
                Picker("显示", selection: $mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                HStack(spacing: 0) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button { withAnimation(reduceMotion ? nil : .snappy) { accentChoice = choice } } label: {
                            VStack(spacing: 8) {
                                swatch(choice)
                                Text(choice.title)
                                    .font(.caption.weight(choice == accentChoice ? .semibold : .regular))
                                    .foregroundStyle(choice == accentChoice ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(choice == accentChoice ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("主题色")
            } footer: {
                Text("默认只用玻璃和中性色。选一个主题色后，发送、麦克风、确认按钮和选中的标签会换成这个颜色；到期、提醒这些表示含义的颜色不受影响。")
            }

            Section("预览") {
                AccentPreview()
                    .environment(\.butlerAccent, accentChoice.accent)
                    .padding(.vertical, 6)
            }

            Section {
                Toggle(isOn: $glow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("背景光")
                        Text("在背景里留一点和管家光球同色的柔光，让玻璃更通透").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func swatch(_ choice: AccentChoice) -> some View {
        let selected = choice == accentChoice
        return ZStack {
            if choice == .glass {
                Circle().fill(.clear).glassEffect(.regular, in: .circle)
                Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
            } else {
                Circle().fill(choice.accent.fill)
            }
        }
        .frame(width: 36, height: 36)
        .padding(3)
        .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 2))
    }
}

private struct AccentPreview: View {
    @Environment(\.butlerAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Text("帮我记一下，买了两盒牛奶")
                    .foregroundStyle(accent.onFill)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(accent.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            HStack(spacing: 10) {
                Button("取消") {}.buttonStyle(QuietButtonStyle(height: 40))
                Button("确认") {}.buttonStyle(AccentButtonStyle(height: 40))
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent.onFill)
                    .frame(width: 40, height: 40)
                    .background(accent.fill, in: Circle())
            }
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}
