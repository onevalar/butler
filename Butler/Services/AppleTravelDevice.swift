import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

@MainActor final class AppleTravelDevice: NSObject, TravelDevice, CLLocationManagerDelegate {
    private lazy var manager: CLLocationManager = {
        let value = CLLocationManager(); value.delegate = self; value.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        return value
    }()
    private var waiter: CheckedContinuation<CLLocation?, Error>?
    private var waitID: UUID?
    private var wantsFix = false
    private var timeout: Task<Void, Never>?
    private func foreground() throws {
        guard UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable else {
            throw TravelFailure("请在已解锁的App前台确认此操作。")
        }
        try Task.checkCancellation()
    }
    private func locationPermission() throws {
        guard CLLocationManager.locationServicesEnabled(),
              [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) else {
            throw TravelFailure("定位未获准；可在系统设置开启，或手动输入地址查路线。不会改成定时提醒。")
        }
    }
    private func location(fix: Bool) async throws -> CLLocation? {
        try foreground()
        guard waiter == nil else { throw TravelFailure("上一次定位请求仍在进行。") }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiter = continuation; waitID = id; wantsFix = fix
                timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(25))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(TravelFailure("定位或授权等待超时，请完成系统授权后重新确认，也可输入地址。")), id: id)
                }
                if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
                else { continueLocation() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), id: id) }
        }
    }
    private func continueLocation() {
        guard waiter != nil else { return }
        do {
            try locationPermission()
            if wantsFix { manager.requestLocation() } else { finish(.success(nil)) }
        } catch { finish(.failure(error)) }
    }
    private func finish(_ result: Result<CLLocation?, Error>, id: UUID? = nil) {
        guard id == nil || id == waitID else { return }
        timeout?.cancel(); timeout = nil
        let value = waiter; waiter = nil; waitID = nil
        value?.resume(with: result)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined { continueLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, (0...100).contains(last.horizontalAccuracy),
              abs(last.timestamp.timeIntervalSinceNow) <= 60 else {
            finish(.failure(TravelFailure("未取得足够新且精度在100米内的位置，请稍后重试或输入准确地址。"))); return
        }
        finish(.success(last))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(TravelFailure("本次定位失败，没有记录位置或安排提醒。")))
    }
    private func point(_ item: MKMapItem, measuredAt: Date? = nil) -> TravelPoint {
        .init(name: item.name ?? "地图地点", address: item.address?.fullAddress ?? item.addressRepresentations?.cityWithContext(.full) ?? "地址未提供，请核对地点",
            latitude: item.location.coordinate.latitude, longitude: item.location.coordinate.longitude,
            timeZone: item.timeZone?.identifier, measuredAt: measuredAt)
    }
    private func mapItem(_ point: TravelPoint) -> MKMapItem {
        let item = MKMapItem(location: CLLocation(latitude: point.latitude, longitude: point.longitude), address: nil)
        item.name = point.name; return item
    }
    func search(_ query: String, near: TravelPoint?) async throws -> [TravelPoint] {
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        if let near {
            request.region = MKCoordinateRegion(center: .init(latitude: near.latitude, longitude: near.longitude), latitudinalMeters: 10000, longitudinalMeters: 10000)
        }
        let response = try await MKLocalSearch(request: request).start()
        try Task.checkCancellation()
        return response.mapItems.prefix(10).map { point($0) }
    }
    func current() async throws -> TravelPoint {
        guard let fix = try await location(fix: true) else { throw TravelFailure("没有取得当前位置。") }
        // Reverse lookup supplies an address, but retain the measured coordinate, never a POI centroid.
        let request = MKReverseGeocodingRequest(location: fix)
        request?.preferredLocale = Locale(identifier: "zh_CN")
        let items = try await request?.mapItems
        try Task.checkCancellation()
        return .init(name: items?.first?.name ?? "本次当前位置", address: items?.first?.address?.fullAddress ?? "地址未识别，请核对后再保存",
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
            timeZone: items?.first?.timeZone?.identifier, measuredAt: fix.timestamp)
    }
    func route(from: TravelPoint, to: TravelPoint, mode: TravelMode, departure: Date) async throws -> TravelRoute {
        let request = MKDirections.Request(); request.source = mapItem(from); request.destination = mapItem(to)
        request.transportType = mode == .driving ? .automobile : .walking
        request.departureDate = departure; request.requestsAlternateRoutes = false
        let response = try await MKDirections(request: request).calculate()
        try Task.checkCancellation()
        guard let route = response.routes.first, route.expectedTravelTime.isFinite, route.expectedTravelTime > 0,
              route.distance.isFinite, route.distance >= 0 else { throw TravelFailure("苹果地图没有返回可用路线，不能猜到达时间。") }
        return .init(origin: from, destination: to, mode: mode, departure: departure,
            arrival: departure.addingTimeInterval(route.expectedTravelTime), meters: route.distance,
            seconds: route.expectedTravelTime, checkedAt: .now)
    }
    private func reminderPermissions() async throws {
        try locationPermission()
        guard manager.accuracyAuthorization == .fullAccuracy,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            throw TravelFailure("此设备暂不支持地点监测或未开启精确位置，请调整系统设置；不会改成定时提醒。")
        }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard [.authorized, .provisional, .ephemeral].contains(status) else { throw TravelFailure("通知未获准，无法安排地点提醒。") }
    }
    func authorizeReminder() async throws {
        _ = try await location(fix: false)
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        }
        try await reminderPermissions(); try Task.checkCancellation()
    }
    func schedule(_ reminder: PlaceReminder) async throws {
        try foreground(); try await reminderPermissions(); try reminder.validate()
        guard reminder.radius <= manager.maximumRegionMonitoringDistance else { throw TravelFailure("范围超过此设备的监测上限，没有缩小范围代替。") }
        let center = UNUserNotificationCenter.current(), pending = await center.pendingNotificationRequests()
        guard pending.count < 60, pending.filter({ $0.trigger is UNLocationNotificationTrigger }).count < 20 else {
            throw TravelFailure("系统通知或地点监测名额不足，请先取消不需要的提醒。")
        }
        try Task.checkCancellation()
        try await center.add(Self.notificationRequest(reminder))
    }
    static func notificationRequest(_ reminder: PlaceReminder) -> UNNotificationRequest {
        let p = reminder.place.point
        let region = CLCircularRegion(center: .init(latitude: p.latitude, longitude: p.longitude), radius: reminder.radius, identifier: reminder.requestID)
        region.notifyOnEntry = true; region.notifyOnExit = false
        let content = UNMutableNotificationContent()
        content.title = "到达\(reminder.place.alias)附近提醒"; content.body = reminder.text; content.sound = .default
        content.userInfo = ["placeReminderID": reminder.id.uuidString]
        return .init(identifier: reminder.requestID, content: content,
            trigger: UNLocationNotificationTrigger(region: region, repeats: reminder.repeats))
    }
    private func matches(_ request: UNNotificationRequest, _ reminder: PlaceReminder) -> Bool {
        guard request.identifier == reminder.requestID, request.content.body == reminder.text,
              let trigger = request.trigger as? UNLocationNotificationTrigger,
              let region = trigger.region as? CLCircularRegion else { return false }
        return trigger.repeats == reminder.repeats && region.notifyOnEntry && !region.notifyOnExit
            && region.radius == reminder.radius && region.center.latitude == reminder.place.point.latitude
            && region.center.longitude == reminder.place.point.longitude
    }
    func status(_ reminder: PlaceReminder) async throws -> PlaceRequestState {
        let center = UNUserNotificationCenter.current()
        if let pending = await center.pendingNotificationRequests().first(where: { $0.identifier == reminder.requestID }) {
            guard matches(pending, reminder) else { throw TravelFailure("同编号系统请求内容不符，不能视为已安排。") }
            try await reminderPermissions(); return .scheduled
        }
        if await center.deliveredNotifications().contains(where: { matches($0.request, reminder) }) { return .delivered }
        return .missing
    }
    func cancel(_ reminder: PlaceReminder) async throws {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminder.requestID])
        center.removeDeliveredNotifications(withIdentifiers: [reminder.requestID])
    }
    func navigate(_ route: TravelRoute) async throws {
        try foreground()
        let opened = MKMapItem.openMaps(with: [mapItem(route.origin), mapItem(route.destination)], launchOptions: [
            MKLaunchOptionsDirectionsModeKey: route.mode == .driving ? MKLaunchOptionsDirectionsModeDriving : MKLaunchOptionsDirectionsModeWalking])
        guard opened else { throw TravelFailure("未能打开苹果地图，没有自动重试。") }
    }
}
extension TravelStore {
    static let shared: TravelStore = {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("DeviceTravel", isDirectory: true)
        var failed = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
        } catch { failed = true }
        return TravelStore(file: directory.appendingPathComponent("places.json"), device: AppleTravelDevice(), preparationFailed: failed)
    }()
}
