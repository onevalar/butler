import SwiftUI
import WidgetKit

struct ButlerWidgetEntryView: View {
    let entry: ButlerWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline, .accessoryCircular, .accessoryRectangular:
            lockScreen // Deliberately never passes rows or titles to the lock-screen view.
        default:
            if let snapshot = entry.current {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("小当家").font(.headline)
                        Spacer()
                        Text(snapshot.generatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                    if family == .systemMedium {
                        HStack(alignment: .top, spacing: 12) {
                            section("今日待办", count: snapshot.taskCount, rows: snapshot.tasks, tasks: true, limit: 2)
                            Divider()
                            section("临期关注", count: snapshot.itemCount, rows: snapshot.items, tasks: false, limit: 2)
                        }
                    } else {
                        section("今日待办", count: snapshot.taskCount, rows: snapshot.tasks, tasks: true, limit: 1)
                        section("临期关注", count: snapshot.itemCount, rows: snapshot.items, tasks: false, limit: 1)
                    }
                    Spacer(minLength: 0)
                }
                .privacySensitive()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("小当家", systemImage: "house")
                    Text("打开 App 更新").font(.headline)
                    Text("摘要尚未就绪或已过期").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func section(_ title: String, count: Int, rows: [WidgetSnapshot.Row], tasks: Bool, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(title) · \(count)").font(.caption.weight(.semibold)).monospacedDigit()
            if rows.isEmpty {
                Text("暂无").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows.prefix(limit)) { row in
                    Link(destination: (tasks ? WidgetDestination.task(row.id) : .lot(row.id)).url) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.subheadline).lineLimit(1)
                            if family == .systemMedium {
                                Text(row.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel("\(row.title)，\(row.detail)，打开对话")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var lockScreen: some View {
        if let snapshot = entry.current {
            switch family {
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Image(systemName: "checklist")
                    Text("\(snapshot.taskCount)").font(.headline).monospacedDigit()
                }
                .accessibilityLabel("小当家今日待办\(snapshot.taskCount)项，打开对话")
            case .accessoryInline:
                Text("待办 \(snapshot.taskCount) · 临期 \(snapshot.itemCount)")
            default:
                VStack(alignment: .leading) {
                    Text("小当家").font(.headline)
                    Text("待办 \(snapshot.taskCount) · 临期 \(snapshot.itemCount)").monospacedDigit()
                }
            }
        } else {
            Label("打开更新", systemImage: "arrow.clockwise")
                .accessibilityLabel("小当家摘要待更新，请打开 App")
        }
    }
}
