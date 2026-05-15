import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI
import UIKit

enum XBookmarksPreferenceKeys {
    static let userID = "xBookmarks.userID"
    static let username = "xBookmarks.username"
    static let displayName = "xBookmarks.displayName"
    static let tokenExpiresAt = "xBookmarks.tokenExpiresAt"
}

enum XBookmarksConfig {
    static let redirectURI = "spinreader://x-oauth"
    static let callbackScheme = "spinreader"
    static let scopes = ["tweet.read", "users.read", "bookmark.read", "offline.access"]

    /// OAuth 2.0 Client ID from `Sources/Info.plist` (`XOAuthClientID`). PKCE makes this safe to ship in the binary.
    static var oauthClientID: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "XOAuthClientID") as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum XBookmarksSyncError: LocalizedError {
    case missingClientID
    case authorizationCanceled
    case invalidRedirect
    case stateMismatch
    case missingAuthorizationCode
    case missingCredentials
    case tokenRequestFailed(String)
    case requestFailed(Int, String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "This build is missing XOAuthClientID in Info.plist."
        case .authorizationCanceled:
            return "X sign in was canceled."
        case .invalidRedirect:
            return "X did not return a valid sign-in response."
        case .stateMismatch:
            return "The X sign-in response could not be verified. Try connecting again."
        case .missingAuthorizationCode:
            return "X did not return an authorization code."
        case .missingCredentials:
            return "Connect X before syncing bookmarks."
        case .tokenRequestFailed(let message):
            return message.isEmpty ? "X sign in failed." : message
        case .requestFailed(let status, let message):
            return message.isEmpty ? "X returned HTTP \(status)." : message
        case .decodingFailed:
            return "Spin could not read the X response."
        }
    }
}

struct XBookmarksSyncSummary: Equatable {
    var scanned = 0
    var imported = 0
    var skipped = 0
    var savedTweets = 0
    var failed = 0

    var isEmpty: Bool {
        scanned == 0 && imported == 0 && skipped == 0 && savedTweets == 0 && failed == 0
    }

    var statusLine: String {
        if scanned == 0 { return "No bookmarks found." }
        return "\(imported) imported, \(savedTweets) saved as posts, \(skipped) already saved, \(failed) failed"
    }
}

private enum XBookmarkSyncOutcome {
    case imported
    case skipped
    case savedTweet
    case failed
}

