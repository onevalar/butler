import Foundation

/// A short local log of how each conversation turn went (steps, timings, errors), so a failure can be
/// explained afterwards. Stays in the app's own folder on the phone; never sent anywhere.
enum ChatDiagnostics {
    private static let limit = 200_000

    nonisolated static var url: URL? {
        BackupService.supportDirectory?.appendingPathComponent("butler-diagnostics.log")
    }

    nonisolated static func log(_ line: String) {
        guard let url else { return }
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size > limit {
                // Keep the newer half.
                try? handle.close()
                if let old = try? Data(contentsOf: url) {
                    try? (old.suffix(limit / 2) + data).write(to: url, options: .atomic)
                }
                return
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// What kind of error this was, in a form worth logging.
    nonisolated static func describe(_ error: Error) -> String {
        if let url = error as? URLError { return "URLError \(url.code.rawValue) \(url.code)" }
        let ns = error as NSError
        return "\(type(of: error)) \(ns.domain) \(ns.code): \(error.localizedDescription)"
    }
}
