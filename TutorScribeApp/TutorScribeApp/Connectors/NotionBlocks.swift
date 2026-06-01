import Foundation

/// Converts the session markdown into Notion block objects.
/// Block structure mirrors buildNotionContent() in push-to-notion.js, but emits
/// real Notion API blocks instead of markdown text.
enum NotionBlocks {
    /// Split "## Segment N — time\n\nbody" sections into (heading, body) pairs.
    static func parseSegments(_ markdown: String) -> [(heading: String, body: String)] {
        markdown.components(separatedBy: "\n## ")
            .map { $0.hasPrefix("## ") ? String($0.dropFirst(3)) : $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .compactMap { seg in
                let lines = seg.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let heading = String(lines[0]).trimmingCharacters(in: .whitespaces)
                let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                return body.isEmpty ? nil : (heading, body)
            }
    }

    static func build(session: SessionData, summary: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        if !summary.isEmpty {
            blocks.append(callout("📋", summary))
        }

        blocks.append(heading2("📝 Notes by Segment"))
        for seg in parseSegments(session.notesMarkdown) {
            blocks.append(heading3(seg.heading))
            for line in seg.body.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = line.trimmingCharacters(in: .whitespaces)
                if let item = bulletText(s) {
                    blocks.append(bullet(item))
                } else {
                    blocks.append(paragraph(s))
                }
            }
        }

        if session.transcriptMarkdown.count > 50 {
            blocks.append(["object": "block", "type": "divider", "divider": [:]])
            blocks.append(heading2("🎙 Full Transcript"))
            for seg in parseSegments(session.transcriptMarkdown) {
                blocks.append(heading3(seg.heading))
                blocks.append(quote(seg.body))
            }
        }
        return blocks
    }

    // MARK: Block builders

    private static func bulletText(_ s: String) -> String? {
        for p in ["- ", "* ", "• "] where s.hasPrefix(p) { return String(s.dropFirst(p.count)) }
        return nil
    }

    private static func heading2(_ t: String) -> [String: Any] {
        ["object": "block", "type": "heading_2", "heading_2": ["rich_text": rich(t)]]
    }
    private static func heading3(_ t: String) -> [String: Any] {
        ["object": "block", "type": "heading_3", "heading_3": ["rich_text": rich(t)]]
    }
    private static func paragraph(_ t: String) -> [String: Any] {
        ["object": "block", "type": "paragraph", "paragraph": ["rich_text": rich(t)]]
    }
    private static func bullet(_ t: String) -> [String: Any] {
        ["object": "block", "type": "bulleted_list_item", "bulleted_list_item": ["rich_text": rich(t)]]
    }
    private static func quote(_ t: String) -> [String: Any] {
        ["object": "block", "type": "quote", "quote": ["rich_text": rich(t)]]
    }
    private static func callout(_ emoji: String, _ t: String) -> [String: Any] {
        ["object": "block", "type": "callout",
         "callout": ["rich_text": rich(t), "icon": ["type": "emoji", "emoji": emoji]]]
    }

    /// Notion caps a single text object at 2000 chars — split longer bodies.
    private static func rich(_ s: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            let piece = String(rest.prefix(2000))
            rest = rest.dropFirst(piece.count)
            out.append(["type": "text", "text": ["content": piece]])
        }
        return out.isEmpty ? [["type": "text", "text": ["content": ""]]] : out
    }
}
