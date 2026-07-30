import Foundation
import HealthKit

/// The fully-automatic path — runs all four SleepPipeline stages in sequence
/// with no pausing for review, no cache needed. This is what the Shortcuts
/// automation triggers via SyncSleepDataIntent, and also what "Sync Now"
/// on the main screen calls.
enum SyncRunner {
    private static var stateDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var checkpointPath: String { stateDir.appendingPathComponent("checkpoint.txt").path }
    private static var logPath: String { stateDir.appendingPathComponent("run.log").path }

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line, terminator: "")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    static func recentLog() -> String {
        (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "(no runs yet)"
    }

    private static func readCheckpoint() -> Date {
        if let text = try? String(contentsOfFile: checkpointPath, encoding: .utf8),
           let date = ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return date
        }
        return Date().addingTimeInterval(-24 * 60 * 60)
    }

    private static func writeCheckpoint(_ date: Date) {
        let text = ISO8601DateFormatter().string(from: date)
        try? text.write(toFile: checkpointPath, atomically: true, encoding: .utf8)
    }

    @discardableResult
    static func run() async -> String {
        do {
            log("Starting sync run")

            guard CredentialStore.hasAllCredentials() else {
                log("ERROR: Google credentials not set up yet.")
                return "Missing credentials — open the app once to set up."
            }

            let since = readCheckpoint()
            log("Stage 1/5: fetching since \(since)")
            let raw = try await SleepPipeline.fetchRaw(since: since)
            log("  found \(raw.sessions.count) session(s)")

            log("Stage 2/5: merging per-minute points into runs")
            let merged = SleepPipeline.mergeStages(raw)

            log("Stage 3/5: formatting")
            let formatted = SleepPipeline.format(merged)
            log("  \(formatted.count) sample(s) formatted")

            log("Stage 4/5: checking for duplicates")
            let (toWrite, skipped) = try await SleepPipeline.dedupe(formatted)
            log("  \(toWrite.count) new, \(skipped) already existed")

            log("Stage 5/5: saving")
            let written = try await SleepPipeline.save(toWrite)

            let latestEnd = formatted.map(\.end).max() ?? since
            writeCheckpoint(latestEnd)

            let summary = "Wrote \(written) new sample(s), skipped \(skipped) duplicate(s). Checkpoint advanced to \(latestEnd)"
            log("Done. \(summary)")
            return summary
        } catch {
            log("ERROR: \(error)")
            return "Error: \(error.localizedDescription)"
        }
    }
}
