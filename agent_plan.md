# LocalNotch Agent Mode — Implementation Plan

## Status

**EXECUTION-READY.** All decisions are final. No `TBD` remains. This file is now the implementation spec.

Last updated: 2026-05-14

---

## Table of Contents

- [1. Concept](#1-concept)
- [2. Architecture](#2-architecture)
  - [2.1 Model separation](#21-model-separation)
  - [2.2 Agent harness loop](#22-agent-harness-loop)
  - [2.3 Tool system](#23-tool-system)
  - [2.4 Agent system prompt](#24-agent-system-prompt)
- [3. UI / UX Specification](#3-ui--ux-specification)
  - [3.1 Agent button (entry point)](#31-agent-button-entry-point)
  - [3.2 The agent orb](#32-the-agent-orb)
  - [3.3 State diagram (A–H)](#33-state-diagram)
  - [3.4 Auto-pause states (agent-initiated)](#34-auto-pause-states-agent-initiated)
  - [3.5 Agent chat history panel](#35-agent-chat-history-panel)
  - [3.6 Screen-edge glow effect](#36-screen-edge-glow-effect)
  - [3.7 Visual styling rules](#37-visual-styling-rules)
- [4. Behavior Rules](#4-behavior-rules)
  - [4.1 Agent autonomy boundaries](#41-what-the-agent-can-and-cannot-do-autonomously)
  - [4.2 User capabilities](#42-what-the-user-can-do)
  - [4.3 Hard-coded safety rails](#43-hard-coded-safety-rails-always-require-approval)
  - [4.4 Error handling](#44-error-handling)
  - [4.5 Multi-task chaining](#45-multi-task-chaining-within-a-session)
  - [4.6 Notch collapse / background](#46-notch-collapse--background-behavior)
  - [4.7 Quitting the app](#47-quitting-the-app)
  - [4.8 Force-stop semantics](#48-force-stop-semantics-in-flight-tool-calls)
  - [4.9 Auto-pause compact notch indicator](#49-auto-pause-compact-notch-indicator)
  - [4.10 Read and listing size limits](#410-read-and-listing-size-limits)
  - [4.11 Allowed paths model](#411-allowed-paths-model)
  - [4.12 Chained-task orb behavior](#412-new-task-chaining-orb-behavior)
  - [4.13 Bulk operation approval semantics](#413-bulk-operation-approval-semantics)
  - [4.14 Reasoning trace toggle](#414-reasoning-trace-toggle-settings)
  - [4.15 Idle-agent-mode compact indicator](#415-agent-active-indicator-in-compact-notch-idle-agent-mode)
  - [4.16 Hidden files](#416-hidden-files)
  - [4.17 Mid-task model swap](#417-agent-model-removed-from-settings-mid-task)
  - [4.18 Concurrency](#418-concurrency)
  - [4.19 Streaming and marker detection](#419-streaming-and-marker-detection)
  - [4.20 Ollama version + tool-calling gate](#420-ollama-version-and-tool-calling-gate)
  - [4.21 Context window management](#421-context-window-management)
  - [4.22 Recommended agent model](#422-recommended-agent-model-onboarding-default)
  - [4.23 Quit during running task](#423-app-quit-during-a-running-task)
  - [4.24 Menu bar icon variants](#424-menu-bar-icon-during-agent-activity)
  - [4.25 Action log](#425-in-session-action-log)
- [5. Implementation Phases](#5-implementation-phases)
- [6. v1 Tool Scope](#6-v1-tool-scope)
- [7. Out of Scope](#7-out-of-scope-explicitly-not-in-v1)
- [8. Risks & Accepted Limitations](#8-risks--accepted-limitations)
- [9. File Inventory](#9-file-inventory)
- [10. Decision Log](#10-decision-log)

---

## 1. Concept

Agent Mode is an opt-in feature that lets the user delegate real tasks on their Mac to a local reasoning LLM. Instead of just answering questions, the model plans and executes multi-step actions on the device — moving files, organizing folders, etc.

The interaction stays ambient: in the notch, no separate window. The agent's plan and progress are surfaced inside the notch panel as it runs.

### Why this exists

LocalNotch today answers questions, sees the screen, and optionally searches the web. Agent Mode shifts the product category from "AI assistant in your notch" to "AI agent on your Mac." It is the headline upgrade that takes the app out of beta.

### Why it's opt-in

- Requires a separate, heavier reasoning model — the existing notch model is too lightweight for planning
- Targets users with 16GB+ RAM (32GB+ ideal)
- Touches the file system — non-trivial risk surface
- Users who just want chat should not see agent UI in their notch

---

## 2. Architecture

### 2.1 Model separation

Two distinct models, each with its own role and its own selector in Settings:

| Model | Role | Type | Required? |
|---|---|---|---|
| **Notch model** | Conversational chat, vision queries, web search classifier | Fast, non-thinking (e.g. Gemma 4) | Yes — already exists |
| **Agent model** | Plans and executes multi-step tasks | Reasoning / thinking (e.g. QwQ, DeepSeek-R1, R1 distills) | No — agent mode is disabled if not configured |

**Why separate models:** Running a thinking model for "what's 12 × 14" is wasteful and slow. Running a small non-thinking model for a multi-step file operation produces unreliable plans. Each role gets the right tool.

**Settings UI:** A new "Agent" section in Settings, parallel to "Models" and "Web Search." If no agent model is selected, the agent button does not appear in the notch.

### 2.2 Agent harness loop

The agent operates in this loop:

1. User triggers agent mode and provides a task in natural language
2. Model generates a **plan** — a sequence of intended steps
3. Plan is displayed to the user as the first thinking bubble
4. Model begins executing tools one at a time
5. Each tool call returns a structured observation back to the model
6. Model decides the next step: continue, revise, pause to ask the user, or finish
7. Loop ends when the model declares the task complete OR the user force-stops

### 2.3 Tool system

Tools are explicit, typed Swift functions the model can call:
- Each tool has a name, description, and JSON parameter schema
- Tools are passed to the model as Ollama tool definitions
- Each tool returns a structured result (success / error + payload)
- Each tool has a risk classification: `readonly` / `write` / `destructive`

**v1 tool scope:** see §6 below.

### 2.4 Agent system prompt

The system prompt is what turns a generic reasoning model into "the LocalNotch agent." It is **prepended to every agent task** (separate from the notch model's normal chat system prompt, which the user can customize in Settings — the agent system prompt is NOT user-editable in v1).

Architecture follows patterns from Claude Code's published / leaked harness and OpenAI's Codex prompting guide:

1. **Identity and safety at the top** — establishes who the model is and the inviolable rules
2. **Core workflow in the middle** — the loop, planning expectations, communication style
3. **Tool definitions next** — full schema for each of the 9 tools, passed via Ollama's tool-calling API (not embedded in the prompt text where possible, to save tokens)
4. **Reminders at the bottom** — critical safety rules restated to exploit recency bias

**Full v1 agent system prompt (locked):**

```
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
   - Read the result. If it failed, decide whether to retry, skip, or abort the plan.
3. ASK when uncertain. If the user's prompt is ambiguous, you DO NOT have to guess. Emit a clarifying question with a leading marker `[NEEDS_CLARIFICATION]` on its own line. The host will pause execution and wait for the user's reply. Resume only when the user answers.
4. ASK before risky actions. Before any destructive or bulk action, emit a marker `[NEEDS_APPROVAL]` on its own line followed by a one-sentence summary of what you are about to do. The host will pause for the user's yes/no.
5. FINISH. When the task is complete, emit a final summary in normal prose (no markers) that tells the user exactly what was done. This summary is shown to the user as the final answer.

# Output style

- Step descriptions: one short sentence, present tense, ending in a period. Example: "Moving 12 PNG files into ~/Desktop/Screenshots."
- Plans: numbered list, one line per step, no padding text.
- Final summary: 1–3 short paragraphs. Lead with what was done. No marketing language, no apologies, no "I hope this helps."
- NEVER repeat the user's request back to them. NEVER preface answers with "Sure!" or "Of course." NEVER explain that you are an AI.
- All output is rendered inside small glass bubbles in a notch panel. Long output gets clipped. Be brief.

# Tools

You have access to nine file-system tools. Full schemas are provided via the tool-calling API. Brief reference:

- `list_directory(path)` — readonly. List contents of a folder.
- `read_file(path)` — readonly. Read text file contents. Files larger than 1 MB are truncated.
- `get_file_info(path)` — readonly. Size, modified date, type.
- `search_files(query, path, includeHidden=false)` — readonly. Find files by name pattern. Returns first 200 matches.
- `move_file(from, to)` — write. Rename or relocate.
- `create_folder(path)` — write. Make a new directory.
- `copy_file(from, to)` — write. Duplicate.
- `delete_file(path)` — destructive. Moves to Trash (NEVER permanent). Requires approval.
- `overwrite_file(path, content)` — destructive. Replaces file contents. Requires approval.

Default allowed paths: ~/Desktop, ~/Documents, ~/Downloads. Any write outside these paths requires approval — emit `[NEEDS_APPROVAL]` first.

# Failure handling

- A single tool failure: log it briefly, decide whether to retry with different params, skip, or revise the plan.
- Three consecutive tool failures: stop. Emit a final summary explaining what went wrong. The host will end the task.

# Recency reminders (do not violate)

- Plan first. Always. Even for one-step tasks.
- Delete and overwrite ALWAYS need approval. No exceptions.
- Never permanently delete. Trash only.
- Be brief. Bubbles are small.
- You cannot cancel yourself. Only the user can.
```

**Why this structure:**
- Identity and safety up top survive context decay better than middle-prompt rules.
- Markers `[NEEDS_CLARIFICATION]` and `[NEEDS_APPROVAL]` are easy for the host (Swift code) to detect via prefix-match without depending on tool calls, which not all Ollama models support reliably.
- Brevity is reinforced multiple times because the notch is small — verbose models will overflow the bubble.
- The recency reminders block at the bottom is the same technique Claude Code uses to combat instruction-following degradation in long contexts.

---

## 3. UI / UX Specification

The agent mode UI lives entirely inside the existing notch panel. No new windows, no overlays outside the notch.

### 3.1 Agent button (entry point)

- **Location:** The expanded prompt bar in normal-mode Welcome screen shows three elements left-to-right: pill (input field) → capture button → **agent button**.
- **Capture button** sits closer to the pill (it modifies what the prompt is about).
- **Agent button** sits furthest right (it switches modes entirely).
- **Icon:** A miniature static version of the pearlescent orb. Same visual treatment as the big orb (liquid glass, multicolored), just small enough to live as a button.
- **Why a mini-orb:** Visual continuity. The button literally *becomes* the orb when pressed — same object, larger. Establishes the orb as the brand of agent mode in a way no other app uses.

### 3.2 The agent orb

A liquid-glass, multicolored, pearlescent sphere. Continuously animated — fluid surface, slow rotation. Symbolizes autonomy and workflow.

**States the orb appears in:**
- **As the button** (mini, static or subtly animated): Welcome screen, expanded prompt bar
- **At rest** (large, center-screen, animated): just entered agent mode, no task sent yet (Sketch 2)
- **At work** (small, top-left corner, animated): agent is running (Sketch 3)
- **Stopped** (small, top-left, static): agent has finished or been force-stopped

### 3.3 State diagram

The notch panel in agent mode passes through these states. Each state defines exactly what is visible and which controls are present.

#### State A — Welcome (normal mode, agent button visible)

The existing Welcome screen. Expanded prompt bar shows pill + capture + agent button.

- **Tap agent button →** transition to State B.

#### State B — Agent Idle (just entered, no task sent)

Equivalent to Sketch 2.

- **Content area:** Large animated orb, centered in the panel.
- **Prompt bar:** Expanded pill (auto-expanded on entry). No capture button — vision is unavailable in agent mode for v1.
- **Pill collapsed state:** Bottom-left = **X** button (exit agent mode). Bottom-right = agent chat history button.
- **Send button (↑):** Enabled. Sending transitions to State C.
- **Tap X →** transition back to State A. (No history to clear since nothing happened.)
- **Tap agent chat history button →** opens history panel (see §3.5). Empty in this state.

#### State C — Agent Running

Equivalent to Sketch 3 while the agent is mid-execution.

- **Content area:**
  - **Top-left:** Orb (small, animated). Hover reveals an X overlay — clicking force-stops the agent (see State F).
  - **Bubbles stack:** Liquid-glass bubbles showing the agent's thinking and step output. Text inside bubbles is **light gray** (not white) so they read as "thinking, not the final answer." Bubbles appear in chronological order, newest at the bottom of the bubble stack.
  - **Final output area:** Appears below the bubbles when the model produces user-facing summary text. Styled exactly like normal chat output (white text, no bubble wrapper).
- **Prompt bar:** Collapsed pill.
  - **Bottom-left button:** **Pause** (`‖` icon).
  - **Bottom-right button:** Agent chat history.
- **Send button (↑):** Disabled, shows loading indicator. New prompts cannot be sent while the agent is running.
- **Tap Pause →** transition to State D.
- **Hover top-left orb → click X →** transition to State F (force-stop).
- **Agent declares task complete →** transition to State E (natural finish).

#### State D — Agent Paused (user-initiated)

User pressed the pause button while the agent was running.

- **Content area:** Same as State C (orb in top-left, bubble stack, partial output). Orb animation continues (visually indicates "still in the loop, just paused").
- **Prompt bar:** Pill is expanded.
- **Bottom-left button:** **▶ Resume**.
- **Bottom-right button:** Agent chat history.
- **Send button (↑):** Enabled. User can type additional context.
- **Tap ▶ Resume →** transition to State C.
  - If user typed text in the pill: that text is injected into the conversation as additional context, and the agent resumes with that information.
  - If pill is empty: agent resumes with no new context.
- **Tap send (↑) with text →** equivalent to "Resume with this context." Injects text, transitions to State C.

#### State E — Agent Finished (natural completion)

The model has declared the task complete and produced its final output.

- **Content area:** Same as State C, but:
  - Orb in top-left becomes **static** (no longer animated, no longer interactive — hovering does nothing).
  - Final output area shows the model's wrap-up summary in normal chat styling.
- **Prompt bar:** Collapsed pill.
- **Bottom-left button:** **X** (replaces the pause button — agent is done, nothing to pause).
- **Bottom-right button:** Agent chat history.
- **Send button (↑):** Enabled. Sending a new prompt starts a new task in the same agent mode session (see §6.2) and transitions to State C. Previous task's bubbles, output, and history remain visible; new task appends below.
- **Tap X →** clear agent history, transition to State A.
- **Tap agent chat history button →** opens history panel showing this completed task and any prior completed tasks within the current agent mode session.

#### State F — Agent Force-Stopped (top-left orb X)

User hovered the orb in top-left during State C and clicked the X overlay.

- **Behavior:** Identical to State E — agent stops, orb becomes static, bottom-left becomes X, final-output area may show partial content.
- **History is NOT cleared.** Bubbles and partial output remain visible so the user can review what happened up to the stop point.
- **Tap X →** clear agent history, transition to State A.

**Why force-stop preserves history:** If you slam stop because the agent did something unexpected, you want to see what it did. The explicit cleanup is the bottom-left X — one consistent rule for both natural finish and force-stop.

### 3.4 Auto-pause states (agent-initiated)

The agent itself can pause execution in two cases. Both manifest the same way visually but have different semantic meanings.

#### State G — Agent Auto-Paused for Clarification

The model has determined the user's prompt is ambiguous and needs an answer before continuing.

- **Trigger:** Model emits a clarifying question (e.g. "Which folder do you mean — Desktop or Documents?").
- **Display:** The question appears as a liquid-glass bubble in the bubble stack (same styling as thinking bubbles, but text is **white** instead of light gray — this signals "I am asking you something, not just thinking out loud").
- **Prompt bar:** Pill is expanded.
- **Bottom-left button:** Shows a "waiting on you" indicator (visually distinct from the user-pause `▶` resume button — TBD exact icon, lean toward a subtle pulsing variant of `▶` or an ellipsis).
- **Send button (↑):** Enabled. The user types their answer.
- **Sending →** the user's reply is injected as a chat turn, agent automatically transitions to State C (resumes execution with the answer).

**Important:** Auto-pause cannot be released by pressing the pause button. The user must answer. (Why: the agent paused because it *needs* the answer; resuming without one would just produce another stall.)

#### State H — Agent Auto-Paused for Approval

The model has decided the next action is risky enough to require explicit user approval. Triggered in two ways:

1. **Model judgment:** The model determines an action is risky and asks for confirmation.
2. **Hard-coded safety rail:** Certain operations always require approval regardless of model judgment — see §4.3.

- **Trigger:** Model emits an approval request (e.g. "I'm about to move these 14 files to Trash — proceed?").
- **Display:** Approval request shown as a liquid-glass bubble with **white text** (same as State G — distinguishes "needs your input" from "thinking").
- **Behavior:** Identical to State G. User types a response in the pill (e.g. "yes" / "no" / "yes but skip the .pdf files") and sends it.
- **On send →** transitions to State C, agent continues based on the response.

### 3.5 Agent chat history panel

A separate panel inside the notch, accessed via the bottom-right history button in any agent mode state.

**Contents:**
- A thread view of everything that has happened in the current agent mode session
- User prompts, agent steps (bubbles), agent outputs, and user clarification/approval responses, all in chronological order
- Multiple completed tasks within the same agent mode session are shown sequentially (e.g. task 1 user prompt → task 1 steps → task 1 output → task 2 user prompt → task 2 steps → task 2 output → ...)

**Lifecycle:**
- History persists across notch collapses/expansions within the same agent mode session
- History persists across multiple sequential tasks within the same agent mode session
- History is cleared automatically when the user presses the **bottom-left X** to exit agent mode (in State E, F, or B)
- History is NOT persisted across app quits (v1 — in-memory only, same as normal chat)

### 3.6 Screen-edge glow effect

When the agent starts a task (transition from State B → C) and again when it finishes (State E or F), a transient pearlescent glow pulses around the entire perimeter of the user's display. Inspired by the Siri / Apple Intelligence edge glow on iOS — same visual language, adapted for macOS via a full-screen overlay window.

**Purpose:**
- Visually signals "an autonomous AI now has access to your machine."
- Reinforces the orb's brand colors at the screen scale — same pearlescent palette, same animation feel.
- Two trigger moments: task start (~1.2s pulse) and task finish (~0.8s pulse). No continuous glow during execution — the orb in the top-left carries that load while the agent works.

**Implementation: full-screen transparent overlay window (AppKit)**

This must be a separate `NSWindow` from the notch panel — the notch is bounded by the panel's frame, but the glow spans the whole display.

1. Create `Sources/LocalNotch/Views/AgentGlowOverlay.swift`:
   - `class AgentGlowWindow: NSWindow` — a borderless transparent window sized to the active display's full frame
   - `styleMask: [.borderless]`
   - `backgroundColor: .clear`
   - `isOpaque: false`
   - `hasShadow: false`
   - `level: .screenSaver` (above .statusBar, ensures it sits above the menu bar and full-screen apps)
   - `ignoresMouseEvents: true` (critical — must not block clicks)
   - `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`
   - Content view hosts a SwiftUI `AgentGlowView`

2. `AgentGlowView` (SwiftUI):
   - A `ZStack` of multiple `RoundedRectangle` strokes inset from the screen edge, each with progressively wider line widths and larger `blur(radius:)` values to create the soft halo gradient
   - Three layers: **outer halo** (widest stroke, heaviest blur ~60pt), **mid glow** (medium stroke, ~30pt blur), **inner edge** (thin stroke, ~8pt blur)
   - Stroke fill is an `AngularGradient` or `LinearGradient` cycling through the same pearlescent palette as the orb (pinks → purples → blues → cyans)
   - Gradient angle/position animates over the pulse duration using `TimelineView` or a state-driven `Animation`
   - Overall view opacity animates: `0 → 1 → 0` over the pulse window (fade-in 200ms, hold 600ms, fade-out 400ms for the start pulse; faster for the finish pulse)

3. Window lifecycle:
   - Window is created on demand by `AgentRunner` when a glow trigger fires, shown via `orderFrontRegardless()`, and `close()`ed after the animation completes
   - On multi-display setups: glow appears on the display containing the LocalNotch notch (i.e., the main display)
   - If the user has `prefers-reduced-motion` enabled (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`), skip the glow entirely

4. Triggers (wired in `AgentRunner`):
   - **Task start:** fires once when transitioning B → C (initial task send only — NOT on resume after pause/auto-pause)
   - **Task finish:** fires once when transitioning C → E (natural completion only — NOT on State F force-stop, since the user is already telling it to stop)
   - **Failure abort (3-failure auto-abort):** fires once, but using a desaturated/reddish variant of the palette to signal "ended with errors"

**Why a separate window, not a notch-panel border:**
The notch panel is small and centered at the top of the screen — drawing a glow on its frame would not feel like "the agent has access to your computer." The full-screen edge glow extends the metaphor to the entire device, which is exactly the right visual scale for "autonomy activated."

**Why pulse, not continuous:**
A constantly glowing screen edge during the entire agent run would be exhausting and would compete with whatever the user is doing in their other apps. Pulses at the bookends — start and finish — are enough to mark the moments that matter.

---

### 3.7 Visual styling rules

| Element | Style |
|---|---|
| Thinking/steps bubbles | Liquid glass, light gray text |
| Agent question / approval request bubbles | Liquid glass, white text |
| Final output (model's user-facing summary) | Normal chat style — white text, no bubble wrapper |
| Error bubbles | Liquid glass with red tint, red text. Agent halts on error (see §4.4). |
| Orb (large, center) | Liquid glass pearlescent, animated, rotating |
| Orb (small, top-left, running) | Same as large but smaller; animated |
| Orb (small, top-left, finished/stopped) | Static, no animation, no hover interaction |
| Screen-edge glow | Pearlescent palette matching the orb, multi-layer blurred gradient strokes, pulse on task start and finish only (see §3.6) |

---

## 4. Behavior Rules

### 4.1 What the agent can and cannot do autonomously

| Action | Autonomous? |
|---|---|
| Read files in user-allowed paths | Yes |
| Write files in user-allowed paths | Yes, if the write is consistent with the user's stated task |
| Move/rename files | Yes, if consistent with the task |
| Delete files (move to Trash) | **Only with explicit approval** (auto-pause for approval) |
| Overwrite existing files | **Only with explicit approval** |
| Pause its own execution (to ask a question) | Yes |
| Resume itself after the user answers | Yes (automatic on user response) |
| Cancel/stop itself | **No** — cancellation is user-only |

### 4.2 What the user can do

| Action | When |
|---|---|
| Send the initial task prompt | State B |
| Pause the agent | State C |
| Resume the agent | State D |
| Type new context during pause | State D |
| Answer agent's clarification/approval question | State G or H |
| Force-stop the agent | State C (hover top-left orb → click X) |
| Exit agent mode | State B, E, F (press bottom-left X) |
| View agent history | Any agent mode state (press bottom-right history button) |
| Open Settings while agent runs | Yes — Settings is a separate window, agent keeps running |
| Collapse the notch while agent runs | Yes — agent keeps running, compact notch shows pulsing indicator |

### 4.3 Hard-coded safety rails (always require approval)

Regardless of the model's judgment, the following actions always trigger State H (auto-pause for approval):

- Deleting any file (always Trash — never permanent delete)
- Overwriting any existing file
- Any write operation outside the user's pre-configured allowed scopes (Settings → Agent → Allowed Paths)
- Bulk operations affecting more than **20** files in a single tool call (configurable threshold)

**Why:** Even a thinking model can produce surprising plans. These guards are the last line of defense.

### 4.4 Error handling

When a tool call fails (file not found, permission denied, etc.):

1. Tool returns a structured error to the model
2. Error is displayed in the bubble stack as a **red-tinted bubble** with red text
3. Model decides next action: retry with different parameters, skip and continue, or abort
4. If **3 consecutive tool failures** occur, the loop force-aborts: a final error bubble is appended explaining the abort, and the agent transitions to **State E** (finished) with the error visible. User can review what happened and either chain a new task or press the bottom-left X to exit.

### 4.5 Multi-task chaining within a session

After the agent finishes (State E), the user can:
- Press the bottom-left X to exit agent mode (clears history, returns to State A)
- OR open the agent chat history panel
- OR type a new prompt and press send — the send button is enabled in State E. This automatically starts a new task in the same session and transitions to State C. The previous task's bubbles and output remain visible; the new task appends below. See §6.2.

### 4.6 Notch collapse / background behavior

- If the user moves the mouse away and the notch collapses to compact, the agent **continues running** in the background.
- The compact notch shows a **pulsing dot** in the right sphere area (same indicator the existing notch model uses while thinking) so the user knows agent work is in progress.
- Hovering the notch back open restores whatever state the agent is currently in (State C, D, G, H, E, or F).

### 4.7 Quitting the app

- v1: agent state is in-memory only. Quitting the app loses agent history and stops any in-flight agent task.
- Same behavior as normal chat history today.
- v2+: optional disk persistence — explicitly out of scope for v1.

### 4.8 Force-stop semantics (in-flight tool calls)

When the user clicks the orb-X to force-stop (transition C → F):

1. The currently in-flight tool call **runs to completion** — we cannot abort a `move_file` or `read_file` syscall mid-flight without risking corrupted state. Any side effect from that one tool is permanent.
2. No further tool calls execute. The agent loop exits immediately after the in-flight call resolves.
3. Any pending model request (token streaming, planning round-trips) is **cancelled** cleanly via `URLSessionTask.cancel()` — token output stops mid-stream.
4. The current state of bubbles and partial output is preserved (per §3.3 State F).
5. A final red-tinted bubble is appended: "Stopped by user. Last action completed: <tool name>." This makes clear what side effects, if any, persisted.

### 4.9 Auto-pause compact notch indicator

When the agent is in State G (clarification) or State H (approval) and the notch is collapsed:

- The compact notch right-sphere area shows a **soft pulsing yellow dot** instead of the white "agent is working" pulse used in States C/D.
- Color choice: yellow signals "waiting" universally (traffic light metaphor — green is go, red is stop, yellow is "pay attention").
- This distinguishes "agent is doing its thing" (white pulse) from "agent needs you to look at the notch" (yellow pulse), so the user can tell at a glance whether they're the bottleneck.

### 4.10 Read and listing size limits

To prevent the model's context window from being blown out by huge files or huge directories:

| Tool | Limit | Behavior on overflow |
|---|---|---|
| `read_file` | **1 MB** of file content | Content is truncated; result includes `truncated: true` and `total_size_bytes` so the model knows it didn't see everything |
| `list_directory` | **500 entries** | Returns first 500 alphabetically, plus `truncated: true` and `total_entries` count |
| `search_files` | **200 matches** | Returns first 200, plus `truncated: true` and `total_matches` count |
| Per-tool-call file enumeration (move/copy targets passed as array) | **100 paths** | Tool returns an error; model must split into multiple calls |

The model is told about these limits in the system prompt and tool schemas, so it can plan around them (e.g., use `search_files` to narrow before listing).

### 4.11 Allowed paths model

The Settings → Agent → Allowed Paths section defines a **default whitelist**. Defaults pre-checked: `~/Desktop`, `~/Documents`, `~/Downloads`.

Behavior:
- **Read operations** (`list_directory`, `read_file`, `get_file_info`, `search_files`) are permitted ANYWHERE the user's macOS account can read. No whitelist gating on reads — the model needs to be able to look around to do useful work.
- **Write operations** (`move_file`, `create_folder`, `copy_file`) inside whitelisted paths: autonomous.
- **Write operations outside whitelisted paths:** require approval (`[NEEDS_APPROVAL]` per §2.4). The agent CAN still operate there — it just must ask first.
- **Destructive operations** (`delete_file`, `overwrite_file`): always require approval regardless of path (per §4.3).

**Why approval-required, not hard-blocked:** Users will inevitably want the agent to clean up files outside Desktop/Documents/Downloads. Hard-blocking means the agent says "I can't" and the user has to go fiddle with Settings. Approval-required preserves the safety boundary without breaking the workflow.

### 4.12 New-task chaining: orb behavior

When the user starts a new task in State E by typing a new prompt and sending (per §6.2):

- The orb remains in the top-left position. It does NOT zoom back to center.
- The orb re-animates (begins rotating / shimmering again from its static finished state) on the new task's first frame.
- No screen-edge glow pulse fires for chained tasks — only the first task in an agent mode session gets the start-pulse glow. (Rationale: chained tasks are an extension of the same "agent now has access" state; re-pulsing would be visual noise.)

Exception: a finish-pulse glow still fires when each chained task completes naturally (the visual reward for completion is per-task, not per-session).

### 4.13 Bulk operation approval semantics

When a single tool call would affect more than 20 files (hard rail per §4.3):

- The agent emits a single bundled `[NEEDS_APPROVAL]` request: "About to move 100 files matching `*.png` from ~/Desktop to ~/Desktop/Screenshots — proceed?"
- The agent does NOT split into 5 batches of 20 to avoid the rail. The system prompt instructs the model not to circumvent safety rails via batching, and the host's bulk-detection logic catches the cumulative count across consecutive same-tool calls within 30 seconds as a fallback safeguard.
- User approves once → the full bulk operation executes.
- User declines → the agent receives the rejection and revises the plan (e.g., asks for a smaller scope).

### 4.14 Reasoning trace toggle (Settings)

The Settings → Agent → "Show full reasoning trace" toggle controls how much of the model's internal thinking is exposed in the bubble stack:

| State | Bubble content |
|---|---|
| **OFF** (default) | Bubbles show only step descriptions ("Listing files in ~/Desktop.") and tool-result summaries. Raw chain-of-thought is hidden. |
| **ON** | Each step description bubble has a small ▾ expander chevron. Clicking it reveals the model's raw `<thinking>` tokens for that step. Collapsed by default; user opens what they want to see. Does NOT autoplay or auto-expand. |

**Why a toggle, not always-on or always-off:** Most users find raw chain-of-thought noisy. Power users debugging unexpected agent behavior need to see it. Default OFF keeps the experience clean; the toggle is one click away in Settings.

### 4.15 Agent-active indicator in compact notch (idle agent mode)

When the user is in agent mode but no task is running (States B, E, F) and the notch collapses:

- The compact notch shows a **small static mini-orb** in the right-sphere area (the same mini-orb that serves as the agent button).
- This signals "you're still in agent mode" so the user doesn't expect the normal-chat compact behavior when they hover back in.
- During active execution (States C/D/G/H), the orb indicator is replaced by the pulsing white dot (working) or pulsing yellow dot (waiting) per §4.9.

### 4.16 Hidden files

`list_directory` and `search_files` exclude hidden files (names starting with `.`) by default. Tools accept an `includeHidden: bool` parameter (default `false`). The model can request hidden files when relevant — for example, if the user says "find my .env files," the model should pass `includeHidden: true`.

### 4.17 Agent model removed from Settings mid-task

If the user opens Settings while an agent task is running and clears the agent model selection (or picks a different model):

- The change does NOT take effect until the next task starts.
- The currently running task continues to completion (or until force-stopped) using the model it began with.
- Rationale: silently swapping a model mid-task would corrupt the conversation state — different models have different tokenizers, behaviors, and tool-calling conventions. Forcing a stop without warning would surprise the user. Letting the current task finish is the least-surprising option.
- The Settings change is applied to the next task the user starts in this session.

### 4.18 Concurrency

Only one agent task runs at a time. This is explicit, not implicit:

- While the agent is in State C, D, G, or H, the send button is gated (per §3.3): disabled in C, enabled in D/G/H only because sending in those states is "resume with context" / "answer the question," not "start a new task."
- A new task can only begin from State B (no prior task this session) or State E/F (prior task ended). The harness asserts this at runtime — `startTask(prompt:)` will refuse to execute if `state` is not in `{B, E, F}`.
- Across windows: only one agent task can run per LocalNotch app instance. Since LocalNotch is a single-window menu-bar app, this is automatically the case.

### 4.19 Streaming and marker detection

Bubble content **live-streams** as the model generates it. Behavior matches the existing notch-model chat: tokens arrive over an `AsyncThrowingStream<String>` and are appended to the current bubble's text in real time.

**Marker detection runs on line boundaries** (buffered):

1. The harness maintains a per-stream `lineBuffer: String`.
2. On every incoming token: append to `lineBuffer`. If it contains a `\n`, split off the completed line and:
   - If the line starts with `[NEEDS_CLARIFICATION]`: stop appending further tokens to the bubble stack, cancel the in-flight model request, capture the text after the marker as the question, transition to State G.
   - If the line starts with `[NEEDS_APPROVAL]`: same as above but transition to State H.
   - Otherwise: render the line normally.
3. End-of-stream without a marker → task continues normally; final assistant message becomes the State E summary.

**Why buffered on line boundaries:** Detecting mid-token would require character-by-character matching during streaming, which complicates the buffer logic without benefit. Models reliably emit markers on their own line, so line-boundary detection is sufficient and simple. The latency cost is one newline (~1 token), invisible to the user.

### 4.20 Ollama version and tool-calling gate

Agent mode requires Ollama with reliable tool-calling support. We gate selection at two layers:

1. **Version check (one-time, on app launch and on agent model selection):**
   - `GET /api/version` → require **Ollama 0.4.0 or higher**.
   - If below: agent section in Settings shows a warning ("Ollama 0.4.0+ required for Agent Mode. You have <version>. Update Ollama at ollama.com.") and the model dropdown is disabled.

2. **Tool-call smoke test (one-time, when the user picks an agent model):**
   - On selection, the Settings panel sends a minimal probe request to the model with a single `noop_test` tool definition and a prompt like "Call the noop_test tool with arg 'hello'."
   - If the model responds with a valid tool call: status line shows "Agent mode enabled with <model>."
   - If the model responds with text only (failed to use the tool): show "Selected model does not support tool calling. Pick a different model." and clear the selection.
   - Smoke test result is cached by model name so it doesn't re-run unnecessarily; a "Re-test" button is available in the agent section of Settings.

**Fallback:** If neither gate is passable, the agent button does not appear in the notch (per §2.1).

### 4.21 Context window management

To prevent runaway context growth on long tasks:

1. At task start, the harness queries the model's max context window via `GET /api/show` for the active agent model (`model_info.context_length` or similar field).
2. Before each model round-trip, the harness estimates the current conversation token count (rough heuristic: `total_chars / 3.5`).
3. If estimated tokens exceed **80%** of the model's context window: the harness aborts the loop, appends a final red-tinted bubble ("Stopped — context limit reached for <model>. The task was too long for this model's context window."), and transitions to State E.

**Why hard-cap-and-abort instead of summarization (v1):**
Summarization requires an additional round-trip and a meta-prompt the model may handle badly. Context blowout is rare for v1's file-system-only tools (most tasks complete in <10 tool calls). Hard cap is the simplest correct behavior; we can add summarization in v2 if real users hit the limit often.

**v2 candidate:** Auto-summarize oldest tool results when crossing 70%, defer hard cap to 95%.

### 4.22 Recommended agent model (onboarding default)

The 7th onboarding step and the Settings → Agent section both suggest:

**Default suggestion: `deepseek-r1:14b`** — strongest reasoning quality that fits comfortably on a 16 GB Apple Silicon Mac. Quantized variants (`deepseek-r1:14b-q4_K_M` etc.) work too.

**Tiered notes shown in onboarding and Settings:**
- *"For 8 GB Macs: agent mode is not recommended. If you want to try, use `deepseek-r1:7b`."*
- *"For 16 GB Macs (recommended): `deepseek-r1:14b`."*
- *"For 32 GB Macs and above: `qwq:32b` for the highest reasoning quality."*

The onboarding step provides a copy-to-clipboard `ollama pull deepseek-r1:14b` button.

### 4.23 App quit during a running task

If the user presses Cmd+Q while the agent is in State C, D, G, or H, LocalNotch shows a confirmation modal **before** quitting:

> **Agent is running.**
> Quitting now will stop the current task. Any file operations that have already completed will not be undone. Files moved to Trash will remain in Trash.
>
> [ Cancel ]   [ Quit Anyway ]

- **Cancel:** dismisses the modal; agent continues running.
- **Quit Anyway:** force-stops the agent (same path as State F internally — in-flight tool finishes, no further tools, no "Stopped" bubble since the app is exiting), then quits.

If the agent is in State A, B, E, or F (no active execution), Cmd+Q quits immediately with no prompt.

### 4.24 Menu bar icon during agent activity

The existing menu bar sparkle (✦) icon gets state-driven variants:

| Agent state | Menu bar icon |
|---|---|
| Outside agent mode (normal) | ✦ (existing, white) |
| In agent mode, idle (State B/E/F) | ✦ with a subtle pearlescent tint |
| Agent running (State C) | ✦ with a slow pearlescent shimmer animation |
| Agent waiting on user (State G/H) | ✦ with a soft yellow dot in the lower-right corner |

This gives users glancing at the menu bar (notch collapsed, other windows in front) a way to know agent status without hovering the notch.

### 4.25 In-session action log

The agent chat history panel (§3.5) gains an **Action Log** subview, accessible via a small tab/toggle at the top of the history panel.

**Contents:**
- Timestamped, append-only list of every tool call made during the current agent mode session
- Each entry: `[HH:MM:SS]` + tool name + key arguments (e.g., `[14:32:07] move_file ~/Desktop/foo.png → ~/Desktop/Screenshots/foo.png`)
- Failures are shown in red text
- Most recent at the bottom (chronological)

**Why:** Users may want to review exactly what the agent did — especially after a force-stop or unexpected behavior. The bubble stack shows the agent's *narration*; the action log shows the *ground truth* of what hit the file system.

**Lifecycle:** Same as the bubble history — in-memory, persists across notch collapse/multiple tasks, cleared on bottom-left X exit. Not persisted across app quits.

---

## 5. Implementation Phases

Each phase produces something testable on its own.

### Phase 1 — Settings & agent model plumbing

1. Add `agentModel: String?` to `AppSettings` (UserDefaults-backed `@Published`).
2. Add `agentModelToolCallVerified: [String: Bool]` cache to `AppSettings` for §4.20 smoke-test memoization.
3. Add agent model detection in `OllamaAPI.swift`:
   - New method `isThinkingCapable(model: OllamaModel) -> Bool`
   - Detection strategy: name-based heuristics first (`qwq`, `r1`, `deepseek-r1`, etc.), `families` metadata as secondary signal
   - New method `verifyToolCalling(model: String) async -> Bool` — sends a minimal probe per §4.20
   - New method `ollamaVersion() async throws -> SemVer` — calls `GET /api/version`, fails closed if Ollama is unreachable
   - New method `contextLengthFor(model: String) async -> Int?` — calls `GET /api/show`, returns `model_info.context_length` when available (per §4.21)
4. Add an "Agent" section to `SettingsView`:
   - Ollama version banner — shows red warning if Ollama < 0.4.0
   - Filtered dropdown showing only thinking-capable models (with a "Show all models" override toggle for advanced users)
   - Refresh button
   - Smoke-test status: green check + "Tool calling verified" or red X + "Model does not support tool calling" (with "Re-test" button)
   - Status line ("Agent mode enabled with [model]" / "No agent model selected — agent mode disabled")
   - Toggle: "Show full reasoning trace" (default OFF — when on, exposes raw chain-of-thought in bubbles; when off, shows just step summaries)
   - Section: Allowed paths — pre-checked defaults are `~/Desktop`, `~/Documents`, `~/Downloads`. Custom path picker for advanced users.
   - Recommended-models help text per §4.22 (tiered by RAM with copy-to-clipboard pull commands)
5. **Gate:** The agent button does not appear in the notch UI unless `agentModel` is non-nil AND `agentModelToolCallVerified[model] == true` AND Ollama version is ≥ 0.4.0.

### Phase 2 — Tool system foundation

1. Create `Sources/LocalNotch/Agent/` directory.
2. Define `AgentTool` protocol:
   ```swift
   protocol AgentTool {
     static var name: String { get }
     static var description: String { get }
     static var parameterSchema: [String: Any] { get }
     static var riskLevel: RiskLevel { get }  // .readonly / .write / .destructive
     static func execute(arguments: [String: Any]) async throws -> ToolResult
   }
   ```
3. Implement v1 tools (see §6 for final scope):
   - `ListDirectory(path, includeHidden=false)` — readonly. 500-entry cap (§4.10), excludes dotfiles by default (§4.16).
   - `ReadFile(path)` — readonly. 1 MB truncation cap (§4.10).
   - `GetFileInfo(path)` — readonly.
   - `SearchFiles(query, path, includeHidden=false)` — readonly. 200-match cap (§4.10).
   - `MoveFile(from, to)` — write.
   - `CreateFolder(path)` — write.
   - `CopyFile(from, to)` — write.
   - `DeleteFile(path)` — destructive. Always uses `NSFileManager.trashItem(at:resultingItemURL:)` — NEVER `removeItem(at:)`.
   - `OverwriteFile(path, content)` — destructive.
4. Path scope enforcement: each write/destructive tool checks the target against the user's allowed paths (§4.11). Writes outside the whitelist are NOT blocked here — the harness handles the approval gate. Tools just execute when called.
5. Build `ToolRegistry` to dispatch tool calls by name with type-safe argument validation.
6. Build `ToolResult` type with `success: Bool`, `output: String?`, `error: String?`, optional `truncated: Bool` and `total_*` size hints for paged tools.

### Phase 3 — Agent harness loop

1. Create `Sources/LocalNotch/Agent/AgentRunner.swift`:
   - `class AgentRunner: ObservableObject`
   - `@Published var state: AgentState` (enum mirroring State B/C/D/E/F/G/H above)
   - `@Published var bubbles: [AgentBubble]` (timeline of steps, questions, errors)
   - `@Published var finalOutput: String` (the normal-chat-style summary text)
2. Implements the harness loop:
   - `func startTask(prompt: String)`
   - `func pause()` / `func resume(withContext: String?)`
   - `func forceStop()`
   - `func handleClarificationResponse(_ text: String)` (for State G/H)
3. Communicates with Ollama via tool-calling API. System prompt from §2.4 is prepended to every task.
4. **Marker detection.** Stream the model's output and watch for `[NEEDS_CLARIFICATION]` or `[NEEDS_APPROVAL]` at the start of any line. On detection: stop streaming further bubbles, transition to State G or H respectively, surface the question as a white-text bubble, and wait on user input.
5. Safety rail check: before any tool with `riskLevel != .readonly`, evaluate hard-coded rules (§4.3). If gated, inject an approval request into the conversation and transition to State H. Tracks cumulative same-tool counts within a 30-second window to catch batching attempts (§4.13).
6. Failure tracking: count consecutive tool failures, force-abort at 3.
7. **Mid-task model swap protection.** `AgentRunner` captures the active model ID at task start and ignores `AppSettings.agentModel` changes for the duration of the task (§4.17).
8. **Concurrency assertion.** `startTask(prompt:)` asserts `state ∈ {B, E, F}`; otherwise no-op (§4.18).
9. **In-flight tool semantics on force-stop.** `forceStop()` cancels the in-flight Ollama request via `URLSessionTask.cancel()` but allows any in-flight tool call to complete (§4.8). After resolution, appends a red-tinted "Stopped by user. Last action completed: <tool>." bubble and transitions to State F.
10. **Streaming + marker detection.** Per-stream `lineBuffer: String`; on every token, append + scan for `\n`; on completed line, check prefix for `[NEEDS_CLARIFICATION]` / `[NEEDS_APPROVAL]`, otherwise render. Live-stream bubble text per §4.19.
11. **Context window monitoring.** Before each model round-trip, estimate cumulative tokens; if > 80% of context length, abort per §4.21.
12. **Action log capture.** Every tool dispatch records an entry into `actionLog: [ActionLogEntry]` (timestamp, tool name, args, success/error). Exposed via `AgentRunner.actionLog` for the history panel's Action Log subview (§4.25).

### Phase 4 — Agent UI

1. Create `Sources/LocalNotch/Views/AgentModeView.swift`.
2. Implements all states A–H as defined in §3.3.
3. The pearlescent orb:
   - Smooth `matchedGeometryEffect` transitions between large-center (State B) and small-top-left (States C/D/G/H/E/F) positions
   - **Implementation fidelity tiers** (start with the simplest, upgrade if it doesn't feel premium):
     - **Tier 1 (recommended starting point):** Layered overlapping `Circle` shapes filled with animated `RadialGradient` and `AngularGradient` stops, color-interpolated over a `TimelineView`. The pearlescent shimmer comes from rotating gradient angles and slowly drifting hue offsets. Lightweight, pure SwiftUI, works on macOS 14+.
     - **Tier 2:** Use `MeshGradient` (macOS 15+) for the orb fill — gives a richer, more 3D iridescent surface. Falls back to Tier 1 on macOS 14.
     - **Tier 3 (highest fidelity):** Custom Metal shader rendered into a SwiftUI view via `Shader` modifier (macOS 14+). Required only if Tier 1/2 don't capture the liquid-glass-pearlescent feel.
   - **Color palette (shared with screen-edge glow §3.6):** soft pinks (#FFB3D9), violets (#C19BFF), blues (#8FB8FF), cyans (#9FE9FF). Animate gradient stops drifting through this palette continuously.
   - **Reference:** the open-source [AppleIntelligenceGlowEffect](https://github.com/jacobamobin/AppleIntelligenceGlowEffect) repo demonstrates Tier 1 patterns and is a good starting point. Do NOT vendor the code directly — read it for technique, then write our own.
   - **Animation states:**
     - Animated (rotating gradients, drifting hues): States B, C, D, G, H
     - Static (gradients frozen, no animation): States E, F
     - Hover-X overlay during State C: cross-fade orb opacity 1→0.3 + cross-fade in a centered SF Symbol `xmark` icon over 150ms
4. Bubble stack:
   - Vertically scrolling list of `AgentBubble` views
   - Liquid glass background using `.glassEffect()` (macOS 26) with fallback frosted style
   - Color rules per §3.6
5. Button states for bottom-left and bottom-right:
   - Bottom-left swaps between X / Pause / Resume / Waiting based on `AgentRunner.state`
   - Bottom-right is always the history button
6. Top-left orb hover-X interaction:
   - On hover: cross-fade orb to X icon over 150ms
   - On click: call `forceStop()`
7. Compact notch indicator (multi-state, see §4.9 and §4.15):
   - State C/D (working): pulsing **white** dot in right-sphere area
   - State G/H (waiting on user): pulsing **yellow** dot
   - State B/E/F (in agent mode, no active work): small **static mini-orb**
   - Outside agent mode: normal compact notch (existing behavior)
8. Build `AgentGlowOverlay.swift` per §3.6:
   - `AgentGlowWindow` (NSWindow subclass) — borderless, transparent, `.screenSaver` level, `ignoresMouseEvents = true`, full-display frame
   - `AgentGlowView` (SwiftUI) — three layered blurred `RoundedRectangle` strokes with animated pearlescent gradient
   - Fires on B → C transition (start pulse) and C → E transition (finish pulse); reddish variant on 3-failure auto-abort
   - Respects `accessibilityDisplayShouldReduceMotion` — skipped entirely if reduced motion is on
   - Appears on the display containing the LocalNotch notch (main display)

### Phase 5 — Agent history panel + action log

1. Build `AgentHistoryView` — similar to existing `HistoryView` but reads from `AgentRunner.bubbles + finalOutput` chronologically grouped by task.
2. Two-tab layout at the top: **Chat** (bubbles + outputs view) and **Action Log** (timestamped tool-call list per §4.25).
3. Pushed onto the notch's view stack the same way normal history is.
4. Back chevron returns to the active agent mode state.
5. Action Log row formatting: `[HH:MM:SS] tool_name(key=val, …)` + result indicator (✓ green / ✗ red).

### Phase 6 — Onboarding + docs + menu bar + quit handling

1. Add optional 7th onboarding step: "Agent model (optional)" — per §4.22 (default suggestion `deepseek-r1:14b`, tiered RAM notes, copy-to-clipboard pull command). Can be skipped, set up later in Settings.
2. Wire up Cmd+Q confirmation modal per §4.23 — install an `NSApplicationDelegate.applicationShouldTerminate` handler that checks `AgentRunner.state` and shows the confirmation alert when active.
3. Add menu bar icon state variants per §4.24 — bind the `NSStatusItem.button.image` to `AgentRunner.state` via observation; provide the four icon variants (normal / tinted / shimmer / yellow-dot).
4. Update README:
   - New "Agent Mode" section with overview, requirements (Ollama 0.4+, 16 GB+ RAM, model recommendations), and screenshots
   - Update "Known Limitations" with v1 agent caveats (file-system only, no shell, no app control, etc.)
5. Update website (`spec.md`, `Features.tsx`, `GetStarted.tsx`):
   - Add a new feature card for Agent Mode
   - Update onboarding/step copy if needed
6. Update `CHANGELOG.md`.

### Phase 7 — Testing & release

1. Manual test matrix:
   - All state transitions A→B→C→D→C→E→A
   - State F (force-stop) — verify in-flight tool completes, no further tools fire, red-tinted "Stopped by user" bubble appears (§4.8)
   - State G (clarification flow) — model emits `[NEEDS_CLARIFICATION]`, host pauses, user reply resumes
   - State H (approval flow) — both model-judgment and hard-rail triggers; bulk-batching circumvention is caught (§4.13)
   - 3-failure auto-abort → transitions to State E with error bubble (§4.4)
   - Notch collapse during agent run — verify correct indicator: white pulse (working), yellow pulse (waiting), static mini-orb (idle agent mode)
   - Multi-task chaining — verify orb stays in top-left, re-animates, no start-pulse glow on chained task, finish-pulse on each (§4.12)
   - Screen-edge glow — fires on B→C and C→E only, NOT on resume / chained start / force-stop; red variant on 3-failure abort; respects reduced motion (§3.6)
   - Read/list/search size caps — model receives `truncated: true` on overflow (§4.10)
   - Hidden files excluded by default; included when `includeHidden=true` (§4.16)
   - Path whitelist: writes inside default scopes are autonomous; writes outside trigger `[NEEDS_APPROVAL]` (§4.11)
   - Mid-task model swap in Settings does NOT affect the running task (§4.17)
   - Concurrent `startTask` while running is a no-op (§4.18)
   - Marker detection: model emits `[NEEDS_CLARIFICATION]` or `[NEEDS_APPROVAL]` on its own line → harness transitions correctly (§4.19); markers not on their own line are rendered as normal text
   - Live token streaming feels responsive in bubbles (no perceived buffering)
   - Ollama < 0.4.0 → agent section in Settings shows version warning, dropdown disabled (§4.20)
   - Smoke test fails for a model → status shows red X, selection cleared
   - Smoke test cache: re-selecting a previously verified model does NOT re-run the probe; "Re-test" button forces re-run
   - Context window 80% trigger → red-tinted "context limit reached" bubble, transitions to State E (§4.21)
   - Onboarding agent step: default `deepseek-r1:14b`, copy-to-clipboard works, can be skipped (§4.22)
   - Cmd+Q during active execution → confirmation modal appears; Cancel keeps agent running; Quit Anyway force-stops and exits (§4.23)
   - Cmd+Q outside active execution (State A/B/E/F) → no prompt, immediate quit
   - Menu bar icon transitions through all four variants correctly per state (§4.24)
   - Action Log tab in history panel shows every tool call with timestamps; failures in red (§4.25)
2. Hardware test: 16GB MacBook (limit), 32GB MacBook (target).
3. Update version to v0.2.0-beta.
4. Update memory files in `~/.claude/projects/.../memory/`.

---

## 6. v1 Tool Scope

The agent can only invoke tools from this menu. Anything not listed here is impossible in v1 by design.

| Tool | Risk | Description |
|---|---|---|
| `list_directory(path)` | readonly | List files and folders at a path |
| `read_file(path)` | readonly | Read text file contents |
| `get_file_info(path)` | readonly | Size, modified date, type |
| `search_files(query, path)` | readonly | Find files by name pattern |
| `move_file(from, to)` | write | Rename or relocate a file |
| `create_folder(path)` | write | Make a new directory |
| `copy_file(from, to)` | write | Duplicate a file |
| `delete_file(path)` | destructive | Move file to Trash (always Trash, never permanent) |
| `overwrite_file(path, content)` | destructive | Replace file contents |

**Why file-system-only for v1:**
- Most common useful task surface
- Clean undo (Trash, not permanent delete)
- Fully implementable with Swift's `FileManager` — no extra entitlements beyond Files & Folders permissions
- Bounded risk — destructive ops are gated by hard rails and approval (§4.3)

**Out of scope for v1** (deferred to v2+):
- Shell command execution (`run_command`)
- AppleScript / JXA (`tell_app`)
- Accessibility / UI automation in other apps
- Network requests (HTTP, scraping)
- Code editing in IDE-style projects

## 6.2 New-task chaining in State E

After the agent finishes, the send button in State E is **re-enabled**. The user can:
- Type a new prompt and send → automatically transitions to State C and starts a new task in the same session
- Previous task's bubbles, output, and history remain — the new task appends below
- OR press the bottom-left X to exit agent mode entirely (clears all history)

**Why:** Lets the user chain related tasks naturally without exiting and re-entering agent mode each time.

## 6.3 Waiting-on-you button (State G / H)

When the agent has auto-paused for a clarification or approval:
- **Bottom-left button:** `▶` icon (same as user-resume) with a subtle **pulsing glow** animation
- The pulse signals "the agent wants something from you" and visually distinguishes it from the static `▶` of a user-initiated pause
- Pressing the button alone does nothing in this state — the user must type a response and send it (auto-resumes on send)

---

## 7. Out of Scope (explicitly NOT in v1)

- Shell command execution
- AppleScript / app control
- Accessibility / UI automation in other apps
- Network access tools (HTTP requests, scraping, etc.)
- Multi-agent / parallel agent runs
- Background agents (agents that run while LocalNotch is not in focus or is quit)
- Scheduled / cron-style agents
- Agent task history persistence across app quits
- Custom user-defined tools
- IDE-style code project editing
- Vision/screenshot tools within agent mode (camera button is hidden in agent mode for v1)
- Navigation to normal chat while an agent is running (X is the only exit during a run)

These are deliberately deferred to keep v1 scope and risk manageable.

---

## 8. Risks & Accepted Limitations

| Risk | Mitigation |
|---|---|
| User's hardware can't run a useful thinking model | Documented in README and Settings status line. Agent mode is opt-in — never imposed. |
| Model produces wrong plan and damages files | Trash-only deletes (no permanent), hard-coded safety rails (§4.3), approval gates for destructive ops, force-stop available at all times. |
| Permission fatigue on first use | Onboarding includes a clear explanation; Settings shows which paths the agent can access. |
| Agent stalls in a loop (model can't make progress) | 3-consecutive-failure auto-abort. |
| User accidentally clears history by hitting X | History is in-memory; this is consistent with normal chat behavior. No undo for v1. |

---

## 9. File Inventory

Complete map of every file that needs to be created or modified to implement v1. All paths relative to `Sources/LocalNotch/`.

### New files

| Path | Purpose | Phase |
|---|---|---|
| `Agent/AgentTool.swift` | `AgentTool` protocol, `RiskLevel` enum, `ToolResult` type | 2 |
| `Agent/ToolRegistry.swift` | Tool dispatch, name → executor mapping, argument validation | 2 |
| `Agent/Tools/ListDirectoryTool.swift` | `list_directory` tool (§4.10, §4.16) | 2 |
| `Agent/Tools/ReadFileTool.swift` | `read_file` tool with 1 MB truncation | 2 |
| `Agent/Tools/GetFileInfoTool.swift` | `get_file_info` tool | 2 |
| `Agent/Tools/SearchFilesTool.swift` | `search_files` tool with 200-match cap | 2 |
| `Agent/Tools/MoveFileTool.swift` | `move_file` tool | 2 |
| `Agent/Tools/CreateFolderTool.swift` | `create_folder` tool | 2 |
| `Agent/Tools/CopyFileTool.swift` | `copy_file` tool | 2 |
| `Agent/Tools/DeleteFileTool.swift` | `delete_file` (Trash-only via `trashItem(at:)`) | 2 |
| `Agent/Tools/OverwriteFileTool.swift` | `overwrite_file` tool | 2 |
| `Agent/AgentSystemPrompt.swift` | The locked agent system prompt string from §2.4 + builder that injects allowed-paths list | 3 |
| `Agent/AgentRunner.swift` | The harness: state machine, model loop, marker detection, safety rails, action log, force-stop | 3 |
| `Agent/AgentState.swift` | `enum AgentState { case welcome, idle, running, paused, finished, forceStopped, clarifying, approving }` + `AgentBubble`, `ActionLogEntry` value types | 3 |
| `Agent/MarkerDetector.swift` | `lineBuffer` streaming marker detector (`[NEEDS_CLARIFICATION]` / `[NEEDS_APPROVAL]`) per §4.19 | 3 |
| `Agent/ContextBudget.swift` | Token estimator + 80% threshold check per §4.21 | 3 |
| `Views/AgentModeView.swift` | Top-level SwiftUI view for agent mode (binds to `AgentRunner`, switches between states A–H) | 4 |
| `Views/AgentOrbView.swift` | The pearlescent orb (Tier 1/2/3 implementation per §3.2) | 4 |
| `Views/AgentBubbleView.swift` | Single bubble rendering (thinking / question / approval / error / output styles per §3.7) | 4 |
| `Views/AgentBubbleStack.swift` | Scrolling vertical stack of bubbles + final output | 4 |
| `Views/AgentPromptBar.swift` | Pill input with state-driven left button (X / Pause / Resume / Waiting) | 4 |
| `Views/AgentGlowOverlay.swift` | `AgentGlowWindow` (NSWindow) + `AgentGlowView` (SwiftUI) — full-display borderless edge-glow overlay per §3.6 | 4 |
| `Views/AgentCompactIndicator.swift` | Compact-notch indicator: white pulse / yellow pulse / mini-orb per §4.9 + §4.15 | 4 |
| `Views/AgentHistoryView.swift` | History panel with Chat / Action Log tabs per §3.5 + §4.25 | 5 |
| `Views/Settings/AgentSettingsView.swift` | Settings → Agent section: model dropdown, version banner, smoke-test status, allowed paths, reasoning toggle, recommended models | 1 |
| `Views/Onboarding/AgentModelStep.swift` | Optional 7th onboarding step per §4.22 | 6 |

### Modified files

| Path | Changes |
|---|---|
| `AppSettings.swift` | Add `agentModel: String?`, `agentModelToolCallVerified: [String: Bool]`, `agentAllowedPaths: [String]`, `agentShowReasoningTrace: Bool` |
| `OllamaAPI.swift` | Add `isThinkingCapable(_:)`, `verifyToolCalling(model:)`, `ollamaVersion()`, `contextLengthFor(model:)`; extend chat method to support tool-calling responses |
| `AppDelegate.swift` | Wire `applicationShouldTerminate` for §4.23 Cmd+Q confirmation; bind menu bar icon variants per §4.24 |
| `ChatView.swift` | Add agent button to expanded prompt bar (Sketch 1 from §3.1); route agent button tap into `AgentRunner.enterAgentMode()` |
| `SettingsView.swift` | Add navigation entry for the new Agent section |
| `OnboardingView.swift` | Insert the optional 7th step after the existing 6 |
| `README.md` (main repo) | New "Agent Mode" section; updated Known Limitations |
| `website/spec.md` | New feature card for Agent Mode |
| `website/src/components/Features.tsx` | New card in the bento grid |
| `CHANGELOG.md` | v0.2.0-beta entry |

### Memory files (post-release)

| Path | Changes |
|---|---|
| `~/.claude/projects/.../memory/project_open_source.md` | Add v0.2.0-beta release notes, agent architecture summary, file paths |

---

## 10. Decision Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-05-13 | Build agent mode as v2 feature, target for v0.2.0-beta | Headline upgrade that takes the app out of beta |
| 2026-05-13 | Separate model selection (thinking for agent, fast for notch) | Right tool for each role |
| 2026-05-13 | Agent mode is opt-in, no default model | Users without compatible hardware are unaffected |
| 2026-05-13 | Agent button = mini pearlescent orb, sits right of capture in expanded prompt bar | Visual continuity with the activation orb; unique brand |
| 2026-05-13 | No vision/camera in agent mode for v1 | Simplifies UI and risk surface |
| 2026-05-13 | Plan-first confirmation flow, autonomous-with-safety-rails for execution | Balances UX smoothness with safety |
| 2026-05-13 | Hard-coded safety rails always require approval for destructive ops | Model judgment is not sufficient on its own |
| 2026-05-13 | Agent can auto-pause for clarification or approval, cannot cancel itself | Autonomy with a hard ceiling — user always has the final cancel |
| 2026-05-13 | Force-stop preserves history; only bottom-left X clears it | One consistent cleanup action; users can review what happened before exiting |
| 2026-05-13 | History in-memory only for v1; persists across notch collapse and multiple tasks within session | Consistent with normal chat behavior |
| 2026-05-13 | Errors shown as red-tinted glass bubbles; 3-failure auto-abort | Visual consistency with bubble language; prevents stuck loops |
| 2026-05-13 | Thinking bubbles use light gray text; questions/approval bubbles use white text; final output uses normal chat style | Visual hierarchy makes it obvious what's "thinking" vs "asking" vs "answer" |
| 2026-05-13 | v1 tool scope = 9 file-system tools (no shell, no AppleScript, no accessibility, no network) | Bounded risk, clean undo via Trash, most common useful task surface |
| 2026-05-13 | Send button re-enabled in State E for new-task chaining; bottom-left X is the only way to clear history | Natural chaining of related tasks without leaving agent mode |
| 2026-05-13 | Auto-pause uses pulsing `▶` with glow to distinguish from user-paused static `▶` | Clear visual signal that the agent needs the user's input |
| 2026-05-14 | Screen-edge pearlescent glow pulse on task start and finish (separate borderless overlay NSWindow, `.screenSaver` level, mouse-transparent, full-display frame) | Visually signals "autonomous AI now has access to your machine" — Siri-style edge glow scaled to the whole display. Pulse at start/finish only, not continuous, so it doesn't compete with user's other work. |
| 2026-05-14 | Agent system prompt locked (§2.4); not user-editable in v1; uses `[NEEDS_CLARIFICATION]` and `[NEEDS_APPROVAL]` markers | Inspired by Claude Code's leaked harness structure (identity-up-top, recency reminders at bottom) and Codex's marker-based control flow. Markers are easier and more reliable than depending on Ollama tool-calling for control signals across many models. |
| 2026-05-14 | Force-stop allows in-flight tool to complete, cancels in-flight Ollama request, appends "Stopped by user. Last action: <tool>." bubble | Cannot abort syscalls mid-flight without risking corrupt state; user needs to know what side effect persisted. |
| 2026-05-14 | Compact notch indicator: white pulse (working), yellow pulse (waiting on user), static mini-orb (idle agent mode) | Traffic-light color metaphor — yellow signals "you're the bottleneck"; mini-orb signals "still in agent mode" without implying activity. |
| 2026-05-14 | Size caps: 1 MB read, 500 list entries, 200 search matches, 100 paths per bulk call | Prevents context-window blowout; tools return `truncated: true` + total counts so model can plan around limits. |
| 2026-05-14 | Allowed paths model: reads anywhere, writes inside whitelist autonomous, writes outside whitelist require approval, destructive always requires approval | Approval-required (not hard-block) preserves safety without forcing the user to fiddle with Settings to clean up arbitrary folders. |
| 2026-05-14 | Chained tasks: orb stays in top-left, re-animates in place; start-pulse glow only on the first task per session; finish-pulse glow on every task | Visual continuity within a session; avoids re-pulsing the "now activated" signal that has already been established. |
| 2026-05-14 | Bulk approval bundled into one `[NEEDS_APPROVAL]` ("about to move N files — proceed?"); host catches batching-circumvention via 30-second cumulative-count window | Single approval matches user mental model; rail bypass attempts (model splits 100 into 5×20) are still gated. |
| 2026-05-14 | Settings "Show full reasoning trace" toggle — OFF default; ON adds a ▾ expander per bubble that reveals raw `<thinking>` tokens, collapsed by default | Power-user visibility without polluting the default minimal experience. |
| 2026-05-14 | Hidden files (`.`-prefixed) excluded from `list_directory`/`search_files` by default; opt-in via `includeHidden=true` parameter | Reduces noise; model can request when relevant. |
| 2026-05-14 | Agent model change in Settings mid-task is deferred — current task completes on the model it began with; change applies to next task | Silent model swap would corrupt conversation state and surprise the user. |
| 2026-05-14 | Concurrency: only one agent task at a time; `startTask` asserts `state ∈ {B, E, F}` | Sequential semantics are simpler to reason about and match user expectation. |
| 2026-05-14 | Bubble text live-streams as model generates; marker detection runs on line boundaries via `lineBuffer` | Matches existing chat UX (feels alive); line-boundary buffer keeps marker logic simple without sacrificing responsiveness. |
| 2026-05-14 | Require Ollama ≥ 0.4.0 + per-model tool-calling smoke test cached in `AppSettings` | Tool-calling support varies by Ollama version and model; gating at selection time prevents the agent button appearing on unsupported configurations. |
| 2026-05-14 | Context window: hard-cap-and-abort at 80% of model's `context_length`; v2 adds summarization | Simplest correct behavior for v1; context blowout is rare for file-system-only tasks. |
| 2026-05-14 | Default agent model recommendation: `deepseek-r1:14b` (16 GB); tiered notes for 8 GB and 32 GB+ | Best reasoning-quality / hardware-fit balance for the bulk of MacBook Pro users in 2026. |
| 2026-05-14 | Cmd+Q during agent execution shows a confirmation modal; otherwise quits immediately | Lowest-effort safety against accidental data loss from in-flight tool getting cut off. |
| 2026-05-14 | Menu bar icon variants for normal / idle agent mode / running / waiting | Lets users tell agent status from outside the notch without hovering. |
| 2026-05-14 | Per-session Action Log in agent history panel — timestamped tool calls with results | Bubble narrative shows what the agent *said*; action log shows what it *did*. Critical for review after force-stop or unexpected behavior. |
