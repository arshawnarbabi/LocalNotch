<p align="center">
  <img src="LocalNotchBanner.svg" alt="LocalNotch" width="100%" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift" />
  <img src="https://img.shields.io/badge/Ollama-local%20inference-8A2BE2?style=flat-square" alt="Ollama" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-M1%2B-black?style=flat-square&logo=apple&logoColor=white" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License" />
  <a href="https://localnotch.arshawnarbabi.com/"><img src="https://img.shields.io/badge/website-localnotch.arshawnarbabi.com-0071e3?style=flat-square" alt="Website" /></a>
</p>

**Website:** [localnotch.arshawnarbabi.com](https://localnotch.arshawnarbabi.com/)

LocalNotch is a macOS AI assistant that lives in your MacBook's notch. Hover to open, type to ask anything — then it disappears. No window to manage, no app to switch to. Everything runs locally through [Ollama](https://ollama.com): your conversations, your screenshots, your data — nothing leaves your machine. Optionally wire in a Brave Search API key and it gains real-time web search, decided automatically by a 3-layer classifier.

<p align="center">
  <video src="https://github.com/user-attachments/assets/acdf91b3-a8b0-4a01-bcea-b0e55e262141" autoplay loop muted playsinline controls width="100%"></video>
</p>

> **This is beta software.** LocalNotch is v0.2.0-beta and actively developed. You may encounter bugs, rough edges, and missing features. Apple Silicon only. See [Known Limitations](#known-limitations) before installing.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [First Launch: Onboarding](#first-launch-onboarding)
- [Using LocalNotch](#using-localnotch)
- [Agent Mode](#agent-mode)
- [Settings](#settings)
- [Web Search](#web-search)
- [Privacy](#privacy)
- [Building from Source](#building-from-source)
- [Architecture Overview](#architecture-overview)
- [Known Limitations](#known-limitations)
- [FAQ & Troubleshooting](#faq--troubleshooting)
- [Credits](#credits)
- [License](#license)

---

## Features

- **Lives in the notch** — expands on hover, collapses on mouse-out, stays completely out of your way when idle
- **Fully local inference** — runs any model you have installed in Ollama; nothing is sent to any cloud service
- **Vision** — tap the camera button to capture your screen and ask questions about it; long-press to clear the screenshot
- **Hybrid web search** — bring your own Brave Search API key; a 3-layer classifier (explicit triggers → keyword detection → LLM) decides when to search automatically
- **Web search badge** — a pulsing dot appears while a search is in flight; a globe badge persists while the model is responding so you always know when live data was used
- **Weather & time** — the idle screen shows current temperature (Fahrenheit), feels-like, humidity, and condition alongside today's date and live clock; refreshes every 10 minutes via [wttr.in](https://wttr.in) — no account or API key required
- **Personalized greeting** — set your name in onboarding or Settings and the idle screen greets you
- **Chat history panel** — view all turns from the current session; tap any response to expand it in full
- **In-session reset** — the counterclockwise arrow button wipes the current response with an animated fade and clears the full conversation history
- **Guided onboarding** — detects Ollama on first launch, walks you through model selection and optional web search setup; progress is saved so you can quit mid-flow and resume where you left off
- **Settings** — switch models, update your API key, change your name, and fully customize the system prompt; open with ⌘, from the menu bar
- **Markdown rendering** — responses support bold, italic, code spans, code blocks (horizontally scrollable), blockquotes, tables, and headings
- **Liquid Glass UI** — native macOS 26 Tahoe glass effect on the input pill, buttons, and badges; clean frosted-glass fallback on macOS 14/15
- **Compact notch indicator** — a pulsing dot in the collapsed notch shows the model is thinking; a green checkmark appears when it finishes
- **Agent Mode** *(new in v0.2)* — opt-in autonomous file-system agent powered by a separate local reasoning model; reads, writes, moves, copies, and searches files on your Mac through a supervised tool loop with per-action approval and pause/resume control; screen-edge glow on task start and finish

---

## Requirements

| Requirement | Details |
|---|---|
| macOS | 14 (Sonoma) or later. macOS 26 (Tahoe) required for Liquid Glass. |
| Architecture | Apple Silicon (M1 or newer). Intel is not supported. |
| Ollama | Must be installed and running before first launch. |
| Display | A Mac with a physical notch (MacBook Pro 14"/16", MacBook Air M2/M3, etc.). |

---

## Installation

### Option A — Download (recommended)

1. Download `LocalNotch.zip` from [Releases](https://github.com/arshawnarbabi/LocalNotch/releases).
2. Unzip and drag `LocalNotch.app` to your Applications folder.
3. **The first launch will be blocked** with *"Apple could not verify 'LocalNotch' is free of malware."* That's expected — LocalNotch is ad-hoc signed, not notarized with a paid Apple Developer ID, and Gatekeeper only auto-approves notarized apps for downloaded copies. Two ways past it:

   1. **Terminal (recommended).** Move `LocalNotch.app` to `/Applications`, then strip the quarantine flag:

      ```sh
      xattr -dr com.apple.quarantine /Applications/LocalNotch.app
      ```

      This is the better route — it also prevents Gatekeeper **App Translocation** (macOS running the app from a random read-only path), which would break the **Screen Recording** permission LocalNotch needs for vision queries. Move the app into `/Applications` *before* its first launch for the same reason.
   2. **System Settings.** Try to open LocalNotch once (let it get blocked), then go to **System Settings → Privacy & Security**, scroll to the "LocalNotch was blocked" notice, and click **Open Anyway**. (On macOS 15 Sequoia and 26 Tahoe, the old right-click → Open bypass no longer works for unnotarized apps.)

   Either way you only need to do this once — after that LocalNotch launches normally.
4. When prompted, grant **Screen Recording** permission. This is required to capture screenshots for vision queries.

### Option B — Build from source

```bash
git clone https://github.com/arshawnarbabi/LocalNotch.git
cd LocalNotch
./scripts/release.sh
```

The script compiles a release binary, assembles a proper `.app` bundle, ad-hoc signs it, and produces `LocalNotch.zip` in the repo root. Unzip, move to `/Applications`, then clear quarantine with `xattr -dr com.apple.quarantine /Applications/LocalNotch.app` (see [Option A → step 3](#option-a--download-recommended) for the full Gatekeeper explanation).

See [Building from Source](#building-from-source) for full details.

---

## First Launch: Onboarding

On first launch the notch expands automatically and walks you through a 7-step setup. Your progress is saved to disk — if you quit mid-flow, reopening the app resumes exactly where you left off.

### Step 1 — Ollama check

LocalNotch probes `http://localhost:11434` to see whether Ollama is running.

- **Detected:** advances automatically after a brief confirmation.
- **Not running:** shows an "Open Ollama" button (opens `/Applications/Ollama.app`) and a "Check again" button.
- **Not installed:** shows a "Get Ollama" button linking to [ollama.com](https://ollama.com).

### Step 2 — Your name *(optional)*

Enter a first name. The idle screen will greet you with "Hello, [name]." every time you open the notch. You can skip this and set it later in **Settings → Personality**.

### Step 3 — Choose a text model *(required)*

A dropdown lists every text model installed in Ollama. You must select one to continue — this model handles all chat and reasoning, including the web search classifier.

**Recommended models:**

```bash
ollama pull gemma3:4b      # fast, lightweight
ollama pull gemma3:12b     # higher quality
ollama pull qwen2.5:7b     # good all-rounder
```

### Step 4 — Vision model *(optional)*

If your text model already supports vision natively (e.g. a Llama 3.2 multimodal variant), this step shows a "Vision included" confirmation and auto-advances.

Otherwise, a dropdown shows only vision-capable models. You can skip this if you don't need screenshot analysis and add one later in Settings.

**Recommended vision models:**

```bash
ollama pull llama3.2-vision   # recommended — mllama architecture
ollama pull llava:7b          # lighter alternative
ollama pull moondream         # smallest footprint
```

### Step 5 — Web search API key *(optional)*

Paste a [Brave Search API key](https://api.search.brave.com/register) to enable live web search. The free tier provides 1,000 queries/month. You can skip this now and add it later in **Settings → Web Search**.

### Step 6 — Agent Model *(optional)*

Set up a dedicated reasoning model for Agent Mode. Agent Mode uses a separate model from your chat model because agentic tasks benefit from deeper reasoning; keeping them separate also means your chat model stays fast and lightweight.

**Recommended by available RAM:**

| RAM | Model | Pull command |
|---|---|---|
| 8 GB | deepseek-r1:7b | `ollama pull deepseek-r1:7b` |
| 16 GB | deepseek-r1:14b | `ollama pull deepseek-r1:14b` |
| 32 GB+ | qwq:32b | `ollama pull qwq:32b` |

You can skip this step and configure Agent Mode later in **Settings → Agent**. The agent button in the notch will remain hidden until a model is verified.

### Step 7 — Done

A confirmation screen. Click "Let's go" to close onboarding and start using the app. You can re-run onboarding at any time via **Settings → About → Show onboarding again**.

---

## Using LocalNotch

### Opening and closing

- **Hover over the notch area** → the panel expands
- **Move your cursor away** → the panel collapses after a 200ms grace period

### Typing and sending

- **Hover over the "Ask anything" pill** → it expands into a text field
- **Type your message**, then press **Return** or click the ↑ button
- While the model is loading, the ↑ button becomes a spinner; the notch's compact trailing area shows a pulsing dot
- When the model finishes, a green checkmark appears briefly in the compact notch

### Controls reference

| Control | Location | Action |
|---|---|---|
| ↺ (counterclockwise arrow) | Left sphere | Reset chat: clears history, cancels any in-flight request, wipes the current response with an animated fade |
| Clock icon | Right sphere | Open chat history for this session |
| Camera / viewfinder | Right of input pill | Tap: capture a screenshot; appears when input is expanded |
| Camera (long-press 1 second) | Camera button | Clear a previously captured screenshot; a progress ring fills while you hold |
| ⌘, | Menu bar sparkle icon | Open Settings |
| ⌘Q | Menu bar sparkle icon | Quit LocalNotch |
| ⌘Z / ⌘⇧Z | Input field | Undo / Redo |
| ⌘C / ⌘X / ⌘V | Input field | Copy / Cut / Paste |
| ⌘A | Input field | Select all text in the input field |

### Screenshot / vision workflow

1. Expand the input by hovering the pill.
2. Tap the camera button on the right. A white flash confirms the capture; the button thumbnail previews the screenshot.
3. Type your question about the screenshot, then send.
4. If using a vision model, animated dots appear while the model processes the image (vision models take noticeably longer than text models before the first token arrives).
5. Long-press the camera button (1 second, the progress ring fills) to discard the screenshot and return to text-only mode.

---

## Agent Mode

Agent Mode is an opt-in autonomous file-system agent that can read, write, move, copy, rename, create, delete, and search files on your Mac — all from a natural-language description of the task. It is designed for multi-step file-management work that would otherwise take many manual steps.

### Requirements

| Requirement | Details |
|---|---|
| Ollama | Version 0.4.0 or later (for streaming tool-call support) |
| RAM | 16 GB recommended (for deepseek-r1:14b); 8 GB minimum (for :7b) |
| Agent model | A reasoning model pulled separately from your chat model |

### How it works

Agent Mode uses a dedicated reasoning model (not your chat model) and a loop:

1. You describe the task in natural language ("rename all the `.jpeg` files in my Downloads folder to `.jpg`")
2. The model reasons about the task and emits a structured tool call
3. LocalNotch shows you what it's about to do and asks for approval (configurable per-session)
4. The tool executes; result is fed back to the model
5. The loop continues until the model emits `task_complete`, you pause, or you force-stop

The agent has access to 9 file-system tools: `read_file`, `write_file`, `list_directory`, `move_item`, `copy_item`, `create_directory`, `delete_item`, `find_files`, and `run_shell`.

> **`run_shell` always requires explicit per-call approval**, regardless of your approval setting, and is disabled by default. Shell commands are shown in full before execution.

### Starting a task

1. Hover the notch to expand it.
2. Expand the input pill and look for the pearlescent orb button to the right of the camera button. (It appears only when an agent model has been verified in Settings.)
3. Click the orb to enter Agent Mode.
4. Describe the task in natural language and press **Return**.

### During a task

The agent panel shows:

- The pearlescent orb in the top-left corner, which pulses while the model is reasoning
- Two tabs: **Chat** (model messages and tool results as conversation bubbles) and **Actions** (a structured log of every tool call with its result and timestamp)
- A **pause** button (‖) to suspend the loop without losing context; press ▶ to resume
- A **force-stop** button (✕) to terminate the loop immediately; the last completed action is reported

When the agent needs clarification or explicit approval for a tool call, the orb turns yellow and a prompt appears in the Chat tab. The compact notch indicator also turns yellow to alert you even when the panel is collapsed.

### Approval modes

Agent Mode has two approval settings, configurable in **Settings → Agent**:

- **Approve all tools** — shows a confirmation dialog before every tool call (default for new users)
- **Auto-approve safe tools** — only `run_shell` and `delete_item` require approval; all other tools execute immediately

You can change this setting per-session from the agent panel.

### Screen-edge glow

When a task starts and when it finishes successfully, a brief pearlescent glow sweeps all four screen edges. This effect respects **System Settings → Accessibility → Reduce Motion** — it is suppressed when that option is on.

### Context window

The agent tracks total token usage against the model's context window. When usage reaches 85% of the context limit, the agent automatically summarizes the conversation history and continues from the summary.

### What the agent can access

By default the agent can access:

- Your home directory (`~/`)
- `/tmp`

Paths outside these roots are blocked unless you add them in **Settings → Agent → Allowed Paths**. Absolute paths beginning with `/System`, `/usr`, `/bin`, and `/sbin` are always blocked regardless of the allow-list.

---

## Settings

Open Settings with **⌘,** from the menu bar sparkle icon. Settings opens in a separate 360 × 480 window. Navigate with the section list; tap the back chevron to return.

### Models

Displays two filtered dropdowns:

- **Text model** — shows only non-vision models from Ollama. If all your models are multimodal, all models are shown instead.
- **Vision model** — shows only vision-capable models (CLIP, mllama, moondream, LLaVA, etc.).

A **Refresh** button re-fetches the model list from Ollama. A status line shows how many text and vision models are available, or warns if Ollama is unreachable.

### Web Search

A masked text field for your Brave Search API key. Click the eye icon to reveal the key. A status line confirms whether web search is enabled or disabled. See [Web Search](#web-search) for full details.

### Personality

- **Display name** — the name shown in your idle-screen greeting.
- **System prompt** — a multiline editor for the full system prompt sent to the model on every turn. The default prompt includes tone, behavior, and web search instructions. A **Reset to default** button restores the original; tap it once to arm (shows "Tap again to confirm"), tap again within 3 seconds to confirm.

### Agent

- **Agent model** — dropdown listing all models installed in Ollama. Select the model you want to use for agent tasks, then click **Test** to run a smoke test (the model must successfully emit a tool call to pass). A verified model enables the orb button in the notch.
- **Approval mode** — toggle between "Approve all tools" and "Auto-approve safe tools" (see [Agent Mode → Approval modes](#approval-modes)).
- **Allowed Paths** — additional directory paths the agent may access beyond `~/` and `/tmp`.

### About

- Version number (v0.2.0-beta)
- GitHub link
- MIT License link
- **Show onboarding again** — re-runs the full 7-step onboarding flow

---

## Web Search

LocalNotch includes automatic web search powered by the [Brave Search API](https://api.search.brave.com). When a Brave API key is configured, the app uses a 3-layer hybrid classifier on every message before calling the model.

### How search is triggered

**Layer 1 — Explicit user intent** (instant, no LLM round-trip)

Phrases like these trigger search immediately, extracting the query from the text:

> "search the web for…", "look up…", "surf the web on…", "find information about…", "research…", "google…", "look into…"

Bare contextual phrases — "google it", "search this up", "look it up" — use your previous message as the search query.

**Layer 2 — Keyword detection** (instant, no LLM round-trip)

High-confidence topics that almost always need live data: weather, news, sports scores, stock/crypto prices, trending topics, release dates, and year references past 2024.

**Layer 3 — LLM classifier** (one fast LLM call)

For ambiguous queries, the text model itself decides whether a search is needed, returning either `SEARCH: <query>` or `NO`. This catches questions like "what's the latest on X?" that don't contain explicit trigger phrases.

If no API key is configured, all three layers are bypassed silently and no search is performed.

### What you see

- While the search is running: a pulsing dot badge labeled **"Searching the web · [query]"** appears above the idle screen.
- While the model is responding: a globe icon badge labeled **"Web · [query]"** stays visible so you always know the response used live data.

### Setting up Brave Search

1. Sign up at [api.search.brave.com/register](https://api.search.brave.com/register). A credit card is required by Brave even for the free tier.
2. Copy your API key.
3. In LocalNotch, open **Settings → Web Search** and paste the key. It saves immediately to `UserDefaults`.

The free tier provides **1,000 queries/month**. Paid tiers are available for heavier use.

---

## Privacy

LocalNotch is privacy-first by design.

| What | Where it goes |
|---|---|
| Chat messages and AI responses | Nowhere — processed entirely by Ollama on your machine |
| Screenshots | Nowhere — encoded locally, sent only to your local Ollama vision model |
| Weather | One anonymous request to [wttr.in](https://wttr.in) every 10 minutes. Uses your IP for geolocation. No account, no API key. |
| Web search queries | Sent to `api.search.brave.com` under your Brave account only when search is triggered |
| Brave API key | Stored in `UserDefaults` on your Mac (not in Keychain — v1 limitation) |
| Display name and system prompt | Stored in `UserDefaults` on your Mac |
| Chat history | In memory only — quitting the app clears it completely |

No telemetry. No analytics. No crash reporting. No servers operated by us.

---

## Building from Source

### Prerequisites

- Xcode 16 or later (for the Swift toolchain; you do not need to open Xcode)
- Swift 5.9 or later
- macOS 14 SDK or later

### Steps

```bash
# 1. Clone the repo
git clone https://github.com/arshawnarbabi/LocalNotch.git
cd LocalNotch

# 2. Build and bundle (recommended)
./scripts/release.sh

# This runs:
#   swift build -c release --arch arm64
#   Assembles LocalNotch.app under .build/staging/
#   Ad-hoc signs the bundle (no Apple Developer account needed)
#   Creates LocalNotch.zip in the repo root

# 3. Install
unzip LocalNotch.zip -d /Applications/
xattr -dr com.apple.quarantine /Applications/LocalNotch.app   # clear Gatekeeper quarantine (see Option A → step 3)
```

Or, if you only want the binary without a zip:

```bash
swift build -c release --arch arm64
# Binary is at .build/release/LocalNotch
```

### What the release script does

1. Runs `swift build -c release --arch arm64`
2. Creates `.build/staging/LocalNotch.app/Contents/{MacOS,Resources}/`
3. Copies the binary and `AppIcon.icns`
4. Writes `Info.plist` with the bundle ID (`com.localnotch`), version, and `NSScreenCaptureUsageDescription`
5. Ad-hoc signs with `codesign --force --deep --sign -`
6. Verifies the app is signed as `com.localnotch` with an identifier-based designated requirement, not a cdhash-based one
7. Zips the `.app` bundle

### Dependencies (resolved automatically by Swift Package Manager)

| Package | Version | Purpose |
|---|---|---|
| [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) | ≥ 1.0.0 | The notch panel framework |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | ≥ 2.4.0 | Markdown rendering in responses |

---

## Architecture Overview

For contributors and the curious. The app is an `NSApplication` with no Dock icon (`LSUIElement = true`).

```
main.swift
  └── AppDelegate (NSApplicationDelegate)
        ├── DynamicNotch<…>           — notch panel, hover detection, expand/compact
        │     └── NotchContentView    — reactive height wrapper
        │           └── ChatView      — all UI driven by chatPhase enum
        │                 ├── WelcomeView         — idle: greeting + weather/time
        │                 ├── searchBadge()       — web search indicator
        │                 ├── ImageProcessingDots — vision processing indicator
        │                 ├── responseScrollView  — streaming markdown response
        │                 ├── HistoryView         — chat history panel
        │                 ├── AgentModeView       — full agent panel (orb + history tabs)
        │                 │     ├── PearlescentOrb     — animated multi-layer gradient orb
        │                 │     └── AgentHistoryView   — Chat + Actions tabs
        │                 └── inputArea           — pill input + capture + orb buttons
        ├── AgentGlowWindow           — NSWindow at .screenSaver, full-screen edge glow
        ├── NSStatusItem              — menu bar sparkle icon → Settings / Quit
        └── NSWindow (settingsWindow) — SettingsView, 360×480, dark
              └── SettingsView        — 5 sections: Models, Agent, Web Search, Personality, About

State layer:
  ChatState          — @Published: currentResponse, isLoading, isSearching,
                        isProcessingImage, chatHistory, capturedImage, lastSearchQuery
  AppSettings        — @Published UserDefaults-backed singleton;
                        agentVerifiedModel gate controls orb button visibility
  AgentRunner        — @MainActor ObservableObject; A–H state machine (welcome / idle /
                        running / paused / finished / forceStopped / clarifying / approving)

Services:
  OllamaAPI          — AsyncThrowingStream<String> streaming chat via /api/chat;
                        contextLengthFor() for agent context-window tracking
  BraveSearchService — Brave /api/v1/web/search, returns formatted result block
  WeatherService     — wttr.in polling every 10 min
  AgentTools         — 9 file-system tools: read_file, write_file, list_directory,
                        move_item, copy_item, create_directory, delete_item,
                        find_files, run_shell (always requires approval)
```

### Key design decisions

- **`chatPhase` enum** — a single enum (`idle / searching / processingImage / responding / erasing`) drives all content-area transitions cleanly, eliminating impossible state combinations.
- **Debounced hover** — the notch expand/compact is debounced with a 200ms grace period to prevent layout-recalculation flicker from causing a race condition between `expand()` and `compact()`.
- **Non-overridable system prompt preamble** — web search capability declarations are prepended in `ChatState.prepareForSend()`, not in the user-editable system prompt, so models can't be talked out of acknowledging search results.
- **History sync on search** — after building the augmented message (user text + `<web_search>` block), `updateLastUserContent()` writes the full augmented string back into the conversation history so follow-up turns see the same context the model saw.
- **SCScreenshotManager + identifier-based designated requirement** — the release script pins the codesign designated requirement to the bundle identifier (`com.localnotch`) rather than letting it default to a cdhash. macOS TCC keys Screen Recording permission to the DR, so ad-hoc re-signed builds don't lose the grant each time. The release script now fails if the packaged app has the wrong identifier, a cdhash-based requirement, or an unsealed `Info.plist`. `CGWindowListCreateImage` was removed — it is fully obsoleted on macOS 15+.
- **Vision detection** — `OllamaTagsResponse.Model.isVisionCapable` checks the model's `families` metadata for CLIP, mllama, and moondream families, plus name-based heuristics for LLaVA and `-vl` variants.
- **`agentVerifiedModel` gate** — a persisted `@Published String` in `AppSettings` that is set only when a smoke test passes for a specific model name. The orb button in the chat input area observes this property, so it appears only when the configured agent model has been verified. Clearing or changing the model clears the gate.
- **Agent context-window tracking** — `OllamaAPI.contextLengthFor()` uses flexible suffix matching (`*.context_length`) instead of the hardcoded `llama.context_length` key, so it works with DeepSeek-R1, QwQ, and other non-Llama model families.
- **Orb position animation** — `matchedGeometryEffect` was avoided because it requires both views to coexist in the hierarchy simultaneously. Instead, `GeometryReader` + `.position(x:y:)` animates a single orb view from the idle center position to a small corner position, giving a smooth spring transition without dual-view bookkeeping.

---

## Known Limitations

These are documented accepted limitations for the v0.2.0-beta release.

| Limitation | Notes |
|---|---|
| **Text and image input only** | No voice, audio, file, or PDF attachments. Image input is via the in-app screenshot button only. |
| **Single-display capture** | The screenshot button captures only the main display. |
| **No conversation persistence** | Chat history lives in memory. Quitting the app loses it. |
| **No auto-update** | Check [Releases](https://github.com/arshawnarbabi/LocalNotch/releases) manually. |
| **Screen Recording awareness prompt** | macOS 15.0 (Sequoia) re-prompts for Screen Recording permission approximately once a month for non-notarized apps. macOS 15.1 and later (including macOS 26 Tahoe) reduced this further — prompts become less frequent the more regularly you use the app. Persistent prompts on every capture were fixed in v0.1.1-beta by stabilizing the app's signing identity; occasional macOS awareness prompts remain a system policy for non-notarized apps. |
| **Apple Silicon only** | Intel Macs are not supported. |
| **Localhost Ollama only** | Remote or custom-URL Ollama instances are not supported in v0.1. |
| **API key in UserDefaults** | The Brave Search API key is stored in `UserDefaults`, not in Keychain. It is stored locally on your machine and never transmitted anywhere. |
| **Response text is not selectable** | AI responses are rendered via MarkdownUI using SwiftUI `Text` views without `.textSelection(.enabled)`. You cannot highlight or copy text from a response in v0.1. |
| **Chat reasoning tokens suppressed** | Regular *chat* requests are sent with `think: false` (final answer only). *Agent Mode* runs with `think: true` so the reasoning model can plan its tool use; its reasoning trace is hidden by default and can be revealed via **Settings → Agent**. |
| **Weather is Fahrenheit only** | Temperature values from wttr.in are displayed in °F. There is no Celsius toggle in v0.1. |
| **Agent Mode: file-system only** | The agent works only with the local file system (read, write, move, copy, rename, create, delete, search). It cannot run shell commands, browse the web, call external APIs, or control other apps. |
| **Agent Mode: may miss an item on large multi-file tasks** | On tasks spanning many files, the local reasoning model occasionally acts on a subset (e.g. 3 of 4) and reports completion. Spot-check the agent's work on big batches; a more capable model reduces this. |
| **Agent Mode: auto-approve bypasses prompts** | The optional *Auto-approve* toggle (**Settings → Agent**, off by default) lets the agent perform destructive and bulk actions without asking. Combined with *no undo* above, enable it deliberately. |
| **Agent Mode: no undo** | File operations (write, move, delete) performed by the agent are not undone when you force-stop. Deleted files are moved to Trash; other operations are permanent. |
| **Agent Mode: no multi-step rollback** | If a task fails mid-way, previously completed steps are not rolled back. Review the Actions tab to see what was completed before the failure. |
| **Agent Mode: single active task** | Only one agent task can run at a time. Starting a new task while one is in progress is a no-op; force-stop the current task first. |
| **Agent Mode: Ollama 0.4+ required** | Agent Mode requires Ollama 0.4.0 or later for streaming tool-call support. Earlier versions will fail the smoke test. |

---

## FAQ & Troubleshooting

### "Apple could not verify…" / "cannot be opened because the developer cannot be verified"

This is Gatekeeper blocking a downloaded app that's ad-hoc signed and not notarized (a paid Apple Developer ID would be needed to make this prompt disappear). It's expected — **don't just double-click.** Two ways past it:

1. **Terminal (recommended).** Move `LocalNotch.app` into `/Applications`, then clear the quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/LocalNotch.app
   ```

   This also prevents **App Translocation** — macOS running a quarantined app from a random read-only path, which would break LocalNotch's **Screen Recording** permission. (Move the app to `/Applications` *before* first launch for the same reason.)
2. **System Settings.** Try to open it once (let it get blocked), then go to **System Settings → Privacy & Security**, find the "LocalNotch was blocked" notice, and click **Open Anyway**. On macOS 15 Sequoia and 26 Tahoe the old right-click → Open trick no longer works for unnotarized apps.

You only need to do this once.

---

### The notch panel doesn't appear / nothing happens when I hover

- LocalNotch requires a Mac with a **physical notch** in the display (MacBook Pro 14"/16" from 2021+, MacBook Air M2/M3/M4). It does not work on external monitors or Macs without a notch.
- Make sure the app is running — look for the sparkle (✦) icon in your menu bar.
- If you have a custom notch tool or utility installed (TopNotch, NotchNook, etc.), they may conflict. Try quitting other notch apps.

---

### Ollama is not detected / "Ollama not found" during onboarding

- Open the Ollama app — its menu bar icon must be visible and active.
- Confirm Ollama is responding: open Terminal and run `curl http://localhost:11434/api/tags` — you should get a JSON response.
- If Ollama starts but LocalNotch still doesn't detect it, click **Check again** on the onboarding screen.

---

### "No model configured. Open Settings (⌘,) to choose one."

You either skipped the text model step in onboarding or the model name was cleared. Open **Settings → Models** and pick a text model from the dropdown.

---

### The model loads slowly or crashes with a Metal error

Your GPU does not have enough VRAM/unified memory for the model you selected. Try a smaller or differently-quantized variant:

```bash
# Instead of gemma3:12b, try:
ollama pull gemma3:12b:q4_0
# Or a smaller model:
ollama pull gemma3:4b
```

This is an Ollama + hardware constraint, not a LocalNotch issue.

---

### Web search doesn't trigger / the model answers from training data instead

1. **Check the API key.** Open **Settings → Web Search**. If the status line says "No key set — web search disabled," paste your Brave key. Make sure there are no leading or trailing spaces.
2. **Check your Brave quota.** Log into [api.search.brave.com](https://api.search.brave.com) and verify you haven't exhausted your 1,000 free monthly queries.
3. **Use an explicit trigger.** Try phrasing your query as "search the web for [topic]" or "look up [topic]" — Layer 1 catches these instantly without relying on the LLM classifier.
4. **Rebuild if you recently updated.** If you built from source, rebuild with `./scripts/release.sh` and reinstall. A stale binary in memory may not have the latest search logic.

---

### The model says "I did not perform a web search" even though the badge appeared

This means the model's training strongly overrides in-context instructions. Ensure you're running the latest build (the web search preamble and XML injection format are required). If this happens after a fresh build, try resetting the system prompt in **Settings → Personality → Reset to default** — an old custom prompt may lack the necessary web search instructions.

---

### Screen Recording permission prompt keeps reappearing

If this happens on every capture, install v0.1.1-beta or later. Earlier or incorrectly copied builds could be signed with a cdhash-based identity, which made macOS treat each rebuild as a different app even when **Screen & System Audio Recording** was toggled on.

After installing v0.1.1-beta or later:

1. Make sure there is only one app at `/Applications/LocalNotch.app` — not a nested `/Applications/LocalNotch.app/LocalNotch.app`.
2. Quit and relaunch LocalNotch after granting Screen Recording permission.
3. If needed, toggle LocalNotch off and on once in **System Settings → Privacy & Security → Screen & System Audio Recording**.

On macOS 15 and later, non-notarized apps may still receive occasional system awareness prompts. On macOS 15.0 (Sequoia) this was approximately monthly; on macOS 15.1 and later, including macOS 26 Tahoe, prompts become less frequent with regular use. When an occasional prompt appears, click **Allow** again.

Screenshot diagnostics are written to `~/Library/Logs/LocalNotch/screen-capture.log` to help debug future ScreenCaptureKit failures without showing extra UI.

---

### The camera button doesn't appear

The camera button only appears when the input area is **expanded** (i.e., when you're hovering the input pill). Hover the pill first, then look for the camera icon to the right.

---

### I took a screenshot but the vision model doesn't see it / responds with just text

- Make sure you have a vision model selected in **Settings → Models → Vision model**.
- Verify the vision model is loaded by checking `ollama list` in Terminal.
- If your text model is multimodal (e.g. Llama 3.2 Vision), it may be selected for both text and vision — that's fine; the same model handles both.

---

### Chat history is empty after I relaunch the app

By design. Conversation history is stored in memory only and is not persisted to disk. This is a v0.1 limitation. All prior turns are lost when you quit.

---

### I can't select or copy text from the AI's response

Known limitation in v0.1. Responses are rendered via MarkdownUI without text selection enabled, so standard click-and-drag or ⌘A / ⌘C does not work on response text. As a workaround, ask the model to repeat the specific content you need in the input field, where you can copy it freely. This will be addressed in a future release.

---

### My reasoning model (QwQ, DeepSeek-R1, etc.) isn't showing its thinking steps

By design. All Ollama requests are sent with `think: false`, which suppresses chain-of-thought / reasoning token output and returns only the final answer. LocalNotch is built for fast, lightweight responses — the panel is too compact to usefully display long reasoning traces. This may become configurable in a future release.

---

### I want to run onboarding again to change my model or name

Go to **Settings → About → Show onboarding again**.

---

## Credits

- [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) by Kai — the notch panel framework (MIT)
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) by Guillermo Gonzalez — Markdown rendering (MIT)
- [Brave Search API](https://api.search.brave.com) — optional live web search
- [wttr.in](https://wttr.in) — anonymous weather data
- [NotchNook](https://lo.cafe/notchnook) by lo.cafe — original inspiration for using the MacBook notch as a productive UI surface; the NotchNook app icon also served as design inspiration for the LocalNotch app icon

---

## License

MIT — see [LICENSE](LICENSE).
