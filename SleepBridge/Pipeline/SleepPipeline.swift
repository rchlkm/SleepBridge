// SleepBridge/Pipeline/SleepPipeline.swift
import Foundation
import HealthKit

/// The raw Google session and every stage point fetched for that session.
struct SessionWithPoints: Codable {
  let session: SleepSession
  let points: [SleepSegmentPoint]
}

/// Output of the fetch stage, preserving the requested time window for diagnostics.
struct RawFetchResult: Codable {
  let sessions: [SessionWithPoints]
  let rangeStart: Date
  let rangeEnd: Date
}

/// A contiguous run of one raw Google Fit stage value.
struct MergedSleepStage {
  let intVal: Int
  let start: Date
  let end: Date
}

/// One session after its minute-level points have been collapsed into runs.
struct MergedSession {
  let session: SleepSession
  let stages: [MergedSleepStage]
}

/// Output of the merge stage.
struct MergedFetchResult {
  let sessions: [MergedSession]
}

/// A write-ready HealthKit sleep category sample, plus its source value for debugging.
struct FormattedSample {
  let start: Date
  let end: Date
  let stage: HKCategoryValueSleepAnalysis
  /// The original Google Fit intVal this came from, nil for a synthesized
  /// in-bed span (which Google Fit doesn't track as its own concept).
  let sourceIntVal: Int?
}

/// One formatted session, keeping the in-bed envelope and its stage samples
/// grouped explicitly — rather than flattened into one list and re-inferred
/// later by scanning for `.inBed` markers, which breaks if dedupe ever filters
/// an envelope sample out while keeping its stages (or vice versa).
///
/// `inBedSpans` may contain more than one sample: if Nest Hub reported an
/// out-of-bed period in the middle of the night, HealthKit's model for that
/// isn't a stage value — it's a gap in the `.inBed` envelope itself (the same
/// way Apple Watch produces two separate `.inBed` samples if you take it off
/// mid-sleep). `sessionStart`/`sessionEnd` are the original Nest Hub session
/// bounds, kept explicitly so downstream logic doesn't have to re-derive them
/// from spans that may now have gaps at the very start or end.
struct FormattedSession {
  let sessionStart: Date
  let sessionEnd: Date
  let inBedSpans: [FormattedSample]
  let stages: [FormattedSample]

  /// All samples in this session, envelope span(s) first
  var allSamples: [FormattedSample] { inBedSpans + stages }
}

/// Result of running all five stages back to back with no pausing for review.
struct PipelineRunResult {
  let formattedSessions: [FormattedSession]
  let written: Int
  let skipped: Int
  let replacedSessions: Int
  let latestEnd: Date?
}

enum SleepPipeline {
  static let pipelineVersion = 2

  /// Stage 1: raw Google Fit data only, no formatting or mapping applied.
  static func fetchRaw(since: Date, until: Date = Date()) async throws -> RawFetchResult {
    SyncRunner.log("Stage 1/5: fetching since \(since) until \(until)")

    let client = GoogleFitClient()
    let sessions = try await client.listSleepSessions(since: since, until: until)

    var sessionsWithPoints: [SessionWithPoints] = []
    // The aggregate endpoint accepts one session interval at a time, so preserve the
    // association between each session and its returned minute-level points.
    for session in sessions {
      let points = try await client.aggregateSleepSegments(
        startTimeMillis: session.startTimeMillis,
        endTimeMillis: session.endTimeMillis
      )
      sessionsWithPoints.append(SessionWithPoints(session: session, points: points))
    }
    return RawFetchResult(sessions: sessionsWithPoints, rangeStart: since, rangeEnd: until)
  }

  /// Stage 2: collapses Google Fit's per-minute points into contiguous runs of
  /// the same stage. Only merges points that are actually back-to-back in time
  /// (one point's end equals the next one's start) — if there's a gap between
  /// two same-value points, that's kept as two separate stages rather than
  /// papering over unknown/missing minutes as one continuous span.
  static func mergeStages(_ raw: RawFetchResult) -> MergedFetchResult {
    SyncRunner.log("Stage 2/5: merging \(raw.sessions.count) raw stages")

    let mergedSessions = raw.sessions.map { item -> MergedSession in
      let sortedPoints = item.points.sorted { $0.start < $1.start }
      var stages: [MergedSleepStage] = []

      for point in sortedPoints {
        if let last = stages.last, last.intVal == point.intVal, last.end == point.start {
          // Contiguous with the current run — extend it instead of adding a new stage.
          stages[stages.count - 1] = MergedSleepStage(
            intVal: last.intVal, start: last.start, end: point.end)
        } else {
          stages.append(MergedSleepStage(intVal: point.intVal, start: point.start, end: point.end))
        }
      }
      return MergedSession(session: item.session, stages: stages)
    }
    return MergedFetchResult(sessions: mergedSessions)
  }

