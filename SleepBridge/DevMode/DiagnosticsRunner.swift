import Foundation
import HealthKit
import UIKit

/// Thin wrappers around SleepPipeline's stages, adding caching between steps
/// and human-readable summaries for the diagnostics screen. The actual logic
/// lives in SleepPipeline.swift — this file doesn't duplicate it.
enum DiagnosticsRunner {

    // MARK: - Quick smoke tests (unrelated to the real pipeline / cache)

    static func testGoogleAuth() async -> String {
        guard CredentialStore.hasAllCredentials() else {
            return "❌ No credentials saved yet — enter them above first."
        }
        do {
            let token = try await GoogleFitClient().accessToken()
            return "✅ Got access token: \(String(token.prefix(12)))…"
        } catch {
            return "❌ Auth failed: \(error)"
        }
    }

    /// Writes one throwaway sample dated Jan 1, 2000 to confirm HealthKit
    /// write access works, independent of any real Google Fit data.
    static func testHealthKitWrite() async -> String {
        do {
            let writer = HealthKitWriter()
            try await writer.requestAuthorization()
            let (start, end) = testSampleRange()
            try await writer.writeSample(start: start, end: end, value: .awake)
            return "✅ Wrote a 1-minute test sample dated Jan 1, 2000. Use 'Delete Test Sample' below to remove it, or check Health app → Browse → Sleep."
        } catch {
            return "❌ HealthKit write failed: \(error)"
        }
    }

    /// Removes the Jan 1, 2000 test sample written by testHealthKitWrite().
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

    /// Stage 1: fetch raw Google Fit data for the given range, cache it, and
    /// return a raw, unmapped dump — one line per minute, exactly what Google
    /// Fit returned, before any merging or formatting.
    static func fetchRaw(since: Date, until: Date) async -> String {
        do {
            let raw = try await SleepPipeline.fetchRaw(since: since, until: until)
            PipelineCache.rawResult = raw
            PipelineCache.rawFetchedAt = Date()

            guard !raw.sessions.isEmpty else {
                return "⚠️ No sleep sessions found in that range."
            }

            var lines = ["✅ \(raw.sessions.count) session(s) — raw Google Fit data (\(raw.sessions.reduce(0) { $0 + $1.points.count }) point(s) total):"]
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

    /// Stage 2: collapses the cached raw per-minute points into contiguous runs
    /// per stage — this is the step that turns "60 identical one-minute rows"
    /// into "one row covering that whole hour."
    static func mergeCached() -> String {
        guard PipelineCache.isFresh(PipelineCache.rawFetchedAt), let raw = PipelineCache.rawResult else {
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

    /// Stage 3: formats the cached merged data into Apple Health categories.
    static func formatCached() -> String {
        guard PipelineCache.isFresh(PipelineCache.mergedAt), let merged = PipelineCache.mergedResult else {
            return "❌ No fresh merged data cached — run 'Merge Stages' first."
        }

        let formatted = SleepPipeline.format(merged)
        PipelineCache.formattedSamples = formatted
        PipelineCache.formattedAt = Date()

        return copyAndReturn(debugFormatted(formatted))
    }

    /// Purely for debugging — readable stage names and formatted dates instead of
    /// raw Swift Date descriptions, so the clipboard output is actually eyeball-able.
    static func debugFormatted(_ samples: [FormattedSample]) -> String {
        guard !samples.isEmpty else {
            return "⚠️ No formatted samples."
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.timeZone = .current
        var lines = ["✅ \(samples.count) formatted sample(s):"]
        for sample in samples {
            let stage = SleepStageMapper.sleepStageName(sample.stage)
            let source = sample.sourceIntVal.map(SleepStageMapper.sleepSourceName) ?? "Synthesized"
            lines.append(
                "  \(stage)  \(formatter.string(from: sample.start)) → \(formatter.string(from: sample.end))  (Google Fit: \(source))"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Stage 4: checks the cached formatted samples against what's already in
    /// HealthKit, caching only the ones that don't already exist.
    static func checkDuplicatesCached() async -> String {
        guard PipelineCache.isFresh(PipelineCache.formattedAt), let formatted = PipelineCache.formattedSamples else {
            return "❌ No fresh formatted data cached — run 'Format' first."
        }
        do {
            let (toWrite, skipped) = try await SleepPipeline.dedupe(formatted)
            PipelineCache.dedupedSamples = toWrite
            PipelineCache.skippedDuplicateCount = skipped
            PipelineCache.dedupedAt = Date()
            return "✅ \(toWrite.count) new sample(s) to write, \(skipped) already exist and will be skipped."
        } catch {
            return "❌ Duplicate check failed: \(error)"
        }
    }

    /// Stage 5: writes the cached, deduped samples to HealthKit.
    static func saveCached() async -> String {
        guard PipelineCache.isFresh(PipelineCache.dedupedAt), let toWrite = PipelineCache.dedupedSamples else {
            return "❌ No fresh deduped data cached — run 'Check Duplicates' first."
        }
        do {
            let written = try await SleepPipeline.save(toWrite)
            let skipped = PipelineCache.skippedDuplicateCount ?? 0
            PipelineCache.clear() // avoid accidentally re-saving the same batch on a second tap
            return "✅ Wrote \(written) sample(s) to Apple Health (\(skipped) duplicate(s) were skipped)."
        } catch {
            return "❌ Save failed: \(error)"
        }
    }

    private static func copyAndReturn(_ text: String) -> String {
        UIPasteboard.general.string = text
        return text
    }
}
