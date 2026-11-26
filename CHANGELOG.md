# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

### Added

- Swift package `Renoo` for iOS 17 and later, with no third-party dependencies and no runtime permissions.
- `Renoo.configure(_:)` with `Configuration`: API key, purchase handler, `ingestURL` (capture only when `nil`), log level, tracking scope, automatic UIKit screen tracking and a debug-only `allowInsecureHTTP`.
- Identity: install ID kept in the Keychain across reinstalls, `Renoo.anonymousId`, `Renoo.identify(userId:)` and `Renoo.reset()`.
- `Renoo.optOut()`, `Renoo.optIn()` and `Renoo.isOptedOut`; opt-out deletes the local queue and user ID and is remembered across launches.
- Automatic capture of `install`, `app_open`, `app_background`, `session_start`, `session_end`, `unclean_exit`, `subscription_state`, `transaction`, `push_permission_changed` and `identify` events, emitted as event `schema_version` 1.
- Screen views: automatic for UIKit, `.renooScreen(_:)` for SwiftUI, and `Renoo.trackScreen(_:source:)` for anything else.
- Subscription state and transactions read from StoreKit 2, observe only.
- Tracking limited to users with an active subscription or trial by default.
- On-disk event queue (up to 5,000 events) and gzip NDJSON uploads to `<ingestURL>/events/sdk`, with batching, retries, backoff and `Retry-After` support.
- `GET /health-check` at every start-up; a `401` from the API switches the SDK off until the next start-up.
- `GET /offers` at start-up, on return to the foreground and when the user becomes tracked (at most every 6 hours), only while the user is tracked, with `Renoo.pendingOffer`, `Renoo.addPendingOfferObserver(_:)` and `Renoo.removePendingOfferObserver(_:)`.
- Debugging helpers: `Renoo.addEventObserver(_:)`, `Renoo.removeEventObserver(_:)` and `Renoo.queuedEvents()`.
- Privacy manifest declaring UserDefaults as the only required-reason API and the data the SDK collects.

[0.1.0]: https://github.com/get-renoo/renoo-ios/releases/tag/0.1.0
