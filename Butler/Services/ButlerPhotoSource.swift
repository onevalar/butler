import Foundation
import SwiftData
import ImageIO

@MainActor final class ButlerPhotoSource: SyncPhotoSource {
    nonisolated deinit {}
    private let container: ModelContainer
    private let root: URL
    private let working: () -> Bool
    private let didImport: () -> Void
    init(container: ModelContainer, root: URL, working: @escaping () -> Bool, didImport: @escaping () -> Void) {
        self.container = container; self.root = root; self.working = working; self.didImport = didImport
    }
    private func turns() throws -> [UUID: (ChatScope, ChatTurn)] {
        guard !working() else { throw SyncFailure("对话结束后再同步图片，未改动当前附件。") }
        var result: [UUID: (ChatScope, ChatTurn)] = [:]
        for scope in try ChatSessionFiles.syncScopes(in: root) {
            let file = ChatSessionFiles(scope: scope, root: root).transcript
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            for turn in try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: file)) {
                guard result[turn.id] == nil else { throw SyncFailure("聊天编号重复，未同步图片。") }
                try SyncedChatTurn(scope: scope, turn: turn).validate()
                result[turn.id] = (scope, turn)
            }
        }
        return result
    }
    func photos() throws -> [SyncRecord.Key: SyncPhotoSourceValue] {
        let turns = try turns()
        var result: [SyncRecord.Key: SyncPhotoSourceValue] = [:]
        for lot in try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()) {
            let profile = try lot.profileData.map { try JSONDecoder().decode(ItemProfile.self, from: $0) }
            let bundle = profile?.photo.map { SyncPhotoBundle(scopeKey: nil, files: [.init(name: "image", data: $0)]) }
            let key = SyncRecord.Key(kind: .itemPhoto, id: lot.id)
            try bundle?.validate(for: key)
            for file in bundle?.files ?? [] { try validateImage(file.data) }
            result[key] = .init(bundle: bundle, incomplete: false)
        }
        for (id, pair) in turns {
            let (scope, turn) = pair, names = (turn.photos ?? []).sorted()
            guard !names.isEmpty else { continue }
            let directory = ChatSessionFiles(scope: scope, root: root).photos
            let files = try names.compactMap { name -> SyncPhotoBundle.File? in
                let url = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return .init(name: name, data: try Data(contentsOf: url))
            }
            let bundle = files.isEmpty ? nil : SyncPhotoBundle(scopeKey: scope.key, files: files)
            let key = SyncRecord.Key(kind: .chatPhoto, id: id)
            try bundle?.validate(for: key)
            for file in files { try validateImage(file.data) }
            result[key] = .init(bundle: bundle, incomplete: files.count != names.count)
        }
        return result
    }
    private func validateImage(_ data: Data) throws {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0, width.intValue <= 4096, height.intValue <= 4096 else {
            throw SyncFailure("图片文件损坏或尺寸超过4096像素，原图保留，未覆盖本机。")
        }
    }
    func apply(_ key: SyncRecord.Key, before: SyncPhotoBundle?, after: SyncPhotoBundle?) throws -> Bool {
        guard !working() else { throw SyncFailure("当前正在对话，稍后恢复图片导入。") }
        try before?.validate(for: key); try after?.validate(for: key)
        for file in after?.files ?? [] { try validateImage(file.data) }
        if key.kind == .itemPhoto {
            let context = ModelContext(container); context.autosaveEnabled = false
            guard let lot = try context.fetch(FetchDescriptor<InventoryLot>()).first(where: { $0.id == key.id }) else { return false }
            var profile = try lot.profileData.map { try JSONDecoder().decode(ItemProfile.self, from: $0) } ?? ItemProfile(category: .other)
            let old = before?.files.first?.data, new = after?.files.first?.data
            guard profile.photo == old || profile.photo == new else { throw SyncFailure("本机物品照片已被修改，未覆盖。") }
            if profile.photo != new {
                guard lot.revision < Int.max else { throw SyncFailure("物品版本无效。") }
                profile.photo = new; try profile.validate()
                lot.profileData = try SyncRecord.encode(profile); lot.revision += 1
                try context.save()
            }
        } else if key.kind == .chatPhoto {
            guard let (scope, turn) = try turns()[key.id] else { return false }
            guard before?.scopeKey == nil || before?.scopeKey == scope.key,
                  after?.scopeKey == nil || after?.scopeKey == scope.key else { throw SyncFailure("图片所属会话不匹配。") }
            guard Set(after?.files.map(\.name) ?? []).isSubset(of: Set(turn.photos ?? [])) else { return false }
            let directory = ChatSessionFiles(scope: scope, root: root).photos
            let old = Dictionary(uniqueKeysWithValues: (before?.files ?? []).map { ($0.name, $0.data) })
            let new = Dictionary(uniqueKeysWithValues: (after?.files ?? []).map { ($0.name, $0.data) })
            let names = Set(old.keys).union(new.keys)
            // Check every file before writing any; partial writes resume only matching values.
            for name in names {
                let url = directory.appendingPathComponent(name)
                let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
                guard current == old[name] || current == new[name] else { throw SyncFailure("本机聊天图片已修改，未覆盖。") }
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in names {
                let url = directory.appendingPathComponent(name)
                if let data = new[name] { try data.write(to: url, options: .atomic) }
                else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        } else { throw SyncFailure("不是图片同步记录。") }
        didImport()
        return true
    }
}
