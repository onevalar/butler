import Foundation

nonisolated struct FolderFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

nonisolated struct FolderGrant: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let bookmark: Data
}

nonisolated struct FolderExport: Codable, Equatable {
    let folderID: UUID
    let filename: String
    let text: String

    func validate() throws {
        guard !filename.isEmpty, filename.utf8.count <= 180, !filename.hasPrefix("."),
              !filename.contains("/"), !filename.contains("\\"), !filename.contains(":"),
              filename == filename.trimmingCharacters(in: .whitespacesAndNewlines),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ["txt", "md", "csv"].contains((filename as NSString).pathExtension.lowercased()),
              !text.isEmpty, text.utf8.count <= 20_000 else {
            throw FolderFailure("文件名须为普通名称并以 txt、md 或 csv 结尾；内容需为1–20000字节，不能指定路径。")
        }
        // Prevent spreadsheet programs from interpreting exported fields as formulas.
        if (filename as NSString).pathExtension.lowercased() == "csv" {
            guard !text.contains(where: { "=+@\t\r".contains($0) }),
                  !text.split(whereSeparator: { $0 == "," || $0 == "\n" }).contains(where: {
                      $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).hasPrefix("-")
                  }) else {
                throw FolderFailure("CSV含可能被表格软件当作公式的内容；请改为txt或md保存，或生成不含公式的CSV。")
            }
        }
    }
}

nonisolated enum FolderChange: Codable, Equatable {
    case authorize
    case revoke(UUID)
    case export(FolderExport)
}

nonisolated struct FolderSearch: Codable {
    let paths: [String]
    let inspected: Int
    let truncated: Bool
}

@MainActor protocol FolderDevice {
    func grant(_ url: URL) throws -> FolderGrant
    func search(_ grant: FolderGrant, query: String) async throws -> FolderSearch
    func create(_ grant: FolderGrant, export: FolderExport) async throws
}

/// Local grants and consumed write IDs are never part of chat backup or cloud sync.
@MainActor final class AuthorizedFolderStore {
    nonisolated struct Write: Codable, Identifiable {
        let id: UUID
        let folderID: UUID
        let filename: String
        let date: Date
        var completed: Bool
    }
    private struct State: Codable {
        var grants: [FolderGrant] = []
        var writes: [Write] = []
    }
    private var state = State()
    private let file: URL
    private let device: any FolderDevice
    private var loadError = false
    private var busy = false

    init(file: URL, device: any FolderDevice) {
        self.file = file; self.device = device
        do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
        catch {
            let error = error as NSError
            loadError = error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError
        }
    }

    func grants() throws -> [FolderGrant] { try readable(); return state.grants }
    func writes() throws -> [Write] { try readable(); return state.writes }

    private func readable() throws {
        guard !loadError else { throw FolderFailure("文件夹授权记录损坏，已停止访问，原记录保留。") }
    }

    private func save(_ next: State) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        state = next
    }

    func authorize(_ url: URL) throws -> FolderGrant {
        try readable()
        guard !busy else { throw FolderFailure("文件操作正在执行，请稍后授权。") }
        let grant = try device.grant(url)
        var next = state
        guard next.grants.count < 20 else { throw FolderFailure("最多授权20个文件夹，请先撤销不再使用的授权。") }
        next.grants.append(grant)
        try save(next)
        return grant
    }

    func revoke(_ id: UUID) throws {
        try readable()
        // No await: revocation invalidates new work; an in-flight system write may finish.
        var next = state
        next.grants.removeAll { $0.id == id }
        try save(next)
    }

    func grant(_ id: UUID) throws -> FolderGrant {
        try readable()
        guard let grant = state.grants.first(where: { $0.id == id }) else {
            throw FolderFailure("文件夹未授权或授权已撤销，请重新选择；旧提案不能使用新授权。")
        }
        return grant
    }

    func search(_ id: UUID, query: String) async throws -> FolderSearch {
        guard query.count <= 120 else { throw FolderFailure("请缩短文件名关键词。") }
        let grant = try grant(id)
        try Task.checkCancellation()
        let result = try await device.search(grant, query: query)
        try Task.checkCancellation()
        _ = try self.grant(id)
        return result
    }

    func export(_ value: FolderExport, operationID: UUID) async throws -> String {
        try readable(); try value.validate()
        guard !busy else { throw FolderFailure("文件正在保存，请等待结果；没有开始本次写入。") }
        if let old = state.writes.first(where: { $0.id == operationID }) {
            guard old.completed else { throw FolderFailure("该操作曾开始，结果待核查；不会自动重试，请检查目标文件。") }
            return "该操作已保存，不重复写入。"
        }
        let grant = try grant(value.folderID)
        try Task.checkCancellation()
        busy = true
        defer { busy = false }
        var next = state
        next.writes.append(Write(id: operationID, folderID: value.folderID, filename: value.filename, date: .now, completed: false))
        try save(next) // Consume the operation durably before handing it to the file provider.
        do {
            try await device.create(grant, export: value)
            next = state // A revocation while awaiting must not be undone.
            next.writes[next.writes.firstIndex(where: { $0.id == operationID })!].completed = true
            try save(next)
            return "已新增文件：\(grant.name)/\(value.filename)。未覆盖或删除其他文件；文件提供商的跨设备同步尚未核实。"
        } catch {
            throw FolderFailure("保存未能完整核实（可能未创建，也可能已有部分或完整文件）；不会自动重试。请检查 \(grant.name)/\(value.filename)。\(error is CancellationError ? "操作已停止。" : "请核对同名文件、目录权限及文件提供商状态。")")
        }
    }
}
