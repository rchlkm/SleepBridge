import SwiftUI

private enum DiagnosticsMode: String, CaseIterable, Identifiable {
  case runAll = "Run All"
  case stepByStep = "Step by Step"
  var id: String { rawValue }
}

struct DiagnosticsView: View {
  @State private var mode: DiagnosticsMode = .runAll

  // Quick checks
  @State private var authResult = ""
  @State private var writeTestResult = ""
  @State private var deleteTestResult = ""
  @State private var isBusyAuth = false
  @State private var isBusyWriteTest = false
  @State private var isBusyDeleteTest = false

  // Date range (calendar days only — noon-to-noon applied under the hood)
  @State private var rangeStartDay =
    Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
  @State private var rangeEndDay = Date()

  // Step-by-step pipeline
  @State private var fetchResult = ""
  @State private var mergeResult = ""
  @State private var formatResult = ""
  @State private var dedupeResult = ""
  @State private var saveResult = ""
  @State private var isBusyFetch = false
  @State private var isBusyMerge = false
  @State private var isBusyFormat = false
  @State private var isBusyDedupe = false
  @State private var isBusySave = false

  // Run all at once
  @State private var runAllResult = ""
  @State private var isBusyRunAll = false

  // Backup export
  @State private var exportResult = ""
  @State private var exportFileURL: URL?
  @State private var isBusyExport = false
  @State private var showShareSheet = false

  var body: some View {
    Form {
      Section {
        Text("Quick checks that one narrow piece works, independent of the full pipeline below.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } header: {
        Text("Quick Checks")
      }

      Section {
        actionRow("Test Google Auth", isBusy: isBusyAuth, result: authResult) {
          isBusyAuth = true
          authResult = await DiagnosticsRunner.testGoogleAuth()
          isBusyAuth = false
        }
        actionRow(
          "Write Test Sample (Jan 1, 2000)", isBusy: isBusyWriteTest, result: writeTestResult
        ) {
          isBusyWriteTest = true
          writeTestResult = await DiagnosticsRunner.testHealthKitWrite()
          isBusyWriteTest = false
        }
        actionRow("Delete Test Sample", isBusy: isBusyDeleteTest, result: deleteTestResult) {
          isBusyDeleteTest = true
          deleteTestResult = await DiagnosticsRunner.deleteTestSample()
          isBusyDeleteTest = false
        }
      }

      Section("Date range") {
        DateRangeCalendarView(startDay: $rangeStartDay, endDay: $rangeEndDay)
        Text(
          "Times aren't shown — noon to noon is used under the hood so each window lines up with one night's sleep. Future dates are disabled."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }

      Section {
        actionRow("Export Raw Data", isBusy: isBusyExport, result: exportResult) {
          isBusyExport = true
          let (message, url) = await DiagnosticsRunner.exportRawData(
            since: effectiveRange.start, until: effectiveRange.end)
          exportResult = message
          exportFileURL = url
          isBusyExport = false
        }
        if exportFileURL != nil {
          Button("Share / Save File") {
            showShareSheet = true
          }
        }
      } header: {
        Label("Backup", systemImage: "externaldrive.badge.icloud")
      } footer: {
        Text(
          "Saves everything Google Fit has for the selected range to a file you keep yourself — a safety net in case Google shuts the API off before you've synced it all."
        )
      }
      .listRowBackground(Color.orange.opacity(0.12))

      Section {
        Picker("Mode", selection: $mode) {
          ForEach(DiagnosticsMode.allCases) { m in
            Text(m.rawValue).tag(m)
          }
        }
        .pickerStyle(.segmented)
      } footer: {
        Text(
          mode == .runAll
            ? "Runs fetch → merge → format → dedupe → save in one tap for the range above. This is the same thing the automatic daily sync does."
            : "Runs each stage separately so you can inspect the output in between — useful for tracking down exactly where something's going wrong."
        )
      }

      if mode == .runAll {
        Section("Writes to Apple Health") {
          actionRow("Run All Steps", isBusy: isBusyRunAll, result: runAllResult, monospace: true) {
            isBusyRunAll = true
            runAllResult = await DiagnosticsRunner.runAllSteps(
              since: effectiveRange.start, until: effectiveRange.end)
            isBusyRunAll = false
          }
        }
      } else {
        Section("1. Fetch raw Google Fit data") {
          actionRow("Fetch Raw", isBusy: isBusyFetch, result: fetchResult, monospace: true) {
            isBusyFetch = true
            fetchResult = await DiagnosticsRunner.fetchRaw(
              since: effectiveRange.start, until: effectiveRange.end)
            isBusyFetch = false
          }
        }
        Section("2. Merge into stage runs") {
          actionRow("Merge Stages", isBusy: isBusyMerge, result: mergeResult, monospace: true) {
            isBusyMerge = true
            mergeResult = DiagnosticsRunner.mergeCached()
            isBusyMerge = false
          }
        }
        Section("3. Format for Apple Health") {
          actionRow("Format", isBusy: isBusyFormat, result: formatResult, monospace: true) {
            isBusyFormat = true
            formatResult = DiagnosticsRunner.formatCached()
            isBusyFormat = false
          }
        }
        Section("4. Check for duplicates") {
          actionRow("Check Duplicates", isBusy: isBusyDedupe, result: dedupeResult) {
            isBusyDedupe = true
            dedupeResult = await DiagnosticsRunner.checkDuplicatesCached()
            isBusyDedupe = false
          }
        }
        Section("5. Save to Apple Health") {
          actionRow("Save to Apple Health", isBusy: isBusySave, result: saveResult) {
            isBusySave = true
            saveResult = await DiagnosticsRunner.saveCached()
            isBusySave = false
          }
        }
      }
    }
    .navigationTitle("Diagnostics")
    .sheet(isPresented: $showShareSheet) {
      if let url = exportFileURL {
        ShareSheet(items: [url])
      }
    }
  }

  /// Converts the calendar-day-only picker selection into an actual noon-to-noon
  /// Date range — a night of sleep straddles midnight, so noon-to-noon lines up
  /// with "one night" better than midnight-to-midnight would.
  private var effectiveRange: (start: Date, end: Date) {
    let calendar = Calendar.current
    let start =
      calendar.date(bySettingHour: 12, minute: 0, second: 0, of: rangeStartDay) ?? rangeStartDay
    let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: rangeEndDay) ?? rangeEndDay
    return (start, end)
  }

  @ViewBuilder
  private func actionRow(
    _ title: String,
    isBusy: Bool,
    result: String,
    monospace: Bool = false,
    action: @escaping () async -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Button(isBusy ? "Running…" : title) {
        Task { await action() }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isBusy)

      if !result.isEmpty {
        CopyableOutputView(text: result, monospace: monospace)
      }
    }
  }
}
