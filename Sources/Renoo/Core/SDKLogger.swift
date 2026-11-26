import Foundation
import os

/// Logging that never throws and never blocks. `debug` also prints, so events show up in any console.
final class SDKLogger: @unchecked Sendable {
    private let level: Configuration.LogLevel
    private let log = Logger(subsystem: "dev.renoo.sdk", category: "sdk")

    init(level: Configuration.LogLevel) { self.level = level }

    func error(_ message: @autoclosure () -> String) {
        guard level.rawValue >= Configuration.LogLevel.error.rawValue else { return }
        let text = message()
        log.error("\(text, privacy: .public)")
        if level == .debug { print("[Renoo] ERROR \(text)") }
    }

    func info(_ message: @autoclosure () -> String) {
        guard level.rawValue >= Configuration.LogLevel.info.rawValue else { return }
        let text = message()
        log.info("\(text, privacy: .public)")
        if level == .debug { print("[Renoo] \(text)") }
    }

    func debug(_ message: @autoclosure () -> String) {
        guard level == .debug else { return }
        let text = message()
        log.debug("\(text, privacy: .public)")
        print("[Renoo] \(text)")
    }
}
