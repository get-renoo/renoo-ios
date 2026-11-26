import Foundation

/// Names of every event the SDK emits. Schema version 1.
public enum EventName: String, Codable, Sendable, CaseIterable {
    case install
    case appOpen = "app_open"
    case appBackground = "app_background"
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case uncleanExit = "unclean_exit"
    case screenView = "screen_view"
    case subscriptionState = "subscription_state"
    case transaction
    case pushPermissionChanged = "push_permission_changed"
    case identify
}

/// One captured event: a fixed envelope plus event-specific `properties`.
public struct Event: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let eventId: String
    public let name: EventName
    /// ISO 8601 UTC with milliseconds: when the event happened on the device.
    public let timestamp: String
    /// Increases by one per committed event, per install.
    public let seq: Int
    public let installId: String
    /// Random per install and login session; replaced by `reset()`. Never null.
    public let anonymousId: String
    public let userId: String?
    public let sessionId: String?
    public let schemaVersion: Int
    public let sdkVersion: String
    public let platform: String
    public let appVersion: String
    public let appBuild: String
    public let osVersion: String
    public let properties: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case name
        case timestamp
        case seq
        case installId = "install_id"
        case anonymousId = "anonymous_id"
        case userId = "user_id"
        case sessionId = "session_id"
        case schemaVersion = "schema_version"
        case sdkVersion = "sdk_version"
        case platform
        case appVersion = "app_version"
        case appBuild = "app_build"
        case osVersion = "os_version"
        case properties
    }

    /// Optional fields are written as explicit `null`, never left out.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventId, forKey: .eventId)
        try container.encode(name, forKey: .name)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(seq, forKey: .seq)
        try container.encode(installId, forKey: .installId)
        try container.encode(anonymousId, forKey: .anonymousId)
        try container.encode(userId, forKey: .userId)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sdkVersion, forKey: .sdkVersion)
        try container.encode(platform, forKey: .platform)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(appBuild, forKey: .appBuild)
        try container.encode(osVersion, forKey: .osVersion)
        try container.encode(properties, forKey: .properties)
    }

    /// The event as compact JSON data (snake_case keys, sorted).
    public func jsonData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    public func jsonString() -> String {
        String(decoding: jsonData(), as: UTF8.self)
    }

    /// The event as a Foundation dictionary, ready for a platform channel.
    public func jsonObject() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: jsonData())) as? [String: Any] ?? [:]
    }
}
