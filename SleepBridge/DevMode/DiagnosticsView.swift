import SwiftUI

/// Developer-only screen for exercising each external dependency and each
/// pipeline stage independently. It is intentionally separate from the normal
/// one-tap sync path used by the app and Shortcuts.
struct DiagnosticsView: View {
    // Smoke tests
    @State private var authResult = ""
    @State private var writeTestResult = ""
    @State private var deleteTestResult = ""
    @State private var isBusyAuth = false
    @State private var isBusyWriteTest = false
    @State private var isBusyDeleteTest = false

    // Step-by-step pipeline
    @State private var rangeStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var rangeEnd = Date()
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

    var body: some View {
        Form {
            Section("Quick smoke tests") {
                actionRow("Test Google Auth", isBusy: isBusyAuth, result: authResult) {
                    isBusyAuth = true
                    authResult = await DiagnosticsRunner.testGoogleAuth()
                    isBusyAuth = false
                }
                actionRow("Write Test Sample (Jan 1, 2000)", isBusy: isBusyWriteTest, result: writeTestResult) {
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

            Section("Pick a date range") {
                DatePicker("Start", selection: $rangeStart)
                DatePicker("End", selection: $rangeEnd)
                Text("Cached results between steps expire after 30 minutes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Step 1: Fetch raw Google Fit data") {
                actionRow("Fetch Raw", isBusy: isBusyFetch, result: fetchResult, monospace: true) {
                    isBusyFetch = true
                    fetchResult = await DiagnosticsRunner.fetchRaw(since: rangeStart, until: rangeEnd)
                    isBusyFetch = false
                }
            }

            Section("Step 2: Merge into stage runs") {
                actionRow("Merge Stages", isBusy: isBusyMerge, result: mergeResult, monospace: true) {
                    isBusyMerge = true
                    mergeResult = DiagnosticsRunner.mergeCached()
                    isBusyMerge = false
                }
            }

            Section("Step 3: Format for Apple Health") {
                actionRow("Format", isBusy: isBusyFormat, result: formatResult, monospace: true) {
                    isBusyFormat = true
                    formatResult = DiagnosticsRunner.formatCached()
                    isBusyFormat = false
                }
            }

            Section("Step 4: Check for duplicates") {
                actionRow("Check Duplicates", isBusy: isBusyDedupe, result: dedupeResult) {
                    isBusyDedupe = true
                    dedupeResult = await DiagnosticsRunner.checkDuplicatesCached()
                    isBusyDedupe = false
                }
            }

            Section("Step 5: Save to Apple Health") {
                actionRow("Save to Apple Health", isBusy: isBusySave, result: saveResult) {
                    isBusySave = true
                    saveResult = await DiagnosticsRunner.saveCached()
                    isBusySave = false
                }
            }
        }
        .navigationTitle("Diagnostics")
    }

    @ViewBuilder
    private func actionRow(
        _ title: String,
        isBusy: Bool,
        result: String,
        monospace: Bool = false,
        action: @escaping () async -> Void
    ) -> some View {
        // Each button owns its busy state so an in-flight operation cannot be started twice.
        VStack(alignment: .leading, spacing: 4) {
            Button(isBusy ? "Running…" : title) {
                Task { await action() }
            }
            .disabled(isBusy)

            if !result.isEmpty {
                ScrollView {
                    Text(result)
                        .font(monospace ? .system(.caption2, design: .monospaced) : .caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
        }
    }
}
