import Foundation
import SwiftUI
import Combine

/// Top-level view model: owns the pipeline and connector registry, exposes
/// observable state to the menu bar UI.
@MainActor
final class AppState: ObservableObject {
    @Published var status: PipelineStatus = .idle
    @Published var isRunning = false
    @Published var segmentCount = 0
    @Published var lastNote: String?
    @Published var banner: String?          // transient success/error message

    let registry = ConnectorRegistry()
    private let pipeline = NotePipeline()

    init() {
        pipeline.onStatus = { [weak self] s in self?.status = s }
        pipeline.onSegment = { [weak self] count, note in
            self?.segmentCount = count
            if let note { self?.lastNote = note }
        }
    }

    var canPush: Bool { registry.notion.isConnected && !isRunning }

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
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func stop() {
        pipeline.stop()
        isRunning = false
        status = .idle
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
