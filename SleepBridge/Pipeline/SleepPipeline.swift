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
    /// The original Google Fit intVal this came from, nil for the synthesized
    /// in-bed span (which Google Fit doesn't track as its own concept).
    let sourceIntVal: Int?
}

/// One formatted session, keeping the in-bed envelope and its stage samples
/// grouped explicitly — rather than flattened into one list and re-inferred
/// later by scanning for `.inBed` markers, which breaks if dedupe ever filters
/// the envelope sample out while keeping its stages (or vice versa).
struct FormattedSession {
    let inBed: FormattedSample
    let stages: [FormattedSample]

    /// All samples in this session, envelope first — the shape dedupe/save need.
    var allSamples: [FormattedSample] { [inBed] + stages }
}

/// Result of running all five stages back to back with no pausing for review.
struct PipelineRunResult {
    let formattedSessions: [FormattedSession]
    let written: Int
    let skipped: Int
    /// The latest sample end time seen, nil if nothing was found in range.
    /// Callers that track a checkpoint (SyncRunner) use this to advance it.
    let latestEnd: Date?
}

enum SleepPipeline {

    /// Stage 1: raw Google Fit data only, no formatting or mapping applied.
    static func fetchRaw(since: Date, until: Date = Date()) async throws -> RawFetchResult {
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
        let mergedSessions = raw.sessions.map { item -> MergedSession in
            let sortedPoints = item.points.sorted { $0.start < $1.start }
            var stages: [MergedSleepStage] = []

            for point in sortedPoints {
                if let last = stages.last, last.intVal == point.intVal, last.end == point.start {
                    // Contiguous with the current run — extend it instead of adding a new stage.
                    stages[stages.count - 1] = MergedSleepStage(intVal: last.intVal, start: last.start, end: point.end)
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
        merged.sessions.map { item -> FormattedSession in
            let sessionStart = Date(timeIntervalSince1970: Double(item.session.startTimeMillis) / 1000)
            let sessionEnd = Date(timeIntervalSince1970: Double(item.session.endTimeMillis) / 1000)
            // HealthKit benefits from an overall in-bed envelope; Google Fit does not emit one.
            let inBed = FormattedSample(start: sessionStart, end: sessionEnd, stage: .inBed, sourceIntVal: nil)

            let stages: [FormattedSample] = item.stages.compactMap { stage in
                // Unsupported Google values (such as out-of-bed) are deliberately omitted.
                guard let mapped = SleepStageMapper.map(stage.intVal) else { return nil }
                return FormattedSample(start: stage.start, end: stage.end, stage: mapped, sourceIntVal: stage.intVal)
            }
            return FormattedSession(inBed: inBed, stages: stages)
        }
    }

    /// Stage 4: checks each formatted sample against what's already in HealthKit
    /// for the same overall time range, and drops exact matches (same start,
    /// end, and stage value). Read-only against HealthKit — writes nothing.
    /// Operates on a flat list — session grouping doesn't matter for this check.
    static func dedupe(_ samples: [FormattedSample]) async throws -> (toWrite: [FormattedSample], skipped: Int) {
        guard let earliestStart = samples.map(\.start).min(), let latestEnd = samples.map(\.end).max() else {
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
                datesMatch(e.startDate, sample.start) && datesMatch(e.endDate, sample.end) && e.value == sample.stage.rawValue
            }
            if alreadyExists {
                skipped += 1
            } else {
                toWrite.append(sample)
            }
        }
        return (toWrite, skipped)
    }

    /// Tolerance for the dedupe timestamp comparison — see the comment in dedupe().
    private static func datesMatch(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 1.0
    }

    /// Stage 5: writes the given samples to HealthKit. Assumes dedupe already ran.
    static func save(_ samples: [FormattedSample]) async throws -> Int {
        let writer = HealthKitWriter()
        try await writer.requestAuthorization()
        for sample in samples {
            try await writer.writeSample(start: sample.start, end: sample.end, value: sample.stage)
        }
        return samples.count
    }

    /// Runs all five stages back to back for an explicit date range, with no
    /// pausing for review. Used by both SyncRunner (automatic, checkpoint-based
    /// range) and the Diagnostics "Run All Steps" button (manual, picked range) —
    /// one implementation, two callers, so they can't drift apart.
    static func runAll(since: Date, until: Date = Date()) async throws -> PipelineRunResult {
        let raw = try await fetchRaw(since: since, until: until)
        let merged = mergeStages(raw)
        let formattedSessions = format(merged)

        let flatSamples = formattedSessions.flatMap(\.allSamples)
        let (toWrite, skipped) = try await dedupe(flatSamples)
        let written = try await save(toWrite)
        let latestEnd = flatSamples.map(\.end).max()

        return PipelineRunResult(formattedSessions: formattedSessions, written: written, skipped: skipped, latestEnd: latestEnd)
    }
}
