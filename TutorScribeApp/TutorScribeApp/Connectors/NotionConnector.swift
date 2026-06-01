import Foundation
import AppKit
import AuthenticationServices
import Combine

struct NotionPage: Identifiable, Hashable {
    let id: String
    let title: String
}

enum NotionError: LocalizedError {
    case missingCredentials
    case notConnected
    case noParent
    case oauth(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Enter your Notion integration token in Settings first."
        case .notConnected:       return "Notion is not connected."
        case .noParent:           return "Pick a parent page in Settings before pushing."
        case .oauth(let m):       return "Notion sign-in failed: \(m)"
        case .http(let c, let m): return "Notion \(c): \(m)"
        }
    }
}

/// Notion connector: OAuth sign-in popup, parent-page picker, and page creation.
/// The OAuth flow uses ASWebAuthenticationSession with the tutorscribe:// scheme.
/// If Notion rejects the custom scheme for your integration, switch the redirect
/// to a localhost loopback and run a tiny listener instead (see SETUP.md).
final class NotionConnector: NSObject, ObservableObject, Connector,
                             ASWebAuthenticationPresentationContextProviding {
    let id = "notion"
    let displayName = "Notion"
    let iconSystemName = "doc.text"
    private let notionVersion = "2022-06-28"

    @Published private(set) var isConnected = false
    @Published var workspaceName = ""
    @Published var parentTitle = ""
    @Published var pages: [NotionPage] = []

    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        isConnected = Keychain.get(Config.kNotionToken)?.isEmpty == false
        workspaceName = UserDefaults.standard.string(forKey: Config.kNotionWorkspace) ?? ""
        parentTitle = UserDefaults.standard.string(forKey: Config.kNotionParentTitle) ?? ""
    }

    // MARK: Access token (internal integration)

    /// Connect with a workspace-scoped integration token (ntn_...). Verifies it
    /// against /v1/users/me, then marks connected.
    func connect(token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotionError.missingCredentials }
        Keychain.set(Config.kNotionToken, trimmed)
        do {
            let data = try await request("GET", "/v1/users/me")
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let workspace = (json?["bot"] as? [String: Any])?["workspace_name"] as? String ?? "Notion"
            UserDefaults.standard.set(workspace, forKey: Config.kNotionWorkspace)
            await MainActor.run { self.workspaceName = workspace; self.isConnected = true }
        } catch {
            Keychain.delete(Config.kNotionToken)   // bad token, roll back
            throw error
        }
    }

    // MARK: OAuth (kept for future multi-workspace use)

    @MainActor
    func authenticate() async throws {
        guard let clientID = UserDefaults.standard.string(forKey: Config.kNotionClientID),
              !clientID.isEmpty,
              let secret = Keychain.get(Config.kNotionSecret), !secret.isEmpty else {
            throw NotionError.missingCredentials
        }

        var comps = URLComponents(string: "https://api.notion.com/v1/oauth/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "owner", value: "user"),
            .init(name: "redirect_uri", value: Config.notionRedirectURI),
        ]
        let authURL = comps.url!

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: authURL, callbackURLScheme: Config.notionCallbackScheme
            ) { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: NotionError.oauth(error?.localizedDescription ?? "cancelled")) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }

        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw NotionError.oauth("no authorization code returned")
        }
        try await exchange(code: code, clientID: clientID, secret: secret)
    }

    private func exchange(code: String, clientID: String, secret: String) async throws {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        let basic = Data("\(clientID):\(secret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.notionRedirectURI,
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["access_token"] as? String else {
            throw NotionError.oauth("no access token in response")
        }
        let workspace = (json?["workspace_name"] as? String) ?? "Notion"
        Keychain.set(Config.kNotionToken, token)
        UserDefaults.standard.set(workspace, forKey: Config.kNotionWorkspace)
        await MainActor.run {
            self.workspaceName = workspace
            self.isConnected = true
        }
    }

    func disconnect() {
        Keychain.delete(Config.kNotionToken)
        UserDefaults.standard.removeObject(forKey: Config.kNotionWorkspace)
        UserDefaults.standard.removeObject(forKey: Config.kNotionParentID)
        UserDefaults.standard.removeObject(forKey: Config.kNotionParentTitle)
        Task { @MainActor in
            isConnected = false; workspaceName = ""; parentTitle = ""; pages = []
        }
    }

    // MARK: Parent page picker

    func loadPages() async throws {
        let body: [String: Any] = [
            "filter": ["value": "page", "property": "object"],
            "page_size": 50,
        ]
        let data = try await request("POST", "/v1/search", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = (json?["results"] as? [[String: Any]]) ?? []
        let parsed: [NotionPage] = results.compactMap { page in
            guard let id = page["id"] as? String else { return nil }
            return NotionPage(id: id, title: Self.pageTitle(page))
        }
        await MainActor.run { self.pages = parsed }
    }

    func setParent(_ page: NotionPage) {
        UserDefaults.standard.set(page.id, forKey: Config.kNotionParentID)
        UserDefaults.standard.set(page.title, forKey: Config.kNotionParentTitle)
        Task { @MainActor in self.parentTitle = page.title }
    }

    private static func pageTitle(_ page: [String: Any]) -> String {
        if let props = page["properties"] as? [String: Any] {
            for (_, value) in props {
                if let v = value as? [String: Any], (v["type"] as? String) == "title",
                   let arr = v["title"] as? [[String: Any]] {
                    let text = arr.compactMap { $0["plain_text"] as? String }.joined()
                    if !text.isEmpty { return text }
                }
            }
        }
        return "Untitled"
    }

    // MARK: Send

    func send(_ session: SessionData) async throws {
        guard isConnected else { throw NotionError.notConnected }
        guard let parentID = UserDefaults.standard.string(forKey: Config.kNotionParentID),
              !parentID.isEmpty else { throw NotionError.noParent }

        let summary = (try? await OpenAIClient().summary(session.notesMarkdown)) ?? ""
        let blocks = NotionBlocks.build(session: session, summary: summary)
        let first = Array(blocks.prefix(100))

        let pageBody: [String: Any] = [
            "parent": ["type": "page_id", "page_id": parentID],
            "properties": ["title": ["title": [["text": ["content": session.title]]]]],
            "children": first,
        ]
        let data = try await request("POST", "/v1/pages", body: pageBody)
        let pageID = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String

        // Append any blocks beyond the 100-per-request limit.
        if let pageID, blocks.count > 100 {
            for batch in stride(from: 100, to: blocks.count, by: 100) {
                let slice = Array(blocks[batch..<min(batch + 100, blocks.count)])
                _ = try await request("PATCH", "/v1/blocks/\(pageID)/children",
                                      body: ["children": slice])
            }
        }
    }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let token = Keychain.get(Config.kNotionToken), !token.isEmpty else {
            throw NotionError.notConnected
        }
        var req = URLRequest(url: URL(string: "https://api.notion.com\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return data
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw NotionError.http(0, "bad response") }
        guard (200..<300).contains(http.statusCode) else {
            throw NotionError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
