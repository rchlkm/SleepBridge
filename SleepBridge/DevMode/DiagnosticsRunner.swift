import Foundation
import HealthKit
import UIKit

/// Thin wrappers around SleepPipeline's stages, adding caching between steps
/// and human-readable summaries for the diagnostics screen. The actual logic
/// lives in SleepPipeline.swift — this file doesn't duplicate it. All
/// multi-line output renders through PipelineDebugFormat so every stage
/// looks the same regardless of which one produced it.
@MainActor
enum DiagnosticsRunner {

  // MARK: - Quick smoke tests (unrelated to the real pipeline / cache)

  static func testGoogleAuth() async -> String {
    guard CredentialStore.hasAllCredentials() else {
      return "❌ No credentials saved yet — enter them in Settings first."
    }
    do {
      let token = try await GoogleFitClient().accessToken()
      return "✅ Got access token: \(String(token.prefix(12)))…"
    } catch {
      return "❌ Auth failed: \(error)"
    }
  }

  static func testHealthKitWrite() async -> String {
    do {
      let writer = HealthKitWriter()
      try await writer.requestAuthorization()
      let (start, end) = testSampleRange()
      try await writer.writeSample(start: start, end: end, value: .awake)
      return
        "✅ Wrote a 1-minute test sample dated Jan 1, 2000. Use 'Delete Test Sample' below to remove it."
    } catch {
      return "❌ HealthKit write failed: \(error)"
    }
  }

  static func deleteTestSample() async -> String {
    do {
      let writer = HealthKitWriter()
      try await writer.requestAuthorization()
      let (start, end) = testSampleRange()
      let existing = try await writer.existingSamples(from: start, to: end)
      guard !existing.isEmpty else {
        return "⚠️ No test sample found — already deleted, or never written."
      }
      try await writer.delete(existing)
      return "✅ Deleted \(existing.count) test sample(s) from Jan 1, 2000."
    } catch {
      return "❌ Delete failed: \(error)"
    }
  }

  private static func testSampleRange() -> (Date, Date) {
    var components = DateComponents()
    components.year = 2000
    components.month = 1
    components.day = 1
    components.hour = 0
    let start = Calendar.current.date(from: components) ?? Date()
    return (start, start.addingTimeInterval(60))
  }

  // MARK: - Step-by-step pipeline, using a user-chosen date range

  static func fetchRaw(since: Date, until: Date) async -> String {
    do {
      let raw = try await SleepPipeline.fetchRaw(since: since, until: until)
      PipelineCache.rawResult = raw
      PipelineCache.rawFetchedAt = Date()

      guard !raw.sessions.isEmpty else {
        return "⚠️ No sleep sessions found in that range."
      }
      return copyAndReturn("✅ Fetched.\n\n" + PipelineDebugFormat.render(raw))
    } catch {
      return "❌ Fetch failed: \(error)"
    }
  }

  static func mergeCached() -> String {
    guard PipelineCache.isFresh(PipelineCache.rawFetchedAt), let raw = PipelineCache.rawResult
    else {
      return "❌ No fresh raw data cached — run 'Fetch Raw' first (cache expires after 30 min)."
    }

    let merged = SleepPipeline.mergeStages(raw)
    PipelineCache.mergedResult = merged
    PipelineCache.mergedAt = Date()

    guard !merged.sessions.isEmpty else {
      return "⚠️ Nothing to merge."
    }
    return copyAndReturn("✅ Merged.\n\n" + PipelineDebugFormat.render(merged))
  }

  static func formatCached() -> String {
    guard PipelineCache.isFresh(PipelineCache.mergedAt), let merged = PipelineCache.mergedResult
    else {
      return "❌ No fresh merged data cached — run 'Merge Stages' first."
    }

    let formattedSessions = SleepPipeline.format(merged)
    PipelineCache.formattedSessions = formattedSessions
    PipelineCache.formattedAt = Date()

    return copyAndReturn("✅ Formatted.\n\n" + PipelineDebugFormat.render(formattedSessions))
  }

  /// Runs the version-aware reconcile stage:
  /// stale sessions get queued for full replacement;
  /// current sessions go through plain exact-match dedupe.
  static func checkDuplicatesCached() async -> String {
    guard PipelineCache.isFresh(PipelineCache.formattedAt),
      let formattedSessions = PipelineCache.formattedSessions
    else {
      return "❌ No fresh formatted data cached — run 'Format' first."
    }
    do {
      let (toWrite, skipped, replacedSessions) = try await SleepPipeline.reconcile(
        formattedSessions)
      PipelineCache.reconciledSamples = toWrite
      PipelineCache.skippedDuplicateCount = skipped
      PipelineCache.replacedSessionCount = replacedSessions
      PipelineCache.reconciledAt = Date()
      return "✅ "
        + PipelineDebugFormat.reconcileSummary(
          toWriteCount: toWrite.count, skipped: skipped, replacedSessions: replacedSessions)
    } catch {
      return "❌ Duplicate check failed: \(error)"
    }
  }