@MainActor
final class XBookmarksSyncManager: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var displayName = ""
    @Published private(set) var username = ""
    @Published private(set) var isWorking = false
    @Published private(set) var progressText = ""
    @Published private(set) var lastSummary = XBookmarksSyncSummary()
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let keychain = XTokenKeychain()
    private let sessionCoordinator = XOAuthSessionCoordinator()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        defaults.removeObject(forKey: "xBookmarks.clientID")
        refreshConnectionState()
    }

    func refreshConnectionState() {
        isConnected = keychain.load() != nil
        displayName = defaults.string(forKey: XBookmarksPreferenceKeys.displayName) ?? ""
        username = defaults.string(forKey: XBookmarksPreferenceKeys.username) ?? ""
    }

    func connect() async {
        let clientID = XBookmarksConfig.oauthClientID
        guard !clientID.isEmpty else {
            errorMessage = XBookmarksSyncError.missingClientID.localizedDescription
            return
        }

        isWorking = true
        progressText = "Opening X..."
        defer {
            isWorking = false
            progressText = ""
        }

        do {
            let verifier = try PKCE.makeVerifier()
            let state = try PKCE.randomURLSafeString(byteCount: 32)
            let authURL = try authorizationURL(clientID: clientID, verifier: verifier, state: state)
            let callbackURL = try await sessionCoordinator.authenticate(with: authURL)
            let code = try authorizationCode(from: callbackURL, expectedState: state)
            progressText = "Finishing connection..."
            let tokens = try await exchangeAuthorizationCode(code, verifier: verifier, clientID: clientID)
            try keychain.save(tokens)
            updateTokenExpiration(tokens)
            let account = try await fetchCurrentUser(accessToken: tokens.accessToken)
            save(account: account)
            refreshConnectionState()
        } catch {
            errorMessage = error.localizedDescription
            refreshConnectionState()
        }
    }

    func disconnect() {
        keychain.clear()
        defaults.removeObject(forKey: XBookmarksPreferenceKeys.userID)
        defaults.removeObject(forKey: XBookmarksPreferenceKeys.username)
        defaults.removeObject(forKey: XBookmarksPreferenceKeys.displayName)
        defaults.removeObject(forKey: XBookmarksPreferenceKeys.tokenExpiresAt)
        lastSummary = XBookmarksSyncSummary()
        refreshConnectionState()
    }

    func syncBookmarks(into store: WebArticleStore) async {
        isWorking = true
        progressText = "Preparing sync..."
        lastSummary = XBookmarksSyncSummary()
        defer {
            isWorking = false
            progressText = ""
            refreshConnectionState()
        }

        do {
            let accessToken = try await validAccessToken()
            let account = try await ensureCurrentUser(accessToken: accessToken)
            var summary = XBookmarksSyncSummary()
            var paginationToken: String?
            repeat {
                let page = try await fetchBookmarks(
                    userID: account.id,
                    accessToken: accessToken,
                    paginationToken: paginationToken
                )
                paginationToken = page.meta.nextToken
                for bookmark in page.bookmarks {
                    try Task.checkCancellation()
                    summary.scanned += 1
                    switch await sync(bookmark, into: store) {
                    case .imported:
                        summary.imported += 1
                    case .skipped:
                        summary.skipped += 1
                    case .savedTweet:
                        summary.savedTweets += 1
                    case .failed:
                        summary.failed += 1
                    }
                    lastSummary = summary
                    progressText = "Synced \(summary.scanned) bookmarks..."
                }
            } while paginationToken != nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sync(_ bookmark: XBookmark, into store: WebArticleStore) async -> XBookmarkSyncOutcome {
        let fallbackSource = bookmark.postURL
        let articleURL = bookmark.bestExternalURL
        let sourceURL = articleURL ?? fallbackSource

        if store.containsArticle(sourceURL: sourceURL) {
            return .skipped
        }

        if let articleURL {
            do {
                let article = try await BackgroundArticleImporter.loadArticle(from: articleURL)
                if let savedSource = article.sourceURL, store.containsArticle(sourceURL: savedSource) {
                    return .skipped
                }
                try await store.save(article)
                return .imported
            } catch {
                // Keep the bookmark by falling back to a readable post snapshot below.
            }
        }

        do {
            try await store.save(bookmark.asArticle())
            return .savedTweet
        } catch {
            return .failed
        }
    }

    private func authorizationURL(clientID: String, verifier: String, state: String) throws -> URL {
        var components = URLComponents(string: "https://x.com/i/oauth2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: XBookmarksConfig.redirectURI),
            URLQueryItem(name: "scope", value: XBookmarksConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components?.url else { throw XBookmarksSyncError.invalidRedirect }
        return url
    }

    private func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw XBookmarksSyncError.invalidRedirect
        }
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard state == expectedState else { throw XBookmarksSyncError.stateMismatch }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw XBookmarksSyncError.missingAuthorizationCode
        }
        return code
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        verifier: String,
        clientID: String
    ) async throws -> XOAuthTokens {
        let body = formEncoded([
            "code": code,
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": XBookmarksConfig.redirectURI,
            "code_verifier": verifier
        ])
        return try await requestToken(body: body)
    }

    private func refreshAccessToken(_ refreshToken: String, clientID: String) async throws -> XOAuthTokens {
        let body = formEncoded([
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "client_id": clientID
        ])
        return try await requestToken(body: body)
    }

    private func requestToken(body: Data) async throws -> XOAuthTokens {
        var request = URLRequest(url: URL(string: "https://api.x.com/2/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XBookmarksSyncError.decodingFailed }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw XBookmarksSyncError.tokenRequestFailed(body)
        }
        do {
            return try decoder.decode(XOAuthTokens.self, from: data)
        } catch {
            throw XBookmarksSyncError.decodingFailed
        }
    }

    private func validAccessToken() async throws -> String {
        guard var tokens = keychain.load() else { throw XBookmarksSyncError.missingCredentials }
        let expiresAt = defaults.object(forKey: XBookmarksPreferenceKeys.tokenExpiresAt) as? Date
        if let expiresAt, expiresAt.timeIntervalSinceNow > 60 {
            return tokens.accessToken
        }

        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw XBookmarksSyncError.missingCredentials
        }
        let clientID = XBookmarksConfig.oauthClientID
        guard !clientID.isEmpty else { throw XBookmarksSyncError.missingClientID }
        let refreshed = try await refreshAccessToken(refreshToken, clientID: clientID)
        tokens = refreshed.refreshToken == nil
            ? XOAuthTokens(
                tokenType: refreshed.tokenType,
                expiresIn: refreshed.expiresIn,
                accessToken: refreshed.accessToken,
                refreshToken: refreshToken,
                scope: refreshed.scope
            )
            : refreshed
        try keychain.save(tokens)
        updateTokenExpiration(tokens)
        return tokens.accessToken
    }

    private func ensureCurrentUser(accessToken: String) async throws -> XUser {
        if let id = defaults.string(forKey: XBookmarksPreferenceKeys.userID),
           !id.isEmpty {
            return XUser(
                id: id,
                name: defaults.string(forKey: XBookmarksPreferenceKeys.displayName) ?? "",
                username: defaults.string(forKey: XBookmarksPreferenceKeys.username) ?? ""
            )
        }
        let account = try await fetchCurrentUser(accessToken: accessToken)
        save(account: account)
        return account
    }

    private func fetchCurrentUser(accessToken: String) async throws -> XUser {
        var components = URLComponents(string: "https://api.x.com/2/users/me")!
        components.queryItems = [URLQueryItem(name: "user.fields", value: "name,username")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let envelope: XUserEnvelope = try await fetch(request)
        return envelope.data
    }

    private func fetchBookmarks(
        userID: String,
        accessToken: String,
        paginationToken: String?
    ) async throws -> XBookmarksPage {
        var components = URLComponents(string: "https://api.x.com/2/users/\(userID)/bookmarks")!
        var queryItems = [
            URLQueryItem(name: "max_results", value: "100"),
            URLQueryItem(name: "tweet.fields", value: "attachments,author_id,created_at,entities,note_tweet"),
            URLQueryItem(name: "expansions", value: "author_id"),
            URLQueryItem(name: "user.fields", value: "name,username")
        ]
        if let paginationToken {
            queryItems.append(URLQueryItem(name: "pagination_token", value: paginationToken))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let response: XBookmarksResponse = try await fetch(request)
        return XBookmarksPage(response: response)
    }

    private func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XBookmarksSyncError.decodingFailed }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw XBookmarksSyncError.requestFailed(http.statusCode, body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw XBookmarksSyncError.decodingFailed
        }
    }

    private func save(account: XUser) {
        defaults.set(account.id, forKey: XBookmarksPreferenceKeys.userID)
        defaults.set(account.username, forKey: XBookmarksPreferenceKeys.username)
        defaults.set(account.name, forKey: XBookmarksPreferenceKeys.displayName)
    }

    private func updateTokenExpiration(_ tokens: XOAuthTokens) {
        guard let expiresIn = tokens.expiresIn else { return }
        defaults.set(Date().addingTimeInterval(TimeInterval(expiresIn)), forKey: XBookmarksPreferenceKeys.tokenExpiresAt)
    }
}

