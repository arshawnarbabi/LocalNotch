import Foundation

struct AgentBubble: Identifiable {
    enum BubbleType {
        case plan, step, toolResult, clarification, approval, error
    }
    let id = UUID()
    var type: BubbleType
    var text: String
    var reasoning: String? = nil
    var isStreaming: Bool = false
    var taskIndex: Int = 0
}

struct ActionLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let toolName: String
    let argsDescription: String
    let succeeded: Bool
    let note: String
}

@MainActor
final class AgentRunner: ObservableObject {
    static let shared = AgentRunner()

    @Published var state: AgentState = .idle
    @Published var bubbles: [AgentBubble] = []
    @Published var finalOutput: String = ""
    @Published var actionLog: [ActionLogEntry] = []

    // Captured at task start — immune to Settings changes mid-task (§4.17).
    private(set) var activeModel: String = ""
    private var contextLength: Int = 8192

    // Conversation history for the Ollama messages API (raw dicts to support tool results).
    private var messages: [[String: Any]] = []

    // Task control
    private var agentTask: Task<Void, Never>? = nil
    private var forceStopped = false
    private var resumeContinuation: CheckedContinuation<String?, Never>? = nil
    private var currentTaskIndex: Int = 0
    private var lastExecutedTool: String = ""

    // Failure tracking
    private var consecutiveFailures = 0

    // Bulk-op circumvention detection (§4.13)
    private var recentToolCalls: [(name: String, timestamp: Date)] = []

    private let agentSystemPrompt = """
You are the LocalNotch Agent — an autonomous AI agent running locally on the user's macOS device. You operate inside the LocalNotch notch panel. Your job is to plan and execute real tasks on the user's Mac by calling the file-system tools you have access to.

# Identity and inviolable rules

- You run entirely on-device through Ollama. Nothing the user says to you leaves their machine.
- You are NOT a chat model and you are NOT here to converse. You exist to complete tasks the user delegates to you. Keep all output brief and operational.
- You have access ONLY to the tools listed below. You cannot access the network, run shell commands, control other apps, take screenshots, or do anything else outside these tools. If the user asks for something outside this scope, say so plainly in one sentence and stop.
- Destructive operations (delete, overwrite) and bulk operations (>20 files in one call) ALWAYS require explicit user approval. You must ask before executing them, even if the user's prompt seems to authorize them — the host harness will gate these regardless, so asking first produces a better user experience.
- Never permanently delete a file. Deletion always means "move to Trash."
- You can pause yourself to ask the user a clarifying question or request approval. You CANNOT cancel or stop yourself — only the user can stop you.

# Workflow — what every task looks like

1. PLAN. The user gives you a task in natural language. Your very first response must be a plan: a numbered list of the concrete steps you intend to take, in order. Keep it short — usually 3–7 steps. Do not start executing yet.
2. EXECUTE. After emitting the plan, immediately begin executing it by calling tools one at a time. For each step:
   - Briefly state what you are about to do in one short sentence ("Listing files in ~/Desktop.").
   - Call the tool.
   - Read the result. If it failed, decide whether to retry with different parameters, skip, or abort the plan.
3. ASK when uncertain. If the user's prompt is ambiguous, you DO NOT have to guess. Emit a clarifying question with a leading marker [NEEDS_CLARIFICATION] on its own line. The host will pause execution and wait for the user's reply. Resume only when the user answers.
4. ASK before risky actions. Before any destructive or bulk action, emit a marker [NEEDS_APPROVAL] on its own line followed by a one-sentence summary of what you are about to do. The host will pause for the user's yes/no.
5. FINISH. When the task is complete, emit a final summary in normal prose (no markers) that tells the user exactly what was done. This summary is shown to the user as the final answer.

# Output style

- Step descriptions: one short sentence, present tense, ending in a period. Example: "Moving 12 PNG files into ~/Desktop/Screenshots."
- Plans: numbered list, one line per step, no padding text.
- Final summary: 1–3 short paragraphs. Lead with what was done. No marketing language, no apologies, no "I hope this helps."
- NEVER repeat the user's request back to them. NEVER preface answers with "Sure!" or "Of course." NEVER explain that you are an AI.
- All output is rendered inside small glass bubbles in a notch panel. Long output gets clipped. Be brief.

# Tools

You have access to nine file-system tools. Full schemas are provided via the tool-calling API. Brief reference:

- list_directory(path) — readonly. List contents of a folder.
- read_file(path) — readonly. Read text file contents. Files larger than 1 MB are truncated.
- get_file_info(path) — readonly. Size, modified date, type.
- search_files(query, path, includeHidden=false) — readonly. Find files by name pattern. Returns first 200 matches.
- move_file(from, to) — write. Rename or relocate.
- create_folder(path) — write. Make a new directory.
- copy_file(from, to) — write. Duplicate.
- delete_file(path) — destructive. Moves to Trash (NEVER permanent). Requires approval.
- overwrite_file(path, content) — destructive. Replaces file contents. Requires approval.

Default allowed paths: ~/Desktop, ~/Documents, ~/Downloads. Any write outside these paths requires approval — emit [NEEDS_APPROVAL] first.

# Failure handling

- A single tool failure: log it briefly, decide whether to retry with different params, skip, or revise the plan.
- Three consecutive tool failures: stop. Emit a final summary explaining what went wrong. The host will end the task.

# Recency reminders (do not violate)

- Plan first. Always. Even for one-step tasks.
- Delete and overwrite ALWAYS need approval. No exceptions.
- Never permanently delete. Trash only.
- Be brief. Bubbles are small.
- You cannot cancel yourself. Only the user can.
"""

