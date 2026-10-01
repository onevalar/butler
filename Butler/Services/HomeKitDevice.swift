import Foundation
import HomeKit
import UIKit

@MainActor final class HomeKitDevice: NSObject, HMHomeManagerDelegate, HomeDevice {
    private var manager: HMHomeManager?
    private var loaded = false
    // Constructing HMHomeManager can trigger system access. Never do it before conversation consent.
    func connect() async throws {
        guard UIApplication.shared.applicationState == .active else { throw HomeFailure("请保持App在前台，再确认家庭访问。") }
        if manager == nil {
            let value = HMHomeManager(); manager = value; loaded = false; value.delegate = self
        }
        let expected = manager
        for _ in 0..<300 {
            try Task.checkCancellation()
            guard manager === expected else { throw HomeFailure("家庭访问已关闭。") }
            if manager?.authorizationStatus.contains(.restricted) == true { throw HomeFailure("家庭访问被系统限制或未获授权。") }
            if loaded { try ready(); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HomeFailure("家庭资料尚未加载，请完成系统授权后重新确认；不会把未加载当成没有家庭。")
    }
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in
            guard let self, self.manager === manager else { return }
            self.loaded = true
        }
    }
    func disconnect() { manager?.delegate = nil; manager = nil; loaded = false }
    private func ready() throws {
        guard loaded, manager?.authorizationStatus.contains(.authorized) == true else {
            throw HomeFailure("家庭资料未加载或系统权限已撤销，请重新确认访问。")
        }
    }
    func homes() throws -> [(UUID, String)] { try ready(); return manager!.homes.map { ($0.uniqueIdentifier, $0.name) } }
    private func home(_ id: UUID) throws -> HMHome {
        try ready()
        guard let value = manager!.homes.first(where: { $0.uniqueIdentifier == id }) else { throw HomeFailure("家庭已不存在或无权访问，不能按同名替代。") }
        return value
    }
    private func kind(_ characteristic: HMCharacteristic) -> HomeControl.Kind? {
        switch characteristic.characteristicType {
        case HMCharacteristicTypePowerState: .power
        case HMCharacteristicTypeBrightness: .brightness
        case HMCharacteristicTypeTargetLockMechanismState: .lock
        case HMCharacteristicTypeTargetDoorState: .garage
        case HMCharacteristicTypeTargetSecuritySystemState: .security
        case HMCharacteristicTypeCurrentTemperature: .temperature
        case HMCharacteristicTypeCurrentLockMechanismState: .currentLock
        case HMCharacteristicTypeCurrentDoorState: .currentDoor
        case HMCharacteristicTypeCurrentSecuritySystemState: .currentSecurity
        case HMCharacteristicTypeObstructionDetected: .obstruction
        default: nil
        }
    }
    private func control(_ c: HMCharacteristic, accessory: HMAccessory, service: HMService) -> HomeControl? {
        guard let kind = kind(c) else { return nil }
        let securityTypes = [HMServiceTypeLockMechanism, HMServiceTypeGarageDoorOpener, HMServiceTypeSecuritySystem]
        let risky = [.lock, .garage, .security].contains(kind)
            || accessory.services.contains { securityTypes.contains($0.serviceType) }
        return .init(id: c.uniqueIdentifier, accessoryID: accessory.uniqueIdentifier,
            room: accessory.room?.name ?? "未分配房间", accessory: accessory.name, service: service.name,
            kind: kind, writable: c.properties.contains(HMCharacteristicPropertyWritable) && !kind.readOnly,
            risky: risky, reachable: accessory.isReachable, value: (c.value as? NSNumber)?.doubleValue,
            minimum: c.metadata?.minimumValue?.doubleValue, maximum: c.metadata?.maximumValue?.doubleValue,
            step: c.metadata?.stepValue?.doubleValue)
    }
    private func controls(_ home: HMHome) -> [(HMCharacteristic, HomeControl)] {
        home.accessories.flatMap { accessory in
            accessory.services.flatMap { service in
                service.characteristics.compactMap { c in control(c, accessory: accessory, service: service).map { (c, $0) } }
            }
        }.sorted { $0.1.id.uuidString < $1.1.id.uuidString }
    }
    func snapshot(_ id: UUID) async throws -> HomeSnapshot {
        let home = try home(id), entries = controls(home)
        let scenes = home.actionSets.map { scene -> HomeScene in
            var unsupported = 0
            let actions = scene.actions.compactMap { action -> HomeAction? in
                guard let write = action as? HMCharacteristicWriteAction<NSNumber>,
                      let c = entries.first(where: { $0.0.uniqueIdentifier == write.characteristic.uniqueIdentifier })?.1,
                      write.targetValue.doubleValue.isFinite else { unsupported += 1; return nil }
                return .init(control: c, target: write.targetValue.doubleValue)
            }.sorted { $0.control.id.uuidString < $1.control.id.uuidString }
            return .init(id: scene.uniqueIdentifier, name: scene.name, actions: actions, unsupportedActions: unsupported)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        return .init(id: home.uniqueIdentifier, name: home.name, rooms: home.rooms.map(\.name).sorted(),
            controls: entries.map(\.1), scenes: scenes)
    }
    private func native(homeID: UUID, controlID: UUID) throws -> (HMCharacteristic, HomeControl) {
        guard let match = controls(try home(homeID)).first(where: { $0.1.id == controlID }) else {
            throw HomeFailure("属性已消失或暂不支持，不能按名称代替。")
        }
        return match
    }
    func write(homeID: UUID, action: HomeAction) async throws {
        guard UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable else {
            throw HomeFailure("设备控制只在已解锁的App前台执行；没有安排后台执行。")
        }
        let (characteristic, current) = try native(homeID: homeID, controlID: action.control.id)
        try current.validate(action.target)
        var before = action.control, after = current; before.value = nil; after.value = nil
        guard before == after else { throw HomeFailure("设备能力或归属已变化，停止执行。") }
        try Task.checkCancellation()
        try await characteristic.writeValue(NSNumber(value: action.target))
    }
    func read(homeID: UUID, controlID: UUID) async throws -> Double? {
        let (characteristic, current) = try native(homeID: homeID, controlID: controlID)
        guard current.reachable, characteristic.properties.contains(HMCharacteristicPropertyReadable) else {
            throw HomeFailure("设备离线或此属性不可读取；不能沿用缓存推断当前状态。")
        }
        try await characteristic.readValue()
        try ready(); try Task.checkCancellation()
        return (characteristic.value as? NSNumber)?.doubleValue
    }
}

extension HomeStore {
    static let shared: HomeStore = {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("DeviceHome", isDirectory: true)
        var failed = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
        } catch { failed = true }
        return HomeStore(file: directory.appendingPathComponent("operations.json"), device: HomeKitDevice(), preparationFailed: failed)
    }()
}
