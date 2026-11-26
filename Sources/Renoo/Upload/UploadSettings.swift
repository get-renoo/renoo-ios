import Foundation

/// Uploader tunables: when to flush, batch limits, backoff and timeouts. Remote config (server-set
/// values) is not built yet; when it is, it replaces this struct via `EventUploader.update(settings:)`.
struct UploadSettings: Equatable {
    /// Flush when the disk queue reaches this many events.
    var flushThreshold = 100
    /// Foreground flush timer.
    var foregroundFlushInterval: TimeInterval = 300
    /// On cellular the timer flush only runs with at least this many events.
    var cellularMinimumEvents = 100
    /// Batch limits the Events API accepts: events per batch, gzip size, decompressed size.
    var maxEventsPerBatch = 500
    var maxCompressedBytes = 512 * 1024
    var maxDecompressedBytes = 5 * 1024 * 1024
    /// Retry backoff: exponential from `backoffBase`, capped at `backoffCap`.
    var backoffBase: TimeInterval = 30
    var backoffFactor: Double = 2
    var backoffCap: TimeInterval = 3_600
    /// Timeouts: connect (idle) and the whole request.
    var connectTimeout: TimeInterval = 10
    var requestTimeout: TimeInterval = 30

    static let defaults = UploadSettings()
}
