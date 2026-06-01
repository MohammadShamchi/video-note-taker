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
/// @MainActor so its mutable state (`segments`, the `SessionStore` instance) is
/// accessed serially; the heavy work (ffmpeg, OpenAI) stays off-main via the
/// nonisolated async calls it awaits.
@MainActor
final class NotePipeline {
    var onStatus: (@MainActor (PipelineStatus) -> Void)?
    var onSegment: (@MainActor (_ count: Int, _ lastNote: String?) -> Void)?
    /// Fires with the per-session transcript file URL once it's named, and again on stop.
    var onSession: (@MainActor (URL?) -> Void)?

    private let capture = AudioCapture()
    private let store = SessionStore()
    private var task: Task<Void, Never>?
    private var segments = 0

    var isRunning: Bool { task != nil }

    func start() throws {
        guard task == nil else { return }
        let client = try OpenAIClient()              // throws if key missing
        let device = try AudioCapture.detectBlackHoleDevice()
        store.startSession()
        segments = 0

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tutorscribe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        task = Task { [weak self] in
            guard let self else { return }
            var chunk = 0
            while !Task.isCancelled {
                let out = tmp.appendingPathComponent("chunk_\(chunk).wav")
                chunk += 1
                await self.emit(.recording)
                do {
                    try await self.capture.recordChunk(device: device, seconds: Config.chunkSecs, to: out)
                    await self.process(out, client: client)
                    try? FileManager.default.removeItem(at: out)
                } catch {
                    if !Task.isCancelled {
                        await self.emit(.error(error.localizedDescription))
                    }
                }
            }
            try? FileManager.default.removeItem(at: tmp)
            let final = self.store.finishSession()
            await MainActor.run { self.onSession?(final) }
            await self.emit(.idle)
        }
    }

    func stop() {
        capture.stop()       // flush current ffmpeg chunk
        task?.cancel()
        task = nil
    }

    // MARK: One chunk — same gates as note-live.js

    private func process(_ wav: URL, client: OpenAIClient) async {
        let sizeMB = fileSizeMB(wav)
        guard sizeMB >= Config.minChunkMB else { return }   // silence

        await emit(.transcribing)
        let transcript: String
        do { transcript = try await client.transcribe(wav) }
        catch { await emit(.error(error.localizedDescription)); return }

        let words = transcript.split(whereSeparator: { $0.isWhitespace }).count
        guard words >= Config.minWords else { return }

        await emit(.generating)
        let notes: String
        do { notes = try await client.notes(transcript) }
        catch { await emit(.error(error.localizedDescription)); return }

        segments += 1

        // First useful chunk: infer the topic and rename the per-session file. A failed
        // inference retries on the next chunk (mirrors note-live.js).
        if store.sessionFile != nil, !store.isTitleResolved {
            if let topic = try? await client.title(transcript),
               !topic.trimmingCharacters(in: .whitespaces).isEmpty {
                store.resolveTitle(topic)
                let named = store.sessionFile
                await MainActor.run { self.onSession?(named) }
            }
        }

        let dropped = notes == "-"
        store.appendSegment(segments, transcript: transcript, notes: dropped ? nil : notes)
        let count = segments
        let last = dropped ? nil : notes
        await MainActor.run { self.onSegment?(count, last) }
    }

    private func fileSizeMB(_ url: URL) -> Double {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Double(size) / 1024 / 1024
    }

    private func emit(_ status: PipelineStatus) async {
        await MainActor.run { self.onStatus?(status) }
    }
}
