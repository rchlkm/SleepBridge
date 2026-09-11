import Foundation
import HealthKit
import UIKit

/// Thin wrappers around SleepPipeline's stages, adding caching between steps
/// and human-readable summaries for the diagnostics screen. The actual logic
/// lives in SleepPipeline.swift — this file doesn't duplicate it.
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

      var lines = [
        "✅ \(raw.sessions.count) session(s) — raw Google Fit data (\(raw.sessions.reduce(0) { $0 + $1.points.count }) point(s) total):"
      ]
      for item in raw.sessions {
        let start = Date(timeIntervalSince1970: Double(item.session.startTimeMillis) / 1000)
        let end = Date(timeIntervalSince1970: Double(item.session.endTimeMillis) / 1000)
        lines.append("Session \(start) → \(end):")
        for point in item.points {
          lines.append("  intVal=\(point.intVal)  \(point.start) → \(point.end)")
        }
      }
      return copyAndReturn(lines.joined(separator: "\n"))
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

    var lines = ["✅ \(merged.sessions.count) session(s) merged:"]
    for session in merged.sessions {
      lines.append("Session (\(session.stages.count) merged stage(s)):")
      for stage in session.stages {
        lines.append("  intVal=\(stage.intVal)  \(stage.start) → \(stage.end)")
      }
    }
    return copyAndReturn(lines.joined(separator: "\n"))
  }

  static func formatCached() -> String {
    guard PipelineCache.isFresh(PipelineCache.mergedAt), let merged = PipelineCache.mergedResult
    else {
      return "❌ No fresh merged data cached — run 'Merge Stages' first."
    }

    let formattedSessions = SleepPipeline.format(merged)
    PipelineCache.formattedSessions = formattedSessions
    PipelineCache.formattedAt = Date()

    return copyAndReturn(debugFormattedGrouped(formattedSessions))
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
      var message =
        "✅ \(toWrite.count) sample(s) to write, \(skipped) already exist and will be skipped."
      if replacedSessions > 0 {
        message +=
          " \(replacedSessions) session(s) were stale (older pipeline version) and will be fully replaced."
      }
      return message
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
      var message =
        "✅ Wrote \(written) sample(s) to Apple Health (\(skipped) duplicate(s) were skipped)."
      if replaced > 0 {
        message += " \(replaced) stale session(s) were replaced."
      }
      return message
    } catch {
      return "❌ Save failed: \(error)"
    }
  }

  // MARK: - Run everything at once, for a manually picked range

  /// Runs all five stages back to back for the given range
  /// Writes to Apple Health (same as the automatic sync)
  static func runAllSteps(since: Date, until: Date) async -> String {
    do {
      let result = try await SleepPipeline.runAll(since: since, until: until)
      var header =
        "✅ Wrote \(result.written) new sample(s), skipped \(result.skipped) duplicate(s)."
      if result.replacedSessions > 0 {
        header += " \(result.replacedSessions) stale session(s) were replaced."
      }
      header += "\n"
      return copyAndReturn(header + debugFormattedGrouped(result.formattedSessions))
    } catch {
      return "❌ Run failed: \(error)"
    }
  }

  // MARK: - Backup export (in case Google sunsets the API)

  static func exportRawData(since: Date, until: Date) async -> (message: String, fileURL: URL?) {
    await DataExporter.exportRawData(since: since, until: until)
  }

  // MARK: - Debug formatting

  /// Purely for debugging — readable stage names and formatted dates instead of
  /// raw Swift Date descriptions, grouped by session:
  ///
  /// =======
  /// Session 05-02-2026 1:31:03 AM → 05-02-2026 10:23:39 AM
  /// Asleep (Core/Light) 2:40:07 AM - 3:39:24 AM
  static func debugFormattedGrouped(_ sessions: [FormattedSession]) -> String {
    guard !sessions.isEmpty else {
      return "⚠️ No formatted sessions."
    }

    let dateTimeFormatter = DateFormatter()
    dateTimeFormatter.dateFormat = "MM-dd-yyyy h:mm:ss a"

    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm:ss a"

    var lines: [String] = []
    for session in sessions {
      lines.append("=======")
      lines.append(
        "Session \(dateTimeFormatter.string(from: session.sessionStart)) → \(dateTimeFormatter.string(from: session.sessionEnd))"
      )
      for inBed in session.inBedSpans {
        lines.append(
          "In Bed \(dateTimeFormatter.string(from: inBed.start)) → \(dateTimeFormatter.string(from: inBed.end))"
        )
      }
      for stage in session.stages {
        let stageName = SleepStageMapper.sleepStageName(stage.stage)
        lines.append(
          "\(stageName) \(timeFormatter.string(from: stage.start)) - \(timeFormatter.string(from: stage.end))"
        )
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func copyAndReturn(_ text: String) -> String {
    UIPasteboard.general.string = text
    return text
  }
}
