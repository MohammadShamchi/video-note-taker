import Foundation

/// Central configuration. Tunables live in UserDefaults, secrets in Keychain.
/// Defaults mirror the Node scripts (note-live.js) so output stays identical.
enum Config {
    // MARK: Keychain item keys
    static let kOpenAIKey       = "openai_api_key"
    static let kNotionSecret    = "notion_client_secret"
    static let kNotionToken     = "notion_access_token"

    // MARK: UserDefaults keys
    static let kNotionClientID  = "notion_client_id"
    static let kNotionWorkspace = "notion_workspace_name"
    static let kNotionParentID  = "notion_parent_id"
    static let kNotionParentTitle = "notion_parent_title"
    static let kChunkSecs       = "chunk_secs"
    static let kNotesModel      = "notes_model"

    // MARK: Tunables (overridable in Settings)
    static var chunkSecs: Int {
        let v = UserDefaults.standard.integer(forKey: kChunkSecs)
        return v > 0 ? v : 60
    }

    static var notesModel: String {
        UserDefaults.standard.string(forKey: kNotesModel) ?? "gpt-4o-mini"
    }

    /// Notes are skipped below this count, but non-empty transcripts are still saved.
    static let minWords = 15

    /// Chunks smaller than this (MB) are treated as silence.
    static let minChunkMB = 0.005

    // MARK: Output paths (home directory, matching the CLI)
    static var notesFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("tutorial_notes.md")
    }

    static var transcriptFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("tutorial_transcript.md")
    }

    // MARK: OAuth
    static let notionRedirectURI = "tutorscribe://oauth"
    static let notionCallbackScheme = "tutorscribe"
}
