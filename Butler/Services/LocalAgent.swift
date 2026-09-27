import Foundation
import Observation

/// Phone-owned memories. Free text is the default; a count is optional, not a category.
struct LocalMemory: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var text: String
    var quantity: Int?
    var revision: Int
}

struct LocalMemoryPreview: Equatable, Identifiable {
    var id: UUID
    var before: LocalMemory?
    var after: LocalMemory
    var sourceText: String
}

enum LocalAgentError: Error {
    case invalidArguments, missingMemory, expiredPreview, busy, toolLimit, conflictingCall
}

/// One instance owns one file. No network, account, or external host is involved.
@MainActor @Observable
final class LocalMemoryStore {
    private struct Snapshot: Codable {
        var records: [LocalMemory] = []
        var confirmed: [UUID] = []
    }

    private let file: URL
    private var snapshot: Snapshot
    private(set) var preview: LocalMemoryPreview?
    var records: [LocalMemory] { snapshot.records }

    init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            // A damaged store must surface an error, never silently become empty.
            snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        } else {
            snapshot = Snapshot()
        }
    }

    // No actor-bound cleanup. Avoid the iOS 26.2 isolated-deinit runtime crash
    // when released synchronously (swiftlang/swift#88036).
    nonisolated deinit { }

    static func openOnDevice() throws -> LocalMemoryStore {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return try LocalMemoryStore(file: directory.appendingPathComponent("agent-test-memory.json"))
    }

    func search(_ query: String) throws -> [LocalMemory] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw LocalAgentError.invalidArguments }
        return records.filter { ($0.title + "\n" + $0.text).localizedStandardContains(query) }
    }

    func propose(id: UUID?, title: String, text: String, quantity: Int?, source: String) throws -> LocalMemoryPreview {
        preview = nil
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 200, text.count <= 8000, quantity.map({ $0 >= 0 }) ?? true else {
            throw LocalAgentError.invalidArguments
        }
        let before = id.flatMap { id in records.first { $0.id == id } }
        if id != nil && before == nil { throw LocalAgentError.missingMemory }
        let after = LocalMemory(id: id ?? UUID(), title: title, text: text,
                                quantity: quantity, revision: (before?.revision ?? 0) + 1)
        let value = LocalMemoryPreview(id: UUID(), before: before, after: after, sourceText: source)
        preview = value
        return value
    }

    func setRemaining(id: UUID, quantity: Int, source: String) throws -> LocalMemoryPreview {
        preview = nil
        guard let before = records.first(where: { $0.id == id }) else { throw LocalAgentError.missingMemory }
        guard before.quantity != nil else { throw LocalAgentError.invalidArguments }
        return try propose(id: id, title: before.title, text: before.text, quantity: quantity, source: source)
    }

    func discard() { preview = nil }

    /// Saves a note the user already confirmed elsewhere (e.g. a batch confirm card).
    func upsert(_ memory: LocalMemory) throws {
        var next = snapshot
        if let index = next.records.firstIndex(where: { $0.id == memory.id }) {
            next.records[index] = memory
        } else {
            next.records.append(memory)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        snapshot = next
    }

    /// Re-reads the file, e.g. after restoring a backup.
    func reload() throws {
        snapshot = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file)) : Snapshot()
        preview = nil
    }

    func delete(_ id: UUID) throws {
        var next = snapshot
        next.records.removeAll { $0.id == id }
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        snapshot = next
    }

    /// The owner's real notes and habits (the file name is historical).
    static func openNotes() throws -> LocalMemoryStore { try openOnDevice() }

    func confirm(_ id: UUID) throws {
        if snapshot.confirmed.contains(id) { return }
        guard let preview, preview.id == id else { throw LocalAgentError.expiredPreview }
        var next = snapshot
        if let index = next.records.firstIndex(where: { $0.id == preview.after.id }) {
            next.records[index] = preview.after
        } else {
            next.records.append(preview.after)
        }
        next.confirmed.append(id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        // Publish to memory only after the full replacement is safely written.
        try data.write(to: file, options: .atomic)
        snapshot = next
        self.preview = nil
    }
}

struct LocalToolCall: Equatable {
    var id: String
    var name: String
    var arguments: String
}

