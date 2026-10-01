import Foundation

/// Called only inside the native security scope and file-coordination accessor.
nonisolated enum FolderFileIO {
    static func search(_ root: URL, query: String) throws -> FolderSearch {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey]
        var failed = false
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in failed = true; return false }) else {
            throw FolderFailure("无法列出文件夹。")
        }
        var paths: [String] = [], inspected = 0, truncated = false
        let prefix = root.standardizedFileURL.path + "/"
        while let child = iterator.nextObject() as? URL {
            try Task.checkCancellation()
            if inspected >= 500 || paths.count >= 100 { truncated = true; break }
            inspected += 1
            let info = try child.resourceValues(forKeys: Set(keys))
            if info.isSymbolicLink == true || info.isPackage == true { iterator.skipDescendants(); continue }
            guard child.standardizedFileURL.path.hasPrefix(prefix),
                  child.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                iterator.skipDescendants(); continue
            }
            if info.isRegularFile == true,
               query.isEmpty || child.lastPathComponent.localizedCaseInsensitiveContains(query) {
                paths.append(String(child.standardizedFileURL.path.dropFirst(prefix.count)))
            }
        }
        guard !failed else { throw FolderFailure("部分目录不可访问，本次查询未完成，请检查授权和网络。") }
        return FolderSearch(paths: paths.sorted(), inspected: inspected, truncated: truncated)
    }

    static func create(_ root: URL, export: FolderExport) throws {
        try export.validate()
        try Task.checkCancellation()
        let target = root.appendingPathComponent(export.filename, isDirectory: false)
        guard target.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw FolderFailure("文件路径超出授权目录。")
        }
        // Exclusive creation, not check-then-overwrite. Retain any partial failure for inspection.
        try Data(export.text.utf8).write(to: target, options: .withoutOverwriting)
    }
}
