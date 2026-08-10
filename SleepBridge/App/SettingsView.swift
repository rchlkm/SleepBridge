import SwiftUI

struct SettingsView: View {
    // Step 1: Client ID / Secret
    @State private var clientId: String = CredentialStore.read(key: "clientId") ?? ""
    @State private var clientSecret: String = CredentialStore.read(key: "clientSecret") ?? ""
    @State private var clientSaveStatus: String = ""

    // Step 2: authorization code → refresh token exchange
    @State private var authCode: String = ""
    @State private var exchangeStatus: String = ""
    @State private var isExchanging = false

    @State private var hasRefreshToken: Bool = CredentialStore.read(key: "refreshToken") != nil

    var body: some View {
        Form {
            Section("1. Google Cloud credentials") {
                TextField("Client ID", text: $clientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Client Secret", text: $clientSecret)

                Button("Save Client ID & Secret") {
                    // Evaluated as separate statements, not chained with &&, so a
                    // failure on one doesn't skip saving the other.
                    let savedId = CredentialStore.save(key: "clientId", value: clientId)
                    let savedSecret = CredentialStore.save(key: "clientSecret", value: clientSecret)
                    clientSaveStatus = (savedId && savedSecret) ? "Saved." : "⚠️ Failed to save — try again."
                }

                if !clientSaveStatus.isEmpty {
                    Text(clientSaveStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("2. Get a refresh token") {
                if let url = GoogleFitOAuth.consentURL() {
                    Link(destination: url) {
                        Label("Open Google Consent Screen", systemImage: "safari")
                    }
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
                            hasRefreshToken = true
                            authCode = ""
                        } catch {
                            exchangeStatus = "❌ \(error)"
                        }
                        isExchanging = false
                    }
                }
                .disabled(isExchanging || authCode.isEmpty)

                if !exchangeStatus.isEmpty {
                    Text(exchangeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Status") {
                Label(
                    hasRefreshToken ? "Refresh token saved" : "No refresh token yet",
                    systemImage: hasRefreshToken ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(hasRefreshToken ? .green : .secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
