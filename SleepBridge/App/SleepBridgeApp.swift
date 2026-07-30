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
                        CredentialStore.save(key: "clientId", value: clientId)
                        CredentialStore.save(key: "clientSecret", value: clientSecret)
                        CredentialStore.save(key: "refreshToken", value: refreshToken)
                        statusMessage = "Saved."
                    }
                }

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
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink("Diagnostics") {
                        DiagnosticsView()
                    }
                }
            }
        }
    }
}
