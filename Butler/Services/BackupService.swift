import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Everything Butler keeps, in one JSON file the owner can save to Files / iCloud Drive and restore later.
/// Chat photos are not included (they can be large); the conversation text is.
struct ButlerBackup: Codable {
    static let format = "butler-backup"
    static let currentVersion = 1

    var format = ButlerBackup.format
    var version = ButlerBackup.currentVersion
    var createdAt = Date()
    var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    var products: [Product] = []
    var lots: [Lot] = []
    var evidence: [Evidence] = []
    var events: [Event] = []
    var templates: [Template] = []

    /// The phone-side files, stored verbatim so their own formats round-trip exactly.
    var files: [String: Data] = [:]
    var settings: [String: String] = [:]

    var activeLotCount: Int { lots.filter { $0.stateRawValue == InventoryLotState.active.rawValue }.count }

    struct Product: Codable {
        var id: UUID, canonicalName: String, brand: String?, categoryRawValue: String?, barcode: String?
        var defaultUnit: String?, typicalShelfLifeDays: Int?, postOpeningLifeDays: Int?
        var createdAt: Date, updatedAt: Date, revision: Int, isArchived: Bool
    }

    struct Lot: Codable {
        var id: UUID, productID: UUID, quantity: Int, unit: String
        var purchasedAt: Date?, packageExpiryDate: Date?, estimatedExpiryDate: Date?, plannedUseByDate: Date?
        var storageLocation: String?, stateRawValue: String, createdAt: Date, updatedAt: Date, revision: Int
    }

    struct Evidence: Codable {
        var id: UUID, subjectKindRawValue: String, subjectID: UUID, fieldKey: String
        var sourceKindRawValue: String, verificationStateRawValue: String, confidence: Double, capturedAt: Date
        var rawText: String?, localArtifactID: String?, operationID: UUID?, confirmationReceiptID: UUID?
        var valueSchemaVersion: Int, valueJSON: Data, createdAt: Date
    }

    struct Event: Codable {
        var id: UUID, operationID: UUID, subjectKindRawValue: String, subjectID: UUID, eventTypeRawValue: String
        var actorRawValue: String, occurredAt: Date, payloadSchemaVersion: Int, payloadJSON: Data, createdAt: Date
    }

    struct Template: Codable {
        var id: UUID, productID: UUID, usualQuantity: Int?, defaultUnit: String?, defaultStorageLocation: String?
        var usualConsumptionDays: Int?, reminderLeadDays: Int?, repurchaseThreshold: Int?
        var createdAt: Date, updatedAt: Date, revision: Int
    }
}

enum BackupError: LocalizedError {
    case notABackup, newerVersion(Int)

    var errorDescription: String? {
        switch self {
        case .notABackup: "这个文件不是小当家的备份。"
        case .newerVersion(let version): "这个备份来自更新版本的小当家（格式 \(version)），请先更新 App。"
        }
    }
}

@MainActor
enum BackupService {
    /// Phone-side files that make up the owner's data, by backup key.
    static let fileNames = ["notes": "agent-test-memory.json", "reminders": "reminders.json",
                            "chat": "butler-chat.json", "chatSummary": "butler-chat-summary.json"]
    static let settingKeys = ["butlerProfile", "expiryWarningDays", "reminderMinutes", "showSystemCalendar"]

    nonisolated static var supportDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    // MARK: Export

