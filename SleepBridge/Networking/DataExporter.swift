import Foundation

enum DataExporter {
    /// Fetches raw Google Fit data for the given range and writes it to a JSON
    /// file in a temporary location, ready to save via the share sheet (Files,
    /// iCloud Drive, email to yourself, AirDrop, etc). This is a backup
    /// mechanism — Google Fit's API is being wound down, so this lets you grab
    /// everything now regardless of whether the sync pipeline itself has
    /// caught up on it yet.
    static func exportRawData(since: Date, until: Date) async -> (message: String, fileURL: URL?) {
        do {
            let raw = try await SleepPipeline.fetchRaw(since: since, until: until)
            guard !raw.sessions.isEmpty else {
                return ("⚠️ No sessions found in that range — nothing to export.", nil)
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(raw)

            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            let filename = "googlefit-sleep-export-\(dayFormatter.string(from: since))-to-\(dayFormatter.string(from: until)).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url)

            let totalPoints = raw.sessions.reduce(0) { $0 + $1.points.count }
            return ("✅ Exported \(raw.sessions.count) session(s), \(totalPoints) raw point(s) → \(filename)", url)
        } catch {
            return ("❌ Export failed: \(error)", nil)
        }
    }
}
