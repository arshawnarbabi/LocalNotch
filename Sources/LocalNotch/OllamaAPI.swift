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

struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let details: Details?

        struct Details: Decodable {
            let family: String?
            let families: [String]?
        }

        // Vision-capable models carry a vision encoder family in Ollama's metadata:
        // "clip" (CLIP encoder, used by LLaVA etc.), "mllama" (Llama 3.2 Vision),
        // "moondream1/2". Base model families like "gemma4" are NOT included —
        // the edge/text-only variants share the same family name as multimodal ones.
        var isVisionCapable: Bool {
            let visionFamilies: Set<String> = ["clip", "mllama", "moondream1", "moondream2"]
            let allFamilies = (details?.families ?? []) + [details?.family].compactMap { $0 }
            if allFamilies.contains(where: { visionFamilies.contains($0.lowercased()) }) { return true }
            let n = name.lowercased()
            return n.contains("vision") || n.contains("llava") || n.contains("moondream")
                || n.contains("minicpm-v") || n.contains("-vl") || n.contains(":vl")
        }
    }
    let models: [Model]
}

final class OllamaAPI: Sendable {
    static let shared = OllamaAPI()
    static var textModel: String   { UserDefaults.standard.string(forKey: "textModelName") ?? "" }
    static var visionModel: String { UserDefaults.standard.string(forKey: "visionModelName") ?? "" }

    // Short-timeout session for Ollama status/tag probes — avoids 60s hangs when Ollama is unreachable.
    static let statusSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 7
        cfg.timeoutIntervalForResource = 7
        return URLSession(configuration: cfg)
    }()

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
