import Foundation
import Combine

/// One tutorial session's content, ready to send to a destination.
struct SessionData {
    let title: String
    let notesMarkdown: String
    let transcriptMarkdown: String

    var isEmpty: Bool { notesMarkdown.isEmpty && transcriptMarkdown.isEmpty }

    /// Build from the last session written to disk.
    static func fromLastSession(title: String) -> SessionData {
        SessionData(
            title: title,
            notesMarkdown: SessionStore.readLastSession(Config.notesFile),
            transcriptMarkdown: SessionStore.readLastSession(Config.transcriptFile)
        )
    }
}

/// A linkable destination (Notion today; other apps later conform the same way).
/// `authenticate()` is the shared "auth popup" entry point.
protocol Connector: AnyObject, Identifiable {
    var id: String { get }
    var displayName: String { get }
    var iconSystemName: String { get }
    var isConnected: Bool { get }

    func authenticate() async throws
    func disconnect()
    func send(_ session: SessionData) async throws
}

/// Holds the available connectors. v1 ships Notion; add a stored connector here
/// and a row in SettingsView to support a new app.
final class ConnectorRegistry: ObservableObject {
    let notion = NotionConnector()
    var all: [any Connector] { [notion] }
}
