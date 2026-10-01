import Foundation

struct TravelFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct TravelPoint: Codable, Equatable, Identifiable {
    var id = UUID()
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let timeZone: String?
    /// Only live fixes expire. A saved place is a user-confirmed fixed location, not a live fix.
    var measuredAt: Date?
    func validate(now: Date = .now) throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
              !name.isEmpty else { throw TravelFailure("地点坐标无效，请重新查找。") }
        if let measuredAt, !(0...300).contains(now.timeIntervalSince(measuredAt)) {
            throw TravelFailure("当前位置已过期，请重新确认获取，不能把旧位置当现在的位置。")
        }
    }
}
struct SavedPlace: Codable, Equatable, Identifiable {
    let id: UUID
    let revision: Int
    let alias: String
    let point: TravelPoint
}
enum TravelMode: String, Codable { case driving, walking }
struct TravelRoute: Codable, Equatable {
    let origin: TravelPoint
    let destination: TravelPoint
    let mode: TravelMode
    let departure: Date
    let arrival: Date
    let meters: Double
    let seconds: Double
    let checkedAt: Date
}
struct PlaceReminder: Codable, Equatable, Identifiable {
    enum State: String, Codable { case attempting, scheduled, delivered, unknown, cancelling, cancelled }
    let id: UUID
    let place: SavedPlace
    let text: String
    let radius: Double
    let repeats: Bool
    var state: State
    var requestID: String { "butler.place.\(id.uuidString)" }
    func validate() throws {
        try place.point.validate()
        guard (1...200).contains(text.trimmingCharacters(in: .whitespacesAndNewlines).count),
              radius.isFinite, (100...2000).contains(radius) else {
            throw TravelFailure("请明确1–200字的提醒内容和100–2000米的范围；不支持精确到家门口。")
        }
    }
    var reservesPlace: Bool { state != .cancelled && state != .delivered }
}
enum TravelChange: Codable, Equatable {
    case access(Bool)
    case current
    case save(alias: String, point: TravelPoint, before: SavedPlace?)
    case remove(SavedPlace)
    case remind(place: SavedPlace, text: String, radius: Double, repeats: Bool)
    case cancel(UUID)
    case navigate(TravelRoute)
}
enum PlaceRequestState { case scheduled, delivered, missing }
@MainActor protocol TravelDevice {
    func search(_ query: String, near: TravelPoint?) async throws -> [TravelPoint]
    /// Only called after confirmation; may request When In Use authorization, never Always.
    func current() async throws -> TravelPoint
    func route(from: TravelPoint, to: TravelPoint, mode: TravelMode, departure: Date) async throws -> TravelRoute
    func authorizeReminder() async throws
    func schedule(_ reminder: PlaceReminder) async throws
    func status(_ reminder: PlaceReminder) async throws -> PlaceRequestState
    func cancel(_ reminder: PlaceReminder) async throws
    func navigate(_ route: TravelRoute) async throws
}
