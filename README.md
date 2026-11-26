# Renoo iOS SDK

Captures in-app behaviour for subscription apps with **zero runtime permissions**: app opens, sessions, screens, subscription state, push-permission status and device context. Renoo uses it to spot subscribers at risk of cancelling and to hold a retention offer for them.

## Requirements

| | |
| --- | --- |
| iOS | 17.0 or later |
| Swift tools | 5.9 or later (Xcode 15 or later); Swift 5 language mode |
| Dependencies | None |
| App extensions | Not supported (`configure` does nothing inside an app extension) |

## Install

Swift Package Manager. In Xcode: **File > Add Package Dependencies…**, enter `https://github.com/get-renoo/renoo-ios` and add the `Renoo` product to your app target. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/get-renoo/renoo-ios", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Renoo", package: "renoo-ios")]),
]
```

## Usage

### Configure

Call `configure` once, on the main thread, as early as possible (for example in `application(_:didFinishLaunchingWithOptions:)` or your SwiftUI `App` initialiser).

```swift
import Renoo

var configuration = Configuration(apiKey: "<your API key>", purchaseHandler: { request in
    // Your purchase code. Not called by this version of the SDK.
    .cancelled
})
configuration.ingestURL = URL(string: "<your Renoo API base URL>")
Renoo.configure(configuration)
```

| `Configuration` property | Default | Meaning |
| --- | --- | --- |
| `apiKey` | (required) | Your API key. An empty key disables the SDK. Never logged |
| `purchaseHandler` | (required) | Your code that completes a discounted purchase and returns `.purchased`, `.cancelled`, `.failed` or `.pending`. The SDK never buys anything itself |
| `ingestURL` | `nil` | Base URL of the Renoo API (no path needed; a trailing slash is fine). `nil` means capture only: events stay on the device and nothing is sent |
| `logLevel` | `.error` | `.none`, `.error`, `.info` or `.debug` (`.debug` prints every event) |
| `trackingScope` | `.subscribersOnly` | `.everyone` also tracks users without a subscription. For development only |
| `automaticScreenTracking` | `true` | Capture UIKit screen views automatically |
| `allowInsecureHTTP` | `false` | Accept an `http://` `ingestURL`. For a local test server only; never ship it on |

`ingestURL` must use HTTPS. An `http://` URL (without `allowInsecureHTTP`), another scheme, or a URL with a query, fragment or user name disables sending and logs an error; capture continues. A second call to `configure` is ignored. Every SDK method is safe to call from any thread, never throws, and does nothing before `configure`.

### Identify users

```swift
Renoo.identify(userId: "user-123")   // after every login
Renoo.reset()                        // on logout
```

- **`identify(userId:)`** links later events to your user ID. Use the same opaque ID your billing SDK uses, never an email address or a name. Calling it again with the current user ID does nothing. It is ignored while opted out.
- **`reset()`** clears the user ID and starts a new anonymous ID. Events already captured keep the old IDs.

### Anonymous ID

```swift
let anonymousId: String? = Renoo.anonymousId
```

A random lowercase UUID generated at `configure` and sent on every event. It survives app restarts but not a reinstall, and `reset()` replaces it. `nil` before `configure`. Use it for debugging, or pass it to your billing SDK (for example as the RevenueCat app user ID).

### Opt-out

```swift
Renoo.optOut()             // stop tracking this install
Renoo.optIn()              // resume
let optedOut = Renoo.isOptedOut
```

`optOut()` stops capture, deletes the events waiting on the device, forgets the user ID and the pending offer, and is remembered across launches. It keeps the anonymous ID. `optIn()` resumes tracking.

### Screens

UIKit screens are captured automatically (set `automaticScreenTracking = false` to turn this off). For SwiftUI, tag each screen:

```swift
SettingsView().renooScreen("Settings")
```

Where neither can see a screen, record it by name:

```swift
Renoo.trackScreen("Checkout")
```

Use static screen names (at most 100 characters), never text that contains user content.

### Offers

The SDK asks the Renoo API whether an offer is waiting for the current user and holds it for you. It never displays anything.

```swift
let offer: PendingOffer? = Renoo.pendingOffer   // read-only; offer.json is the API's JSON object

let token = Renoo.addPendingOfferObserver { offer in
    // Main actor. Called with the current value straight away, then on every change (including to nil).
}
if let token { Renoo.removePendingOfferObserver(token) }
```

`pendingOffer` is `nil` before `configure`, in capture-only mode, while the user isn't tracked (no active subscription or trial), after `reset()` or `optOut()`, and when the API has no offer. In this version its content is a free-form JSON object.

### Debugging

```swift
let token = Renoo.addEventObserver { event in print(event.jsonString()) }  // on the SDK's background queue
let waiting = Renoo.queuedEvents()                                        // events not sent yet, oldest first
```

