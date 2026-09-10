import Foundation

/// Holds output between pipeline stages so the diagnostics screen can run them
/// one at a time. Expires after maxAge so you can't accidentally act on stale
/// data from an hour ago. Lives only in memory — resets if the app restarts,
/// which is intentional; this is a debugging aid, not durable storage.
@MainActor
enum PipelineCache {
  static let maxAge: TimeInterval = 30 * 60  // 30 minutes

  static var rawResult: RawFetchResult?
  static var rawFetchedAt: Date?

  static var mergedResult: MergedFetchResult?
  static var mergedAt: Date?

  static var formattedSessions: [FormattedSession]?
  static var formattedAt: Date?

  /// Renamed from "deduped" — this now holds the output of `reconcile`, which
  /// does version-aware stale-session replacement in addition to plain
  /// exact-match dedupe, so "deduped" undersold what's actually in here.
  static var reconciledSamples: [FormattedSample]?
  static var skippedDuplicateCount: Int?
  static var replacedSessionCount: Int?
  static var reconciledAt: Date?

  static func isFresh(_ date: Date?) -> Bool {
    guard let date else { return false }
    return Date().timeIntervalSince(date) < maxAge
  }

  static func clear() {
    rawResult = nil
    rawFetchedAt = nil
    mergedResult = nil
    mergedAt = nil
    formattedSessions = nil
    formattedAt = nil
    reconciledSamples = nil
    skippedDuplicateCount = nil
    replacedSessionCount = nil
    reconciledAt = nil
  }
}
