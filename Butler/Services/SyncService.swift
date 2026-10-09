import CloudKit
import Foundation
import SwiftData
import UIKit

@MainActor final class SyncService {
    static let shared = SyncService()
    private(set) var store: SyncStore?
    private(set) var chatStore: SyncStore?
    private(set) var photoStore: SyncStore?
    private(set) var setupWarning: String?
    private var job: Task<Void, Never>?
    private var accountObserver: NSObjectProtocol?
    private let sessions = NSHashTable<ChatSessions>.weakObjects()
    var isSyncingForBrief: Bool { job != nil || store?.busy == true || chatStore?.busy == true }
    private init() {}
    func attach(_ sessions: ChatSessions) { self.sessions.add(sessions) }
    func configure(container: ModelContainer) {
        guard store == nil else { return }
        do {
            let root = URL.applicationSupportDirectory.appendingPathComponent("DeviceSync", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var url = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            let local = ButlerSyncData(container: container, notes: try .openNotes(), tasks: .openOnDevice(),
                revisionFile: root.appendingPathComponent("local-revision.json"))
            store = SyncStore(file: root.appendingPathComponent("journal.json"), local: local, transport: CloudKitSyncTransport())
            // The household's shared things travel in their own zone; this device's own sync leaves them out.
            HouseholdService.shared.configure(container: container, base: local, root: root)
            if let directory = BackupService.supportDirectory {
                let isWorking: () -> Bool = { [weak self] in
                    guard let sessions = self?.sessions.allObjects, !sessions.isEmpty else { return true }
                    return sessions.contains { $0.working }
                }
                let chats = ChatSyncData(root: directory, isWorking: isWorking, didImport: { [weak self] scope in
                    self?.sessions.allObjects.forEach { $0.reloadSyncedHistory(scope) }
                })
                chatStore = SyncStore(file: root.appendingPathComponent("chat-journal.json"), local: chats,
                    transport: CloudKitSyncTransport(chatHistory: true), kinds: [.chat])
                do {
                    let journal = root.appendingPathComponent("photo-journal.json"), cache = root.appendingPathComponent("photo-cache.json")
                    guard !FileManager.default.fileExists(atPath: journal.path) || FileManager.default.fileExists(atPath: cache.path) else {
                        throw SyncFailure("图片接收记录缺失，不能当作图片被删除。")
                    }
                    let source = ButlerPhotoSource(container: container, root: directory, working: isWorking, didImport: { [weak self] in
                        self?.sessions.allObjects.forEach { $0.reloadSyncedPhotos() }
                    })
                    let photos = try PhotoSyncData(file: cache, source: source)
                    photoStore = SyncStore(file: journal, local: photos,
                        transport: CloudKitSyncTransport(photos: true), kinds: [.itemPhoto, .chatPhoto])
                } catch { setupWarning = "图片同步未准备好，未开启；原图片保留，普通资料同步不受影响。" }
            }
            accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
                Task { @MainActor in try? SyncService.shared.pause() }
            }
        } catch { setupWarning = "同步本地记录准备失败，未开启网络同步；原数据保留。" }
    }
    func pause() throws {
        job?.cancel(); job = nil
        // Attempt both even when one journal is unreadable.
        let main = Result { try store?.pause() }, chats = Result { try chatStore?.pause() }, photos = Result { try photoStore?.pause() }
        try main.get(); try chats.get(); try photos.get()
    }
    func prepareForRestore() throws {
        try pause()
        try store?.prepareForRestore(); try chatStore?.prepareForRestore(); try photoStore?.prepareForRestore()
    }

    /// Only already-enabled sources needed by the brief; no photo transfers or permission prompts.
    func refreshForBrief() async {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        await HouseholdService.shared.sync()
        guard let store, store.enabled, !store.busy, job == nil else { return }
        let refresh = Task { [weak self] in
            try? await store.synchronize()
            guard !Task.isCancelled, store.enabled else { return }
            if let chats = self?.chatStore, chats.enabled, !chats.busy { try? await chats.synchronize() }
        }
        job = refresh
        defer {
            job = nil
            NotificationCenter.default.post(name: .init("butlerBriefBatchFinished"), object: nil)
        }
        await withTaskCancellationHandler { await refresh.value } onCancel: { refresh.cancel() }
    }

    func foregroundTick() {
        if UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable {
            Task { await HouseholdService.shared.sync() }
        }
        guard UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
              let store, store.enabled, !store.busy, job == nil else { return }
        job = Task { [weak self] in
            defer {
                self?.job = nil
                NotificationCenter.default.post(name: .init("butlerBriefBatchFinished"), object: nil)
            }
            try? await store.synchronize()
            if store.enabled, let chats = self?.chatStore, chats.enabled, !chats.busy {
                try? await chats.synchronize()
            }
            if store.enabled, let photos = self?.photoStore, photos.enabled, !photos.busy {
                try? await photos.synchronize()
            }
        }
    }
}
