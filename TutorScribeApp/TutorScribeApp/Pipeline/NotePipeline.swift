import Foundation

enum PipelineStatus: Equatable {
    case idle
    case recording
    case transcribing
    case generating
    case finishing
    case error(String)

    var label: String {
        switch self {
        case .idle:         return "Idle"
        case .recording:    return "Recording…"
        case .transcribing: return "Transcribing…"
        case .generating:   return "Writing notes…"
        case .finishing:    return "Finishing…"
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
    private struct QueuedChunk {
        let index: Int
        let url: URL
        let completedAt: Date
    }

    var onStatus: (@MainActor (PipelineStatus) -> Void)?
    var onSegment: (@MainActor (_ count: Int, _ lastNote: String?) -> Void)?
    /// Fires with the per-session transcript file URL once it's named, and again on stop.
    var onSession: (@MainActor (URL?) -> Void)?

    private let capture = AudioCapture()
    private var store: SessionStore?
    private var task: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var queuedChunks: [QueuedChunk] = []
    private var stopRequested = false
    private var previousTranscriptTail = ""
    private let transcriptPromptChars = 600

    var isRunning: Bool { task != nil }

    func start() throws {
        guard task == nil else { return }

        let client = try OpenAIClient()              // throws if key missing
        let device = try AudioCapture.detectBlackHoleDevice()

        let store = SessionStore()
        store.startSession()
        self.store = store
        stopRequested = false
        previousTranscriptTail = ""
        queuedChunks.removeAll()
        processingTask = nil

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tutorscribe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        task = Task { [weak self] in
            guard let self else { return }
            var chunk = 0
            while !Task.isCancelled && !self.stopRequested {
                let index = chunk
                chunk += 1
                let out = tmp.appendingPathComponent("chunk_\(index).wav")
                self.emit(.recording)
                do {
                    try await self.capture.recordChunk(device: device, seconds: Config.chunkSecs, to: out)
                    self.enqueue(
                        QueuedChunk(index: index, url: out, completedAt: Date()),
                        client: client,
                        store: store
                    )
                } catch {
                    if !Task.isCancelled && !self.stopRequested {
                        self.emit(.error(error.localizedDescription))
                    }
                    try? FileManager.default.removeItem(at: out)
                }
            }
            self.emit(.finishing)
            await self.waitForProcessingDrain()
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
        guard task != nil else { return }
        stopRequested = true
        emit(.finishing)
        capture.stop()       // flush current ffmpeg chunk; queued processing drains normally
    }

    // MARK: Queue processing — same order guarantees as note-live.js

    private func enqueue(_ chunk: QueuedChunk, client: OpenAIClient, store: SessionStore) {
        queuedChunks.append(chunk)
        ensureProcessingTask(client: client, store: store)
    }

    private func ensureProcessingTask(client: OpenAIClient, store: SessionStore) {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard !self.queuedChunks.isEmpty else { break }
                let chunk = self.queuedChunks.removeFirst()
                await self.process(chunk, client: client, store: store)
                try? FileManager.default.removeItem(at: chunk.url)
            }
            self.processingTask = nil
            if !self.queuedChunks.isEmpty {
                self.ensureProcessingTask(client: client, store: store)
            }
        }
    }

    private func waitForProcessingDrain() async {
        while let processingTask {
            await processingTask.value
        }
    }

    private func process(_ chunk: QueuedChunk, client: OpenAIClient, store: SessionStore) async {
        let wav = chunk.url
        let sizeMB = fileSizeMB(wav)
        guard sizeMB >= Config.minChunkMB else { return }   // silence

        emit(.transcribing)
        let transcript: String
        do { transcript = try await client.transcribe(wav, prompt: previousTranscriptTail) }
        catch { emit(.error(error.localizedDescription)); return }

        let words = transcript.split(whereSeparator: { $0.isWhitespace }).count
        guard words > 0 else {
            if !stopRequested { emit(.recording) }
            return
        }

        let segment = store.appendTranscriptSegment(transcript, date: chunk.completedAt)
        updateTranscriptTail(transcript)
        if self.store === store { self.onSegment?(segment.number, nil) }

        guard words >= Config.minWords else {
            if !stopRequested { emit(.recording) }
            return
        }

        // First useful chunk: infer the topic and rename the per-session file. A failed
        // inference retries on the next chunk (mirrors note-live.js).
        if store.sessionFile != nil, !store.isTitleResolved {
            if let topic = try? await client.title(transcript),
               !topic.trimmingCharacters(in: .whitespaces).isEmpty {
                store.resolveTitle(topic)
                if self.store === store { self.onSession?(store.sessionFile) }
            }
        }

        emit(.generating)
        let notes: String
        do { notes = try await client.notes(transcript) }
        catch { emit(.error(error.localizedDescription)); return }

        let dropped = notes == "-"
        if !dropped {
            store.appendNotesSegment(notes, segment: segment)
        }
        guard self.store === store else { return }
        self.onSegment?(segment.number, dropped ? nil : notes)
        if !stopRequested { emit(.recording) }
    }

    private func fileSizeMB(_ url: URL) -> Double {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Double(size) / 1024 / 1024
    }

    private func updateTranscriptTail(_ transcript: String) {
        let combined = "\(previousTranscriptTail)\n\(transcript)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        previousTranscriptTail = String(combined.suffix(transcriptPromptChars))
    }

    private func emit(_ status: PipelineStatus) {
        onStatus?(status)
    }
}
