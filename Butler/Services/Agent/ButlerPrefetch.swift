import Foundation

/// Prepares only current read-only data. The main model keeps every tool and can fetch more.
@MainActor
enum ButlerPrefetch {
    static func prepare(request: String, previousQuestion: String? = nil, previousAnswer: String? = nil,
                        hasPhotos: Bool = false, enabled: Bool, tools: ButlerTools,
                        timeout: Duration = .seconds(1.5),
                        log: (String) -> Void = ChatDiagnostics.log) async throws -> [PrefetchedToolResult] {
        try Task.checkCancellation()
        guard enabled else {
            log("prefetch status=disabled")
            return []
        }
        let started = Date.now
        let plan = try await JevPrefetchPlanner.plan(request: request, previousQuestion: previousQuestion,
            previousAnswer: previousAnswer, hasPhotos: hasPhotos, judge: tools.jev, timeout: timeout)
        try Task.checkCancellation()
        let results: [PrefetchedToolResult]
        do {
            results = try await tools.prefetch(inventory: plan.inventory, notes: plan.notes)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            log("prefetch status=read_failed")
            return []
        }
        try Task.checkCancellation()
        // Diagnostics contain timings and coverage only, never record contents or user messages.
        let bytes = results.reduce(0) { $0 + $1.output.utf8.count }
        log("prefetch status=\(plan.status) inventory=\(plan.inventory) notes=\(plan.notes) judge=\(String(format: "%.3f", plan.elapsedSeconds))s total=\(String(format: "%.3f", Date.now.timeIntervalSince(started)))s tools=\(results.count) bytes=\(bytes)")
        return results
    }
}
