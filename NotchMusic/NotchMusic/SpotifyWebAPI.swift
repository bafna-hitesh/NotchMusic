import Foundation
import AuthenticationServices
import CryptoKit

// MARK: - Configuration

/// Set your Spotify Client ID in Info.plist under the `SpotifyClientID` key.
/// Get one at https://developer.spotify.com/dashboard
/// Also add `notchmusic://callback` as a Redirect URI in your app's settings on the dashboard.
private var spotifyClientID: String {
    Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""
}

private let redirectURI = "notchmusic://callback"
private let tokenDefaultsKey = "com.notchmusic.spotifyTokens"
private let verifierDefaultsKey = "com.notchmusic.pkceVerifier"

/// Scopes requested during authorization. Add new scopes here only when
/// the corresponding Web API feature is actually built.
private let authScopes: [String] = [
    "user-read-playback-state",
    "user-read-currently-playing",
]

extension Notification.Name {
    static let spotifyAuthDidReset = Notification.Name("spotifyAuthDidReset")
}

// MARK: - Token Storage

private struct SpotifyTokens: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

// MARK: - Auth Controller

final class SpotifyAuthController: NSObject, ObservableObject {
    static let shared = SpotifyAuthController()

    @Published var isAuthenticated = false
    private(set) var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiresAt: Date = .distantPast
    private var pendingSession: ASWebAuthenticationSession?

    override private init() {
        super.init()
        loadTokens()
    }

    var isConfigured: Bool { !spotifyClientID.isEmpty }

    func clearAuth() {
        accessToken = nil
        refreshToken = nil
        tokenExpiresAt = .distantPast
        isAuthenticated = false
        UserDefaults.standard.removeObject(forKey: tokenDefaultsKey)
        UserDefaults.standard.removeObject(forKey: verifierDefaultsKey)
        print("[Auth] cleared all saved tokens")
        NotificationCenter.default.post(name: .spotifyAuthDidReset, object: nil)
    }

    func authenticate() {
        guard isConfigured else { print("[Auth] not configured — client ID missing"); return }
        print("[Auth] authenticate() starting...")
        let verifier = generateCodeVerifier()
        guard let challenge = generateCodeChallenge(verifier) else { return }

        UserDefaults.standard.set(verifier, forKey: verifierDefaultsKey)

        let scopeString = authScopes.joined(separator: " ")

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: spotifyClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: scopeString),
            URLQueryItem(name: "show_dialog", value: "true"),
        ]

        let session = ASWebAuthenticationSession(
            url: components.url!,
            callbackURLScheme: "notchmusic"
        ) { [weak self] url, error in
            guard let self, let url,
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
            else { return }
            self.exchangeCode(code: code, verifier: verifier)
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        session.start()
        pendingSession = session
    }

    func getValidToken() async -> String? {
        guard isAuthenticated else { return nil }
        if Date() < tokenExpiresAt, let token = accessToken {
            return token
        }
        await refreshAccessToken()
        return accessToken
    }

    // MARK: - Private

    private func exchangeCode(code: String, verifier: String) {
        print("[Auth] exchanging code for token...")
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": spotifyClientID,
            "code_verifier": verifier,
        ]
        req.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&").data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data else { return }
            self.handleTokenResponse(data)
        }.resume()
    }

    @discardableResult
    func refreshAccessToken() async -> Bool {
        guard let refreshToken else {
            print("[Auth] refresh failed — no refresh token")
            await MainActor.run {
                isAuthenticated = false
                accessToken = nil
                NotificationCenter.default.post(name: .spotifyAuthDidReset, object: nil)
            }
            return false
        }
        print("[Auth] refreshing token...")
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": spotifyClientID,
        ]
        req.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&").data(using: .utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else {
            print("[Auth] refresh failed — clearing tokens")
            await MainActor.run {
                isAuthenticated = false
                accessToken = nil
                self.refreshToken = nil
                UserDefaults.standard.removeObject(forKey: tokenDefaultsKey)
                NotificationCenter.default.post(name: .spotifyAuthDidReset, object: nil)
            }
            return false
        }

        print("[Auth] token refreshed successfully")
        await MainActor.run {
            accessToken = access
            self.refreshToken = (json["refresh_token"] as? String) ?? self.refreshToken
            tokenExpiresAt = Date().addingTimeInterval((json["expires_in"] as? TimeInterval) ?? 3600)
            isAuthenticated = true
            saveTokens()
        }
        return true
    }

    private func handleTokenResponse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else {
            print("[Auth] token response parse failed. body: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "nil")")
            return
        }

        print("[Auth] token received, expires in \(json["expires_in"] ?? "?")s, scope: \(json["scope"] ?? "none")")
        accessToken = access
        refreshToken = (json["refresh_token"] as? String) ?? refreshToken
        tokenExpiresAt = Date().addingTimeInterval((json["expires_in"] as? TimeInterval) ?? 3600)
        saveTokens()

        DispatchQueue.main.async {
            self.isAuthenticated = true
        }
    }

    private func saveTokens() {
        guard let accessToken else { return }
        let tokens = SpotifyTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: tokenExpiresAt
        )
        if let data = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(data, forKey: tokenDefaultsKey)
        }
    }

    private func loadTokens() {
        guard let data = UserDefaults.standard.data(forKey: tokenDefaultsKey),
              let tokens = try? JSONDecoder().decode(SpotifyTokens.self, from: data)
        else { print("[Auth] no saved tokens found"); return }
        print("[Auth] loaded saved token, expires at \(tokens.expiresAt)")
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        tokenExpiresAt = tokens.expiresAt
        isAuthenticated = Date() < tokens.expiresAt
    }

    // MARK: - PKCE helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private func generateCodeChallenge(_ verifier: String) -> String? {
        guard let data = verifier.data(using: .utf8) else { return nil }
        let hash = CryptoKit.SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }
}

extension SpotifyAuthController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
