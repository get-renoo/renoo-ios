import Foundation

/// What the SDK asks the client's purchase code to buy. Not used by this version of the SDK.
public struct PurchaseRequest: Sendable {
    public let productId: String
    public let offerId: String?
    public let accountToken: UUID
}

/// The only four results a purchase handler may return.
public enum PurchaseResult: String, Sendable {
    case purchased, cancelled, failed, pending
}

/// Client code that completes a discounted purchase. The SDK never buys anything itself.
public typealias PurchaseHandler = @Sendable (PurchaseRequest) async -> PurchaseResult

public struct Configuration {
    public enum LogLevel: Int, Sendable { case none = 0, error, info, debug }

    public enum TrackingScope: Sendable {
        /// Default. Only users with an active subscription or trial are tracked.
        case subscribersOnly
        /// Track everyone. For development and test apps only.
        case everyone
    }

    public var apiKey: String
    public var purchaseHandler: PurchaseHandler
    public var logLevel: LogLevel = .error
    public var trackingScope: TrackingScope = .subscribersOnly
    /// Capture UIKit screen views automatically.
    public var automaticScreenTracking = true
    /// Base URL of the ingest API, for example `https://ingest.example.com` (no path needed; a
    /// trailing slash is fine). The SDK posts events to `<ingestURL>/events/sdk`.
    /// `nil` (the default) means capture only: events stay on disk and nothing is sent.
    /// Must be `https`; an `http` URL disables uploading unless `allowInsecureHTTP` is on.
    public var ingestURL: URL?
    /// Debug only, for a local API: accept an `http://` `ingestURL`. Never ship it turned on.
    public var allowInsecureHTTP = false

    public init(apiKey: String, purchaseHandler: @escaping PurchaseHandler) {
        self.apiKey = apiKey
        self.purchaseHandler = purchaseHandler
    }

    var isValid: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
