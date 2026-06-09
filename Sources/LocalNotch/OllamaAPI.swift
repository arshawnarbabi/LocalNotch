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

        // Models known to support Ollama tool-calling well enough for the agent loop.
        // Vision models are excluded — they're slower and optimised for image tasks, not agentic loops.
        // Note: deepseek-r1 standard tags do NOT support tool calling in Ollama — smoke test will catch them.
        // Use qwen3 or the MFDoom/deepseek-r1-tool-calling community builds instead.
        var isAgentCapable: Bool {
            guard !isVisionCapable else { return false }
            let n = name.lowercased()
            let prefixes = ["qwen3", "qwen2.5", "qwen2", "qwq",
                            "llama3.1", "llama3.2", "llama3.3",
                            "mistral", "phi4", "gemma3", "command-r",
                            "mfdoom/deepseek-r1-tool-calling", "deepseek-r1-tool-calling"]
            return prefixes.contains { n.hasPrefix($0) }
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

    // Dedicated session for agent streaming — 120s between bytes, 600s for the full task.
    // 240s idle (between bytes): a think:true turn on a 14B with a grown multi-turn context can
    // take >120s to produce its first token (cold load or long prefill), which spuriously timed
    // out mid-task. 240s gives headroom; the 600s resource cap still bounds a truly stuck request.
    static let agentSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 240
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    private static let agentChatURL = URL(string: "http://localhost:11434/api/chat")!

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

    // Working context window for agent mode. We do NOT use the model's full trained context
    // (qwen3:14b reports ~40 K) — that would inflate the KV-cache RAM cost on a 32 GB machine and
    // slow prefill. 16 K is a generous-but-bounded window for multi-step file tasks. Crucially this
    // SAME value is sent as Ollama's num_ctx AND used as the harness's contextLength, so the two
    // agree: without an explicit num_ctx Ollama silently runs at its 4 K default while the harness
    // assumes 40 K, causing silent truncation and "context limit" surprises.
    static let agentContextCap = 16384
    func agentNumCtx(forModelMax modelMax: Int?) -> Int {
        min(modelMax ?? OllamaAPI.agentContextCap, OllamaAPI.agentContextCap)
    }

    func contextLengthFor(model: String) async -> Int? {
        // Memoize the model's trained context length (a fixed property of the model file). Both
        // warmUp (at agent-mode entry) and the harness (at task start) call this; caching the first
        // successful probe guarantees they derive the SAME num_ctx even if a later /api/show times
        // out — otherwise a divergent num_ctx would force Ollama to reload the model mid-session.
        let cacheKey = "ctxLen.\(model)"
        if let cached = UserDefaults.standard.object(forKey: cacheKey) as? Int, cached > 0 { return cached }

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
                var val: Int? = nil
                if let v = modelInfo[key] as? Int { val = v }
                else if let v = modelInfo[key] as? Double { val = Int(v) }
                if let val, val > 0 {
                    UserDefaults.standard.set(val, forKey: cacheKey)   // cache only a successful probe
                    return val
                }
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
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        let session = URLSession(configuration: cfg)
        guard let (data, _) = try? await session.data(for: req) else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]],
              !toolCalls.isEmpty else { return false }
        return true
    }

    // Interpret a free-text approval reply as yes/no when keyword matching can't. Reuses the already
    // loaded agent model with think:false, no tools, and a 1-word answer, so it's fast (~1–2 s warm)
    // and needs no second model. Same num_ctx as the agent so Ollama reuses the loaded instance (a
    // different num_ctx would force a reload). Returns true=approve, false=decline, nil=couldn't tell.
    func interpretApprovalReply(_ reply: String, question: String, model: String, numCtx: Int) async -> Bool? {
        let prompt = """
        A user was asked to approve an action and replied. Decide whether the reply means YES (approve / go ahead / proceed) or NO (decline / cancel / stop).

        Action awaiting approval: \(question)
        User's reply: "\(reply)"

        Answer with ONLY one word — YES or NO.
        """
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "think": false,
            "tools": [],   // no tools → think:false is safe here (the think:false-breaks-tools issue only applies WITH tools)
            "options": ["num_ctx": numCtx, "num_predict": 4, "temperature": 0] as [String: Any],
            "keep_alive": -1
        ]
        guard let url = URL(string: "http://localhost:11434/api/chat"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (respData, _) = try? await OllamaAPI.agentSession.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = (message["content"] as? String)?.lowercased() else { return nil }
        if content.contains("yes") { return true }
        if content.contains("no") { return false }
        return nil
    }

    // Fire-and-forget preload: loads the model into memory (no generation) so the first
    // real task doesn't pay the cold-load cost. Called when the user enters agent mode, so
    // the load overlaps with them reading/typing. Idempotent — a no-op if already loaded.
    func warmUp(model: String) {
        guard !model.isEmpty, let url = URL(string: "http://localhost:11434/api/generate") else { return }
        Task {
            // Preload with the SAME num_ctx the chat path will request. If they differ, Ollama
            // reloads the model on the first real turn (num_ctx is part of the runtime instance),
            // which would defeat the whole point of preloading.
            let numCtx = self.agentNumCtx(forModelMax: await self.contextLengthFor(model: model))
            let payload: [String: Any] = [
                "model": model,
                "keep_alive": -1,
                "options": ["num_ctx": numCtx]
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            _ = try? await OllamaAPI.agentSession.data(for: req)
        }
    }

    // Fire-and-forget unload: tells Ollama to evict the model from memory now (keep_alive: 0).
    // Called when the user leaves agent mode so the model doesn't linger. Idempotent / safe if
    // the model isn't loaded.
    func unload(model: String) {
        guard !model.isEmpty,
              let url = URL(string: "http://localhost:11434/api/generate"),
              let body = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Task { _ = try? await OllamaAPI.agentSession.data(for: req) }
    }

    // Adaptive thinking — the reliable, Ollama-native way. The agent ALWAYS sends think:true
    // (verified 2026-06-03: think:false makes qwen3:14b emit a narration with NO tool_call once
    // many tools are present — 0/8 vs 5/5 — so disabling thinking silently breaks tasks). Instead
    // we keep thinking ON and, for SIMPLE tasks, append a soft steering note telling the model to
    // reason in one sentence then act. Verified: trivial tasks drop from ~30-73s to ~11s while
    // tool-calling stays 100% reliable — worst case is "reasoned a little less than ideal," never a
    // broken tool call. (A true token-capped thinking budget would need vLLM, which isn't viable on
    // Apple Silicon; Claude's self-allocating adaptive thinking is a trained-model property we can't
    // replicate on qwen3 with a flag. This nudge is the best reliable approximation on this stack.)
    static func isSimpleTask(_ text: String) -> Bool {
        guard text.count < 160 else { return false }
        let t = text.lowercased()
        let simple = ["list ", "count ", "how many", "read ", "rename ", "show ", "what time",
                      "capitalize", "lowercase", "uppercase", "spell ", "open "]
        return simple.contains(where: { t.contains($0) })
    }

    private static let thinkMinimalNudge =
        "\n\n(Simple task — reason in at most one short sentence, then immediately call the appropriate tool.)"

    // Streaming chat with tool-calling support for the agent harness.
    // Messages are passed as raw [String:Any] dictionaries to support tool result messages.
    func agentChat(messages: [[String: Any]], model: String, numCtx: Int = OllamaAPI.agentContextCap) -> AsyncThrowingStream<AgentChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: OllamaAPI.agentChatURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    // For simple tasks, append a transient "reason minimally" nudge to the latest
                    // user message (request-only, never stored) — trims over-thinking, keeps think:true.
                    var reqMessages = messages
                    if let idx = reqMessages.lastIndex(where: { ($0["role"] as? String) == "user" }),
                       let content = reqMessages[idx]["content"] as? String,
                       OllamaAPI.isSimpleTask(content) {
                        reqMessages[idx]["content"] = content + OllamaAPI.thinkMinimalNudge
                    }
                    let body: [String: Any] = [
                        "model": model,
                        "messages": reqMessages,
                        "stream": true,
                        "think": true,   // always — think:false breaks tool emission at 9 tools (see note above)
                        "tools": ToolRegistry.toolDefinitions,
                        // Explicit working context window. Without this Ollama defaults to ~4 K and
                        // silently truncates the prompt while the harness believes it has far more —
                        // so a single large tool result blows the context. Must match warmUp's num_ctx.
                        "options": ["num_ctx": numCtx],
                        // Stay resident for the ENTIRE agent-mode session (-1 = keep loaded until
                        // explicitly unloaded). AppDelegate unloads it the moment the user leaves
                        // agent mode, so it never pins RAM after they're done — exactly "loaded
                        // from agent-mode entry until agent-mode exit, regardless of idle time."
                        "keep_alive": -1
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, _) = try await OllamaAPI.agentSession.bytes(for: request)
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
                        // Check tool_calls on every chunk — some models emit them before done.
                        if let toolCalls = chunk.message?.tool_calls, !toolCalls.isEmpty {
                            continuation.yield(.toolCalls(toolCalls))
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
