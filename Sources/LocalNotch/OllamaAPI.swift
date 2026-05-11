import Foundation

struct OllamaMessage: Codable {
    let role: String
    let content: String
    var images: [String]?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        if let images { try c.encode(images, forKey: .images) }
    }
    enum CodingKeys: String, CodingKey { case role, content, images }
}

private struct OllamaChatRequest: Codable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let think: Bool
}

private struct OllamaChatChunk: Codable {
    struct Message: Codable {
        let content: String
    }
    let message: Message?
    let done: Bool
}

final class OllamaAPI: Sendable {
    static let shared = OllamaAPI()
    static var textModel: String   { UserDefaults.standard.string(forKey: "textModelName") ?? "" }
    static var visionModel: String { UserDefaults.standard.string(forKey: "visionModelName") ?? "" }

    func chat(messages: [OllamaMessage], model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = URL(string: "http://localhost:11434/api/chat")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body = OllamaChatRequest(model: model, messages: messages, stream: true, think: false)
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        let data = Data(line.utf8)
                        let chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: data)
                        if let token = chunk.message?.content {
                            continuation.yield(token)
                        }
                        if chunk.done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
