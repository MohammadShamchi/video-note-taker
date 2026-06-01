import Foundation

enum PipelineStatus: Equatable {
    case idle
    case recording
    case transcribing
    case generating
    case error(String)

    var label: String {
        switch self {
        case .idle:         return "Idle"
        case .recording:    return "Recording…"
        case .transcribing: return "Transcribing…"
        case .generating:   return "Writing notes…"
        case .error(let m): return m
        }
    }
}

/// The record → transcribe → note loop. Mirrors the main loop in note-live.js.
/// @MainActor so its mutable state is accessed serially; the heavy work (ffmpeg,
/// OpenAI) stays off-main via the nonisolated async calls it awaits. All per-session
/// state lives in a fresh `SessionStore` per run, captured by the running task, so a
/// rapid Stop→Start can't let an old task's cleanup touch the new session.
@MainActor
final class NotePipeline {
    var onStatus: (@MainActor (PipelineStatus) -> Void)?
    var onSegment: (@MainActor (_ count: Int, _ lastNote: String?) -> Void)?
    /// Fires with the per-session transcript file URL once it's named, and again on stop.
    var onSession: (@MainActor (URL?) -> Void)?

    private let capture = AudioCapture()
    private var store: SessionStore?
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func start() throws {
        let client = try OpenAIClient()              // throws if key missing
        let device = try AudioCapture.detectBlackHoleDevice()

        // Supersede any in-flight session: its cleanup will see a different `store`
        // and bail out (see the guard at the end of the task).
        task?.cancel()
        capture.stop()

        let store = SessionStore()
        store.startSession()
        self.store = store

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tutorscribe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        task = Task { [weak self] in
            guard let self else { return }
            var chunk = 0
            while !Task.isCancelled {
                let out = tmp.appendingPathComponent("chunk_\(chunk).wav")
                chunk += 1
                self.emit(.recording)
                do {
                    try await self.capture.recordChunk(device: device, seconds: Config.chunkSecs, to: out)
                    await self.process(out, client: client, store: store)
                    try? FileManager.default.removeItem(at: out)
                } catch {
                    if !Task.isCancelled {
                        self.emit(.error(error.localizedDescription))
                    }
                }
            }
            try? FileManager.default.removeItem(at: tmp)
            let final = store.finishSession()
            // Only report completion if no newer session has taken over.
            guard self.store === store else { return }
            self.onSession?(final)
            self.emit(.idle)
            self.task = nil
        }
    }

    func stop() {
        capture.stop()       // flush current ffmpeg chunk
        task?.cancel()       // task = nil happens at the end of its own cleanup
    }

    // MARK: One chunk — same gates as note-live.js

    private func process(_ wav: URL, client: OpenAIClient, store: SessionStore) async {
        let sizeMB = fileSizeMB(wav)
        guard sizeMB >= Config.minChunkMB else { return }   // silence

        emit(.transcribing)
        let transcript: String
        do { transcript = try await client.transcribe(wav) }
        catch { emit(.error(error.localizedDescription)); return }

        let words = transcript.split(whereSeparator: { $0.isWhitespace }).count
        guard words >= Config.minWords else { return }

        emit(.generating)
        let notes: String
        do { notes = try await client.notes(transcript) }
        catch { emit(.error(error.localizedDescription)); return }

        // First useful chunk: infer the topic and rename the per-session file. A failed
        // inference retries on the next chunk (mirrors note-live.js).
        if store.sessionFile != nil, !store.isTitleResolved {
            if let topic = try? await client.title(transcript),
               !topic.trimmingCharacters(in: .whitespaces).isEmpty {
                store.resolveTitle(topic)
                if self.store === store { self.onSession?(store.sessionFile) }
            }
        }

        let dropped = notes == "-"
        let count = store.appendSegment(transcript: transcript, notes: dropped ? nil : notes)
        guard self.store === store else { return }
        self.onSegment?(count, dropped ? nil : notes)
    }

    private func fileSizeMB(_ url: URL) -> Double {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Double(size) / 1024 / 1024
    }

    private func emit(_ status: PipelineStatus) {
        onStatus?(status)
    }
}
