import SwiftUI

/// 外观: the page theme, light / dark / system, and the one optional brand colour.
struct AppearanceSettingsView: View {
    @AppStorage(AccentChoice.modeKey) private var mode: AppearanceMode = .system
    @AppStorage(AccentChoice.storageKey) private var accentChoice: AccentChoice = .glass
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .mist
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(AppTheme.allCases) { option in
                        Button { withAnimation(reduceMotion ? nil : .snappy) { theme = option } } label: { themeTile(option) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(option.title)，\(option.caption)")
                            .accessibilityAddTraits(option == theme ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            } header: {
                Text("主题")
            } footer: {
                Text("主题只换页面背后的光影，卡片和按钮仍是同样的玻璃。")
            }

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
            .glassRows()

            Section("预览") {
                AccentPreview()
                    .environment(\.butlerAccent, accentChoice.accent)
                    .padding(.vertical, 6)
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A small phone-shaped preview of one theme, with two glass cards on it.
    private func themeTile(_ option: AppTheme) -> some View {
        let selected = option == theme
        let dark = colorScheme == .dark
        return VStack(spacing: 8) {
            ThemeBackdrop(theme: option, dark: dark)
                .frame(height: 168)
                .overlay(alignment: .top) {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ButlerSurface.card)
                            .frame(height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(ButlerSurface.cardEdge, lineWidth: 0.5))
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ButlerSurface.card)
                            .frame(height: 60)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(ButlerSurface.cardEdge, lineWidth: 0.5))
                    }
                    .padding(.horizontal, 8).padding(.top, 22)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Color.primary : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 0.5))
            VStack(spacing: 1) {
                Text(option.title).font(.subheadline.weight(selected ? .semibold : .medium)).foregroundStyle(.primary)
                Text(option.caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
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