private final class XOAuthSessionCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    @MainActor
    func authenticate(with url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: XBookmarksConfig.callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: XBookmarksSyncError.authorizationCanceled)
                } else {
                    continuation.resume(throwing: error ?? XBookmarksSyncError.invalidRedirect)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: XBookmarksSyncError.invalidRedirect)
            }
        }
    }

    @MainActor
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

private enum PKCE {
    static func makeVerifier() throws -> String {
        try randomURLSafeString(byteCount: 48)
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw XBookmarksSyncError.invalidRedirect }
        return Data(bytes).base64URLEncodedString()
    }
}

private struct XOAuthTokens: Codable {
    let tokenType: String?
    let expiresIn: Int?
    let accessToken: String
    let refreshToken: String?
    let scope: String?

    private enum CodingKeys: String, CodingKey {
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case scope
    }
}

private final class XTokenKeychain {
    private let service = "com.tareqismail.ponder.x-bookmarks"
    private let account = "oauth"

    func load() -> XOAuthTokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(XOAuthTokens.self, from: data)
    }

    func save(_ tokens: XOAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        var query = baseQuery()
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound || status == errSecSuccess else {
            throw XBookmarksSyncError.missingCredentials
        }
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw XBookmarksSyncError.missingCredentials }
        }
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}

