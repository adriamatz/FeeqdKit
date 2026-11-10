import Foundation

/// Something the user wrote that could not go out: kept on the device and sent on its own later,
/// always with `id` as its Idempotency-Key, so a server that already stored it answers with
/// what it stored instead of storing it again.
package struct PendingWrite: Codable, Equatable, Identifiable, Sendable {
    package enum Kind: Codable, Equatable, Sendable {
        case request(boardID: String, title: String, description: String)
        case comment(boardID: String, entryID: String, content: String, parentID: String?)
        /// `conversationID` is where it was going, `nil` when it was starting one: the key names
        /// the same write only on the same route. `context` is the app's, when this was the
        /// first message of a visit; the device's part is read again when it goes out.
        case chatMessage(body: String, conversationID: String?, context: [String: String]? = nil)
    }

    package let id: String
    package let kind: Kind
    package let createdAt: Date

    package init(id: String = UUID().uuidString, kind: Kind, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
    }

    /// Past this it is dropped unsent: what someone wrote a week ago is no longer what they
    /// would send. The server remembers a key for longer than this.
    package static let maxAge: TimeInterval = 7 * 24 * 3600

    package func isExpired(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) > Self.maxAge
    }
}

/// The pending writes, in the order they were written, in a file that outlives the app.
package actor Outbox {
    /// More than this and the oldest goes: a device offline for days should not pile up.
    package static let capacity = 50

    private let fileURL: URL?
    private var writes: [PendingWrite]

    /// `nil` keeps them in memory only.
    package init(fileURL: URL?) {
        self.fileURL = fileURL
        writes = fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([PendingWrite].self, from: $0) } ?? []
    }

    /// `Application Support/FeeqdKit/pending-writes.json`, outside what the user sees in Files.
    package static var onDisk: Outbox {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return Outbox(fileURL: base?.appendingPathComponent("FeeqdKit/pending-writes.json"))
    }

    package func all() -> [PendingWrite] { writes }

    package func add(_ write: PendingWrite) {
        guard !writes.contains(where: { $0.id == write.id }) else { return }
        writes.append(write)
        if writes.count > Self.capacity { writes.removeFirst(writes.count - Self.capacity) }
        save()
    }

    package func remove(id: String) {
        writes.removeAll { $0.id == id }
        save()
    }

    package func clear() {
        writes = []
        save()
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var options: Data.WritingOptions = .atomic
            #if os(iOS)
            // What the user wrote: readable once the device was unlocked after a restart.
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try JSONEncoder().encode(writes).write(to: fileURL, options: options)
        } catch {}
    }
}
