import SwiftUI

struct SettingsView: View {
    // Step 1: Client ID / Secret — locked by default so they're not trivial to
    // accidentally overwrite; tap Edit to unlock.
    @State private var clientId: String = CredentialStore.read(key: "clientId") ?? ""
    @State private var clientSecret: String = CredentialStore.read(key: "clientSecret") ?? ""
    @State private var isEditingCredentials = false
    @State private var clientSaveStatus: String = ""

    // Step 2: authorization code → refresh token exchange
    @State private var authCode: String = ""
    @State private var exchangeStatus: String = ""
    @State private var isExchanging = false

    // Step 3: verifying the saved refresh token actually works right now,
    // not just that something is stored.
    @State private var connectionTestResult: String = ""
    @State private var isTestingConnection = false

    private var hasClientCredentials: Bool {
        CredentialStore.read(key: "clientId") != nil && CredentialStore.read(key: "clientSecret") != nil
    }

    var body: some View {
        Form {
            Section {
                if isEditingCredentials {
                    TextField("Client ID", text: $clientId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Client Secret", text: $clientSecret)

                    HStack {
                        Button("Save") {
                            let savedId = CredentialStore.save(key: "clientId", value: clientId)
                            let savedSecret = CredentialStore.save(key: "clientSecret", value: clientSecret)
                            clientSaveStatus = (savedId && savedSecret) ? "Saved." : "⚠️ Failed to save — try again."
                            if savedId && savedSecret {
                                isEditingCredentials = false
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Cancel") {
                            clientId = CredentialStore.read(key: "clientId") ?? ""
                            clientSecret = CredentialStore.read(key: "clientSecret") ?? ""
                            isEditingCredentials = false
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    LabeledContent("Client ID", value: hasClientCredentials ? maskedClientId : "Not set")
                    LabeledContent("Client Secret", value: hasClientCredentials ? "•••••••• (saved)" : "Not set")

                    Button(hasClientCredentials ? "Edit" : "Set Up") {
                        isEditingCredentials = true
                    }
                    .buttonStyle(.bordered)
                }

                if !clientSaveStatus.isEmpty {
                    Text(clientSaveStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("1. Google Cloud credentials")
            } footer: {
                Text("Locked by default so they're not easy to overwrite by accident. Tap Edit to change them.")
            }

            Section {
                if let url = GoogleFitOAuth.consentURL() {
                    Link(destination: url) {
                        Label("Open Google Consent Screen", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("Save your Client ID above first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("After approving access in Safari, you'll land on Google's OAuth Playground page with a code in the address bar (developers.google.com/oauthplayground/?code=...). Copy just that code and paste it below.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextField("Paste authorization code here", text: $authCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button(isExchanging ? "Exchanging…" : "Exchange for Refresh Token") {
                    Task {
                        isExchanging = true
                        do {
                            try await GoogleFitOAuth.exchangeCodeForRefreshToken(authCode)
                            exchangeStatus = "✅ Refresh token saved."
                            authCode = ""
                            connectionTestResult = "" // stale until re-tested
                        } catch {
                            exchangeStatus = "❌ \(error)"
                        }
                        isExchanging = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExchanging || authCode.isEmpty)

                if !exchangeStatus.isEmpty {
                    Text(exchangeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("2. Get a refresh token")
            }

            Section {
                Button(isTestingConnection ? "Testing…" : "Test Connection") {
                    Task {
                        isTestingConnection = true
                        connectionTestResult = await DiagnosticsRunner.testGoogleAuth()
                        isTestingConnection = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTestingConnection)

                if !connectionTestResult.isEmpty {
                    Text(connectionTestResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("3. Verify it actually works")
            } footer: {
                Text("A saved token isn't the same as a working one — this makes a real call to Google and confirms it's actually accepted right now.")
            }
        }
        .navigationTitle("Settings")
    }

    private var maskedClientId: String {
        guard let id = CredentialStore.read(key: "clientId") else { return "" }
        guard id.count > 10 else { return id }
        return "\(id.prefix(6))…\(id.suffix(4))"
    }
}