    static func makeBackup(container: ModelContainer, directory: URL? = supportDirectory,
                           defaults: UserDefaults = .standard) throws -> ButlerBackup {
        let context = ModelContext(container)
        var backup = ButlerBackup()
        backup.products = try context.fetch(FetchDescriptor<CatalogProduct>()).map {
            .init(id: $0.id, canonicalName: $0.canonicalName, brand: $0.brand, categoryRawValue: $0.categoryRawValue,
                  barcode: $0.barcode, defaultUnit: $0.defaultUnit, typicalShelfLifeDays: $0.typicalShelfLifeDays,
                  postOpeningLifeDays: $0.postOpeningLifeDays, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                  revision: $0.revision, isArchived: $0.isArchived)
        }
        backup.lots = try context.fetch(FetchDescriptor<InventoryLot>()).map {
            .init(id: $0.id, productID: $0.productID, quantity: $0.quantity, unit: $0.unit, purchasedAt: $0.purchasedAt,
                  packageExpiryDate: $0.packageExpiryDate, estimatedExpiryDate: $0.estimatedExpiryDate,
                  plannedUseByDate: $0.plannedUseByDate, storageLocation: $0.storageLocation,
                  stateRawValue: $0.stateRawValue, createdAt: $0.createdAt, updatedAt: $0.updatedAt, revision: $0.revision)
        }
        backup.evidence = try context.fetch(FetchDescriptor<FieldEvidence>()).map {
            .init(id: $0.id, subjectKindRawValue: $0.subjectKindRawValue, subjectID: $0.subjectID, fieldKey: $0.fieldKey,
                  sourceKindRawValue: $0.sourceKindRawValue, verificationStateRawValue: $0.verificationStateRawValue,
                  confidence: $0.confidence, capturedAt: $0.capturedAt, rawText: $0.rawText,
                  localArtifactID: $0.localArtifactID, operationID: $0.operationID,
                  confirmationReceiptID: $0.confirmationReceiptID, valueSchemaVersion: $0.valueSchemaVersion,
                  valueJSON: $0.valueJSON, createdAt: $0.createdAt)
        }
        backup.events = try context.fetch(FetchDescriptor<InventoryEvent>()).map {
            .init(id: $0.id, operationID: $0.operationID, subjectKindRawValue: $0.subjectKindRawValue, subjectID: $0.subjectID,
                  eventTypeRawValue: $0.eventTypeRawValue, actorRawValue: $0.actorRawValue, occurredAt: $0.occurredAt,
                  payloadSchemaVersion: $0.payloadSchemaVersion, payloadJSON: $0.payloadJSON, createdAt: $0.createdAt)
        }
        backup.templates = try context.fetch(FetchDescriptor<PersonalProductTemplate>()).map {
            .init(id: $0.id, productID: $0.productID, usualQuantity: $0.usualQuantity, defaultUnit: $0.defaultUnit,
                  defaultStorageLocation: $0.defaultStorageLocation, usualConsumptionDays: $0.usualConsumptionDays,
                  reminderLeadDays: $0.reminderLeadDays, repurchaseThreshold: $0.repurchaseThreshold,
                  createdAt: $0.createdAt, updatedAt: $0.updatedAt, revision: $0.revision)
        }
        if let directory {
            for (key, name) in fileNames {
                if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) { backup.files[key] = data }
            }
        }
        for key in settingKeys {
            if let value = defaults.object(forKey: key) { backup.settings[key] = "\(value)" }
        }
        return backup
    }

    static func encode(_ backup: ButlerBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> ButlerBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(ButlerBackup.self, from: data), backup.format == ButlerBackup.format else {
            throw BackupError.notABackup
        }
        guard backup.version <= ButlerBackup.currentVersion else { throw BackupError.newerVersion(backup.version) }
        return backup
    }

    static func fileName(for date: Date = .now) -> String {
        "小当家备份 \(date.isoDay)"
    }

    // MARK: Restore

    /// Replaces everything with the backup. The current data is saved next to the store first,
    /// so a wrong restore can still be undone by restoring that file.
    static func restore(_ backup: ButlerBackup, container: ModelContainer, directory: URL? = supportDirectory,
                        defaults: UserDefaults = .standard) throws {
        if let directory {
            let safety = try encode(makeBackup(container: container, directory: directory, defaults: defaults))
            let folder = directory.appendingPathComponent("backups", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try safety.write(to: folder.appendingPathComponent("恢复前自动保存 \(Int(Date().timeIntervalSince1970)).json"), options: .atomic)
        }

        let context = ModelContext(container)
        try context.delete(model: CatalogProduct.self)
        try context.delete(model: InventoryLot.self)
        try context.delete(model: FieldEvidence.self)
        try context.delete(model: InventoryEvent.self)
        try context.delete(model: PersonalProductTemplate.self)
        for p in backup.products {
            context.insert(CatalogProduct(id: p.id, canonicalName: p.canonicalName, brand: p.brand, categoryRawValue: p.categoryRawValue,
                                          barcode: p.barcode, defaultUnit: p.defaultUnit, typicalShelfLifeDays: p.typicalShelfLifeDays,
                                          postOpeningLifeDays: p.postOpeningLifeDays, createdAt: p.createdAt, updatedAt: p.updatedAt,
                                          revision: p.revision, isArchived: p.isArchived))
        }
        for l in backup.lots {
            let lot = InventoryLot(id: l.id, productID: l.productID, quantity: l.quantity, unit: l.unit, purchasedAt: l.purchasedAt,
                                   packageExpiryDate: l.packageExpiryDate, estimatedExpiryDate: l.estimatedExpiryDate,
                                   plannedUseByDate: l.plannedUseByDate, storageLocation: l.storageLocation,
                                   createdAt: l.createdAt, updatedAt: l.updatedAt, revision: l.revision)
            lot.stateRawValue = l.stateRawValue
            context.insert(lot)
        }
        for e in backup.evidence {
            let evidence = FieldEvidence(id: e.id, subjectKind: .lot, subjectID: e.subjectID, fieldKey: e.fieldKey,
                                         sourceKind: .userStated, confidence: e.confidence, capturedAt: e.capturedAt,
                                         rawText: e.rawText, localArtifactID: e.localArtifactID, operationID: e.operationID,
                                         confirmationReceiptID: e.confirmationReceiptID, valueSchemaVersion: e.valueSchemaVersion,
                                         valueJSON: e.valueJSON, createdAt: e.createdAt)
            evidence.subjectKindRawValue = e.subjectKindRawValue
            evidence.sourceKindRawValue = e.sourceKindRawValue
            evidence.verificationStateRawValue = e.verificationStateRawValue
            context.insert(evidence)
        }
        for e in backup.events {
            let event = InventoryEvent(id: e.id, operationID: e.operationID, subjectKind: .lot, subjectID: e.subjectID,
                                       eventTypeRawValue: e.eventTypeRawValue, actor: .user, occurredAt: e.occurredAt,
                                       payloadSchemaVersion: e.payloadSchemaVersion, payloadJSON: e.payloadJSON, createdAt: e.createdAt)
            event.subjectKindRawValue = e.subjectKindRawValue
            event.actorRawValue = e.actorRawValue
            context.insert(event)
        }
        for t in backup.templates {
            context.insert(PersonalProductTemplate(id: t.id, productID: t.productID, usualQuantity: t.usualQuantity,
                                                   defaultUnit: t.defaultUnit, defaultStorageLocation: t.defaultStorageLocation,
                                                   usualConsumptionDays: t.usualConsumptionDays, reminderLeadDays: t.reminderLeadDays,
                                                   repurchaseThreshold: t.repurchaseThreshold, createdAt: t.createdAt,
                                                   updatedAt: t.updatedAt, revision: t.revision))
        }
        try context.save()

        if let directory {
            for (key, name) in fileNames {
                let url = directory.appendingPathComponent(name)
                if let data = backup.files[key] {
                    try data.write(to: url, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        for key in settingKeys {
            guard let value = backup.settings[key] else { continue }
            switch key {
            case "expiryWarningDays", "reminderMinutes": if let number = Int(value) { defaults.set(number, forKey: key) }
            case "showSystemCalendar": defaults.set(value == "1" || value == "true", forKey: key)
            default: defaults.set(value, forKey: key)
            }
        }
    }
}

/// The backup as a document for the system "save to Files" sheet.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
