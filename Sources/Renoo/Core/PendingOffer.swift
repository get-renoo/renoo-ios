import Foundation

/// An offer the backend is holding for the current user, as returned by `GET /offers`.
/// The content is a free-form JSON object for now; the SDK does not render it.
public struct PendingOffer: Equatable, Sendable {
    /// The offer object exactly as the API returned it.
    public let json: [String: JSONValue]

    public init(json: [String: JSONValue]) {
        self.json = json
    }
}

/// Token returned by `Renoo.addPendingOfferObserver`; pass it to `removePendingOfferObserver`.
public struct PendingOfferObserverToken: Hashable, Sendable {
    let id = UUID()
}

/// Called on the main actor with the current pending offer, or `nil` when there is none.
public typealias PendingOfferObserver = @MainActor @Sendable (PendingOffer?) -> Void

/// Holds the pending offer and tells observers when it changes. Safe from any thread.
///
/// Observers run on the main actor (the offer is for UI), in the order the changes happened:
/// every notification is dispatched to the main queue while the lock is held.
final class PendingOfferStore: @unchecked Sendable {
    private let lock = NSLock()
    private var offer: PendingOffer?
    private var observers: [PendingOfferObserverToken: PendingOfferObserver] = [:]

    var current: PendingOffer? {
        lock.lock()
        defer { lock.unlock() }
        return offer
    }

    /// Replaces the offer. Observers hear about it only if it changed.
    func set(_ newValue: PendingOffer?) {
        lock.lock()
        defer { lock.unlock() }
        guard newValue != offer else { return }
        offer = newValue
        for handler in observers.values { Self.deliver(newValue, to: handler) }
    }

    /// The handler gets the current value straight away, then every change.
    func addObserver(_ handler: @escaping PendingOfferObserver) -> PendingOfferObserverToken {
        let token = PendingOfferObserverToken()
        lock.lock()
        defer { lock.unlock() }
        observers[token] = handler
        Self.deliver(offer, to: handler)
        return token
    }

    func removeObserver(_ token: PendingOfferObserverToken) {
        lock.lock()
        defer { lock.unlock() }
        observers[token] = nil
    }

    private static func deliver(_ offer: PendingOffer?, to handler: @escaping PendingOfferObserver) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(offer) }
        }
    }
}
