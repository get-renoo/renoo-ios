import Foundation

/// The persistent on-disk queue: one JSON event per line. Only ever used from the SDK queue.
/// The uploader reads the oldest lines with `oldest(...)` and deletes them with `remove(eventIds:)`.
final class EventStore {
    static let defaultMaxEvents = 5_000

    private let fileURL: URL
    private let maxEvents: Int
    private let logger: SDKLogger
    private(set) var count = 0

    init(directory: URL, maxEvents: Int = EventStore.defaultMaxEvents, logger: SDKLogger) {
        self.fileURL = directory.appendingPathComponent("queue.jsonl")
        self.maxEvents = maxEvents
        self.logger = logger
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(values)
        } catch {
            logger.error("Could not create the queue directory: \(error)")
        }
        count = lines().count
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Renoo", isDirectory: true)
    }

    func append(_ event: Event) {
        var data = event.jsonData()
        data.append(0x0A)
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
            count += 1
            if count > maxEvents { trim() }
        } catch {
            logger.error("Could not persist an event: \(error)")
        }
    }

    /// Every queued event, oldest first. Lines that fail to decode are skipped.
    func all() -> [Event] {
        let decoder = JSONDecoder()
        return lines().compactMap { try? decoder.decode(Event.self, from: Data($0.utf8)) }
    }

    /// One stored line, exactly as written to disk (no trailing newline).
    struct StoredLine {
        let eventId: String
        let data: Data
    }

    private struct IdOnly: Decodable {
        let event_id: String
    }

    /// The oldest stored events, at most `maxEvents` of them and at most `maxBytes` of line data
    /// (always at least one event, however large). Lines without a readable `event_id` are skipped
    /// here and deleted by the next `remove(eventIds:)`.
    func oldest(maxEvents: Int, maxBytes: Int) -> [StoredLine] {
        let decoder = JSONDecoder()
        var result: [StoredLine] = []
        var bytes = 0
        for line in lines() {
            guard result.count < maxEvents else { break }
            let data = Data(line.utf8)
            guard let id = try? decoder.decode(IdOnly.self, from: data).event_id else { continue }
            if !result.isEmpty, bytes + data.count + 1 > maxBytes { break }
            result.append(StoredLine(eventId: id, data: data))
            bytes += data.count + 1
        }
        return result
    }

    /// Deletes the events with these IDs, plus any line that can't be read. Atomic rewrite.
    func remove(eventIds: Set<String>) {
        guard !eventIds.isEmpty else { return }
        let decoder = JSONDecoder()
        var dropped = 0
        let kept = lines().filter { line in
            guard let id = try? decoder.decode(IdOnly.self, from: Data(line.utf8)).event_id else {
                dropped += 1
                return false
            }
            return !eventIds.contains(id)
        }
        if dropped > 0 { logger.error("Deleted \(dropped) unreadable queue line(s)") }
        do {
            if kept.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } else {
                try Data((kept.joined(separator: "\n") + "\n").utf8).write(to: fileURL, options: .atomic)
            }
            count = kept.count
        } catch {
            logger.error("Could not remove sent events from the queue: \(error)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        count = 0
    }

    private func lines() -> [Substring] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    }

    /// Drops the oldest events so the file never grows without bound.
    private func trim() {
        let kept = lines().suffix(maxEvents - maxEvents / 10)
        let text = kept.joined(separator: "\n") + "\n"
        do {
            try Data(text.utf8).write(to: fileURL, options: .atomic)
            count = kept.count
        } catch {
            logger.error("Could not trim the queue: \(error)")
        }
    }
}
