import AppKit
import CryptoKit
import Foundation
import Security

/// Google sign-in for team features. Native-app OAuth with PKCE (no client secret) in the user's
/// default browser, where they are usually already signed in to Google; Google redirects back to the
/// app's URL scheme (the reversed client ID, registered in project.yml). Only the refresh token is
/// kept, in the login Keychain; access tokens stay in memory.
/// Scope is drive.file: Exanote can reach only the folders and files it created or the user picked.
@MainActor
final class GoogleAccount: NSObject, ObservableObject {
    struct Profile: Codable, Equatable {
        let email: String
        let name: String?
    }

    static let scopes = ["openid", "email", "profile", "https://www.googleapis.com/auth/drive.file"]
    /// Set in project.yml (Info.plist). Empty means this build has no OAuth client.
    static var clientID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "ExanoteGoogleClientID") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    @Published private(set) var profile: Profile?
    @Published private(set) var busy = false
    @Published var error: String?

    var configured: Bool { Self.clientID != nil }
    private var cached: (token: String, expires: Date)?
    private var pending: CheckedContinuation<URL, Error>?
    private var pendingScheme = ""
    private static let profileKey = "googleProfile"

    override init() {
        super.init()
        if Keychain.read() != nil, let data = UserDefaults.standard.data(forKey: Self.profileKey) {
            profile = try? JSONDecoder().decode(Profile.self, from: data)
        }
    }

    func signIn() async {
        guard let clientID = Self.clientID else { return }
        busy = true
        defer { busy = false }
        do {
            let verifier = Self.random()
            let state = Self.random()
            // Google's native-app redirect: the client ID's reverse-DNS form as a URL scheme.
            let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
            let redirect = "\(scheme):/oauth2redirect"
            var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            url.queryItems = [
                .init(name: "client_id", value: clientID),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: Self.scopes.joined(separator: " ")),
                .init(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state),
                .init(name: "prompt", value: "select_account"),
            ]
            let callback = try await authorize(url.url!, scheme: scheme)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                throw GoogleError(items.first { $0.name == "error" }?.value == "access_denied" ? "로그인을 취소했어요." : "Google 로그인 응답이 올바르지 않아요.")
            }
            let token = try await Self.tokenRequest([
                "grant_type": "authorization_code", "code": code, "client_id": clientID,
                "redirect_uri": redirect, "code_verifier": verifier,
            ])
            guard token.scope?.contains("drive.file") == true else {
                throw GoogleError("Google Drive 권한에 체크해야 팀 폴더를 만들 수 있어요. 다시 로그인해 주세요.")
            }
            guard let refresh = token.refresh_token, let claims = token.id_token.flatMap(Self.claims) else {
                throw GoogleError("Google 로그인 정보를 받지 못했어요.")
            }
            Keychain.write(refresh)
            cached = (token.access_token, Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600) - 60))
            let signedIn = Profile(email: claims.email, name: claims.name)
            UserDefaults.standard.set(try? JSONEncoder().encode(signedIn), forKey: Self.profileKey)
            profile = signedIn
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Stops waiting for the browser, for example when the user closed the tab.
    func cancelSignIn() {
        pending?.resume(throwing: GoogleError("로그인을 취소했어요."))
        pending = nil
    }

    func signOut() async {
        if let refresh = Keychain.read() {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": refresh])
            _ = try? await URLSession.shared.data(for: request)  // Best effort; the local copy goes regardless.
        }
        Keychain.delete()
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        cached = nil
        profile = nil
    }

    /// A fresh access token, refreshed with the stored refresh token when needed.
    func accessToken() async throws -> String {
        if let cached, cached.expires > Date() { return cached.token }
        guard let clientID = Self.clientID, let refresh = Keychain.read() else { throw GoogleError("Google에 다시 로그인해 주세요.") }
        do {
            let token = try await Self.tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
            cached = (token.access_token, Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600) - 60))
            return token.access_token
        } catch let failure as GoogleError where failure.code == "invalid_grant" {
            // Revoked or expired: forget it locally. Revoking again would only fail.
            NSLog("Exanote: Google refresh rejected: %@", failure.message)
            Keychain.delete()
            UserDefaults.standard.removeObject(forKey: Self.profileKey)
            cached = nil
            profile = nil
            throw GoogleError("Google 로그인이 만료됐어요. 다시 로그인해 주세요.")
        }
    }

    private func authorize(_ url: URL, scheme: String) async throws -> URL {
        cancelSignIn()
        pendingScheme = scheme
        // Takes over URL events from SwiftUI, which would otherwise open another window for them.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            if !NSWorkspace.shared.open(url) {
                pending = nil
                continuation.resume(throwing: GoogleError("브라우저를 열지 못했어요."))
            }
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text), url.scheme == pendingScheme, let pending else { return }
        self.pending = nil
        NSApp.activate()
        pending.resume(returning: url)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
        let id_token: String?
        let scope: String?
    }

    private static func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            struct Failure: Decodable { let error: String?; let error_description: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            NSLog("Exanote: Google token request failed: %@ %@", failure?.error ?? "?", failure?.error_description ?? "")
            throw GoogleError(failure?.error_description ?? "Google 토큰을 받지 못했어요.", code: failure?.error)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// Email and name from the ID token. It came straight from Google's token endpoint over TLS,
    /// so its payload is read without verifying the signature.
    private static func claims(_ idToken: String) -> (email: String, name: String?)? {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3, let data = Data(base64URL: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else { return nil }
        return (email, json["name"] as? String)
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)!
    }

    private static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }
}

struct GoogleError: LocalizedError {
    let message: String
    let code: String?
    init(_ message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
    var errorDescription: String? { message }
}

/// The refresh token in the login Keychain, readable only by this app without a prompt.
private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.exanote.google",
        kSecAttrAccount as String: "refresh_token",
    ]

    static func read() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
