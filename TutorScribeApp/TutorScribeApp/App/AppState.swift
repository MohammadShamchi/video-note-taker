import Foundation
import SwiftUI
import Combine
import AppKit

/// Top-level view model: owns the pipeline and connector registry, exposes
/// observable state to the menu bar UI.
@MainActor
final class AppState: ObservableObject {
    @Published var status: PipelineStatus = .idle
    @Published var isRunning = false
    @Published var segmentCount = 0
    @Published var lastNote: String?
    @Published var banner: String?          // transient success/error message
    @Published var lastTranscriptFile: URL? // per-session transcript, set on Stop
    /// Default Notion page title: the topic inferred for the current/last session
    /// (Feature 2), falling back to the latest session topic, then a date title.
    /// Stored (not computed) so the SwiftUI text field doesn't hit disk per keystroke;
    /// recomputed only when the per-session file changes.
    @Published var defaultNotionTitle: String = SessionData.dateTitle()

    let registry = ConnectorRegistry()
    private let pipeline = NotePipeline()

    init() {
        pipeline.onStatus = { [weak self] s in self?.status = s }
        pipeline.onSegment = { [weak self] count, note in
            self?.segmentCount = count
            if let note { self?.lastNote = note }
        }
        pipeline.onSession = { [weak self] url in
            self?.lastTranscriptFile = url
            self?.refreshDefaultTitle()
        }
        refreshDefaultTitle()
    }

    var canPush: Bool { registry.notion.isConnected && !isRunning }

    /// Recompute `defaultNotionTitle` from disk. Called once at init and whenever the
    /// per-session file changes (named on the first chunk, finalized on Stop).
    private func refreshDefaultTitle() {
        if let file = lastTranscriptFile, let topic = SessionStore.title(of: file) {
            defaultNotionTitle = topic
        } else {
            defaultNotionTitle = SessionStore.latestSessionTitle() ?? SessionData.dateTitle()
        }
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        do {
            try pipeline.start()
            isRunning = true
            segmentCount = 0
            lastNote = nil
            banner = nil
            lastTranscriptFile = nil
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func stop() {
        pipeline.stop()
        isRunning = false
        status = .idle
    }

    func openTranscript() {
        guard let url = lastTranscriptFile else { return }
        if (try? url.checkResourceIsReachable()) == true {
            NSWorkspace.shared.open(url)
        } else {
            banner = "Transcript file no longer exists."
        }
    }

    func pushToNotion(title: String) {
        let session = SessionData.fromLastSession(title: title)
        guard !session.isEmpty else { banner = "No session to push yet."; return }
        Task {
            do {
                try await registry.notion.send(session)
                banner = "Pushed to Notion ✓"
            } catch {
                banner = error.localizedDescription
            }
        }
    }
}
