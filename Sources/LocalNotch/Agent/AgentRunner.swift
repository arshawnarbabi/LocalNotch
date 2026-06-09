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
    var placeholder: String = "Thinking…"   // shown by the view while streaming + text empty
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

    @Published var state: AgentState = .welcome {
        didSet { if oldValue != state { print("[Agent] \(oldValue) → \(state)") } }
    }
    @Published var isShowingAgentView = false
    @Published var bubbles: [AgentBubble] = []
    @Published var finalOutput: String = ""
    @Published var actionLog: [ActionLogEntry] = []
    @Published var showAgentCompletionCheck = false

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
    // Paths the agent has inspected (read_file/get_file_info) this task — the read-before-destroy
    // guard refuses to delete/overwrite a path not in this set. Reset per task.
    private var seenPaths: Set<String> = []
    // True when the model narrated prose this turn — used to suppress the redundant deterministic
    // step bubble (the narration already describes the action).
    private var modelNarratedThisTurn = false
    // True when the harness loop is being re-entered after the user answered a
    // clarification/approval — so the first bubble reads "Resuming…" not "Starting up…"
    // (the model is still warm via keep_alive; it's continuing, not cold-starting).
    private var resumingAfterUserInput = false

    // When the hard safety gate intercepts a tool call before the user approved it,
    // we store it here. handleUserResponse executes or skips it before restarting the loop.
    private var pendingApprovalToolCall: OllamaRawToolCall? = nil
    private var pendingApprovalQuestion: String = ""   // the question shown; gives the reply interpreter context
    private var fileWriteSucceeded = false             // true once overwrite_file actually ran this task
    private var taskRequestedFileWrite = false         // true if THIS task's prompt asked to write/create a file

    // Set when a [NEEDS_APPROVAL] marker was approved — lets the next destructive executeTool
    // skip the hard gate (one-shot: cleared immediately after use).
    private var markerApprovedNextDestructive = false

    // Tracks the active completion-dismiss timer so a new task cancels the old one (B4).
    private var completionDismissTask: Task<Void, Never>? = nil

    // Failure tracking
    private var consecutiveFailures = 0

    // Bulk-op circumvention detection (§4.13)
    private var recentToolCalls: [(name: String, timestamp: Date)] = []

    private let agentSystemPrompt = """
You are the LocalNotch Agent — an autonomous agent running locally on the user's macOS device, inside the notch panel. You complete real file tasks by calling the file-system tools you are given. You run entirely on-device via Ollama; nothing the user says leaves their machine.

# Inviolable rules
- NEVER describe, list, or summarize file-system state you have not gotten from a tool. Until a tool tells you, you do not know what is there — call the tool, never guess or invent.
- ONLY act on paths that appeared in a tool result THIS task. Never invent or assume a filename (e.g. do not "read BidPilot.pdf" unless a tool actually returned that exact path). To work with a specific file, list_directory or search_files FIRST, then use an exact path from the result.
- NEVER fabricate a tool result. If a tool fails, relay its exact error, then retry, skip, or stop.
- Destructive operations (delete_file, overwrite_file) and bulk operations (>20 items) ALWAYS require approval — emit the approval marker and wait, even if the prompt seems to pre-authorize them.
- Deletion ALWAYS means move-to-Trash. You never permanently delete.
- You can pause to ask the user, but you cannot stop yourself — only the user can.

# How you work
1. Plan only if needed. If the task is one or two tool calls you could describe in one sentence (read a file, list a folder, rename one item), SKIP planning and just do it. Emit a short numbered plan (3–7 action-only lines, no predicted results) ONLY for multi-step, multi-file, or order-dependent tasks.
2. Execute one tool at a time. Say the action in ONE short sentence ("Listing ~/Desktop."), then call the tool, then read the result before the next step. Never write out what a tool would return — call it. Reason briefly before each call; do not over-deliberate, especially on simple tasks — decide the next tool and call it.
3. Ask when unsure. If the request is ambiguous, emit on ONE line: [NEEDS_CLARIFICATION] your question here — then wait. (e.g. `[NEEDS_CLARIFICATION] Which folder should I look in?`)
4. Ask before risk. Before any destructive or bulk action, emit on ONE line: [NEEDS_APPROVAL] one-sentence summary — then wait for yes/no. (e.g. `[NEEDS_APPROVAL] Move 12 files into ~/Desktop/Archive?`) An ambiguous reply means no.
5. Finish with a brief plain-prose summary (no markers). The tools already showed the user every file, path, count, and content — do NOT relist or restate any of it. State only the outcome.

# Output style (you render in a tiny notch panel; your tool calls are a live log)
Your prose is ONLY for brief explanation — it must not repeat what the tools displayed.
- Step sentence: ≤1 short sentence, present tense. ("Reading config.json.")
- Plan: ≤7 numbered lines, one action each, no predicted results.
- Final summary: ≤3 short sentences. Lead with the outcome and any number that matters. Do not recap each step or relist files the tools showed. If nothing changed, say so in one sentence.
- Do not preface with "Sure", "Of course", "Here is…", and do not explain that you are an AI. Lead with the answer, not the process.
- Prioritize accuracy over agreement: if the user's description of the files contradicts what a tool returns, surface the contradiction.
- When you report a count or total, recount and confirm the number equals your own breakdown (e.g. files + folders) before sending it.
- Process EVERY item, not a subset. When a search or listing returns N items and the task is to act on all/each/every one (move, read, summarize, etc.), handle all N — count them from the tool result, act on each, and before finishing verify your actions cover the full count (e.g. "search returned 4 → I moved 4 and read 4"). Never stop at 3 of 4 or silently drop one.
- When you read files, summarize what they contain in your own words — do not paste their full contents unless the user asks for the raw text.

# Scope discipline
- Do only what was asked. Do not create extra files, folders, READMEs, or notes the user didn't request; prefer moving/editing existing items.
- If the user is vague about quantity ("some", "a few"), sample at most 3–5 relevant items or ask — never process an entire large folder unless explicitly told to.
- Read access is unrestricted. Writes are limited to approved paths (~/Desktop, ~/Documents, ~/Downloads by default); a write outside them needs [NEEDS_APPROVAL] first.

# Tools
Nine file-system tools (full schemas via the tool API): list_directory, read_file, get_file_info, search_files (read-only); move_file, create_folder, copy_file (write); delete_file, overwrite_file (destructive — always need approval). You cannot use the network, a shell, other apps, or screenshots; if asked for something outside these tools, say so in one sentence and stop.
- To rank or filter files by date or size (newest, oldest, largest, "most recent N"), get the metadata in ONE call: list_directory already returns each entry's size and modified date, and search_files takes sort="modified"/"size" with an optional limit. Do NOT call get_file_info on each file in a loop to gather dates/sizes — that is slow. Reserve get_file_info for inspecting a single specific file.

# Examples
<example>
user: How many PDFs are in ~/Downloads?
assistant: Counting PDFs in ~/Downloads.   ›[calls search_files(query: "*.pdf", path: "~/Downloads")]
assistant: 12 PDFs.
</example>
<counterexample do_not_do_this>
assistant: I found these PDFs in your Downloads folder: invoice.pdf, label.pdf, report.pdf, … This appears to be a collection of documents. In summary, there are 12 PDF files located in ~/Downloads.
(WRONG: relists what the tool already showed, and is far too long.)
</counterexample>

# Failure handling
- One failure: note it briefly, then retry with different parameters, skip, or revise the plan.
- Three consecutive failures: stop and give a one- or two-sentence summary of what went wrong.

# Reminders (do not violate)
- delete_file and overwrite_file ALWAYS need [NEEDS_APPROVAL] first. No exceptions. Trash only; never permanent.
- Never fabricate results; never claim file state you didn't get from a tool.
- Keep prose minimal — the tools show the detail. Final summary ≤3 sentences, no relisting.
"""

    // MARK: — Mock mode (UI testing only — flip to false to use real Ollama agent)
    static let mockMode = false

    private init() {}

    // MARK: — Public control API

    func startTask(prompt: String) {
        guard state == .idle || state == .finished || state == .forceStopped || state == .welcome else { return }
        bubbles = []
        finalOutput = ""
        actionLog = []
        showAgentCompletionCheck = false
        forceStopped = false
        consecutiveFailures = 0
        recentToolCalls = []
        seenPaths = []                   // read-before-destroy is per-task
        fileWriteSucceeded = false       // tracks whether overwrite_file actually ran (per task)
        markerApprovedNextDestructive = false   // never let a prior task's approval leak into this one
        taskRequestedFileWrite = promptRequestsFileWrite(prompt)   // did THIS task ask to write a file?
        resumingAfterUserInput = false   // genuine new task → first bubble is "Starting up…"
        activeModel = AppSettings.shared.agentModel
        currentTaskIndex += 1
        let taskIdx = currentTaskIndex

        // System message only on first task; chained tasks reuse the same conversation.
        if messages.isEmpty {
            var systemContent = agentSystemPrompt
            if AppSettings.shared.agentAutoApprove {
                systemContent += "\n\nAUTO-APPROVE MODE IS ON: do not ask for approval and do not emit [NEEDS_APPROVAL]. Perform destructive and bulk actions directly. (Still inspect a file with read_file/get_file_info before deleting or overwriting it.)"
            }
            messages.append(["role": "system", "content": systemContent])
        }
        messages.append(["role": "user", "content": prompt])

        print("[Agent] Task start — model: \(activeModel)")
        print("[Agent] Prompt: \(prompt.prefix(120))")
        state = .running
        agentTask = Task { [weak self] in
            if Self.mockMode {
                await self?.runMockTask(prompt: prompt, taskIndex: taskIdx)
            } else {
                await self?.runHarnessLoop(taskIndex: taskIdx)
            }
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
        // Unblock the pause gate — withCheckedContinuation is not Task-cancellation-aware,
        // so cancelling agentTask alone leaves it suspended forever if stopped while paused.
        resumeContinuation?.resume(returning: nil)
        resumeContinuation = nil
        pendingApprovalToolCall = nil
        markerApprovedNextDestructive = false
        // If the last assistant message has unanswered tool_calls, balance with a cancel result
        // so any future continuation of this conversation isn't malformed.
        if let lastMsg = messages.last,
           (lastMsg["role"] as? String) == "assistant",
           let toolCalls = lastMsg["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            messages.append(["role": "tool", "content": "Cancelled by user."])
        }
        state = .forceStopped
        let toolMsg = lastExecutedTool.isEmpty ? "" : " Last action completed: \(lastExecutedTool)."
        addBubble(type: .error, text: "Stopped by user.\(toolMsg)", taskIndex: currentTaskIndex)
        scheduleCompletionCheckDismiss()
    }

    // Called when user sends a reply in State G (clarification) or H (approval).
    func handleUserResponse(_ text: String) {
        guard state == .clarifying || state == .approving else { return }
        let wasApproving = state == .approving
        state = .running
        finalOutput = ""   // clear the surfaced question now that the user has answered
        resumingAfterUserInput = true   // continuing after the user's reply → "Resuming…", not "Starting up…"
        let taskIdx = currentTaskIndex

        if let pending = pendingApprovalToolCall {
            // Gate-triggered approval: the assistant message with tool_calls is already in history
            // but no tool result was appended. We execute or skip the tool now, then restart the loop.
            // We do NOT add a user message — the next message must be a tool result to match the tool_call.
            pendingApprovalToolCall = nil
            agentTask = Task { [weak self] in
                guard let self else { return }
                let approved = await self.interpretApproval(text)
                if approved {
                    await self.executeApprovedTool(pending, taskIndex: taskIdx)
                } else {
                    self.messages.append(["role": "tool", "content": "Operation denied by user."])
                    self.addBubble(type: .error, text: "Operation denied.", taskIndex: taskIdx)
                }
                if !self.forceStopped && !Task.isCancelled {
                    await self.runHarnessLoop(taskIndex: taskIdx)
                }
            }
        } else {
            // Marker-triggered clarification/approval: append user reply and continue the loop.
            // If this was an approval and the user said yes, flag so the next destructive call skips
            // the redundant hard gate (interpreting the reply the same way the gate would).
            messages.append(["role": "user", "content": text])
            agentTask = Task { [weak self] in
                guard let self else { return }
                if wasApproving, await self.interpretApproval(text) {
                    self.markerApprovedNextDestructive = true
                }
                await self.runHarnessLoop(taskIndex: taskIdx)
            }
        }
    }

    // Surface an approval/clarification question in the OUTPUT area (finalOutput), not just a step
    // bubble. Bubbles are a glanceable action log; the output is where the agent talks TO the user —
    // a question that BLOCKS the task until they reply belongs there, prominently, with the expected
    // replies spelled out. (Users were missing the question because it only appeared as a bubble.)
    private func promptUser(_ question: String, approval: Bool) {
        pendingApprovalQuestion = question   // remembered so the reply interpreter has context
        let hint = approval ? "\n\n*Reply **yes** to proceed, or **no** to skip.*"
                            : "\n\n*Type your answer below.*"
        finalOutput = question + hint
    }

    private enum ApprovalDecision { case approve, deny, unclear }

    // Fast, deterministic keyword pass. Returns .unclear (rather than guessing) when the reply is
    // neither an obvious yes nor an obvious no — those go to the model interpreter below.
    private func keywordDecision(_ text: String) -> ApprovalDecision {
        let words = Set(text.lowercased().unicodeScalars.split {
            !CharacterSet.alphanumerics.contains($0)
        }.map(String.init))
        let approveWords: Set<String> = ["yes", "ok", "okay", "sure", "proceed", "approve", "approved",
                                         "confirm", "confirmed", "yeah", "yep", "yup", "yea", "continue",
                                         "ahead", "accept", "allow", "fine", "affirmative", "do"]
        let denyWords: Set<String> = ["no", "cancel", "deny", "stop", "nope", "nah", "don", "dont", "wait"]
        if !words.isDisjoint(with: denyWords) { return .deny }       // deny takes precedence ("no", "don't"…)
        if !words.isDisjoint(with: approveWords) { return .approve }
        return .unclear
    }

    // Interpret an approval reply. Keyword fast-path handles the obvious replies instantly; anything
    // it can't classify ("go for it", "sounds good", "eh leave it") is handed to the loaded model for
    // a quick yes/no read, so the user isn't forced to use a magic word. Falls back to deny only if
    // the model itself can't tell or is unreachable (ambiguous = no, the safe default for a write).
    private func interpretApproval(_ text: String) async -> Bool {
        switch keywordDecision(text) {
        case .approve: return true
        case .deny:    return false
        case .unclear:
            let verdict = await OllamaAPI.shared.interpretApprovalReply(
                text, question: pendingApprovalQuestion, model: activeModel, numCtx: contextLength)
            print("[Agent] approval reply '\(text.prefix(40))' unclear by keyword → model says \(verdict.map(String.init) ?? "nil")")
            return verdict ?? false
        }
    }

    func exitAgentMode() {
        resumeContinuation?.resume(returning: nil)
        resumeContinuation = nil
        completionDismissTask?.cancel()
        agentTask?.cancel()
        state = .idle
        bubbles = []
        finalOutput = ""
        actionLog = []
        showAgentCompletionCheck = false
        messages = []
        consecutiveFailures = 0
        currentTaskIndex = 0
        forceStopped = false
        recentToolCalls = []
        pendingApprovalToolCall = nil
        markerApprovedNextDestructive = false
    }

    func resetAgentConversation() {
        resumeContinuation?.resume(returning: nil)
        resumeContinuation = nil
        completionDismissTask?.cancel()
        agentTask?.cancel()
        state = .welcome
        bubbles = []
        finalOutput = ""
        actionLog = []
        showAgentCompletionCheck = false
        messages = []
        consecutiveFailures = 0
        currentTaskIndex = 0
        forceStopped = false
        recentToolCalls = []
        pendingApprovalToolCall = nil
        markerApprovedNextDestructive = false
    }

    private func scheduleCompletionCheckDismiss() {
        completionDismissTask?.cancel()
        showAgentCompletionCheck = true
        completionDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run { self?.showAgentCompletionCheck = false }
        }
    }

    // MARK: — Mock task (UI testing — remove when wiring real agent)

    private func runMockTask(prompt: String, taskIndex: Int) async {
        // Each step: bubble created first (shows "…"), then latency, then stream.
        // This matches runHarnessLoop so the UI is never blank between steps.

        func pauseGate() async -> Bool {
            while state == .paused {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return forceStopped || Task.isCancelled
        }

        func step(_ text: String, type: AgentBubble.BubbleType = .step,
                  latency: UInt64 = 700, charDelay: UInt64 = 38) async -> Bool {
            let id = addStreamingBubble(type: type, taskIndex: taskIndex)
            try? await Task.sleep(for: .milliseconds(latency))
            if await pauseGate() { return true }
            await mockStream(text, into: id, charDelay: charDelay)
            finalizeBubble(id: id, text: text, reasoning: nil)
            return forceStopped || Task.isCancelled
        }

        func tool(_ name: String, args: String, result: String, latency: UInt64 = 400) async -> Bool {
            try? await Task.sleep(for: .milliseconds(latency))
            if forceStopped || Task.isCancelled { return true }
            addBubble(type: .toolResult, text: result, taskIndex: taskIndex)
            actionLog.append(ActionLogEntry(timestamp: Date(), toolName: name,
                                            argsDescription: args, succeeded: true, note: result))
            return false
        }

        // --- Plan ---
        let planText = "1. Scan project structure.\n2. Read source files.\n3. Identify dependencies.\n4. Run tests.\n5. Patch failing cases.\n6. Verify build.\n7. Summarise changes."
        if await step(planText, type: .plan, latency: 900, charDelay: 32) { return }

        // --- Step 1: scan structure ---
        if await step("Scanning top-level project structure.", latency: 650) { return }
        let scanResult = "[DIR]  Sources/\n[DIR]  Tests/\n[DIR]  .build/\n[FILE] Package.swift\n[FILE] README.md"
        if await tool("list_directory", args: "path=.", result: scanResult) { return }

        // --- Step 2: read Package.swift ---
        if await step("Reading Package.swift to identify targets and dependencies.", latency: 750) { return }
        let pkgResult = "targets: [LocalNotch, LocalNotchTests]\ndependencies: [DynamicNotchKit 0.4.1, MarkdownUI 2.4.0]"
        if await tool("read_file", args: "path=Package.swift", result: pkgResult) { return }

        // --- Step 3: read source list ---
        if await step("Listing Swift source files in Sources/LocalNotch.", latency: 700) { return }
        let srcResult = "[FILE] AppDelegate.swift\n[FILE] ChatView.swift\n[FILE] Agent/AgentRunner.swift\n[FILE] Views/AgentModeView.swift\n[FILE] Views/AgentGlowOverlay.swift"
        if await tool("list_directory", args: "path=Sources/LocalNotch", result: srcResult) { return }

        // --- Step 4: inspect AgentRunner ---
        if await step("Inspecting AgentRunner.swift for state-machine transitions.", latency: 800) { return }
        let runnerSnippet = "enum AgentState { case idle, running, paused, finished, forceStopped, clarifying, approving, welcome }\n// 527 lines"
        if await tool("read_file", args: "path=Sources/LocalNotch/Agent/AgentRunner.swift", result: runnerSnippet) { return }

        // --- Step 5: read AgentState ---
        if await step("Reading AgentState.swift to inspect state definitions.", latency: 1100) { return }
        let stateResult = "enum AgentState {\n  case idle, running, paused, finished\n  case forceStopped, clarifying, approving, welcome\n}"
        if await tool("read_file", args: "path=Sources/LocalNotch/Agent/AgentState.swift", result: stateResult, latency: 1200) { return }

        // --- Step 6: diagnose ---
        if await step("Diagnosing pause gate logic in AgentRunner.", latency: 750) { return }
        let pauseSnippet = "func pause() {\n  guard state == .running else { return }\n  state = .paused\n}"
        if await tool("read_file", args: "path=Sources/LocalNotch/Agent/AgentRunner.swift", result: pauseSnippet) { return }

        // --- Step 7: patch ---
        if await step("Writing updated pause gate to AgentRunner.swift.", latency: 900) { return }
        let patchResult = "Written 312 bytes to Sources/LocalNotch/Agent/AgentRunner.swift"
        if await tool("overwrite_file", args: "path=Sources/LocalNotch/Agent/AgentRunner.swift", result: patchResult, latency: 500) { return }

        // --- Step 8: verify file info ---
        if await step("Verifying file was updated correctly.", latency: 1000) { return }
        let infoResult = "path: Sources/LocalNotch/Agent/AgentRunner.swift\ntype: NSFileTypeRegular\nsize: 24812 bytes\nmodified: May 22, 2026 at 10:14 AM"
        if await tool("get_file_info", args: "path=Sources/LocalNotch/Agent/AgentRunner.swift", result: infoResult, latency: 1100) { return }

        // --- Step 9: scan build output ---
        if await step("Listing build artifacts to confirm compilation succeeded.", latency: 900) { return }
        let buildResult = "[DIR]  debug/\n[DIR]  release/\n[FILE] LocalNotch  (4.2 MB)\n[FILE] LocalNotch.dSYM  (1.1 MB)"
        if await tool("list_directory", args: "path=.build/release", result: buildResult, latency: 1300) { return }

        // --- Done ---
        try? await Task.sleep(for: .milliseconds(700))
        if forceStopped || Task.isCancelled { return }

        finalOutput = "All 3 tests pass. Fixed pause() to handle .clarifying state. Release build clean. No other files modified."
        state = .finished
        scheduleCompletionCheckDismiss()
    }

    private func mockStream(_ text: String, into id: UUID, charDelay: UInt64) async {
        var current = ""
        for char in text {
            if forceStopped || Task.isCancelled { return }
            while state == .paused && !forceStopped && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if forceStopped || Task.isCancelled { return }
            current.append(char)
            updateBubble(id: id, text: current)
            try? await Task.sleep(nanoseconds: charDelay * 1_000_000)
        }
    }

    // MARK: — Harness loop

    private func runHarnessLoop(taskIndex: Int) async {
        // Resolve the WORKING context window once. This is min(model's trained max, agentContextCap)
        // and is the exact value sent to Ollama as num_ctx — so the harness's compaction threshold
        // and Ollama's real window agree. (Previously we used the model's full trained max here while
        // sending no num_ctx, so Ollama silently ran at 4 K and a big tool result blew the context.)
        let modelMax = await OllamaAPI.shared.contextLengthFor(model: activeModel)
        contextLength = OllamaAPI.shared.agentNumCtx(forModelMax: modelMax)
        print("[Agent] context window: \(contextLength) tokens (model max: \(modelMax.map(String.init) ?? "unknown"))")

        // First model response of a task triggers a (possibly cold) model load, so its
        // placeholder reads "Starting up…"; later responses are warm → "Thinking…".
        var isFirstResponse = true

        // Hard cap on model turns per loop entry — bounds a runaway loop (tools succeeding but
        // the model never converging). File tasks essentially never need this many turns.
        let maxIterations = 40
        var iterations = 0

        // Narrate-without-finishing guard: track whether any tool ran, and how many times we've
        // nudged the model to actually call a tool / report results instead of just narrating.
        var toolUsedThisTask = false
        var actionNudges = 0
        var fileWriteNudges = 0      // separate budget for the "task wanted a file, none written" nudge
        var autoApprovedMarkers = 0  // bounds an auto-mode model that keeps emitting [NEEDS_APPROVAL]

        while !Task.isCancelled && !forceStopped {
            // Exit if waiting for user input from a gate or marker.
            if state == .approving || state == .clarifying { return }

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

            iterations += 1
            if iterations > maxIterations {
                addBubble(type: .error, text: "Stopped after \(maxIterations) steps without finishing — try a more specific task.", taskIndex: taskIndex)
                finalOutput = "Stopped after \(maxIterations) steps without finishing."
                state = .finished
                scheduleCompletionCheckDismiss()
                return
            }

            // Context budget check with compaction (§4.21).
            if estimateTokens() > compactionThreshold {
                print("[Agent] Context at \(Int(Double(estimateTokens())/Double(max(contextLength,1))*100))% — compacting")
                if compactContext() {
                    print("[Agent] Compaction succeeded — now at \(Int(Double(estimateTokens())/Double(max(contextLength,1))*100))%")
                    addBubble(type: .step, text: "Context compacted — continuing task.", taskIndex: taskIndex)
                } else {
                    addBubble(type: .error,
                              text: "Stopped — context limit reached for \(activeModel). The task was too long for this model's context window.",
                              taskIndex: taskIndex)
                    state = .finished
                    return
                }
            }

            // Stream the next model response.
            var streamedText = ""
            var pendingThinking = ""
            var toolCalls: [OllamaRawToolCall] = []
            var markerDetected: String? = nil

            let placeholder: String
            if isFirstResponse {
                // First response of this loop entry: "Resuming…" after a user reply (model is
                // warm), "Starting up…" for a genuine new task (model may be cold-loading).
                placeholder = resumingAfterUserInput ? "Resuming…" : "Starting up…"
                resumingAfterUserInput = false
            } else {
                placeholder = "Thinking…"
            }
            let bubble = addStreamingBubble(type: .step, placeholder: placeholder, taskIndex: taskIndex)
            isFirstResponse = false

            let stream = OllamaAPI.shared.agentChat(messages: messages, model: activeModel, numCtx: contextLength)

            do {
                for try await event in stream {
                    if forceStopped || Task.isCancelled { break }

                    switch event {
                    case .thinking(let t):
                        pendingThinking += t

                    case .token(let token):
                        // Pause gate mid-stream — honors pause without waiting for the full response.
                        while state == .paused && !forceStopped && !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        if forceStopped || Task.isCancelled { break }

                        streamedText += token
                        updateBubble(id: bubble, text: streamedText)

                    case .toolCalls(let calls):
                        toolCalls = calls
                    }
                }
            } catch {
                if !forceStopped {
                    print("[Agent] Stream error: \(error)")
                    addBubble(type: .error, text: "Connection error: \(error.localizedDescription)", taskIndex: taskIndex)
                    state = .finished
                    return
                }
            }

            if forceStopped || Task.isCancelled { break }

            print("[Agent] Stream — \(streamedText.count) chars, \(toolCalls.count) tool calls, ~\(estimateTokens())/\(contextLength) tokens (\(Int(Double(estimateTokens())/Double(max(contextLength,1))*100))%)")

            // Detect a clarification/approval marker in the FULL streamed text. The question
            // or summary may sit on the line(s) after the marker, so take everything following
            // the marker token as the body (not just the same-line remainder).
            if let r = streamedText.range(of: "[NEEDS_CLARIFICATION]") {
                markerDetected = "clarification:" + streamedText[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let r = streamedText.range(of: "[NEEDS_APPROVAL]") {
                markerDetected = "approval:" + streamedText[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Finalize the streaming bubble — with two exceptions that keep BUBBLES for the
            // work and route explanatory prose to PLAIN TEXT:
            //  • Terminal turn (no tool calls, no marker): the prose IS the final summary, so
            //    discard the bubble — it renders once as the plain-text finalOutput below.
            //  • Empty prose (model emitted only tool calls): discard the empty bubble; the
            //    per-tool step bubbles carry the progress instead.
            if markerDetected == nil && toolCalls.isEmpty {
                removeBubble(id: bubble)
            } else if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                removeBubble(id: bubble)
            } else {
                finalizeBubble(id: bubble, text: streamedText, reasoning: pendingThinking.isEmpty ? nil : pendingThinking)
            }

            // One tool per turn: if the model emitted several tool calls, keep only the FIRST.
            // This keeps the loop in lock-step and GUARANTEES the tool_calls↔tool_result pairing
            // can't go unbalanced when a gate (approval/bulk/whitelist) fires mid-array — the
            // assistant message and the executed set both contain exactly one call. qwen3 is told
            // to emit one tool per turn anyway; it re-decides the next action after seeing the result.
            if toolCalls.count > 1 { toolCalls = Array(toolCalls.prefix(1)) }

            // If the model emitted BOTH a tool call and a marker ([NEEDS_APPROVAL]/[NEEDS_CLARIFICATION])
            // in one turn, drop the tool call. The marker path pauses (or auto-answers with a user
            // message) WITHOUT appending a tool result, so a co-emitted tool_call would be left
            // unanswered — an orphaned tool_calls→user-message pairing that Ollama's chat template can
            // reject. The marker takes precedence; the model re-issues the tool after the reply.
            if markerDetected != nil { toolCalls = [] }

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
                    let question = q.isEmpty ? "I need a bit more detail to continue." : q
                    updateBubble(id: bubble, text: question)
                    promptUser(question, approval: false)   // also show it in the output area
                    state = .clarifying
                    return
                } else if marker.hasPrefix("approval:") {
                    let q = String(marker.dropFirst("approval:".count))
                    let question = q.isEmpty ? "I need your approval to continue." : q
                    if AppSettings.shared.agentAutoApprove {
                        // Auto mode: don't pause — record the approval and tell the model to proceed.
                        // Bounded so a model that keeps emitting markers (ignoring the auto-mode prompt)
                        // can't burn all 40 iterations re-asking; after a few, tell it firmly to stop.
                        markerApprovedNextDestructive = true
                        autoApprovedMarkers += 1
                        addBubble(type: .step, text: "Auto-approved: \(question)", taskIndex: taskIndex)
                        let reply = autoApprovedMarkers <= 3
                            ? "Yes, proceed."
                            : "Yes — and auto-approve mode is ON, so stop asking for approval entirely. Perform the remaining actions directly, then give your final summary."
                        messages.append(["role": "user", "content": reply])
                        continue
                    }
                    updateBubble(id: bubble, text: question)
                    promptUser(question, approval: true)    // also show it in the output area
                    state = .approving
                    return
                }
            }

            // Handle tool calls.
            if !toolCalls.isEmpty {
                toolUsedThisTask = true
                // If the model narrated this turn (non-empty prose), that bubble already describes
                // the action — suppress the redundant deterministic step bubble. If it emitted ONLY
                // a tool call (no prose), keep the step bubble so the action is still shown.
                modelNarratedThisTurn = !streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                for tc in toolCalls {
                    if forceStopped || state == .approving || state == .clarifying { break }
                    await executeTool(tc, taskIndex: taskIndex)
                }
                // If a gate fired or the task finished inside executeTool, exit the loop cleanly.
                if state == .approving || state == .clarifying || state == .finished { return }
                continue // Next harness loop iteration.
            }

            // No tool calls and no markers. Guard against "narrate-without-finishing": qwen3 sometimes
            // ends a turn with a bare action narration ("Reading X.") — or no tool at all — instead of
            // completing the action or reporting results, leaving the task useless (exactly the
            // "Reading BidPilot.pdf." dead-end). Nudge it to either CALL the tool or give a real final
            // summary. Capped to avoid loops; after that, accept whatever it produced.
            if (!toolUsedThisTask || looksLikeUnfinishedAction(streamedText)) && actionNudges < 2 {
                actionNudges += 1
                messages.append(["role": "user", "content": "You stopped after describing an action without completing it or reporting results. If the task still needs a tool, CALL it now — do not just say you will. Otherwise give your FINAL answer: in 1–3 sentences, state what you found or did (e.g. the files, and what's in the one you read)."])
                continue
            }

            // The task asked for a file to be written but overwrite_file never succeeded — the model
            // likely PRINTED the content instead of saving it (it conflates producing text with writing
            // a file). Push it to actually call overwrite_file. Uses its OWN one-shot counter so it
            // can't be starved by the action nudges above, and is gated on task INTENT so a read-only
            // task is never pushed to create a file.
            if taskRequestedFileWrite && !fileWriteSucceeded && fileWriteNudges < 1 {
                fileWriteNudges += 1
                messages.append(["role": "user", "content": "This task asked you to write/create a file, but you haven't called overwrite_file yet — printing the content in your reply does NOT save it to disk. Call overwrite_file now with the exact path and the full content, then confirm in one sentence."])
                continue
            }

            // Model is done.
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
        // Auto-approve mode bypasses the user-facing approval PROMPTS (destructive / bulk / outside-
        // allowed-paths). Read-before-destroy is intentionally NOT bypassed — it auto-recovers (the
        // model inspects then retries) and is the last line against destroying a hallucinated path.
        let autoApprove = AppSettings.shared.agentAutoApprove

        guard let riskLevel = ToolRegistry.riskLevel(for: name) else {
            let result = ToolResult.fail("Unknown tool: \(name)")
            appendToolResult(name: name, args: args, result: result, taskIndex: taskIndex)
            return
        }

        // Hard safety rails (§4.3).
        if riskLevel == .destructive {
            let targetPath = args["path"] as? String ?? ""
            let target = normalizedPath(targetPath)
            // P1 — read-before-destroy: the agent MUST have inspected an EXISTING target this task
            // (get_file_info or read_file) before deleting/overwriting it. Deterministic guard, not
            // a prompt request — a 14B will skip a polite instruction. Skipped when the target does
            // NOT exist, because overwrite_file on a new path is a create (nothing to lose, and an
            // absent path can't be inspected — that would deadlock). Marker approval is preserved
            // across the inspect detour (it is not consumed here).
            if !targetPath.isEmpty,
               FileManager.default.fileExists(atPath: target),
               !seenPaths.contains(target) {
                let verb = name == "delete_file" ? "deleting" : "overwriting"
                let result = ToolResult.fail("Inspect \(targetPath) before \(verb) it — call get_file_info or read_file on it first, then retry.")
                appendToolResult(name: name, args: args, result: result, taskIndex: taskIndex)
                return
            }
            if markerApprovedNextDestructive || autoApprove {
                // Pre-approved via marker, or auto-approve is on — consume the flag and execute.
                markerApprovedNextDestructive = false
            } else {
                // Not pre-approved via marker — gate here as a fallback. P2 (look-before-destroy):
                // show the user exactly what they're about to lose (size + first line) so a wrong
                // target is caught before it's trashed/overwritten.
                pendingApprovalToolCall = tc
                let detail = fileSummary(target).map { " — \($0)" } ?? ""
                let action = name == "delete_file" ? "Move to Trash" : "Overwrite"
                let question = "\(action): \(targetPath)\(detail)?"
                addBubble(type: .approval, text: question, taskIndex: taskIndex)
                promptUser(question, approval: true)
                state = .approving
                return
            }
        }

        // Bulk op detection (§4.13): count same-tool calls within 30s.
        let now = Date()
        recentToolCalls = recentToolCalls.filter { now.timeIntervalSince($0.timestamp) < 30 }
        recentToolCalls.append((name: name, timestamp: now))
        let sameToolCount = recentToolCalls.filter { $0.name == name }.count
        if sameToolCount > 20 && riskLevel == .write && !autoApprove {
            pendingApprovalToolCall = tc
            let question = "Bulk operation detected: \(sameToolCount) \(name) calls in 30s. Proceed?"
            addBubble(type: .approval, text: question, taskIndex: taskIndex)
            promptUser(question, approval: true)
            state = .approving
            return
        }

        // Path whitelist check for writes (§4.11).
        // Normalizes `..` and symlinks so /Desktop/../../../etc/passwd can't bypass the prefix check.
        if riskLevel == .write {
            let targetPath = (args["to"] as? String ?? args["path"] as? String ?? "")
            let candidate = normalizedPath(targetPath)
            let allowed = AppSettings.shared.agentAllowedPaths.map { normalizedPath($0) }
            let isAllowed = allowed.contains { candidate == $0 || candidate.hasPrefix($0 + "/") }
            if !isAllowed && !targetPath.isEmpty && !autoApprove {
                pendingApprovalToolCall = tc
                let question = "Write outside allowed paths: \(targetPath). Proceed?"
                addBubble(type: .approval, text: question, taskIndex: taskIndex)
                promptUser(question, approval: true)
                state = .approving
                return
            }
        }

        lastExecutedTool = name
        // Concise progress bubble BEFORE the tool runs — but only if the model didn't already
        // narrate this turn (otherwise it duplicates the narration, e.g. "Listing ~/Downloads."
        // + "Listing ~/Downloads").
        if !modelNarratedThisTurn {
            addBubble(type: .step, text: describeStep(name: name, args: args), taskIndex: taskIndex)
        }
        let result: ToolResult
        do {
            result = try await ToolRegistry.execute(toolName: name, arguments: args)
        } catch {
            result = .fail(error.localizedDescription)
        }

        // Record inspected files so the read-before-destroy guard knows the agent looked first.
        if result.success, (name == "read_file" || name == "get_file_info"), let p = args["path"] as? String {
            seenPaths.insert(normalizedPath(p))
        }

        appendToolResult(name: name, args: args, result: result, taskIndex: taskIndex)
    }

    // Hard ceiling on any single tool result entering the model's context. Set ABOVE read_file's
    // maxReturnBytes (16 KB) by enough to cover the trailing paging note + the asString "[truncated]"
    // marker, so a full read_file/PDF page passes through this guard UNCHANGED — otherwise we'd chop
    // exactly the "read more with offset=N" hint the model needs to page. It still backstops genuinely
    // oversized results from other tools (huge directory listings, broad searches), and stays small
    // enough (~5.5 K tokens) that the keep=1 compaction floor fits comfortably under the prompt budget.
    private static let maxToolResultChars = 16_512
    private func cappedToolResult(_ s: String) -> String {
        guard s.count > Self.maxToolResultChars else { return s }
        return String(s.prefix(Self.maxToolResultChars)) +
            "\n[output truncated to fit the context window — narrow your query (a more specific path or pattern) or use offset/limit to page through]"
    }

    private func appendToolResult(name: String, args: [String: Any], result: ToolResult, taskIndex: Int) {
        print("[Agent] \(name)(\(describeArgs(args))) → \(result.success ? "✓" : "✗") \(result.asString.prefix(120))")
        // A real file write happened — tracked here (the shared sink for BOTH executeTool and the
        // user-approved executeApprovedTool path) so the "claimed a write that never happened" guard
        // doesn't false-fire after a normally-approved overwrite.
        if result.success, name == "overwrite_file" { fileWriteSucceeded = true }
        // Always balance the assistant tool_call with a tool result message before any early return.
        messages.append(["role": "tool", "content": cappedToolResult(result.asString)])

        if result.success {
            consecutiveFailures = 0
            // No raw-output bubble: the step bubble already described the action, and the
            // full result is preserved in the Actions log below + the model's context above.
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

        if actionLog.count >= 500 { actionLog.removeFirst() }
        actionLog.append(ActionLogEntry(
            timestamp: Date(),
            toolName: name,
            argsDescription: describeArgs(args),
            succeeded: result.success,
            note: result.error ?? result.output?.prefix(120).description ?? ""
        ))
    }

    // Execute a tool that was previously gated and has now been approved by the user.
    // Skips all safety gates — they already fired and the user said yes.
    private func executeApprovedTool(_ tc: OllamaRawToolCall, taskIndex: Int) async {
        let name = tc.function.name
        let args = tc.function.arguments.dict
        lastExecutedTool = name
        addBubble(type: .step, text: describeStep(name: name, args: args), taskIndex: taskIndex)
        let result: ToolResult
        do {
            result = try await ToolRegistry.execute(toolName: name, arguments: args)
        } catch {
            result = .fail(error.localizedDescription)
        }
        appendToolResult(name: name, args: args, result: result, taskIndex: taskIndex)
    }

    // MARK: — Context management

    // Tool schemas are serialized once; they're sent in the request's "tools" field on EVERY call
    // (not inside `messages`), so they must be counted against the window or we systematically
    // undercount the real prefill and silently overflow num_ctx. ~3 chars/token, computed once.
    private static let toolSchemaTokens: Int = {
        guard let data = try? JSONSerialization.data(withJSONObject: ToolRegistry.toolDefinitions) else { return 1200 }
        return data.count / 3
    }()

    // Fraction of the window the PROMPT may occupy before we compact. The remainder (~25%) is
    // reserved for the model's generation (think:true traces + the reply), which also lives inside
    // num_ctx — without this reserve a near-full prompt leaves no room to answer.
    private static let promptBudgetRatio = 0.75
    private var compactionThreshold: Int { Int(Double(contextLength) * Self.promptBudgetRatio) }

    private func estimateTokens() -> Int {
        let messageTokens = messages.reduce(0) { sum, m in
            var chars = (m["content"] as? String)?.count ?? 0
            // Tool call JSON in assistant messages also consumes tokens.
            if let toolCalls = m["tool_calls"],
               let data = try? JSONSerialization.data(withJSONObject: toolCalls) {
                chars += data.count
            }
            return sum + chars
        } / 3
        // + tool schemas (sent every request) + a small per-message margin for chat-template/role markers.
        return messageTokens + Self.toolSchemaTokens + messages.count * 4
    }

    // Compact context by replacing old message content with a stub. Tries progressively harder:
    // keep the last 6 tool results, then 2, then 1 — and if even that overflows, an aggressive pass
    // that also stubs old ASSISTANT prose and USER messages. Tool results are not the only thing that
    // grows: assistant narration + tool-call JSON accumulate every turn and are counted by
    // estimateTokens, so on a long task tool-result stubbing alone is not enough. The aggressive pass
    // bounds the floor to (system + tool schemas + the latest turn), which always fits — so a long
    // task can no longer dead-end with "context limit reached".
    @discardableResult
    private func compactContext() -> Bool {
        if compactKeepingLast(6) { return true }
        if compactKeepingLast(2) { return true }
        if compactKeepingLast(1) { return true }
        return compactAggressively()
    }

    // Stub every tool result except the most recent `keep`. Returns true once usage is under budget.
    private func compactKeepingLast(_ keep: Int) -> Bool {
        var toolIndices: [Int] = []
        for (i, msg) in messages.enumerated() {
            if (msg["role"] as? String) == "tool" { toolIndices.append(i) }
        }
        for idx in toolIndices.dropLast(keep) {
            if (messages[idx]["content"] as? String) != "[compacted]" {
                messages[idx]["content"] = "[compacted]"
            }
        }
        return estimateTokens() < compactionThreshold
    }

    // Last-resort compaction: stub the prose `content` of every message EXCEPT the system prompt,
    // the original user request, the most recent assistant turn, and the most recent tool result.
    // tool_calls dictionaries are left intact so the assistant↔tool pairing invariant still holds —
    // only the human-readable `content` is replaced. If stubbing everything else still isn't enough
    // (a small-context model whose budget can't hold one full tool result), the preserved tool result
    // is itself trimmed to the remaining budget. This guarantees we fit on any window large enough to
    // hold the system prompt + tool schemas at all; a genuinely tiny model (where those alone exceed
    // the budget) can still dead-end, which is an inherent limit, not a bug.
    private func compactAggressively() -> Bool {
        let lastAssistant = messages.lastIndex { ($0["role"] as? String) == "assistant" }
        let lastTool = messages.lastIndex { ($0["role"] as? String) == "tool" }
        let firstUser = messages.firstIndex { ($0["role"] as? String) == "user" }
        for i in messages.indices {
            let role = messages[i]["role"] as? String
            if role == "system" || i == lastAssistant || i == lastTool || i == firstUser { continue }
            if (messages[i]["content"] as? String) != "[compacted]" {
                messages[i]["content"] = "[compacted]"
            }
            // Old assistant tool-call arguments are also counted by estimateTokens and can be large
            // (e.g. an overwrite_file with big content). Shrink them to a stub while keeping the call
            // present with its name, so the assistant↔tool pairing/structure stays valid.
            if role == "assistant", let calls = messages[i]["tool_calls"] as? [[String: Any]] {
                messages[i]["tool_calls"] = calls.map { call in
                    let name = (call["function"] as? [String: Any])?["name"] as? String ?? "tool"
                    return ["function": ["name": name, "arguments": ["_": "compacted"]] as [String: Any]]
                }
            }
        }
        if estimateTokens() < compactionThreshold { return true }

        // Still over budget — the one preserved tool result is now the dominant term. Measure the
        // floor with it stubbed, then keep only as much of it as the remaining budget allows. Sizes
        // off the actual threshold, so this works regardless of the model's context window.
        if let lt = lastTool, let content = messages[lt]["content"] as? String, !content.isEmpty {
            let full = content
            messages[lt]["content"] = ""
            let floorTokens = estimateTokens()                 // everything except this result
            let budgetChars = (compactionThreshold - floorTokens - 24) * 3   // ~3 chars/token, small safety
            if budgetChars >= full.count {
                messages[lt]["content"] = full                 // it actually fits; keep it whole
            } else if budgetChars < 200 {
                messages[lt]["content"] = "[result omitted — exceeds the remaining context budget; narrow the request]"
            } else {
                messages[lt]["content"] = String(full.prefix(budgetChars)) + "\n[result truncated to fit the remaining context]"
            }
        }
        return estimateTokens() < compactionThreshold
    }

    // MARK: — Path helpers

    // True when a terminal response is a bare action narration ("Reading X.", "Listing Y") rather
    // than a real result — the model said it would do something but emitted no tool call. Used to
    // nudge it to actually finish instead of treating the narration as the final answer.
    private func looksLikeUnfinishedAction(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 80 else { return false }
        let verbs: Set<String> = ["reading", "listing", "searching", "moving", "copying",
                                   "checking", "writing", "creating", "deleting", "opening", "finding"]
        let firstWord = t.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return verbs.contains(firstWord)
    }

    // Does THIS task's prompt actually ask the agent to write/create/save a FILE (not just move files
    // or make a folder)? Computed once per task. Tying the unwritten-file guard to task INTENT — rather
    // than scanning the model's answer for claim words — means a read-only task can never be pushed to
    // create a file (the old keyword heuristic both false-fired on read summaries and missed real
    // claims). Requires a write verb AND either a concrete file extension or an explicit "a file" phrase.
    private func promptRequestsFileWrite(_ prompt: String) -> Bool {
        let p = prompt.lowercased()
        let writeVerbs = ["write", "create", "save", "generate", "make"]
        guard writeVerbs.contains(where: { p.contains($0) }) else { return false }
        let exts = [".md", ".txt", ".json", ".csv", ".swift", ".py", ".js", ".html", ".yaml", ".yml", ".xml", ".rtf"]
        let filePhrases = ["a file", "the file", "file named", "file called", "into a file", "to a file",
                           "an index", "a summary file", "a report file", "a markdown", "index.md", "readme"]
        return exts.contains(where: { p.contains($0) }) || filePhrases.contains(where: { p.contains($0) })
    }

    // Expands ~ and collapses .. to prevent path-traversal bypasses.
    private func normalizedPath(_ raw: String) -> String {
        let expanded = NSString(string: raw).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    }

    // Short human description of a target for the look-before-destroy approval prompt:
    // "1.2 KB, starts: "Q2 budget…"". Returns nil if the path doesn't exist.
    private func fileSummary(_ path: String) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return "folder" }
        let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        if let data = fm.contents(atPath: path),
           let text = String(data: data.prefix(200), encoding: .utf8),
           var first = text.split(whereSeparator: \.isNewline).first.map(String.init) {
            first = first.trimmingCharacters(in: .whitespaces)
            if first.count > 50 { first = String(first.prefix(50)) + "…" }
            if !first.isEmpty { return "\(sizeStr), starts: \"\(first)\"" }
        }
        return sizeStr
    }

    // MARK: — Bubble helpers

    @discardableResult
    private func addBubble(type: AgentBubble.BubbleType, text: String, taskIndex: Int) -> UUID {
        if bubbles.count >= 500 { bubbles.removeFirst() }
        let b = AgentBubble(type: type, text: text, taskIndex: taskIndex)
        bubbles.append(b)
        print("[Bubble] + \(type) \"\(text.prefix(40))\" → count=\(bubbles.count)")
        return b.id
    }

    @discardableResult
    private func addStreamingBubble(type: AgentBubble.BubbleType, placeholder: String = "Thinking…", taskIndex: Int) -> UUID {
        var b = AgentBubble(type: type, text: "", taskIndex: taskIndex)
        b.isStreaming = true
        b.placeholder = placeholder
        bubbles.append(b)
        print("[Bubble] + streaming(\(placeholder)) → count=\(bubbles.count)")
        return b.id
    }

    private func removeBubble(id: UUID) {
        let before = bubbles.count
        bubbles.removeAll { $0.id == id }
        print("[Bubble] - removed \(before - bubbles.count) → count=\(bubbles.count)")
    }

    // Concise, human-readable description of a tool call, shown as a step bubble
    // BEFORE the tool runs (so the chat reads as a progress log, not a raw dump).
    private func describeStep(name: String, args: [String: Any]) -> String {
        func leaf(_ p: String?) -> String {
            guard let p, !p.isEmpty else { return "" }
            return (NSString(string: p).expandingTildeInPath as NSString).lastPathComponent
        }
        func short(_ p: String?) -> String {
            guard let p, !p.isEmpty else { return "" }
            return NSString(string: p).expandingTildeInPath
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        let path  = args["path"] as? String
        let from  = args["from"] as? String
        let to    = args["to"] as? String
        let query = args["query"] as? String
        switch name {
        case "list_directory": return "Listing \(short(path))"
        case "read_file":      return "Reading \(leaf(path))"
        case "get_file_info":  return "Checking \(leaf(path))"
        case "search_files":   return "Searching for “\(query ?? "")”" + (path.map { " in \(short($0))" } ?? "")
        case "move_file":      return "Moving \(leaf(from)) → \(short(to))"
        case "copy_file":      return "Copying \(leaf(from)) → \(short(to))"
        case "create_folder":  return "Creating folder \(short(path))"
        case "delete_file":    return "Deleting \(leaf(path))"
        case "overwrite_file": return "Writing \(leaf(path))"
        default:               return "\(name)(\(describeArgs(args)))"
        }
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
        print("[Bubble] finalize \"\(text.prefix(40))\" (kept) → count=\(bubbles.count)")
    }

    private func describeArgs(_ args: [String: Any]) -> String {
        args.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }
}
