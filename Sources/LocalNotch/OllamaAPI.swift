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
        let content: String?
        let tool_calls: [OllamaRawToolCall]?
        let thinking: String?
    }
    let message: Message?
    let done: Bool
}

struct OllamaRawToolCall: Codable {
    struct Function: Codable {
        let name: String
        let arguments: OllamaToolArguments
    }
    let function: Function
}

// arguments can be any JSON object — decoded as [String: Any] via a special container.
struct OllamaToolArguments: Codable {
    let dict: [String: Any]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(AnyCodable.self)
        dict = (raw.value as? [String: Any]) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(AnyCodable(dict))
    }
}

// Minimal AnyCodable for [String: Any] round-trip.
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self)   { value = v; return }
        if let v = try? c.decode(Int.self)       { value = v; return }
        if let v = try? c.decode(Double.self)    { value = v; return }
        if let v = try? c.decode(Bool.self)      { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) {
            value = v.mapValues { $0.value }; return
        }
        if let v = try? c.decode([AnyCodable].self) {
            value = v.map { $0.value }; return
        }
        value = NSNull()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String:  try c.encode(s)
        case let i as Int:     try c.encode(i)
        case let d as Double:  try c.encode(d)
        case let b as Bool:    try c.encode(b)
        case let dict as [String: Any]:
            try c.encode(dict.mapValues { AnyCodable($0) })
        case let arr as [Any]:
            try c.encode(arr.map { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }
}

enum AgentChatEvent {
    case token(String)
    case thinking(String)
    case toolCalls([OllamaRawToolCall])
}

struct SemVer: Comparable {
    let major: Int; let minor: Int; let patch: Int
    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
    static func parse(_ s: String) -> SemVer? {
        let digits = s.split(separator: "-").first ?? s[...]
        let parts = digits.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return SemVer(major: parts[0], minor: parts[1], patch: parts.count > 2 ? parts[2] : 0)
    }
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

    // MARK: — Agent Mode helpers

    // Returns true if this model name/families suggest reasoning/thinking capability.
    func isThinkingCapable(model: OllamaTagsResponse.Model) -> Bool {
        let n = model.name.lowercased()
        if n.contains("qwq") || n.contains("deepseek-r1") || n.contains("r1") || n.contains("thinking") { return true }
        let families = (model.details?.families ?? []) + [model.details?.family].compactMap { $0 }
        return families.map { $0.lowercased() }.contains(where: { $0.contains("qwq") || $0.contains("deepseek") })
    }

    func ollamaVersion() async throws -> SemVer {
        struct VersionResponse: Decodable { let version: String }
        let url = URL(string: "http://localhost:11434/api/version")!
        let (data, _) = try await OllamaAPI.statusSession.data(from: url)
        let resp = try JSONDecoder().decode(VersionResponse.self, from: data)
        guard let v = SemVer.parse(resp.version) else { throw URLError(.cannotParseResponse) }
        return v
    }

    func contextLengthFor(model: String) async -> Int? {
        struct ShowRequest: Encodable { let model: String }
        guard let url = URL(string: "http://localhost:11434/api/show") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(ShowRequest(model: model))
        guard let (data, _) = try? await OllamaAPI.statusSession.data(for: req) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelInfo = json["model_info"] as? [String: Any] else { return nil }
        // Different model families use different keys (e.g. "llama.context_length", "qwen2.context_length").
        // Find any key ending in ".context_length" or falling back to "context_length".
        for key in modelInfo.keys {
            if key.hasSuffix(".context_length") || key == "context_length" {
                if let val = modelInfo[key] as? Int { return val }
                if let val = modelInfo[key] as? Double { return Int(val) }
            }
        }
        return nil
    }

    // Sends a minimal noop_test tool probe. Returns true if the model responds with a tool call.
    func verifyToolCalling(model: String) async -> Bool {
        let noop: [String: Any] = [
            "type": "function",
            "function": [
                "name": "noop_test",
                "description": "No-op test. Always call this tool immediately.",
                "parameters": [
                    "type": "object",
                    "properties": ["arg": ["type": "string"]],
                    "required": ["arg"]
                ]
            ] as [String: Any]
        ]
        let messageDict: [String: Any] = ["role": "user", "content": "Call the noop_test tool with arg 'hello'."]
        let body: [String: Any] = [
            "model": model,
            "messages": [messageDict],
            "stream": false,
            "tools": [noop]
        ]
        guard let url = URL(string: "http://localhost:11434/api/chat"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        // Use a generous timeout — large models can be slow on first call.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        let session = URLSession(configuration: cfg)
        guard let (data, _) = try? await session.data(for: req) else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]],
              !toolCalls.isEmpty else { return false }
        return true
    }

    // Streaming chat with tool-calling support for the agent harness.
    // Messages are passed as raw [String:Any] dictionaries to support tool result messages.
    func agentChat(messages: [[String: Any]], model: String) -> AsyncThrowingStream<AgentChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = URL(string: "http://localhost:11434/api/chat")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let body: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "stream": true,
                        "think": true,
                        "tools": ToolRegistry.toolDefinitions
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        let data = Data(line.utf8)
                        let chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: data)
                        if let thinking = chunk.message?.thinking, !thinking.isEmpty {
                            continuation.yield(.thinking(thinking))
                        }
                        if let content = chunk.message?.content, !content.isEmpty {
                            continuation.yield(.token(content))
                        }
                        if chunk.done {
                            if let toolCalls = chunk.message?.tool_calls, !toolCalls.isEmpty {
                                continuation.yield(.toolCalls(toolCalls))
                            }
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

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
