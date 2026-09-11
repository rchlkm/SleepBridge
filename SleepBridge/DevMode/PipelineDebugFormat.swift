import Foundation
import HealthKit

/// Single source of truth for turning any pipeline stage's output into
/// human-readable text. Every stage renders through here so results look
/// identical regardless of which stage produced them — one date format, one
/// column layout, one delimiter style. That consistency also makes the
/// output easy to paste elsewhere and parse mechanically: fixed-width label
/// column, fixed arrow separator, duration always in parentheses.
enum PipelineDebugFormat {

  private static let dateTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd-yyyy h:mm:ss a"
    return f
  }()

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "h:mm:ss a"
    return f
  }()

  static func dateTime(_ date: Date) -> String { dateTimeFormatter.string(from: date) }
  static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

  /// "1h 23m" or "4m 05s" — quick glance at span length without doing math
  /// on two timestamps yourself.
  static func duration(_ start: Date, _ end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    return h > 0 ? String(format: "%dh %02dm", h, m) : String(format: "%dm %02ds", m, s)
  }

  /// Pads without truncating — `String.padding(toLength:)` silently cuts off
  /// labels longer than the target width, which would have quietly mangled
  /// "Asleep (Unspecified)" (21 chars) at anything under a 21-wide column.
  private static func pad(_ s: String, to width: Int) -> String {
    guard s.count < width else { return s + " " }
    return s + String(repeating: " ", count: width - s.count)
  }

  private static let labelWidth = 22

  /// One row shape used everywhere a stage/interval needs to be shown:
  ///   LABEL                  h:mm:ss a → h:mm:ss a  (duration)
  private static func row(_ label: String, _ start: Date, _ end: Date) -> String {
    "\(pad(label, to: labelWidth))\(time(start)) → \(time(end))  (\(duration(start, end)))"
  }

  // MARK: - Stage 1: Fetch Raw

  static func render(_ raw: RawFetchResult) -> String {
    guard !raw.sessions.isEmpty else { return "No sleep sessions found in that range." }

    var lines: [String] = [
      "\(raw.sessions.count) session(s), \(raw.sessions.reduce(0) { $0 + $1.points.count }) raw point(s) total"
    ]
    for item in raw.sessions {
      let start = Date(timeIntervalSince1970: Double(item.session.startTimeMillis) / 1000)
      let end = Date(timeIntervalSince1970: Double(item.session.endTimeMillis) / 1000)
      lines.append("")
      lines.append("SESSION  \(dateTime(start)) → \(dateTime(end))")
      for point in item.points {
        lines.append(
          "  " + row(SleepStageMapper.sleepSourceName(point.intVal), point.start, point.end))
      }
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Stage 2: Merge Stages

  static func render(_ merged: MergedFetchResult) -> String {
    guard !merged.sessions.isEmpty else { return "Nothing to merge." }

    var lines: [String] = ["\(merged.sessions.count) session(s) merged"]
    for session in merged.sessions {
      let start = Date(timeIntervalSince1970: Double(session.session.startTimeMillis) / 1000)
      let end = Date(timeIntervalSince1970: Double(session.session.endTimeMillis) / 1000)
      lines.append("")
      lines.append(
        "SESSION  \(dateTime(start)) → \(dateTime(end))  — \(session.stages.count) merged stage(s)")
      for stage in session.stages {
        lines.append(
          "  " + row(SleepStageMapper.sleepSourceName(stage.intVal), stage.start, stage.end))
      }
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Stage 3: Formatted sessions (also used by Run All's summary)

  static func render(_ sessions: [FormattedSession]) -> String {
    guard !sessions.isEmpty else { return "No formatted sessions." }

    var lines: [String] = []
    for session in sessions {
      lines.append("SESSION  \(dateTime(session.sessionStart)) → \(dateTime(session.sessionEnd))")
      for inBed in session.inBedSpans {
        lines.append("  " + row("In Bed", inBed.start, inBed.end))
      }
      for stage in session.stages {
        lines.append(
          "  " + row(SleepStageMapper.sleepStageName(stage.stage), stage.start, stage.end))
      }
      lines.append("")
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Stage 4/5 one-line summaries

  static func reconcileSummary(toWriteCount: Int, skipped: Int, replacedSessions: Int) -> String {
    var s = "\(toWriteCount) sample(s) to write, \(skipped) already exist and will be skipped."
    if replacedSessions > 0 {
      s +=
        " \(replacedSessions) session(s) were stale (older pipeline version) and will be fully replaced."
    }
    return s
  }

  static func saveSummary(written: Int, skipped: Int, replacedSessions: Int) -> String {
    var s = "Wrote \(written) sample(s) to Apple Health (\(skipped) duplicate(s) skipped)."
    if replacedSessions > 0 {
      s += " \(replacedSessions) stale session(s) replaced."
    }
    return s
  }
}
