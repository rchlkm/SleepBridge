import Foundation
import HealthKit

/// The fully-automatic path — calls SleepPipeline.runAll() with no pausing for
/// review. This is what the Shortcuts automation triggers via
/// SyncSleepDataIntent, and also what "Sync Now" on the main screen calls.
enum SyncRunner {
    /// App-private storage for the last successful sync checkpoint and human-readable log.
    private static var stateDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    // The checkpoint controls incremental fetching; the log makes scheduled runs inspectable.
    private static var checkpointPath: String { stateDir.appendingPathComponent("checkpoint.txt").path }
    private static var logPath: String { stateDir.appendingPathComponent("run.log").path }

    /// Appends a timestamped entry both to Xcode's console and the persistent local log.
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
    /// Returns the entire persisted run log for display on the main screen.
    static func recentLog() -> String {
        (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "(no runs yet)"
    }
    /// Starts from the prior successful endpoint, or the past 24 hours on first run.
    private static func readCheckpoint() -> Date {
        if let text = try? String(contentsOfFile: checkpointPath, encoding: .utf8),
           let date = ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return date
        }
        return Date().addingTimeInterval(-24 * 60 * 60)
    }
    /// Advances the checkpoint only after every pipeline stage has completed successfully.
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
                return "Missing credentials — open Settings to set up."
            }

            let since = readCheckpoint()
            log("Running full pipeline since \(since)")
            log("Stage 1/5: fetching since \(since)")

            let result = try await SleepPipeline.runAll(since: since)

            if let latestEnd = result.latestEnd {
                writeCheckpoint(latestEnd)
            }

            let summary = "Wrote \(result.written) new sample(s), skipped \(result.skipped) duplicate(s)."
            log("Done. \(summary)")
            return summary
        } catch {
            log("ERROR: \(error)")
            return "Error: \(error.localizedDescription)"
        }
    }
}