private struct XUserEnvelope: Decodable {
    let data: XUser
}

private struct XUser: Decodable {
    let id: String
    let name: String
    let username: String
}

private struct XBookmarksResponse: Decodable {
    let data: [XTweet]?
    let includes: XIncludes?
    let meta: XMeta
}

private struct XBookmarksPage {
    let bookmarks: [XBookmark]
    let meta: XMeta

    init(response: XBookmarksResponse) {
        let usersByID = Dictionary(uniqueKeysWithValues: (response.includes?.users ?? []).map { ($0.id, $0) })
        bookmarks = (response.data ?? []).map { tweet in
            XBookmark(tweet: tweet, author: tweet.authorID.flatMap { usersByID[$0] })
        }
        meta = response.meta
    }
}

private struct XIncludes: Decodable {
    let users: [XUser]?
}

private struct XMeta: Decodable {
    let resultCount: Int?
    let nextToken: String?

    private enum CodingKeys: String, CodingKey {
        case resultCount = "result_count"
        case nextToken = "next_token"
    }
}

private struct XTweet: Decodable {
    let id: String
    let text: String
    let authorID: String?
    let createdAt: Date?
    let entities: XEntities?
    let noteTweet: XNoteTweet?

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case authorID = "author_id"
        case createdAt = "created_at"
        case entities
        case noteTweet = "note_tweet"
    }
}

private struct XNoteTweet: Decodable {
    let text: String?
    let entities: XEntities?
}

private struct XEntities: Decodable {
    let urls: [XURLEntity]?
}

private struct XURLEntity: Decodable {
    let url: String?
    let expandedURL: String?
    let unwoundURL: String?
    let displayURL: String?

    private enum CodingKeys: String, CodingKey {
        case url
        case expandedURL = "expanded_url"
        case unwoundURL = "unwound_url"
        case displayURL = "display_url"
    }
}

private struct XBookmark {
    let tweet: XTweet
    let author: XUser?

    var bestExternalURL: URL? {
        let urls = (tweet.noteTweet?.entities?.urls ?? []) + (tweet.entities?.urls ?? [])
        for entity in urls {
            let candidates = [entity.unwoundURL, entity.expandedURL, entity.url]
            for candidate in candidates {
                guard let raw = candidate,
                      let url = URL(string: raw),
                      url.scheme?.lowercased().hasPrefix("http") == true,
                      !url.isTwitterHost,
                      url.displayHost != "t.co" else {
                    continue
                }
                return url
            }
        }
        return nil
    }

    var postURL: URL {
        let username = author?.username.isEmpty == false ? author!.username : "i"
        return URL(string: "https://x.com/\(username)/status/\(tweet.id)")!
    }

    func asArticle() -> WebArticle {
        let byline = author.map { "@\($0.username)" } ?? "X"
        let body = tweet.noteTweet?.text ?? tweet.text
        var items: [ScrollTextView.ReadableItem] = [
            .byline(byline),
            .paragraph(body)
        ]
        if let url = bestExternalURL {
            items.append(.paragraph(url.absoluteString))
        }

        return WebArticle(
            id: UUID(),
            title: title,
            author: byline,
            sourceURL: postURL,
            savedAt: Date(),
            items: items
        )
    }

    private var title: String {
        let name = author?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return "Post by \(name)"
        }
        return "Bookmarked Post"
    }
}

private func formEncoded(_ values: [String: String]) -> Data {
    values
        .map { "\($0.key.xFormEncoded)=\($0.value.xFormEncoded)" }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
}

private extension String {
    var xFormEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
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