struct LocalModelReply {
    var text: String
    var calls: [LocalToolCall]
    // Preserve opaque reasoning and complete tool-call items for cloud continuation.
    var wireOutput: Data? = nil
}

enum LocalAgentMessage {
    case user(String)
    /// A message with photos (JPEG), e.g. groceries, a receipt or a package label.
    case userPhotos(String, [Data])
    case assistant(LocalModelReply)
    case tool(id: String, result: String)
    case receipt(preview: UUID, saved: Bool)
    /// What the phone actually did (or that the owner cancelled), in plain words.
    case note(String)
    /// Background the phone supplies, e.g. the summary of older conversation.
    case context(String)
}

/// The cloud adapter handles authentication/transport only. It cannot access the store.
@MainActor
protocol LocalAgentModel {
    func reply(to messages: [LocalAgentMessage]) async throws -> LocalModelReply
}

/// A small tool loop, not a second model or an external Agent process.
@MainActor @Observable
final class LocalAgent {
    let memory: LocalMemoryStore
    private let model: any LocalAgentModel
    private(set) var messages: [LocalAgentMessage] = []
    private(set) var busy = false

    init(memory: LocalMemoryStore, model: any LocalAgentModel) {
        self.memory = memory
        self.model = model
    }

    func send(_ text: String) async throws -> String {
        guard !busy else { throw LocalAgentError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 8000 else {
            throw LocalAgentError.invalidArguments
        }
        busy = true
        defer { busy = false }
        memory.discard()
        let start = messages.count
        messages.append(.user(text))
        var completed: [String: (LocalToolCall, String)] = [:]
        do {
            // Bounds stop accidental endless tool requests, not user language.
            for _ in 0..<8 {
                try Task.checkCancellation()
                let reply = try await model.reply(to: messages)
                try Task.checkCancellation()
                guard reply.calls.count <= 8 else { throw LocalAgentError.toolLimit }
                messages.append(.assistant(reply))
                if reply.calls.isEmpty { return reply.text }
                for call in reply.calls {
                    guard !call.id.isEmpty else { throw LocalAgentError.invalidArguments }
                    let output: String
                    if let (previous, value) = completed[call.id] {
                        guard previous == call else { throw LocalAgentError.conflictingCall }
                        output = value
                    } else {
                        output = execute(call, source: text)
                        completed[call.id] = (call, output)
                    }
                    messages.append(.tool(id: call.id, result: output))
                }
            }
            throw LocalAgentError.toolLimit
        } catch {
            memory.discard()
            messages.removeSubrange(start...)
            throw error
        }
    }

    func confirm(_ id: UUID) throws {
        guard !busy else { throw LocalAgentError.busy }
        let pending = memory.preview?.id == id
        try memory.confirm(id)
        if pending { messages.append(.receipt(preview: id, saved: true)) }
    }

    func discard() throws {
        guard !busy else { throw LocalAgentError.busy }
        if let preview = memory.preview {
            memory.discard()
            messages.append(.receipt(preview: preview.id, saved: false))
        }
    }

    private func execute(_ call: LocalToolCall, source: String) -> String {
        struct Query: Decodable { var query: String }
        struct Write: Decodable { var id: UUID?; var title: String; var text: String; var quantity: Int? }
        struct Remaining: Decodable { var id: UUID; var quantity: Int }
        func encoded<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
        do {
            let data = Data(call.arguments.utf8)
            let decoder = JSONDecoder()
            switch call.name {
            case "search_memory":
                return try encoded(memory.search(decoder.decode(Query.self, from: data).query))
            case "propose_memory":
                let args = try decoder.decode(Write.self, from: data)
                _ = try memory.propose(id: args.id, title: args.title, text: args.text, quantity: args.quantity, source: source)
            case "set_remaining":
                let args = try decoder.decode(Remaining.self, from: data)
                _ = try memory.setRemaining(id: args.id, quantity: args.quantity, source: source)
            default:
                return "{\"error\":\"unknown_tool\"}"
            }
            return "{\"status\":\"awaiting_user_confirmation\",\"saved\":false}"
        } catch {
            memory.discard()
            return "{\"error\":\"invalid_arguments_or_missing_memory\",\"saved\":false}"
        }
    }
}
