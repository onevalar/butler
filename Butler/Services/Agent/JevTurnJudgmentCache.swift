import Foundation

/// Reuses only successful independent judgments within one active user turn.
/// Keys include the exact input, question and candidate. IDs only map answers back to callers.
@MainActor
final class JevTurnJudgmentCache {
    typealias Answers = [String: Double]

    private struct Key: Hashable {
        let request: String
        let question: String
        let candidate: String
    }

    private struct Flight {
        let batchID: UUID
        let answerID: String
        let task: Task<Answers, any Error>
    }

    private(set) var generation: UUID?
    private var configuration: UUID?
    private var successful: [Key: Double] = [:]
    private var flights: [Key: Flight] = [:]
    private let limit = 256

    nonisolated deinit {}

    func beginTurn() {
        invalidateConfiguration()
        generation = UUID()
    }

    func endTurn() {
        invalidateConfiguration()
        generation = nil
    }

    func invalidateConfiguration() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        successful.removeAll()
        configuration = nil
    }

    func judge(request: String, questions: [JevClient.Question], using judge: any ConditionJudge) async throws -> Answers {
        try Task.checkCancellation()
        guard judge.isAvailable else {
            invalidateConfiguration()
            throw judge.isEnabled ? JevClient.JevError.notConfigured : JevClient.JevError.disabled
        }
        guard !questions.isEmpty else { return [:] }
        var byID: [String: Key] = [:]
        for question in questions {
            let key = Key(request: request, question: question.question, candidate: question.candidate)
            guard byID[question.id] == nil || byID[question.id] == key else { throw JevClient.JevError.invalidResponse }
            byID[question.id] = key
        }
        // A judge without a settings generation cannot guarantee safe reuse after a toggle/key change.
        guard let generation, let token = judge.reuseToken else {
            invalidateConfiguration()
            let answers = try await judge.judge(request: request, questions: questions)
            try Task.checkCancellation()
            try Self.validate(answers, questions: questions)
            return answers
        }
        if configuration != token {
            invalidateConfiguration()
            configuration = token
        }

        var unanswered: [Key: JevClient.Question] = [:]
        for question in questions {
            let key = byID[question.id]!
            if successful[key] == nil, flights[key] == nil { unanswered[key] = question }
        }
        if !unanswered.isEmpty {
            let batchID = UUID()
            let requested = unanswered.values.sorted { $0.id < $1.id }
            let task = Task { @MainActor [weak self] () throws -> Answers in
                do {
                    try Task.checkCancellation()
                    guard self?.generation == generation, self?.configuration == token,
                          judge.isAvailable, judge.reuseToken == token else { throw CancellationError() }
                    let answers = try await judge.judge(request: request, questions: requested)
                    try Task.checkCancellation()
                    try Self.validate(answers, questions: requested)
                    return answers
                } catch {
                    // Never leave a failed/incomplete task available for the next request to reuse.
                    self?.removeFlights(batchID)
                    throw error
                }
            }
            for (key, question) in unanswered {
                flights[key] = Flight(batchID: batchID, answerID: question.id, task: task)
            }
        }

        var output: Answers = [:]
        var completedBatches: [UUID: Answers] = [:]
        // Capture flight references before suspension: a concurrent caller can finish and remove them.
        let needed = byID.mapValues { key -> (Double?, Flight?) in (successful[key], flights[key]) }
        for question in questions {
            let key = byID[question.id]!
            guard let (cached, flight) = needed[question.id] else { throw JevClient.JevError.invalidResponse }
            if let cached { output[question.id] = cached; continue }
            guard let flight else { throw JevClient.JevError.invalidResponse }
            let answers: Answers
            if let batch = completedBatches[flight.batchID] { answers = batch }
            else {
                answers = try await Self.awaitFlight(flight.task)
                completedBatches[flight.batchID] = answers
            }
            try Task.checkCancellation()
            guard self.generation == generation, self.configuration == token,
                  judge.isAvailable, judge.reuseToken == token else { throw CancellationError() }
            guard let answer = answers[flight.answerID] else { throw JevClient.JevError.invalidResponse }
            output[question.id] = answer
            // Another caller can be waiting on only one question from this batch.
            // Publish all validated answers before removing the shared flight, so
            // a third caller cannot accidentally submit its other questions again.
            rememberBatch(answers, batchID: flight.batchID)
            if successful[key] == nil {
                if successful.count >= limit { successful.removeAll(keepingCapacity: true) }
                successful[key] = answer
            }
        }
        for batchID in completedBatches.keys { removeFlights(batchID) }
        return output
    }

    private func removeFlights(_ batchID: UUID) {
        flights = flights.filter { $0.value.batchID != batchID }
    }

    private func rememberBatch(_ answers: Answers, batchID: UUID) {
        let completed = flights.filter { $0.value.batchID == batchID }
        if successful.count + completed.count > limit { successful.removeAll(keepingCapacity: true) }
        for (key, flight) in completed.prefix(limit) {
            if let answer = answers[flight.answerID] { successful[key] = answer }
        }
        removeFlights(batchID)
    }

    private static func validate(_ answers: Answers, questions: [JevClient.Question]) throws {
        guard questions.allSatisfy({ question in
            guard let value = answers[question.id] else { return false }
            return value.isFinite && (0...1).contains(value)
        }) else { throw JevClient.JevError.invalidResponse }
    }

    /// A cancelled caller stops waiting immediately, without cancelling another caller's shared query.
    /// The turn boundary cancels all remaining transport tasks.
    private static func awaitFlight(_ task: Task<Answers, any Error>) async throws -> Answers {
        let waiter = Waiter()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiter.continuation = continuation
                waiter.task = Task { @MainActor in
                    do { waiter.finish(.success(try await task.value)) }
                    catch { waiter.finish(.failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(.failure(CancellationError())) }
        }
    }

    private final class Waiter {
        var continuation: CheckedContinuation<Answers, any Error>?
        var task: Task<Void, Never>?
        private var finished = false
        nonisolated deinit {}

        func finish(_ result: Result<Answers, any Error>) {
            guard !finished else { return }
            finished = true
            let pending = continuation
            continuation = nil
            task?.cancel()
            task = nil
            pending?.resume(with: result)
        }
    }
}
