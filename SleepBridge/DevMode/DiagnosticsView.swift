import SwiftUI

struct DiagnosticsView: View {
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

  // Pipeline stages
  @State private var stageResults: [DiagnosticsRunner.PipelineStage: String] = [:]
  @State private var busyStage: DiagnosticsRunner.PipelineStage?
  @State private var expandedStage: DiagnosticsRunner.PipelineStage?
  @State private var showSaveConfirm = false

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
          Button("Share / Save File") { showShareSheet = true }
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
        ForEach(DiagnosticsRunner.PipelineStage.allCases) { stage in
          stageRow(stage)
        }
      } header: {
        Text("Pipeline")
      } footer: {
        Text(
          "Tap any stage to run it — earlier stages run automatically first if their cache is stale, using cached results where still fresh. \"Save\" is the only stage that writes to Apple Health."
        )
      }
    }
    .navigationTitle("Diagnostics")
    .sheet(isPresented: $showShareSheet) {
      if let url = exportFileURL {
        ShareSheet(items: [url])
      }
    }
    .alert("Write to Apple Health?", isPresented: $showSaveConfirm) {
      Button("Cancel", role: .cancel) {}
      Button("Save", role: .destructive) {
        Task { await runStage(.save) }
      }
    } message: {
      Text(
        "This runs any needed prior stages, then writes new samples to Apple Health for the selected range."
      )
    }
  }

  private var effectiveRange: (start: Date, end: Date) {
    let calendar = Calendar.current
    let start =
      calendar.date(bySettingHour: 12, minute: 0, second: 0, of: rangeStartDay) ?? rangeStartDay
    let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: rangeEndDay) ?? rangeEndDay
    return (start, end)
  }

  @ViewBuilder
  private func stageRow(_ stage: DiagnosticsRunner.PipelineStage) -> some View {
    let isBusy = busyStage == stage
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button {
          if stage == .save {
            showSaveConfirm = true
          } else {
            Task { await runStage(stage) }
          }
        } label: {
          HStack {
            Text(stage.title)
            Spacer()
            statusBadge(for: stage)
          }
        }
        .disabled(busyStage != nil)
      }

      if isBusy {
        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
      } else if let result = stageResults[stage] {
        DisclosureGroup(
          isExpanded: Binding(
            get: { expandedStage == stage },
            set: { expandedStage = $0 ? stage : nil }
          )
        ) {
          CopyableOutputView(text: result, monospace: true, maxHeight: 220)
        } label: {
          Text("Output")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private func statusBadge(for stage: DiagnosticsRunner.PipelineStage) -> some View {
    switch DiagnosticsRunner.status(for: stage) {
    case .notRun:
      badge("Not run", color: .secondary)
    case .stale:
      badge("Stale", color: .orange)
    case .fresh(let date):
      badge("Fresh · \(relativeMinutes(date))", color: .green)
    }
  }

  private func badge(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.caption2.weight(.medium))
      .foregroundStyle(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.15), in: Capsule())
  }

  private func relativeMinutes(_ date: Date) -> String {
    let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
    return minutes == 0 ? "just now" : "\(minutes)m ago"
  }

  private func runStage(_ stage: DiagnosticsRunner.PipelineStage) async {
    busyStage = stage
    let result = await DiagnosticsRunner.run(
      stage, since: effectiveRange.start, until: effectiveRange.end)
    stageResults[stage] = result
    expandedStage = stage
    busyStage = nil
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