    private init() {}

    // MARK: — Public control API

    func startTask(prompt: String) {
        guard state == .idle || state == .finished || state == .forceStopped else { return }
        forceStopped = false
        consecutiveFailures = 0
        recentToolCalls = []
        activeModel = AppSettings.shared.agentModel
        currentTaskIndex += 1
        let taskIdx = currentTaskIndex

        // System message only on first task; chained tasks reuse the same conversation.
        if messages.isEmpty {
            messages.append(["role": "system", "content": agentSystemPrompt])
        }
        messages.append(["role": "user", "content": prompt])

        state = .running
        agentTask = Task { [weak self] in
            await self?.runHarnessLoop(taskIndex: taskIdx)
        }
    }

    func pause() {
        guard state == .running else { return }
        state = .paused
    }

    func resume(withContext: String? = nil) {
        guard state == .paused else { return }
        state = .running
        resumeContinuation?.resume(returning: withContext)
        resumeContinuation = nil
    }

    func forceStop() {
        guard state.isActive else { return }
        forceStopped = true
        agentTask?.cancel()
        state = .forceStopped
        let toolMsg = lastExecutedTool.isEmpty ? "" : " Last action completed: \(lastExecutedTool)."
        addBubble(type: .error, text: "Stopped by user.\(toolMsg)", taskIndex: currentTaskIndex)
    }

    // Called when user sends a reply in State G (clarification) or H (approval).
    func handleUserResponse(_ text: String) {
        guard state == .clarifying || state == .approving else { return }
        state = .running
        messages.append(["role": "user", "content": text])
        agentTask = Task { [weak self] in
            await self?.runHarnessLoop(taskIndex: self?.currentTaskIndex ?? 0)
        }
    }

    func exitAgentMode() {
        agentTask?.cancel()
        state = .idle
        bubbles = []
        finalOutput = ""
        actionLog = []
        messages = []
        consecutiveFailures = 0
        currentTaskIndex = 0
    }

    // MARK: — Harness loop