  /// Stage 3: maps merged Google Fit values into Apple HealthKit sleep categories.
  /// Returns one FormattedSession per merged session — grouping preserved
  /// explicitly, not flattened.
  static func format(_ merged: MergedFetchResult) -> [FormattedSession] {
    SyncRunner.log("Stage 3/5: formatting \(merged.sessions.count) merged stages")

    return merged.sessions.map { item -> FormattedSession in
      let sessionStart = Date(timeIntervalSince1970: Double(item.session.startTimeMillis) / 1000)
      let sessionEnd = Date(timeIntervalSince1970: Double(item.session.endTimeMillis) / 1000)

      // intVal == 3 means "out of bed" — physically left the bed, distinct from
      // intVal == 1 ("awake", still in bed)
      // HealthKit has no stage value for this;
      // the correct representation is a *gap* in the `.inBed` envelope,
      // not a continuous inBed span that ignores what Nest Hub reported.
      let outOfBedWindows = item.stages
        .filter { $0.intVal == 3 }
        .sorted { $0.start < $1.start }

      let inBedSpans = splitInBedSpans(
        sessionStart: sessionStart, sessionEnd: sessionEnd, excluding: outOfBedWindows
      ).map { FormattedSample(start: $0.start, end: $0.end, stage: .inBed, sourceIntVal: nil) }

      let stages: [FormattedSample] = item.stages.compactMap { stage in
        // Unsupported Google values (out-of-bed, and anything unrecognized)
        // are deliberately omitted from the detailed stage timeline.
        guard let mapped = SleepStageMapper.map(stage.intVal) else { return nil }
        return FormattedSample(
          start: stage.start, end: stage.end, stage: mapped, sourceIntVal: stage.intVal)
      }
      return FormattedSession(
        sessionStart: sessionStart, sessionEnd: sessionEnd, inBedSpans: inBedSpans, stages: stages)
    }
  }

  /// Subtracts out-of-bed windows from the session range, returning the
  /// remaining continuous "actually in bed" intervals in chronological order.
  /// With no out-of-bed windows, this is just the whole session range — one
  /// `.inBed` span, matching prior behavior exactly.
  private static func splitInBedSpans(
    sessionStart: Date, sessionEnd: Date, excluding outOfBed: [MergedSleepStage]
  ) -> [(start: Date, end: Date)] {
    guard !outOfBed.isEmpty else { return [(sessionStart, sessionEnd)] }

    var spans: [(start: Date, end: Date)] = []
    var cursor = sessionStart
    for window in outOfBed {
      let clampedStart = max(window.start, sessionStart)
      let clampedEnd = min(window.end, sessionEnd)
      guard clampedStart < clampedEnd else { continue }
      if clampedStart > cursor {
        spans.append((cursor, clampedStart))
      }
      cursor = max(cursor, clampedEnd)
    }
    if cursor < sessionEnd {
      spans.append((cursor, sessionEnd))
    }
    return spans
  }

  /// Stage 4 (plain path): checks each formatted sample against what's already
  /// in HealthKit for the same overall time range, and drops exact matches
  /// (same start, end, and stage value). Read-only against HealthKit — writes
  /// nothing. Operates on a flat list — session grouping doesn't matter for
  /// this check. Kept standalone (not just folded into reconcile) since it's
  /// useful on its own for isolating "is duplicate detection working" from
  /// "is version-staleness detection working" while debugging.
  static func dedupe(_ samples: [FormattedSample]) async throws -> (
    toWrite: [FormattedSample], skipped: Int
  ) {
    SyncRunner.log("Stage 4/5: dedupeing \(samples.count) formatted sessions")

    guard let earliestStart = samples.map(\.start).min(), let latestEnd = samples.map(\.end).max()
    else {
      return ([], 0)
    }

    let writer = HealthKitWriter()
    try await writer.requestAuthorization()
    let existing = try await writer.existingSamples(from: earliestStart, to: latestEnd)

    var toWrite: [FormattedSample] = []
    var skipped = 0
    for sample in samples {
      // Compared with a small tolerance rather than exact equality: HealthKit
      // isn't guaranteed to preserve sub-second precision on saved timestamps,
      // so a freshly-computed Date from nanosecond-precision Google Fit data
      // could differ from what HealthKit actually stored by a fraction of a
      // second even for the "same" sample — exact `==` would then never match,
      // and the same data could get silently rewritten on every sync.
      let alreadyExists = existing.contains { e in
        datesMatch(e.startDate, sample.start) && datesMatch(e.endDate, sample.end)
          && e.value == sample.stage.rawValue
      }
      if alreadyExists {
        skipped += 1
      } else {
        toWrite.append(sample)
      }
    }
    return (toWrite, skipped)
  }

