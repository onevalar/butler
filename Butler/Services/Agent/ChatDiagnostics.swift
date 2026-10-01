import Foundation

/// A short local log of how each conversation turn went (steps, timings, errors), so a failure can be
/// explained afterwards. Stays in the app's own folder on the phone; never sent anywhere.
enum ChatDiagnostics {
    nonisolated private static let limit = 200_000
    nonisolated private static let writer = DispatchQueue(label: "butler.diagnostics", qos: .utility)

    nonisolated static var url: URL? {
        BackupService.supportDirectory?.appendingPathComponent("butler-diagnostics.log")
    }

    nonisolated static func log(_ line: String) {
        guard let url else { return }
        log(line, to: url)
    }

    /// One queue owns the entire append/rotation transaction. Callers (including
    /// audio callbacks) never wait for disk I/O. The destination also permits isolated tests.
    nonisolated static func log(_ line: String, to url: URL) {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        let data = Data("\(stamp) \(line)\n".utf8)
        writer.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                if let size = try? handle.seekToEnd(), size + UInt64(data.count) > limit {
                    // Keep the newer half, starting at a complete line (valid UTF-8).
                    if let old = try? Data(contentsOf: url) {
                        let tail = old.suffix(limit / 2)
                        let kept = tail.firstIndex(of: 10).map { tail.suffix(from: tail.index(after: $0)) } ?? Data()
                        try? (kept + data).write(to: url, options: .atomic)
                    }
                    return
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// What kind of error this was, in a form worth logging.
    nonisolated static func describe(_ error: Error) -> String {
        if let url = error as? URLError { return "URLError \(url.code.rawValue) \(url.code)" }
        let ns = error as NSError
        // A service's description may echo credentials or request contents.
        return "\(type(of: error)) \(ns.domain) \(ns.code)"
    }
}