    private func runHarnessLoop(taskIndex: Int) async {
        // Fetch context length once.
        if let len = await OllamaAPI.shared.contextLengthFor(model: activeModel) {
            contextLength = len
        }

        while !Task.isCancelled && !forceStopped {
            // Pause gate.
            if state == .paused {
                let context = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                    resumeContinuation = cont
                }
                if let ctx = context, !ctx.isEmpty {
                    messages.append(["role": "user", "content": ctx])
                }
                if forceStopped { break }
            }

            // Context budget check (§4.21).
            let estimatedTokens = messages.reduce(0) { sum, m in
                sum + ((m["content"] as? String)?.count ?? 0)
            } / 3
            if estimatedTokens > Int(Double(contextLength) * 0.80) {
                addBubble(type: .error,
                          text: "Stopped — context limit reached for \(activeModel). The task was too long for this model's context window.",
                          taskIndex: taskIndex)
                state = .finished
                return
            }

            // Stream the next model response.
            var streamedText = ""
            var pendingThinking = ""
            var toolCalls: [OllamaRawToolCall] = []
            var markerDetected: String? = nil

            let bubble = addStreamingBubble(type: .step, taskIndex: taskIndex)

            let stream = OllamaAPI.shared.agentChat(messages: messages, model: activeModel)
            var lineBuffer = ""

            do {
                for try await event in stream {
                    if forceStopped || Task.isCancelled { break }

                    switch event {
                    case .thinking(let t):
                        pendingThinking += t

                    case .token(let token):
                        streamedText += token
                        lineBuffer += token

                        // Marker detection on line boundaries (§4.19).
                        while let newline = lineBuffer.firstIndex(of: "\n") {
                            let line = String(lineBuffer[lineBuffer.startIndex..<newline])
                            lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])

                            if line.hasPrefix("[NEEDS_CLARIFICATION]") {
                                let question = line.dropFirst("[NEEDS_CLARIFICATION]".count).trimmingCharacters(in: .whitespaces)
                                markerDetected = "clarification:\(question)"
                                break
                            } else if line.hasPrefix("[NEEDS_APPROVAL]") {
                                let request = line.dropFirst("[NEEDS_APPROVAL]".count).trimmingCharacters(in: .whitespaces)
                                markerDetected = "approval:\(request)"
                                break
                            }
                        }

                        if markerDetected != nil { break }
                        updateBubble(id: bubble, text: streamedText)

                    case .toolCalls(let calls):
                        toolCalls = calls
                    }

                    if markerDetected != nil { break }
                }
            } catch {
                if !forceStopped {
                    addBubble(type: .error, text: "Connection error: \(error.localizedDescription)", taskIndex: taskIndex)
                    state = .finished
                    return
                }
            }

            if forceStopped || Task.isCancelled { break }

            // Finalize the streaming bubble.
            finalizeBubble(id: bubble, text: streamedText, reasoning: pendingThinking.isEmpty ? nil : pendingThinking)

            // Append assistant message to history.
            var assistantMsg: [String: Any] = ["role": "assistant", "content": streamedText]
            if !toolCalls.isEmpty {
                let toolCallDicts = toolCalls.map { tc -> [String: Any] in
                    ["function": ["name": tc.function.name, "arguments": tc.function.arguments.dict] as [String: Any]]
                }
                assistantMsg["tool_calls"] = toolCallDicts
            }
            messages.append(assistantMsg)

            // Handle markers.
            if let marker = markerDetected {
                if marker.hasPrefix("clarification:") {
                    let q = String(marker.dropFirst("clarification:".count))
                    updateBubble(id: bubble, text: q)
                    state = .clarifying
                    return
                } else if marker.hasPrefix("approval:") {
                    let q = String(marker.dropFirst("approval:".count))
                    updateBubble(id: bubble, text: q)
                    state = .approving
                    return
                }
            }

            // Handle tool calls.
            if !toolCalls.isEmpty {
                for tc in toolCalls {
                    if forceStopped { break }
                    await executeTool(tc, taskIndex: taskIndex)
                }
                continue // Next harness loop iteration.
            }

            // No tool calls and no markers — model is done.
            if !streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalOutput = streamedText
            }
            state = .finished
            return
        }
    }

    // MARK: — Tool execution

    private func executeTool(_ tc: OllamaRawToolCall, taskIndex: Int) async {
        let name = tc.function.name
        let args = tc.function.arguments.dict

        guard let riskLevel = ToolRegistry.riskLevel(for: name) else {
            let result = ToolResult.fail("Unknown tool: \(name)")
            appendToolResult(name: name, args: args, result: result, taskIndex: taskIndex)
            return
        }

        // Hard safety rails (§4.3).
        if riskLevel == .destructive {
            // Should have been gated by [NEEDS_APPROVAL] already.
            // If not, gate here as a fallback.
            addBubble(type: .approval, text: "Approve destructive operation: \(name)(\(describeArgs(args)))?", taskIndex: taskIndex)
            state = .approving
            return
        }

        // Bulk op detection (§4.13): count same-tool calls within 30s.
        let now = Date()
        recentToolCalls = recentToolCalls.filter { now.timeIntervalSince($0.timestamp) < 30 }
        recentToolCalls.append((name: name, timestamp: now))
        let sameToolCount = recentToolCalls.filter { $0.name == name }.count
        if sameToolCount > 20 && riskLevel == .write {
            addBubble(type: .approval, text: "Bulk operation detected: \(sameToolCount) \(name) calls in 30s. Proceed?", taskIndex: taskIndex)
            state = .approving
            return
        }

        // Path whitelist check for writes (§4.11).
        if riskLevel == .write {
            let targetPath = (args["to"] as? String ?? args["path"] as? String ?? "")
            let expanded = NSString(string: targetPath).expandingTildeInPath
            let allowed = AppSettings.shared.agentAllowedPaths
            let isAllowed = allowed.contains { expanded.hasPrefix($0) }
            if !isAllowed && !targetPath.isEmpty {
                addBubble(type: .approval, text: "Write outside allowed paths: \(targetPath). Proceed?", taskIndex: taskIndex)
                state = .approving
                return
            }
        }

        lastExecutedTool = name
        let result: ToolResult
        do {
            result = try await ToolRegistry.execute(toolName: name, arguments: args)
        } catch {
            result = .fail(error.localizedDescription)
        }

        appendToolResult(name: name, args: args, result: result, taskIndex: taskIndex)
    }

    private func appendToolResult(name: String, args: [String: Any], result: ToolResult, taskIndex: Int) {
        if result.success {
            consecutiveFailures = 0
            addBubble(type: .toolResult, text: result.asString, taskIndex: taskIndex)
        } else {
            consecutiveFailures += 1
            addBubble(type: .error, text: result.asString, taskIndex: taskIndex)
            if consecutiveFailures >= 3 {
                addBubble(type: .error,
                          text: "Three consecutive tool failures. Stopping task.",
                          taskIndex: taskIndex)
                state = .finished
                return
            }
        }

        actionLog.append(ActionLogEntry(
            timestamp: Date(),
            toolName: name,
            argsDescription: describeArgs(args),
            succeeded: result.success,
            note: result.error ?? result.output?.prefix(120).description ?? ""
        ))

        // Append tool result to conversation for next model turn.
        messages.append(["role": "tool", "content": result.asString])
    }

    // MARK: — Bubble helpers

    @discardableResult
    private func addBubble(type: AgentBubble.BubbleType, text: String, taskIndex: Int) -> UUID {
        let b = AgentBubble(type: type, text: text, taskIndex: taskIndex)
        bubbles.append(b)
        return b.id
    }

    @discardableResult
    private func addStreamingBubble(type: AgentBubble.BubbleType, taskIndex: Int) -> UUID {
        var b = AgentBubble(type: type, text: "", taskIndex: taskIndex)
        b.isStreaming = true
        bubbles.append(b)
        return b.id
    }

    private func updateBubble(id: UUID, text: String) {
        guard let idx = bubbles.firstIndex(where: { $0.id == id }) else { return }
        bubbles[idx].text = text
    }

    private func finalizeBubble(id: UUID, text: String, reasoning: String?) {
        guard let idx = bubbles.firstIndex(where: { $0.id == id }) else { return }
        bubbles[idx].text = text
        bubbles[idx].reasoning = reasoning
        bubbles[idx].isStreaming = false
    }

    private func describeArgs(_ args: [String: Any]) -> String {
        args.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }
}
