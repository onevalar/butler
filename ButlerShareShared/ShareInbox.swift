import Foundation

/// Only this transport inbox is shared. The app's database stays in its existing container.
nonisolated struct ShareInbox {
    static let groupID = "group.com.anvalar.Butler.share"
    static let maxFiles = 8
    static let maxFileBytes = 20 * 1024 * 1024
    static let maxTotalBytes = 40 * 1024 * 1024
    static let maxTextCharacters = 20_000
    let root: URL

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    struct Attachment: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let name: String
        let type: String
        let bytes: Int
        var filename: String { id.uuidString }
    }
    struct Record: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let createdAt: Date
        let text: String
        let attachments: [Attachment]

        func validate() throws {
            guard text.count <= ShareInbox.maxTextCharacters,
                  attachments.count <= ShareInbox.maxFiles,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
                  Set(attachments.map(\.id)).count == attachments.count,
                  attachments.allSatisfy({ $0.bytes > 0 && $0.bytes <= ShareInbox.maxFileBytes
                      && $0.name.count <= 200 && !$0.type.isEmpty && $0.type.utf8.count <= 200 }) else {
                throw Failure("分享记录为空、重复或超过允许范围，原件保留，未导入。")
            }
            // Sum only bounded values, including when metadata came from disk.
            guard attachments.reduce(0, { $0 + $1.bytes }) <= ShareInbox.maxTotalBytes else {
                throw Failure("分享附件总计超过40 MB，原件保留，未导入。")
            }
        }
    }
    struct Listing {
        var records: [Record] = []
        var unreadableCount = 0
    }

    #if os(iOS)
    static func onDevice() throws -> Self {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw Failure("分享收件箱不可用，请检查 App Group 签名配置。原内容仍在来源 App 中。")
        }
        return Self(root: container.appendingPathComponent("ShareInbox", isDirectory: true))
    }
    #endif

    /// Each invocation owns a unique staging folder. Readers see only atomically published records.
    func begin(id: UUID) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: directory(id).path),
              !FileManager.default.fileExists(atPath: staging(id).path) else {
            throw Failure("这次分享已保存或正在处理，请勿重复提交。")
        }
        try FileManager.default.createDirectory(at: staging(id), withIntermediateDirectories: false)
    }

    /// Must run inside NSItemProvider's file callback, before its temporary URL expires.
    func copyFile(_ source: URL, name: String, type: String, id: UUID, existing: [Attachment]) throws -> Attachment {
        var currentSource = source
        currentSource.removeAllCachedResourceValues()
        let values = try currentSource.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw Failure("不支持文件夹或链接文件，请分享其中的文件。")
        }
        let bytes = values.fileSize ?? 0
        guard bytes > 0, bytes <= Self.maxFileBytes, existing.count < Self.maxFiles,
              existing.reduce(bytes, { $0 + $1.bytes }) <= Self.maxTotalBytes else {
            throw Failure("每次最多8个附件，单个不超过20 MB，总计不超过40 MB；不支持空文件。")
        }
        let file = Attachment(id: UUID(), name: String(name.prefix(200)), type: type, bytes: bytes)
        let destination = staging(id).appendingPathComponent(file.filename)
        try FileManager.default.copyItem(at: source, to: destination)
        // A provider can change a file while it is copied. Never publish an oversized result.
        let copied = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard copied == bytes else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure("来源文件在读取时发生变化，请重新分享。")
        }
        return file
    }

    func publish(id: UUID, text: String, attachments: [Attachment]) throws -> Record {
        guard text.count <= Self.maxTextCharacters, attachments.count <= Self.maxFiles,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            throw Failure("分享内容为空或超过20000字，请缩短后再试。")
        }
        let record = Record(id: id, createdAt: .now, text: text, attachments: attachments)
        try record.validate()
        for file in attachments {
            _ = try checkedFile(file, folder: staging(id))
        }
        try JSONEncoder().encode(record).write(to: staging(id).appendingPathComponent("record.json"), options: .atomic)
        try FileManager.default.moveItem(at: staging(id), to: directory(id))
        return record
    }

    func cancel(id: UUID) { try? FileManager.default.removeItem(at: staging(id)) }

    /// A picker batch is published once, only after every original has been copied.
    func importFiles(_ sources: [(url: URL, type: String)], id: UUID) throws -> Record {
        guard !sources.isEmpty, sources.count <= Self.maxFiles,
              Set(sources.map { $0.url.standardizedFileURL }).count == sources.count else {
            throw Failure("每次请选择1至8个不同文件，未保存本次选择。")
        }
        try Task.checkCancellation()
        try begin(id: id)
        do {
            var attachments: [Attachment] = []
            for source in sources {
                try Task.checkCancellation()
                #if os(iOS)
                let scoped = source.url.startAccessingSecurityScopedResource()
                defer { if scoped { source.url.stopAccessingSecurityScopedResource() } }
                #endif
                attachments.append(try copyFile(source.url, name: source.url.lastPathComponent,
                    type: source.type, id: id, existing: attachments))
            }
            try Task.checkCancellation()
            return try publish(id: id, text: "从文件选择器导入的资料（原件保留）", attachments: attachments)
        } catch {
            cancel(id: id)
            throw error
        }
    }

    func list() throws -> Listing {
        guard FileManager.default.fileExists(atPath: root.path) else { return Listing() }
        var result = Listing()
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do {
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure("分享目录无效") }
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: folder.appendingPathComponent("record.json")))
                guard record.id == id else { throw Failure("分享记录编号不一致") }
                try record.validate()
                for attachment in record.attachments { _ = try fileURL(attachment, in: record) }
                result.records.append(record)
            } catch { result.unreadableCount += 1 }
        }
        result.records.sort { $0.createdAt < $1.createdAt }
        return result
    }

    func fileURL(_ attachment: Attachment, in record: Record) throws -> URL {
        try record.validate()
        guard record.attachments.contains(attachment) else { throw Failure("附件不属于这条分享") }
        return try checkedFile(attachment, folder: directory(record.id))
    }

    private func checkedFile(_ attachment: Attachment, folder: URL) throws -> URL {
        let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true else {
            throw Failure("分享目录无效，未读取外部文件。")
        }
        let url = folder.appendingPathComponent(attachment.filename)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == attachment.bytes else {
            throw Failure("分享原件缺失或已损坏，未覆盖原记录。")
        }
        return url
    }

    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func staging(_ id: UUID) -> URL { root.appendingPathComponent(".receiving-" + id.uuidString, isDirectory: true) }
}
