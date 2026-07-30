import SwiftUI

@main
/// App entry point. The main screen owns setup credentials and one-tap sync.
struct SleepBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Main configuration and manual-sync screen.
struct ContentView: View {
    // OAuth values are loaded from Keychain once when the view is created.
    @State private var clientId: String = CredentialStore.read(key: "clientId") ?? ""
    @State private var clientSecret: String = CredentialStore.read(key: "clientSecret") ?? ""
    @State private var refreshToken: String = CredentialStore.read(key: "refreshToken") ?? ""
    @State private var statusMessage: String = ""
    @State private var isSyncing: Bool = false
    @State private var logText: String = SyncRunner.recentLog()

    var body: some View {
        NavigationView {
            Form {
                Section("Google Fit credentials (one-time setup)") {
                    TextField("Client ID", text: $clientId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Client Secret", text: $clientSecret)
                    SecureField("Refresh Token", text: $refreshToken)

                    Button("Save Credentials") {
                        // Keychain keeps OAuth secrets out of UserDefaults and source control.
                        CredentialStore.save(key: "clientId", value: clientId)
                        CredentialStore.save(key: "clientSecret", value: clientSecret)
                        CredentialStore.save(key: "refreshToken", value: refreshToken)
                        statusMessage = "Saved."
                    }
                }

                Section("Manual sync") {
                    Button(isSyncing ? "Syncing…" : "Sync Now") {
                        Task {
                            // Keep the UI responsive while the pipeline performs network and HealthKit work.
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
                    // The log persists in Application Support so the last run is visible after relaunch.
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink("Diagnostics") {
                        DiagnosticsView()
                    }
                }
            }
        }
    }
}
