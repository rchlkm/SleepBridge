import SwiftUI

@main
struct SleepBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var statusMessage: String = ""
    @State private var isSyncing: Bool = false
    @State private var logText: String = SyncRunner.recentLog()

    var body: some View {
        NavigationView {
            Form {
                Section("Manual sync") {
                    Button(isSyncing ? "Syncing…" : "Sync Now") {
                        Task {
                            isSyncing = true
                            statusMessage = await SyncRunner.run()
                            logText = SyncRunner.recentLog()
                            isSyncing = false
                        }
                    }
                    .disabled(isSyncing)

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Recent log") {
                    ScrollView {
                        Text(logText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 200)
                }
            }
            .navigationTitle("SleepBridge")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                    }
                }
            }
        }
    }
}
