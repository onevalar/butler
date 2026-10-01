import Foundation

@MainActor final class AppleFolderDevice: FolderDevice {
    static let store: AuthorizedFolderStore = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AuthorizedFolderStore(file: root.appendingPathComponent("device-file-access/state.json"), device: AppleFolderDevice())
    }()

    func grant(_ url: URL) throws -> FolderGrant {
        guard url.startAccessingSecurityScopedResource() else { throw FolderFailure("未获得文件夹访问权，请重新选择。") }
        defer { url.stopAccessingSecurityScopedResource() }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw FolderFailure("请选择普通文件夹，不支持符号链接。") }
        return FolderGrant(id: UUID(), name: url.lastPathComponent,
            bookmark: try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    func search(_ grant: FolderGrant, query: String) async throws -> FolderSearch {
        let task = Task.detached(priority: .userInitiated) {
            try Self.access(grant, writing: false) { root in
                try FolderFileIO.search(root, query: query)
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func create(_ grant: FolderGrant, export: FolderExport) async throws {
        let task = Task.detached(priority: .userInitiated) {
            try export.validate()
            try Self.access(grant, writing: true) { root in
                try FolderFileIO.create(root, export: export)
            }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private nonisolated static func access<T>(_ grant: FolderGrant, writing: Bool, body: @escaping (URL) throws -> T) throws -> T {
        try Task.checkCancellation()
        var stale = false
        let root = try URL(resolvingBookmarkData: grant.bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, root.startAccessingSecurityScopedResource() else {
            throw FolderFailure("文件夹授权失效，请重新选择；未自动扩大权限。")
        }
        defer { root.stopAccessingSecurityScopedResource() }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        let action: (URL) -> Void = { url in
            result = Result {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw FolderFailure("授权目录已变化，请重新选择。") }
                return try body(url)
            }
        }
        if writing { coordinator.coordinate(writingItemAt: root, options: .forMerging, error: &coordinationError, byAccessor: action) }
        else { coordinator.coordinate(readingItemAt: root, options: [], error: &coordinationError, byAccessor: action) }
        if let coordinationError { throw coordinationError }
        guard let result else { throw FolderFailure("文件提供商未完成协调，请稍后重新查询。") }
        return try result.get()
    }
}
