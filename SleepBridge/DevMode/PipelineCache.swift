import Foundation

/// Debugging Aid
/// Holds output between pipeline stages so the diagnostics screen can run them
/// one at a time. Expires after maxAge so you can't accidentally act on stale
/// data from an hour ago. Lives only in memory — resets if the app restarts,
/// which is intentional; this is a debugging aid, not durable storage.
enum PipelineCache {
    static let maxAge: TimeInterval = 30 * 60 // 30 minutes

    static var rawResult: RawFetchResult?
    static var rawFetchedAt: Date?

    static var mergedResult: MergedFetchResult?
    static var mergedAt: Date?

    static var formattedSamples: [FormattedSample]?
    static var formattedAt: Date?

    static var dedupedSamples: [FormattedSample]?
    static var skippedDuplicateCount: Int?
    static var dedupedAt: Date?

    static func isFresh(_ date: Date?) -> Bool {
        // A missing timestamp is never valid; every cached stage must record when it ran.
        guard let date else { return false }
        return Date().timeIntervalSince(date) < maxAge
    }

    static func clear() {
        // Clear the entire chain after a write so later diagnostics must start from fresh input.
        rawResult = nil
        rawFetchedAt = nil
        mergedResult = nil
        mergedAt = nil
        formattedSamples = nil
        formattedAt = nil
        dedupedSamples = nil
        skippedDuplicateCount = nil
        dedupedAt = nil
    }
}
