import Foundation
import HealthKit

struct SessionWithPoints {
    let session: SleepSession
    let points: [SleepSegmentPoint]
}

struct RawFetchResult {
    let sessions: [SessionWithPoints]
    let rangeStart: Date
    let rangeEnd: Date
}

struct MergedSleepStage {
    let intVal: Int
    let start: Date
    let end: Date
}

struct MergedSession {
    let session: SleepSession
    let stages: [MergedSleepStage]
}

struct MergedFetchResult {
    let sessions: [MergedSession]
}

struct FormattedSample {
    let start: Date
    let end: Date
    let stage: HKCategoryValueSleepAnalysis
    /// The original Google Fit intVal this came from, nil for the synthesized
    /// in-bed span (which Google Fit doesn't track as its own concept).
    let sourceIntVal: Int?
}

enum SleepPipeline {

    /// Stage 1: raw Google Fit data only, no formatting or mapping applied.
    static func fetchRaw(since: Date, until: Date = Date()) async throws -> RawFetchResult {
        let client = GoogleFitClient()
        let sessions = try await client.listSleepSessions(since: since, until: until)

        var sessionsWithPoints: [SessionWithPoints] = []
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
    /// Pure function — no network, no HealthKit calls, just the mapping table.
    static func format(_ merged: MergedFetchResult) -> [FormattedSample] {
        var samples: [FormattedSample] = []
        for item in merged.sessions {
            let sessionStart = Date(timeIntervalSince1970: Double(item.session.startTimeMillis) / 1000)
            let sessionEnd = Date(timeIntervalSince1970: Double(item.session.endTimeMillis) / 1000)
            samples.append(FormattedSample(start: sessionStart, end: sessionEnd, stage: .inBed, sourceIntVal: nil))

            for stage in item.stages {
                guard let mapped = SleepStageMapper.map(stage.intVal) else { continue }
                samples.append(FormattedSample(start: stage.start, end: stage.end, stage: mapped, sourceIntVal: stage.intVal))
            }
        }
        return samples
    }

    /// Stage 4: checks each formatted sample against what's already in HealthKit
    /// for the same overall time range, and drops exact matches (same start,
    /// end, and stage value). Read-only against HealthKit — writes nothing.
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
            let alreadyExists = existing.contains { e in
                e.startDate == sample.start && e.endDate == sample.end && e.value == sample.stage.rawValue
            }
            if alreadyExists {
                skipped += 1
            } else {
                toWrite.append(sample)
            }
        }
        return (toWrite, skipped)
    }

    /// Stage 5: writes the given samples to HealthKit. Assumes dedupe already ran —
    /// this stage doesn't check for duplicates itself, on purpose, so it stays a
    /// single-responsibility "just write what I'm handed" function.
    static func save(_ samples: [FormattedSample]) async throws -> Int {
        let writer = HealthKitWriter()
        try await writer.requestAuthorization()
        for sample in samples {
            try await writer.writeSample(start: sample.start, end: sample.end, value: sample.stage)
        }
        return samples.count
    }
}
