import Foundation

enum GoogleFitOAuthError: Error {
    case missingClientCredentials
    case badResponse(String)
    case noRefreshTokenReturned
}

enum GoogleFitOAuth {
    /// Must match a redirect URI actually registered on the Google Cloud OAuth
    /// client — https://developers.google.com/oauthplayground is Google's own
    /// page, so it's always pre-registered and valid without any extra setup.
    /// We don't rely on the Playground's own UI though — we read the `code`
    /// query param off that URL ourselves and exchange it directly.
    private static let redirectURI = "https://developers.google.com/oauthplayground"
    private static let scope = "https://www.googleapis.com/auth/fitness.sleep.read"

    /// The consent-screen URL to open in Safari, built from the saved Client ID.
    /// nil if no Client ID has been saved yet.
    static func consentURL() -> URL? {
        guard let clientId = CredentialStore.read(key: "clientId"), !clientId.isEmpty else { return nil }
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url
    }

    /// Exchanges a one-time authorization code (copied from the browser's address
    /// bar after consenting) for a refresh token, and saves it to Keychain on
    /// success. Throws without saving anything if it fails.
    @discardableResult
    static func exchangeCodeForRefreshToken(_ rawCode: String) async throws -> String {
        guard
            let clientId = CredentialStore.read(key: "clientId"), !clientId.isEmpty,
            let clientSecret = CredentialStore.read(key: "clientSecret"), !clientSecret.isEmpty
        else {
            throw GoogleFitOAuthError.missingClientCredentials
        }

        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleFitOAuthError.badResponse(String(data: data, encoding: .utf8) ?? "unknown error")
        }

        struct TokenResponse: Codable {
            let refresh_token: String?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)

        // Google only returns a refresh_token on first consent, or when
        // prompt=consent forces re-consent (which we always send) — this should
        // always be present, but if it's ever missing the likely fix is revoking
        // prior access at https://myaccount.google.com/permissions and retrying.
        guard let refreshToken = decoded.refresh_token else {
            throw GoogleFitOAuthError.noRefreshTokenReturned
        }

        CredentialStore.save(key: "refreshToken", value: refreshToken)
        return refreshToken
    }
}
