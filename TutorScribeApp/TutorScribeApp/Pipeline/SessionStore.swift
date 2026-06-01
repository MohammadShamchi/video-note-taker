import Foundation

/// Append-only writer for ~/tutorial_notes.md and ~/tutorial_transcript.md.
/// Markdown conventions match scripts/note-live.js exactly so the existing
/// push-to-notion.js parser (and the Swift Notion push) keep working.
struct SessionStore {
    let notesFile: URL
    let transcriptFile: URL

    init(notes: URL = Config.notesFile, transcript: URL = Config.transcriptFile) {
        self.notesFile = notes
        self.transcriptFile = transcript
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .medium; return f
    }()

    /// Write the session header (new file) or the new-session delimiter (append).
    func startSession(date: Date = Date()) {
        let stamp = Self.stampFormatter.string(from: date)
        write(notesFile, label: "Notes", stamp: stamp)
        write(transcriptFile, label: "Transcript", stamp: stamp)
    }

    private func write(_ file: URL, label: String, stamp: String) {
        if FileManager.default.fileExists(atPath: file.path) {
            append(file, "\n\n---\n\n_New session: \(stamp)_\n\n---\n")
        } else {
            let header = "# Tutorial \(label)\n\n_Session started: \(stamp)_\n\n---\n"
            try? header.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Append one segment. Notes file is skipped when `notes` is nil ("-" result);
    /// the transcript is always saved.
    func appendSegment(_ n: Int, transcript: String, notes: String?, date: Date = Date()) {
        let time = Self.timeFormatter.string(from: date)
        append(transcriptFile, "\n## Segment \(n) — \(time)\n\n\(transcript)\n")
        if let notes {
            append(notesFile, "\n## Segment \(n) — \(time)\n\n\(notes)\n")
        }
    }

    private func append(_ file: URL, _ text: String) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: file)
        }
    }

    // MARK: Last-session recovery (port of push-to-notion.js#readLastSession)

    static func readLastSession(_ file: URL) -> String {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        let pattern = "\\n_(?:New session|Session started|Generated): "
        let ns = content as NSString
        var tail = content
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            if let last = matches.last {
                tail = ns.substring(from: last.range.location + last.range.length)
            }
        }
        if let r = tail.range(of: "\n## ") {
            let start = tail.index(after: r.lowerBound) // keep "## ..." drop leading \n
            return String(tail[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
