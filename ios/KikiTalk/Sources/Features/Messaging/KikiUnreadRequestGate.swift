import Foundation

/// Prevents an older inbox fetch from restoring a badge after a read operation.
struct KikiUnreadRequestGate {
    struct Fetch {
        fileprivate let revision: UInt
        fileprivate let id: UUID
    }
    private var revision: UInt = 0
    private var latestFetch = UUID()
    private var mutations: Set<UUID> = []
    var hasPendingMutation: Bool { !mutations.isEmpty }

    mutating func beginFetch() -> Fetch {
        latestFetch = UUID()
        return Fetch(revision: revision, id: latestFetch)
    }
    func accepts(_ fetch: Fetch) -> Bool {
        !hasPendingMutation && fetch.revision == revision && fetch.id == latestFetch
    }
    mutating func beginMutation() -> UUID {
        revision &+= 1
        let id = UUID(); mutations.insert(id)
        return id
    }
    mutating func finishMutation(_ id: UUID) {
        guard mutations.remove(id) != nil else { return }
        revision &+= 1
    }
}
