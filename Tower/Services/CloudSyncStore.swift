import Foundation

protocol CloudSnapshotSyncing: Sendable {
    var isAccountAvailable: Bool { get }
    func download() async throws -> AppSnapshot?
    func upload(_ snapshot: AppSnapshot) async throws
    func removeRemoteSnapshot() async throws
    func commit(_ snapshot: AppSnapshot, replacing expected: AppSnapshot?) async throws
    func compact() async throws
    func recoveryCopies() async throws -> [CloudRecoveryCopy]
    func resolveConflict(with snapshot: AppSnapshot) async throws
}

extension CloudSnapshotSyncing {
    /// Trims old versions without writing a new one.
    func compact() async throws {}
    func recoveryCopies() async throws -> [CloudRecoveryCopy] { [] }
    func resolveConflict(with snapshot: AppSnapshot) async throws { try await upload(snapshot) }
}

enum CloudSyncError: LocalizedError, Equatable {
    case unavailable
    case noRemoteSnapshot
    case downloading
    case conflict

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "iCloud 不可用，请检查系统设置里的 iCloud 云盘是否开启")
        case .downloading:
            String(localized: "iCloud 配置尚未下载完成，请稍后重试")
        case .conflict:
            String(localized: "同步冲突，已保留双方配置。请从备份中选择要恢复的版本。")
        case .noRemoteSnapshot: String(localized: "iCloud 上还没有配置")
        }
    }
}

/// The legacy document is read for migration only. New writes are immutable
/// journal commits, so simultaneous devices cannot destroy each other's version.
actor CloudSyncStore: CloudSnapshotSyncing {
    static let containerIdentifier = "iCloud.com.jzb.tower"
    private static let fileName = "state.json"

    private let containerID: String?
    private let fileURLOverride: URL?
    private let removeItem: (URL) throws -> Void
    private nonisolated let accountAvailableOverride: Bool?

    init(containerIdentifier: String? = CloudSyncStore.containerIdentifier) {
        self.containerID = TowerTestIsolation.isEnabled ? nil : containerIdentifier
        self.fileURLOverride = TowerTestIsolation.isEnabled ? TowerTestIsolation.directory.appendingPathComponent("cloud.json") : nil
        self.removeItem = { try FileManager.default.removeItem(at: $0) }
        self.accountAvailableOverride = nil
    }

    /// Local file injection keeps the coordination and encoding paths under
    /// test without requiring the test runner to own an iCloud container.
    init(
        fileURL: URL,
        isAccountAvailable: Bool = true,
        removeItem: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.containerID = nil
        self.fileURLOverride = fileURL
        self.removeItem = removeItem
        self.accountAvailableOverride = isAccountAvailable
    }

    /// Whether the device has an iCloud account Tower can write to.
    ///
    /// Signing out of iCloud leaves the identity token nil, which is the only
    /// check that does not block on the network.
    nonisolated var isAccountAvailable: Bool {
        if let accountAvailableOverride { return accountAvailableOverride }
        return FileManager.default.ubiquityIdentityToken != nil
    }

    /// Resolving the container touches the file system and can be slow the
    /// first time, so it never runs on the main actor.
    private func documentsURL() throws -> URL {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else {
            throw CloudSyncError.unavailable
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    private func fileURL() throws -> URL {
        if let fileURLOverride { return fileURLOverride }
        return try documentsURL().appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private func journal() throws -> CloudSnapshotJournal {
        let url = try fileURL()
        return CloudSnapshotJournal(directory: url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-versions-v2", isDirectory: true))
    }

    func upload(_ snapshot: AppSnapshot) async throws {
        let current = try download()
        try await commit(snapshot, replacing: current)
    }

    func compact() async throws {
        try Task.checkCancellation()
        let journal = try journal()
        guard !(try journal.commits()).isEmpty else { return }
        try journal.prune()
    }

    func commit(_ snapshot: AppSnapshot, replacing expected: AppSnapshot?) async throws {
        try Task.checkCancellation()
        let journal = try journal()
        let records = try journal.commits()
        let current = try records.isEmpty ? legacyDownload() : journal.snapshot(records)
        guard CloudSnapshotMerge.equal(current, expected) else { throw CloudSyncError.conflict }
        if !records.isEmpty, journal.heads(records).count == 1, CloudSnapshotMerge.equal(snapshot, current) { try journal.prune(); return }
        var parents = journal.heads(records)
        if records.isEmpty, let current {
            try journal.append(current, parents: [])
            parents = journal.heads(try journal.commits())
        }
        // Other devices can append concurrently; both branches remain available.
        try journal.append(snapshot, parents: parents)
        try journal.prune()
    }

    func recoveryCopies() async throws -> [CloudRecoveryCopy] {
        let history = try journal()
        try history.prune()
        let records = try history.commits()
        var copies = records.values.compactMap { record in record.snapshot.map { CloudRecoveryCopy(id: record.id, snapshot: $0) } }
        if records.isEmpty, let legacy = try legacyDownload() { copies.append(CloudRecoveryCopy(id: "legacy", snapshot: legacy)) }
        return copies.sorted { ($0.snapshot.updatedAt ?? .distantPast) > ($1.snapshot.updatedAt ?? .distantPast) }
    }

    func resolveConflict(with snapshot: AppSnapshot) async throws {
        let journal = try journal()
        try journal.append(snapshot, parents: journal.heads(try journal.commits()))
        try journal.prune()
    }

    func download() throws -> AppSnapshot? {
        let records = try journal().commits()
        return try records.isEmpty ? legacyDownload() : journal().snapshot(records)
    }

    /// The snapshot stored in iCloud, or nil when there is none yet.
    private func legacyDownload() throws -> AppSnapshot? {
        let url = try fileURL()

        // A file that exists in the container may not be on this device yet;
        // asking for it starts the transfer.
        if !FileManager.default.fileExists(atPath: url.path) {
            let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
            if FileManager.default.fileExists(atPath: placeholder.path) {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                throw CloudSyncError.downloading
            }
            return nil
        }

        try CloudSnapshotJournal.requireDownloaded(url)
        var coordinationError: NSError?
        var result: Result<AppSnapshot?, Error> = .success(nil)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            do {
                let data = try Data(contentsOf: target)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                result = .success(try decoder.decode(AppSnapshot.self, from: data))
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    func removeRemoteSnapshot() throws {
        let url = try fileURL()
        let history = try journal().directory
        if FileManager.default.fileExists(atPath: history.path) { try removeItem(history) }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordinationError: NSError?
        var removalError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do {
                try removeItem(target)
            } catch {
                removalError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let removalError { throw removalError }
    }
}

/// Which of two snapshots is the one to keep.
///
/// Split out from the store so the rule can be tested without an iCloud
/// account, and so there is exactly one place that decides it.
enum CloudSyncResolution: Equatable {
    case keepLocal
    case takeRemote

    /// A snapshot written before sync existed carries no date. It loses to any
    /// dated one, because it cannot have been the newer edit made on another
    /// device — sync did not exist when it was written.
    static func resolve(local: Date?, remote: Date?) -> CloudSyncResolution {
        switch (local, remote) {
        case (_, nil): .keepLocal
        case (nil, _): .takeRemote
        case let (localDate?, remoteDate?): remoteDate > localDate ? .takeRemote : .keepLocal
        }
    }
}
