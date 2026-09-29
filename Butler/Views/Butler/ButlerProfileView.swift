import SwiftUI

// The top of 管家与设置: what the butler knows about the owner, and its diary.

struct UnderstandingCard<Editor: View>: View {
    let chat: ButlerChat
    let editor: Editor

    var body: some View {
        let notes = chat.tools?.notes.records ?? []
        let profile = chat.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("我对你的了解", systemImage: "sparkle").font(.headline)
                Spacer()
                Image(systemName: "square.and.pencil").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            if profile.isEmpty && notes.isEmpty {
                Text("还不太了解你。聊天时说说你的习惯，比如“饮用水我都放卫生间”“周末去盒马买菜”，我会记下来。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                if !profile.isEmpty {
                    Text(profile).font(.body).lineLimit(6)
                }
                ForEach(notes.prefix(3)) { note in
                    Text("· \(note.title)：\(note.text)").font(.subheadline).lineLimit(2)
                }
                if !notes.isEmpty {
                    Text("共 \(notes.count) 条习惯和偏好").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        // The whole card opens the editor; the link is hidden so the row shows no second chevron.
        .background { NavigationLink { editor } label: { EmptyView() }.opacity(0) }
        .accessibilityElement(children: .combine)
        .accessibilityHint("编辑关于我和家里")
        .accessibilityAddTraits(.isButton)
    }
}

/// The last two weeks, one card per day, scrolled sideways.
struct DiaryStrip: View {
    let turns: [ChatTurn]

    var body: some View {
        let diary = DiaryDay.build(from: turns)
        if diary.isEmpty {
            Text("还没有日记。每天和我说过的事、帮你记下的东西，会按天留在这里。")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(diary) { day in DiaryCard(day: day) }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
        }
    }
}

private struct DiaryCard: View {
    let day: DiaryDay
    @Environment(\.butlerAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                Text(weekday).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent.onFill)
                    .frame(maxWidth: .infinity).padding(.vertical, 1)
                    .background(accent.fill)
                Text(day.day.formatted(.dateTime.day())).font(.title3.weight(.semibold)).monospacedDigit()
                    .padding(.vertical, 2)
            }
            .frame(width: 44)
            .background(Color(.systemBackground).opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)

            Text(day.headline).font(.headline).lineLimit(2)
            if !day.lines.isEmpty {
                Text(day.lines.prefix(4).joined(separator: "；") + (day.lines.count > 4 ? "；等 \(day.lines.count) 项" : ""))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            }
            Spacer(minLength: 0)
            Text("聊了 \(day.conversations) 次").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 232, height: 196, alignment: .topLeading)
        .glassCard(radius: 22)
        .accessibilityElement(children: .combine)
    }

    private var weekday: String {
        if Calendar.current.isDateInToday(day.day) { return "今天" }
        if Calendar.current.isDateInYesterday(day.day) { return "昨天" }
        return day.day.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN")))
    }
}
