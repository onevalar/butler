//
//  ButlerWidget.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import WidgetKit
import SwiftUI
import SwiftData

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), items: PreviewData.sampleItems.prefix(3).map { $0 })
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        Task { @MainActor in
            let items = fetchActiveItems()
            let entry = SimpleEntry(date: Date(), items: items.isEmpty ? Array(PreviewData.sampleItems.prefix(3)) : items)
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        Task { @MainActor in
            let items = fetchActiveItems()
            let entry = SimpleEntry(date: Date(), items: items)
            
            // Refresh database hourly
            let refreshDate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
            let timeline = Timeline(entries: [entry], policy: .after(refreshDate))
            completion(timeline)
        }
    }
    
    @MainActor
    private func fetchActiveItems() -> [Item] {
        let schema = Schema([Item.self])
        guard let sharedURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.butler") else {
            return []
        }
        let databaseURL = sharedURL.appendingPathComponent("Butler.sqlite")
        let modelConfiguration = ModelConfiguration(schema: schema, url: databaseURL)
        
        guard let container = try? ModelContainer(for: schema, configurations: [modelConfiguration]) else {
            return []
        }
        
        let context = container.mainContext
        let activeRawValue = ItemStatus.active.rawValue
        let descriptor = FetchDescriptor<Item>(
            predicate: #Predicate<Item> { $0.statusRawValue == activeRawValue },
            sortBy: [SortDescriptor(\.expiryDate, order: .forward)]
        )
        
        return (try? context.fetch(descriptor)) ?? []
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let items: [Item]
}

struct ButlerWidgetEntryView : View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            ButlerSmallWidget(items: entry.items)
        case .systemMedium:
            ButlerMediumWidget(items: entry.items)
        default:
            ButlerSmallWidget(items: entry.items)
        }
    }
}

struct ButlerWidget: Widget {
    let kind: String = "ButlerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            if #available(iOS 17.0, *) {
                ButlerWidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                ButlerWidgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Butler 管家")
        .description("一眼掌握家庭库存与到期预警。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
