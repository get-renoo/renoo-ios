# CLAUDE.md

Guidance for AI coding assistants working in this repo: the Renoo iOS SDK, a Swift package (`Renoo`) that silently captures in-app behaviour for subscription apps. Public API and behaviour are documented in `README.md`.

## Hard rules

1. **Zero runtime permissions.** Never import or call CoreMotion, CoreLocation, AdSupport / AppTrackingTransparency, Contacts, UIPasteboard. Reading push permission status is allowed; requesting it is not.
2. **Required-reason APIs: UserDefaults only** (declared in `Sources/Renoo/Resources/PrivacyInfo.xcprivacy`). The same file lists the collected data types (product interaction, purchase history, user ID, device ID; linked, not tracking); update it whenever an event starts carrying a new kind of data. Do not use file timestamp attributes, `systemUptime` / `mach_absolute_time`, disk space, or active keyboard APIs. Use `Date()` for time.
3. **Never crash or block the host app.** No `fatalError`, force unwraps, or `try!` in SDK code. Slow work (disk, Keychain, StoreKit, network) goes on `environment.queue`, never the main thread.
4. **No purchases.** The SDK only observes StoreKit; it never starts a purchase or finishes a transaction.
5. **No third-party dependencies.**
6. **Never log the API key.** Event payloads are logged only at `.debug`.
7. **Identity never goes in a URL**: headers or the event body only.

## Layout

- `Sources/Renoo/Renoo.swift`: public API.
- `Sources/Renoo/Core/`: event model, pipeline (gate → seq → disk → observers), on-disk queue, pending offer store (`PendingOffer.swift`).
- `Sources/Renoo/Collectors/`: one file per event source; each is a `Collector` started from `SDKCore.start()`.
- `Sources/Renoo/Upload/`: the uploader (batches the disk queue to `POST <ingestURL>/events/sdk`) and `RemoteChecks.swift` (`GET /health-check`, `GET /offers`). A `401` from any call is the kill switch (`EventPipeline.disable()`, in memory until the next start-up). Tunables are constants in `UploadSettings.swift`.
- `Tests/RenooTests/`: unit tests. Network code is tested with fake transports, clocks and network monitors; tests must not need network access.
- `StoreKit/TestProducts.storekit`: StoreKit test configuration for hosted tests.
- `test-apps/` is git-ignored and local only. Never commit it.

## Events and wire contract

- Events follow event schema v1 (`schema_version` 1). Every listed property is always present, `null` when unknown. Adding or changing a field is a schema change, not a local edit.
- `Tests/RenooTests/EventSchemaTests.swift` validates one event of each type against the schema v1 JSON file (`event-v1.schema.json`, with its `fixtures/` folder next to it) named by the `RENOO_EVENT_SCHEMA` environment variable (skipped when it isn't set), using the minimal validator in `JSONSchemaValidator.swift`. Add every new event type to its sample.

## Commands

- Fast logic tests on the Mac: `swift test`
- iOS build: `xcodebuild build -scheme Renoo -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/dd`
- iOS tests: `xcodebuild test -scheme Renoo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/dd` (pick any installed simulator: `xcrun simctl list devices available`)
- Schema test: set `RENOO_EVENT_SCHEMA` to the absolute path of the schema file. `RENOO_EVENT_SCHEMA=/path/to/event-v1.schema.json swift test`; for `xcodebuild test`, export `TEST_RUNNER_RENOO_EVENT_SCHEMA=/path/to/event-v1.schema.json` (xcodebuild passes `TEST_RUNNER_`-prefixed variables to the test process without the prefix).

## Code rules

- Code that needs UIKit goes inside `#if canImport(UIKit)` so `swift test` keeps working on macOS.
- Minimum iOS 17; macOS 14 is declared only so `swift test` runs. Swift 5 language mode.
- Public API: every method safe from any thread, never throws, does nothing before `configure`. Document public symbols with `///` comments written for app developers.
- Behaviour changes need tests, an update to `README.md` when client-visible, and a `CHANGELOG.md` entry.
- Never commit secrets, signing settings or a `DEVELOPMENT_TEAM`.
- Commit messages: conventional style (`feat:`, `fix:`, `docs:`, `test:`).