  /// Tolerance for deciding whether an existing sample belongs to a session's
  /// range. Separate from (and in addition to) `datesMatch`'s per-sample exact
  /// match: this one exists because a session's own start/end (from Google's
  /// `sessions.list`) and its segment data (from `dataset:aggregate`) are two
  /// separate API responses and aren't guaranteed to agree to the same
  /// millisecond — which specifically bites the leading/trailing Awake
  /// intervals, since those sit right at the session boundary by definition.
  private static let sessionBoundaryTolerance: TimeInterval = 2

  private static func withinSession(_ date: Date, start: Date, end: Date) -> Bool {
    date >= start.addingTimeInterval(-sessionBoundaryTolerance)
      && date <= end.addingTimeInterval(sessionBoundaryTolerance)
  }

  /// Stage 4 (default path): version-aware replacement for plain dedupe.
  /// Reads the pipelineVersion tag off any existing `.inBed` sample belonging
  /// to this session — every stage sample inside the session's window was
  /// necessarily written by the same pipeline run, so one tag is enough to
  /// know the whole session is stale (see
  /// HealthKitWriter.pipelineVersionMetadataKey). A session may now have more
  /// than one `.inBed` sample (see FormattedSession.inBedSpans), so staleness
  /// and replacement are evaluated over the session's full `sessionStart...
  /// sessionEnd` range rather than against a single envelope sample's exact
  /// bounds. If a session is stale, every old in-bed and stage sample within
  /// its range is deleted and the whole session is rewritten unconditionally.
  /// If a session is current, its samples go through ordinary exact-match
  /// dedupe so a routine resync with no logic changes stays cheap.
  static func reconcile(_ sessions: [FormattedSession]) async throws -> (
    toWrite: [FormattedSample], skipped: Int, replacedSessions: Int
  ) {
    SyncRunner.log("Stage 4/5: reconciling \(sessions.count) formatted sessions")

    let flatSamples = sessions.flatMap(\.allSamples)
    guard let earliestStart = flatSamples.map(\.start).min(),
      let latestEnd = flatSamples.map(\.end).max()
    else {
      return ([], 0, 0)
    }

    let writer = HealthKitWriter()
    try await writer.requestAuthorization()
    let existing = try await writer.existingSamplesWrittenByThisApp(
      from: earliestStart, to: latestEnd)

    let existingInBed = existing.filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }
    let existingStages = existing.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue }

    var toWrite: [FormattedSample] = []
    var skipped = 0
    var toDelete: [HKCategorySample] = []
    var replacedSessions = 0

    for session in sessions {
      let matchingInBed = existingInBed.filter {
        withinSession($0.startDate, start: session.sessionStart, end: session.sessionEnd)
          && withinSession($0.endDate, start: session.sessionStart, end: session.sessionEnd)
      }

      let isStale: Bool
      if !matchingInBed.isEmpty {
        isStale = matchingInBed.contains { sample in
          let version = sample.metadata?[HealthKitWriter.pipelineVersionMetadataKey] as? Int
          return version == nil || version! < pipelineVersion
        }
      } else {
        isStale = false
      }

      if isStale {
        toDelete.append(
          contentsOf: existingInBed.filter {
            withinSession($0.startDate, start: session.sessionStart, end: session.sessionEnd)
              && withinSession($0.endDate, start: session.sessionStart, end: session.sessionEnd)
          })
        toDelete.append(
          contentsOf: existingStages.filter {
            withinSession($0.startDate, start: session.sessionStart, end: session.sessionEnd)
              && withinSession($0.endDate, start: session.sessionStart, end: session.sessionEnd)
          })
        toWrite.append(contentsOf: session.allSamples)
        replacedSessions += 1
      } else {
        // per-sample exact-match dedupe only happens here
        for sample in session.allSamples {
          let pool = sample.stage == .inBed ? existingInBed : existingStages
          let alreadyExists = pool.contains { e in
            datesMatch(e.startDate, sample.start) && datesMatch(e.endDate, sample.end)
              && e.value == sample.stage.rawValue
          }
          if alreadyExists {
            skipped += 1
          } else {
            toWrite.append(sample)
          }
        }
      }
    }

    if !toDelete.isEmpty {
      try await writer.delete(toDelete)
    }
    return (toWrite, skipped, replacedSessions)
  }

  /// Unconditional full-range replace: deletes every SleepBridge-authored
  /// sample in the given samples' overall range regardless of version tag,
  /// then returns everything for rewrite. Not wired into the UI — reconcile's
  /// automatic version-gating covers the "logic changed" case on its own.
  /// Kept as a lower-level tool for cases version-gating doesn't cover, e.g.
  /// Google Fit correcting a past night's data retroactively (see
  /// docs/SLEEP_DATA_SCHEMA.md).
  static func replaceExisting(_ samples: [FormattedSample]) async throws -> (
    toWrite: [FormattedSample], deleted: Int
  ) {
    guard let earliestStart = samples.map(\.start).min(), let latestEnd = samples.map(\.end).max()
    else {
      return ([], 0)
    }
    let writer = HealthKitWriter()
    try await writer.requestAuthorization()
    let existing = try await writer.existingSamplesWrittenByThisApp(
      from: earliestStart, to: latestEnd)
    if !existing.isEmpty {
      try await writer.delete(existing)
    }
    return (samples, existing.count)
  }

  /// Tolerance for sample-timestamp comparisons — see the comment in dedupe().
  private static func datesMatch(_ a: Date, _ b: Date) -> Bool {
    abs(a.timeIntervalSince(b)) < 1.0
  }

  /// Stage 5: writes the given samples to HealthKit. Assumes reconcile/dedupe
  /// already ran. Attaches the pipelineVersion tag only to `.inBed` samples
  /// (there may be more than one per session now — see inBedSpans) — see
  /// HealthKitWriter.pipelineVersionMetadataKey for why in-bed tagging is
  /// sufficient and per-stage tagging would be wasteful.
  static func save(_ samples: [FormattedSample]) async throws -> Int {
    SyncRunner.log("Stage 5/5: saving \(samples.count) samples to Apple Health")

    let writer = HealthKitWriter()
    try await writer.requestAuthorization()
    for sample in samples {
      let metadata: [String: Any]? =
        sample.stage == .inBed
        ? [HealthKitWriter.pipelineVersionMetadataKey: pipelineVersion]
        : nil
      try await writer.writeSample(
        start: sample.start, end: sample.end, value: sample.stage, metadata: metadata)
    }
    return samples.count
  }

  /// Runs all five stages back to back for an explicit date range, with no
  /// pausing for review. Used by both SyncRunner (automatic, checkpoint-based
  /// range) and the Diagnostics "Run All Steps" button (manual, picked range) —
  /// one implementation, two callers, so they can't drift apart.
  ///
  /// Uses `reconcile` (version-aware) by default, so a pipelineVersion bump
  /// self-heals affected sessions automatically on the very next sync — no
  /// manual replace step needed for the common "I changed the mapping logic"
  /// case. `forceReplace` is a manual override for cases that isn't
  /// version-related — not currently exposed in the UI.
  static func runAll(since: Date, until: Date = Date(), forceReplace: Bool = false) async throws
    -> PipelineRunResult
  {
    let raw = try await fetchRaw(since: since, until: until)
    let merged = mergeStages(raw)
    let formattedSessions = format(merged)
    let flatSamples = formattedSessions.flatMap(\.allSamples)

    let toWrite: [FormattedSample]
    let skipped: Int
    let replacedSessions: Int

    if forceReplace {
      let result = try await replaceExisting(flatSamples)
      toWrite = result.toWrite
      skipped = 0
      replacedSessions = formattedSessions.count  // whole range rewritten
    } else {
      let result = try await reconcile(formattedSessions)
      toWrite = result.toWrite
      skipped = result.skipped
      replacedSessions = result.replacedSessions
    }

    let written = try await save(toWrite)
    let latestEnd = flatSamples.map(\.end).max()

    return PipelineRunResult(
      formattedSessions: formattedSessions, written: written, skipped: skipped,
      replacedSessions: replacedSessions, latestEnd: latestEnd)
  }
}
