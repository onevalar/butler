import WidgetKit
import SwiftUI

struct ButlerWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var current: WidgetSnapshot? { snapshot.flatMap { $0.isCurrent(at: date) ? $0 : nil } }
}

struct ButlerWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ButlerWidgetEntry {
        ButlerWidgetEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ButlerWidgetEntry) -> Void) {
        completion(read()) // No sample household ever substitutes for missing or empty data.
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ButlerWidgetEntry>) -> Void) {
        let entry = read()
        var entries = [entry]
        if let snapshot = entry.current {
            // Expire even if the main app is not running. WidgetKit controls actual render timing.
            entries.append(ButlerWidgetEntry(date: snapshot.validUntil, snapshot: nil))
        }
        completion(Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(1800))))
    }

    private func read() -> ButlerWidgetEntry {
        let snapshot = WidgetSnapshot.fileURL().flatMap { try? WidgetSnapshot.read(from: $0) }
        return ButlerWidgetEntry(date: .now, snapshot: snapshot)
    }
}

struct ButlerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.kind, provider: ButlerWidgetProvider()) { entry in
            ButlerWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetDestination.overview.url)
        }
        .configurationDisplayName("小当家 · 今日与临期")
        .description("查看本地待办和7天内需关注的物品。点击进入对话，锁屏只显示数量。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}
