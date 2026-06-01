import Foundation

enum CaptureError: LocalizedError {
    case ffmpegNotFound
    case blackholeNotFound
    case ffmpeg(Int32)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:    return "ffmpeg not found. Install it with: brew install ffmpeg"
        case .blackholeNotFound: return "BlackHole device not found. Install it (brew install blackhole-2ch), then route output through a Multi-Output Device."
        case .ffmpeg(let code):  return "ffmpeg exited with code \(code)."
        }
    }
}

/// Captures live system audio via ffmpeg + avfoundation (BlackHole), one WAV
/// chunk per call. Mirrors recordChunk() in scripts/note-live.js.
final class AudioCapture {
    private var current: Process?

    /// Resolve the ffmpeg binary (GUI apps don't inherit the shell PATH).
    static func ffmpegPath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Parse `ffmpeg -list_devices` stderr for the BlackHole avfoundation index.
    static func detectBlackHoleDevice() throws -> String {
        guard let ffmpeg = ffmpegPath() else { throw CaptureError.ffmpegNotFound }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-f", "avfoundation", "-list_devices", "true", "-i", ""]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = Pipe()
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"\[(\d+)\]\s+BlackHole"#, options: .caseInsensitive)
        for line in output.split(separator: "\n") {
            let s = String(line)
            if let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range(at: 1), in: s) {
                return String(s[r])
            }
        }
        throw CaptureError.blackholeNotFound
    }

    /// Record one chunk to `out`. Success on exit 0 or 255 (255 = our SIGTERM).
    func recordChunk(device: String, seconds: Int, to out: URL) async throws {
        guard let ffmpeg = Self.ffmpegPath() else { throw CaptureError.ffmpegNotFound }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = [
            "-y", "-f", "avfoundation", "-i", ":\(device)",
            "-t", String(seconds), "-ar", "16000", "-ac", "1", out.path,
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        current = proc

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { p in
                let code = p.terminationStatus
                if code == 0 || code == 255 { cont.resume() }
                else { cont.resume(throwing: CaptureError.ffmpeg(code)) }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
        current = nil
    }

    /// Flush the active chunk (SIGTERM, ffmpeg writes a valid file and exits 255).
    func stop() {
        current?.terminate()
    }
}