  static func saveCached() async -> String {
    guard PipelineCache.isFresh(PipelineCache.reconciledAt),
      let toWrite = PipelineCache.reconciledSamples
    else {
      return "❌ No fresh reconciled data cached — run 'Check Duplicates' first."
    }
    do {
      let written = try await SleepPipeline.save(toWrite)
      let skipped = PipelineCache.skippedDuplicateCount ?? 0
      let replaced = PipelineCache.replacedSessionCount ?? 0
      PipelineCache.clear()
      return "✅ "
        + PipelineDebugFormat.saveSummary(
          written: written, skipped: skipped, replacedSessions: replaced)
    } catch {
      return "❌ Save failed: \(error)"
    }
  }

  // MARK: - Run everything at once, for a manually picked range

  /// Runs all five stages back to back for the given range.
  /// Writes to Apple Health (same as the automatic sync).
  static func runAllSteps(since: Date, until: Date) async -> String {
    do {
      let result = try await SleepPipeline.runAll(since: since, until: until)
      let header =
        "✅ "
        + PipelineDebugFormat.saveSummary(
          written: result.written, skipped: result.skipped,
          replacedSessions: result.replacedSessions)
      return copyAndReturn(header + "\n\n" + PipelineDebugFormat.render(result.formattedSessions))
    } catch {
      return "❌ Run failed: \(error)"
    }
  }

  // MARK: - Backup export (in case Google sunsets the API)

  static func exportRawData(since: Date, until: Date) async -> (message: String, fileURL: URL?) {
    await DataExporter.exportRawData(since: since, until: until)
  }

  private static func copyAndReturn(_ text: String) -> String {
    UIPasteboard.general.string = text
    return text
  }

  // MARK: - Unified stage list for the Diagnostics UI

  enum PipelineStage: Int, CaseIterable, Identifiable {
    case fetch, merge, format, reconcile, save
    var id: Int { rawValue }

    var title: String {
      switch self {
      case .fetch: return "Fetch Raw"
      case .merge: return "Merge Stages"
      case .format: return "Format"
      case .reconcile: return "Check Duplicates"
      case .save: return "Save to Apple Health"
      }
    }
  }

  enum StageStatus {
    case notRun
    case stale
    case fresh(Date)
  }

  static func status(for stage: PipelineStage) -> StageStatus {
    let date: Date?
    let isFresh: Bool
    switch stage {
    case .fetch:
      date = PipelineCache.rawFetchedAt
      isFresh = PipelineCache.isFresh(date)
    case .merge:
      date = PipelineCache.mergedAt
      isFresh = PipelineCache.isFresh(date)
    case .format:
      date = PipelineCache.formattedAt
      isFresh = PipelineCache.isFresh(date)
    case .reconcile:
      date = PipelineCache.reconciledAt
      isFresh = PipelineCache.isFresh(date)
    case .save:
      date = nil  // save clears the cache on success — never shown as "fresh"
      isFresh = false
    }
    guard let date else { return .notRun }
    return isFresh ? .fresh(date) : .stale
  }

  // Cascading runners: fill in whatever upstream cache is missing/stale,
  // silently, so the UI never has to know the pipeline's internal ordering.

  @discardableResult
  private static func ensureFetch(since: Date, until: Date) async -> String {
    if PipelineCache.isFresh(PipelineCache.rawFetchedAt) { return "(reused cached fetch)" }
    return await fetchRaw(since: since, until: until)
  }

  @discardableResult
  private static func ensureMerge(since: Date, until: Date) async -> String {
    await ensureFetch(since: since, until: until)
    if PipelineCache.isFresh(PipelineCache.mergedAt) { return "(reused cached merge)" }
    return mergeCached()
  }

  @discardableResult
  private static func ensureFormat(since: Date, until: Date) async -> String {
    await ensureMerge(since: since, until: until)
    if PipelineCache.isFresh(PipelineCache.formattedAt) { return "(reused cached format)" }
    return formatCached()
  }

  @discardableResult
  private static func ensureReconcile(since: Date, until: Date) async -> String {
    await ensureFormat(since: since, until: until)
    if PipelineCache.isFresh(PipelineCache.reconciledAt) { return "(reused cached reconcile)" }
    return await checkDuplicatesCached()
  }

  /// Runs exactly the stages needed to produce `stage`'s output, reusing
  /// fresh cache where possible.
  static func run(_ stage: PipelineStage, since: Date, until: Date) async -> String {
    switch stage {
    case .fetch:
      return await fetchRaw(since: since, until: until)  // explicit tap always re-fetches
    case .merge:
      await ensureFetch(since: since, until: until)
      return mergeCached()
    case .format:
      await ensureMerge(since: since, until: until)
      return formatCached()
    case .reconcile:
      await ensureFormat(since: since, until: until)
      return await checkDuplicatesCached()
    case .save:
      await ensureReconcile(since: since, until: until)
      return await saveCached()
    }
  }
}
