import Foundation

/// Append-only writer for ~/tutorial_notes.md and ~/tutorial_transcript.md, plus a
/// per-session, topic-named transcript copy under ~/TutorScribe/transcripts/.
/// Markdown conventions match scripts/note-live.js exactly so the existing
/// push-to-notion.js parser (and the Swift Notion push) keep working.
/// @MainActor so its mutable session state is accessed serially with NotePipeline.
@MainActor
final class SessionStore {
    let notesFile: URL
    let transcriptFile: URL

    /// Per-session transcript copy. Starts at a `pending-…` path, renamed to a
    /// topic-based filename once the first useful chunk lets us infer the topic.
    private(set) var sessionFile: URL?
    private var titleResolved = false
    private var sessionDate = Date()

    var isTitleResolved: Bool { titleResolved }

    init(notes: URL? = nil, transcript: URL? = nil) {
        self.notesFile = notes ?? Config.notesFile
        self.transcriptFile = transcript ?? Config.transcriptFile
    }

    /// `~/TutorScribe/transcripts/` — per-session transcript directory (matches the CLI).
    private static var sessionDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("TutorScribe", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .medium; return f
    }()
    /// `_Created: 1 Jun 2026, 14:30_` — matches transcriptHeader() in note-live.js.
    private static let createdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f
    }()
    /// `2026-06-01-14-30` — stable, sortable filename stamp (POSIX locale for fixed digits).
    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH-mm"
        return f
    }()

    /// Write the session header (new file) or the new-session delimiter (append), and
    /// open the per-session transcript copy under a pending name.
    func startSession(date: Date = Date()) {
        sessionDate = date
        titleResolved = false
        let stamp = Self.stampFormatter.string(from: date)
        write(notesFile, label: "Notes", stamp: stamp)
        write(transcriptFile, label: "Transcript", stamp: stamp)

        do {
            try FileManager.default.createDirectory(at: Self.sessionDir, withIntermediateDirectories: true)
            let pending = Self.sessionDir
                .appendingPathComponent("pending-\(Self.timestampForFilename(date)).md")
            let header = Self.transcriptHeader("Tutorial session (identifying topic…)", date)
            try header.write(to: pending, atomically: true, encoding: .utf8)
            sessionFile = pending
        } catch {
            sessionFile = nil
        }
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
    /// the transcript files are always saved.
    func appendSegment(_ n: Int, transcript: String, notes: String?, date: Date = Date()) {
        let time = Self.timeFormatter.string(from: date)
        let block = "\n## Segment \(n) — \(time)\n\n\(transcript)\n"
        append(transcriptFile, block)
        if let sessionFile { append(sessionFile, block) }
        if let notes {
            append(notesFile, "\n## Segment \(n) — \(time)\n\n\(notes)\n")
        }
    }

    /// First useful chunk: rename the pending per-session file to a topic-based name and
    /// rewrite its `# …` heading. No-op once resolved or when `topic` is empty.
    func resolveTitle(_ topic: String) {
        guard let pending = sessionFile, !titleResolved else { return }
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let final = Self.sessionDir
            .appendingPathComponent("\(Self.timestampForFilename(sessionDate))-\(Self.slugify(trimmed)).md")
        guard rename(pending, to: final, heading: trimmed) else { return }
        sessionFile = final
        titleResolved = true
    }

    /// On stop: if no topic was ever resolved, rename the pending file to a clean
    /// fallback name (matches the CLI SIGINT handler). Returns the final session file.
    @discardableResult
    func finishSession() -> URL? {
        if let pending = sessionFile, !titleResolved {
            let final = Self.sessionDir
                .appendingPathComponent("\(Self.timestampForFilename(sessionDate))-tutorial-session.md")
            if rename(pending, to: final, heading: "Tutorial Session") {
                sessionFile = final
            }
        }
        return sessionFile
    }

    /// Rewrite the first `# …` heading line to `# heading`, write to `dst`, remove `src`.
    private func rename(_ src: URL, to dst: URL, heading: String) -> Bool {
        guard let content = try? String(contentsOf: src, encoding: .utf8) else { return false }
        let fixed = replaceFirstHeading(content, with: heading)
        do {
            try fixed.write(to: dst, atomically: true, encoding: .utf8)
            if dst != src { try? FileManager.default.removeItem(at: src) }
            return true
        } catch {
            return false
        }
    }

    private func replaceFirstHeading(_ content: String, with heading: String) -> String {
        guard content.hasPrefix("#"), let nl = content.firstIndex(of: "\n") else {
            return "# \(heading)\n" + content
        }
        return "# \(heading)" + String(content[nl...])
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

    // MARK: Filename helpers (port of note-live.js)

    /// Filesystem-safe slug: lowercase ASCII, hyphen-separated, diacritics stripped, max 80.
    static func slugify(_ title: String) -> String {
        let folded = title.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        var slug = ""
        var lastDash = false
        for scalar in folded.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                slug.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                slug.append("-")
                lastDash = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 80 { slug = String(slug.prefix(80)) }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "untitled" : slug
    }

    /// `yyyy-MM-dd-HH-mm` for stable, sortable filenames.
    static func timestampForFilename(_ date: Date) -> String {
        filenameFormatter.string(from: date)
    }

    static func transcriptHeader(_ title: String, _ date: Date) -> String {
        "# \(title)\n\n_Created: \(createdFormatter.string(from: date))_\n\n---\n"
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
