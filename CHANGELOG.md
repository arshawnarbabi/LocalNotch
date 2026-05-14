# Changelog

## v0.2.0-beta (2026-05-14)

### New: Agent Mode

- **Autonomous file-system agent** — opt-in mode powered by a dedicated local reasoning model (deepseek-r1:7b / :14b, qwq:32b recommended). Describe a file task in natural language; the agent reasons, calls tools, and executes — all on-device.
- **9 file-system tools**: `read_file`, `write_file`, `list_directory`, `move_item`, `copy_item`, `create_directory`, `delete_item`, `find_files`, `run_shell` (always requires approval).
- **A–H state machine**: welcome / idle / running / paused / finished / forceStopped / clarifying / approving — covering pause/resume, per-tool approval requests, and graceful force-stop with last-action reporting.
- **Per-tool approval flow** — two modes: approve all tools, or auto-approve safe tools (only `delete_item` and `run_shell` require confirmation).
- **Pearlescent orb UI** — animated multi-layer gradient orb in the notch panel that repositions from center (idle) to corner (active) with a spring animation. Static mini-orb in the compact notch when agent mode is enabled.
- **Agent history panel** — two-tab view: Chat bubbles (conversation with the model) and Actions (structured log of every tool call, result, and timestamp).
- **Compact notch indicators** — white pulsing dot while agent is running; yellow pulsing dot when the agent needs user attention (clarifying / approving).
- **Screen-edge glow** — full-screen pearlescent edge glow on task start and finish (respects `Reduce Motion`).
- **Context window management** — tracks token usage against the model's context limit; auto-summarizes history at 85% to keep tasks running.
- **agentVerifiedModel gate** — the orb button only appears after a smoke test passes for the configured agent model, preventing startup with an unverified model.
- **Cmd+Q guard** — quitting while the agent is active shows a confirmation dialog describing what will and won't be undone.
- **Onboarding step 7** — optional agent model setup with tiered recommendations and one-click `ollama pull` commands to copy.

### Fixed

- `contextLengthFor()` now uses flexible key-suffix matching instead of the hardcoded `llama.context_length` key — correctly reads context limits for DeepSeek-R1, QwQ, and other non-Llama model families.
- Agent system prompt no longer duplicated on chained tasks (was appended on every `startTask()` call; now only when `messages` is empty).
- `forceStop` bubble now reports the last tool that successfully completed before the stop.

## v0.1.1-beta (2026-05-12)

### Fixed
- Fixed persistent Screen Recording permission prompts caused by unstable ad-hoc signing or malformed installs.
- Hardened the release script so packaging fails if LocalNotch is signed with a cdhash-based designated requirement, the wrong bundle identifier, or an unsealed Info.plist.
- Added quiet screenshot diagnostics at `~/Library/Logs/LocalNotch/screen-capture.log` to make future ScreenCaptureKit failures easier to debug without adding UI.

## v0.1.0-beta (2026-05-11)

Initial public release.

### Features
- Notch-resident AI assistant — hover to expand, type to chat
- Fully local inference via [Ollama](https://ollama.com) — nothing leaves your machine
- Vision support: long-press the camera button to capture a screenshot and ask questions about it
- Optional web search via Brave Search API (user-supplied key)
- In-panel Settings: model picker, API key, display name, custom system prompt
- Guided first-launch onboarding: Ollama detection, model selection, optional Brave key
- JARVIS-toned default system prompt, fully customizable
- Liquid Glass UI on macOS 26 Tahoe; graceful fallback on macOS 14/15
- Chat history panel (in-session only)

### Known limitations
See [README — Known limitations](README.md#known-limitations).