`Renoo.sdkVersion` is the SDK version string.

## What is captured

Only users with an **active subscription or trial** (including grace period and billing retry) are tracked. For anyone else, no events are stored or sent.

| Event | When |
| --- | --- |
| `install` | First launch after an install or reinstall; says whether it is a reinstall |
| `session_start` / `session_end` | A session ends after more than 30 seconds in the background. `session_start` carries the device context below |
| `app_open` / `app_background` | The app becomes active (cold or warm start) / goes to the background |
| `unclean_exit` | The previous run ended while the app was in the foreground (for example a crash or a force quit) |
| `screen_view` | A screen appears: its name, the previous screen, and the source (`uikit`, `swiftui`, `manual`, `flutter`, `react_native`) |
| `subscription_state` | Subscription status, product, expiry, auto-renew, trial and offer type, read from StoreKit 2 |
| `transaction` | A purchase, renewal, upgrade or revocation seen through StoreKit 2 |
| `push_permission_changed` | The notification permission status changes |
| `identify` | A user ID is set, or a new anonymous ID starts being tracked |

Every event carries an event ID, timestamp, sequence number, install ID, anonymous ID, user ID (or `null`), session ID, and the SDK, app and OS versions. Device context: device model, locale, time zone, network type (Wi-Fi, cellular or none), Low Power Mode, dark mode, push-permission status, days since install and whether it is a reinstall.

StoreKit is **observe only**: the SDK reads current entitlements, subscription status and transaction updates. It never starts a purchase and never finishes a transaction. If your app sets an `appAccountToken` on purchases, it is sent with subscription events.

The SDK emits event `schema_version` 1. Every field is always present; unknown values are `null`.

## Privacy and permissions

- **Zero runtime permissions.** The SDK shows no prompts and does not use motion sensors, location, the advertising identifier (IDFA / App Tracking Transparency), contacts or the clipboard. It reads the notification permission status but never requests it.
- **Privacy manifest** (`PrivacyInfo.xcprivacy`, bundled with the package):

  | Section | Contents |
  | --- | --- |
  | Tracking | `NSPrivacyTracking` false; no tracking domains |
  | Required-reason APIs | UserDefaults only, reason `CA92.1` |
  | Collected data | Product interaction, purchase history, user ID, device ID. Each linked to the user, not used for tracking, for analytics and product personalisation |

  Include this data in your app's App Store privacy details.
- **Storage on the device.** The install ID and install date are kept in the Keychain (this device only, not synced) so a reinstall can be recognised. The anonymous ID, user ID, opt-out choice and SDK state are kept in UserDefaults. Events waiting to be sent are kept in a file in the app's container (at most 5,000).
- **Network.** Nothing is sent unless `ingestURL` is set. Then the SDK talks only to that URL, over HTTPS, with `Authorization: Bearer <apiKey>`, using an ephemeral `URLSession` (no cookies, no cache, redirects not followed). Identity goes in headers or the event body, never in URLs.

## Sending events

With `ingestURL` set, the SDK uploads the on-device queue in gzip-compressed batches to `<ingestURL>/events/sdk`: at cold start, when the app goes to the background, when 100 events are waiting, and every 5 minutes in the foreground (on cellular only with 100 or more events waiting). It retries failures with exponential backoff, honours `Retry-After`, and keeps events on the device until the API has answered for them. All network and disk work runs off the main thread.

### Start-up checks

On every start-up, after `configure` and off the main thread, the SDK calls:

1. **`GET <ingestURL>/health-check`.** A `401` (unknown or revoked key) switches the SDK off until the next start-up: capture stops, the waiting events are deleted, no offer is fetched and nothing is sent. The install ID, anonymous ID and opt-out choice are kept. Any other answer, or a network error: the SDK carries on. A `401` on an upload has the same effect.
2. **`GET <ingestURL>/offers`**, only while the user is tracked (an active subscription or trial, the same rule as for events). It is called again when the app returns to the foreground or when the user becomes tracked, at most every 6 hours; a call skipped because the user isn't tracked doesn't count. The anonymous ID and, once set, the user ID go in the `X-Renoo-Anonymous-Id` and `X-Renoo-User-Id` headers. The answer updates `Renoo.pendingOffer`.

The health check carries no identity. Nothing about a user who isn't tracked is sent, not even the anonymous ID. When the user stops being tracked (the subscription lapses), `Renoo.pendingOffer` becomes `nil` and an answer still on its way is ignored.

Neither call is made in capture-only mode (no `ingestURL`). No offer is fetched while opted out.

## Versioning

This SDK follows [Semantic Versioning](https://semver.org). Until 1.0.0, a minor version may include breaking changes. See [CHANGELOG.md](CHANGELOG.md).

## Licence

Apache License 2.0. See [LICENSE](LICENSE).
