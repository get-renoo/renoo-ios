import Foundation

/// Builds the Events API URLs from the developer's base URL: HTTPS only (HTTP behind a debug flag),
/// a host is required, and no query or fragment is allowed.
enum IngestEndpoint {
    static let eventsPath = "/events/sdk"
    static let healthCheckPath = "/health-check"
    static let offersPath = "/offers"

    /// Every URL the SDK calls, all on the same base.
    struct URLs: Equatable {
        let events: URL
        let healthCheck: URL
        let offers: URL
    }

    enum Problem: Error, Equatable, CustomStringConvertible {
        case unsupportedScheme
        case insecureHTTP
        case missingHost
        case hasQueryOrFragment
        case hasCredentials

        var description: String {
            switch self {
            case .unsupportedScheme: return "ingestURL must be an https URL"
            case .insecureHTTP: return "ingestURL uses http; only https is allowed (allowInsecureHTTP is for local debugging only)"
            case .missingHost: return "ingestURL has no host"
            case .hasQueryOrFragment: return "ingestURL must be a base URL without query or fragment"
            case .hasCredentials: return "ingestURL must not contain a user name or password"
            }
        }
    }

    /// The three URLs, or the first problem with the base URL.
    static func urls(base: URL, allowInsecureHTTP: Bool) -> Result<URLs, Problem> {
        url(base: base, path: eventsPath, allowInsecureHTTP: allowInsecureHTTP).flatMap { events in
            url(base: base, path: healthCheckPath, allowInsecureHTTP: allowInsecureHTTP).flatMap { health in
                url(base: base, path: offersPath, allowInsecureHTTP: allowInsecureHTTP).map { offers in
                    URLs(events: events, healthCheck: health, offers: offers)
                }
            }
        }
    }

    /// `<base>/events/sdk`.
    static func eventsURL(base: URL, allowInsecureHTTP: Bool) -> Result<URL, Problem> {
        url(base: base, path: eventsPath, allowInsecureHTTP: allowInsecureHTTP)
    }

    /// `<base><path>`. A trailing slash on the base is ignored; a base path is kept
    /// (`https://host/api` → `https://host/api/events/sdk`).
    static func url(base: URL, path suffix: String, allowInsecureHTTP: Bool) -> Result<URL, Problem> {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return .failure(.missingHost)
        }
        switch components.scheme?.lowercased() {
        case "https": break
        case "http": if !allowInsecureHTTP { return .failure(.insecureHTTP) }
        default: return .failure(.unsupportedScheme)
        }
        guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }
        guard components.user == nil, components.password == nil else { return .failure(.hasCredentials) }
        guard components.query == nil, components.fragment == nil else { return .failure(.hasQueryOrFragment) }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + suffix
        guard let url = components.url else { return .failure(.missingHost) }
        return .success(url)
    }
}
