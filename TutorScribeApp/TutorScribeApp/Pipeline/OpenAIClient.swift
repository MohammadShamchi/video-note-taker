import Foundation

enum OpenAIError: LocalizedError {
    case missingKey
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:        return "OpenAI API key is not set. Add it in Settings."
        case .http(let c, let m): return "OpenAI \(c): \(m)"
        case .badResponse:       return "Unexpected response from OpenAI."
        }
    }
}

/// Direct OpenAI calls — Whisper transcription + GPT notes.
/// Prompts and models mirror scripts/note-live.js and push-to-notion.js.
struct OpenAIClient {
    let apiKey: String

    init() throws {
        guard let key = Keychain.get(Config.kOpenAIKey), !key.isEmpty else {
            throw OpenAIError.missingKey
        }
        apiKey = key
    }

    // MARK: Transcription (whisper-1, response_format=text)

    func transcribe(_ wav: URL) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: wav)
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
        field("model", "whisper-1")
        field("response_format", "text")
        body.append("--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Notes (chat completions) — exact prompt from note-live.js

    func notes(_ transcript: String) async throws -> String {
        let system = """
        You are a concise note-taker for tutorial videos.
        Extract from the transcript:
        - Key concepts introduced
        - Steps, techniques, or workflows explained
        - Specific commands, code, file names, or values mentioned
        - Tips or warnings from the instructor

        Bullet points under a short bold heading. Skip filler and repetition.
        If nothing useful, reply with just a dash "-".
        """
        return try await chat(system: system, user: transcript)
    }

    // MARK: Session summary — exact prompt from push-to-notion.js

    func summary(_ notesText: String) async throws -> String {
        let system = "Write a 3-5 sentence plain-prose summary of what was covered in this tutorial session. No bullet points."
        return try await chat(system: system, user: notesText)
    }

    // MARK: Shared chat helper

    private func chat(system: String, user: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": Config.notesModel,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenAIError.badResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw OpenAIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}
