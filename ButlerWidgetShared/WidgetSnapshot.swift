import Foundation

/// A disposable projection, never a second database. Only the main app writes it.
nonisolated struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let kind = "ButlerWidget"
    static let groupID = "group.com.anvalar.Butler.widgets"
    struct Row: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let detail: String
    }
    let version: Int
    let generatedAt: Date
    let validUntil: Date
    let timeZoneID: String
    let available: Bool
    let taskCount: Int
    let itemCount: Int
    let tasks: [Row]
    let items: [Row]

    init(now: Date, calendar: Calendar, tasks: [Row], items: [Row], available: Bool = true, nextChange: Date? = nil) {
        version = 1
        generatedAt = now
        timeZoneID = calendar.timeZone.identifier
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        validUntil = min(midnight, now.addingTimeInterval(3600), nextChange ?? .distantFuture)
        self.available = available
        taskCount = available ? tasks.count : 0
        itemCount = available ? items.count : 0
        self.tasks = available ? Array(tasks.prefix(3)) : []
        self.items = available ? Array(items.prefix(3)) : []
    }

    func isCurrent(at now: Date, timeZone: TimeZone = .current) -> Bool {
        version == 1 && available && generatedAt <= now && now < validUntil && timeZoneID == timeZone.identifier
    }

    #if os(iOS)
    static func fileURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("widget-snapshot.json")
    }
    #endif

    static func read(from file: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    func write(to file: URL) throws {
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

/// All widget links only navigate. No completion, deletion, quantities, or text commands in URLs.
nonisolated enum WidgetDestination: Equatable, Sendable {
    case overview, task(UUID), lot(UUID)

    var url: URL {
        var components = URLComponents()
        components.scheme = "butler"
        components.host = "widget"
        switch self {
        case .overview: components.path = "/overview"
        case .task(let id): components.path = "/task/" + id.uuidString
        case .lot(let id): components.path = "/lot/" + id.uuidString
        }
        return components.url!
    }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "butler", parts.host == "widget", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        if path == ["", "overview"] { self = .overview; return }
        guard path.count == 3, path[0].isEmpty, let id = UUID(uuidString: String(path[2])) else { return nil }
        switch path[1] {
        case "task": self = .task(id)
        case "lot": self = .lot(id)
        default: return nil
        }
    }
}
