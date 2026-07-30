import Foundation

struct SleepSegmentPoint {
    let start: Date
    let end: Date
    let intVal: Int
}

struct SleepSession {
    let startTimeMillis: Int64
    let endTimeMillis: Int64
    let activityType: Int
}

enum GoogleFitError: Error {
    case missingCredentials
    case badResponse(String)
    case decodeFailed
}

final class GoogleFitClient {
    private var cachedAccessToken: String?
    private var cachedTokenExpiry: Date?

    private func credentials() throws -> (clientId: String, clientSecret: String, refreshToken: String) {
        guard
            let clientId = CredentialStore.read(key: "clientId"),
            let clientSecret = CredentialStore.read(key: "clientSecret"),
            let refreshToken = CredentialStore.read(key: "refreshToken")
        else {
            throw GoogleFitError.missingCredentials
        }
        return (clientId, clientSecret, refreshToken)
    }

    func accessToken() async throws -> String {
        if let token = cachedAccessToken, let expiry = cachedTokenExpiry, expiry > Date() {
            return token
        }

        let creds = try credentials()
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "client_id": creds.clientId,
            "client_secret": creds.clientSecret,
            "refresh_token": creds.refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleFitError.badResponse(String(data: data, encoding: .utf8) ?? "unknown error")
        }

        struct TokenResponse: Codable {
            let access_token: String
            let expires_in: Int
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        cachedAccessToken = decoded.access_token
        cachedTokenExpiry = Date().addingTimeInterval(TimeInterval(decoded.expires_in - 60))
        return decoded.access_token
    }

    func listSleepSessions(since: Date, until: Date = Date()) async throws -> [SleepSession] {
        let token = try await accessToken()
        var components = URLComponents(string: "https://www.googleapis.com/fitness/v1/users/me/sessions")!
        components.queryItems = [
            URLQueryItem(name: "startTime", value: iso8601(since)),
            URLQueryItem(name: "endTime", value: iso8601(until))
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleFitError.badResponse(String(data: data, encoding: .utf8) ?? "unknown error")
        }

        struct SessionsResponse: Codable {
            struct Session: Codable {
                let startTimeMillis: String
                let endTimeMillis: String
                let activityType: Int?
            }
            let session: [Session]?
        }
        let decoded = try JSONDecoder().decode(SessionsResponse.self, from: data)
        return (decoded.session ?? [])
            .filter { $0.activityType == 72 } // 72 = sleep
            .compactMap { s in
                guard let start = Int64(s.startTimeMillis), let end = Int64(s.endTimeMillis) else { return nil }
                return SleepSession(startTimeMillis: start, endTimeMillis: end, activityType: 72)
            }
    }

    func aggregateSleepSegments(startTimeMillis: Int64, endTimeMillis: Int64) async throws -> [SleepSegmentPoint] {
        let token = try await accessToken()
        let url = URL(string: "https://www.googleapis.com/fitness/v1/users/me/dataset:aggregate")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "aggregateBy": [["dataTypeName": "com.google.sleep.segment"]],
            "startTimeMillis": startTimeMillis,
            "endTimeMillis": endTimeMillis
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleFitError.badResponse(String(data: data, encoding: .utf8) ?? "unknown error")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let buckets = json["bucket"] as? [[String: Any]]
        else {
            throw GoogleFitError.decodeFailed
        }

        var points: [SleepSegmentPoint] = []
        for bucket in buckets {
            guard let datasets = bucket["dataset"] as? [[String: Any]] else { continue }
            for ds in datasets {
                guard let pointList = ds["point"] as? [[String: Any]] else { continue }
                for p in pointList {
                    guard
                        let startNanosStr = p["startTimeNanos"] as? String,
                        let endNanosStr = p["endTimeNanos"] as? String,
                        let startNanos = Int64(startNanosStr),
                        let endNanos = Int64(endNanosStr),
                        let values = p["value"] as? [[String: Any]],
                        let intVal = values.first?["intVal"] as? Int
                    else { continue }

                    let start = Date(timeIntervalSince1970: Double(startNanos) / 1_000_000_000)
                    let end = Date(timeIntervalSince1970: Double(endNanos) / 1_000_000_000)
                    points.append(SleepSegmentPoint(start: start, end: end, intVal: intVal))
                }
            }
        }
        return points
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
