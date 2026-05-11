# LocalNotch — Open-Source Release Plan

The project formerly known as **GemmaNotchKit** will be released as **LocalNotch**, an open-source MIT-licensed macOS menu-bar/notch assistant that talks to a user-supplied local Ollama install. This document is the working plan to get from the current personal-build state to a publishable release.

**Release status: BETA (v0.x).** Known limitations are listed below — these are intentional for the initial release. They are documented up front so users know what to expect; not blockers to publishing.

---

## Known limitations (beta scope)

These are accepted limitations for the first public release. Some may be addressed in later versions, some may never be.

- **No full-screen support.** When another app is in macOS full-screen mode (its own Space), the notch panel's expanded-state input pill and camera button don't reliably receive mouse-down events. Investigated extensively (see commit history); root cause is some interaction between DynamicNotchKit's NSPanel and full-screen Spaces that hover events bypass but click events don't. Workaround: leave full-screen before using the assistant.
- **Text + image input only.** No voice dictation, no audio recording, no file/PDF attachment, no clipboard auto-paste. Image input requires taking a screenshot via the camera button.
- **Single-screen capture.** Screen recording captures only the main display. Multi-monitor users on a secondary display will get the wrong screen.
- **No conversation persistence across launches.** Chat history lives in memory only — quitting the app loses everything.
- **No auto-update.** Users must check GitHub Releases manually for new versions.
- **English-tuned default system prompt.** The JARVIS-inspired default prompt is in English; non-English users will want to customize it in Settings.
- **Periodic screen recording re-prompt.** macOS Sequoia (15) and Tahoe (26) re-prompt every ~7 days for screen recording permission unless an app holds the `com.apple.developer.persistent-content-capture` entitlement (Apple-restricted to enterprise dev accounts). Not fixable without Apple's permission; we'll document it as a known macOS behavior in the README.
- **Apple Silicon only.** Intel Macs are not supported (Ollama itself runs poorly on Intel).
- **Localhost-only Ollama.** Setups with Ollama on a separate machine on the network aren't supported in v1.

These should be listed in the README so first-time users aren't surprised.

---

## Locked-in decisions

| Area | Decision |
|---|---|
| License | MIT (compatible with DynamicNotchKit's MIT) |
| App name | **LocalNotch** (renamed from GemmaNotchKit) |
| Bundle ID | `com.localnotch` |
| GitHub repo | `https://github.com/s24b/LocalNotch` |
| Default system prompt | JARVIS-toned, model-neutral (no identity claim for a specific model) |
| Distribution | Path B — unsigned/ad-hoc-signed `.app` on GitHub Releases + public source. Not paying Apple Developer Program ($99/yr). |
| Model config | Settings UI queries Ollama for installed models, presents dropdowns for text + vision |
| Web search | User-supplied Brave Search API key. If absent, search is silently disabled. No errors. |
| Settings scope (v1) | Models, Brave API key, display name, custom system prompt. **Not** v1: animation tuning, theme toggles, custom triggers. |
| First-launch UX | Guided onboarding screen (detects Ollama install/running, model availability, walks through optional Brave key) |
| macOS minimum | 14 (Sonoma). Liquid Glass UI degrades gracefully on 14/15; full effect on 26+. |
| Settings persistence | `UserDefaults` (no JSON config files in v1) |
| CPU architecture | **Apple Silicon (arm64) only.** Intel Macs not supported — Ollama runs poorly on Intel anyway. |
| Ollama host | **Localhost only** (`http://localhost:11434`). No remote-host setting in v1. |
| App icon | Custom `.icns` designed before v0.1.0-beta release (no generic-icon launches). |

---

## Workstreams

### 1. Rename `GemmaNotchKit` → `LocalNotch`

- [ ] Rename Swift package and executable target in `Package.swift`
- [ ] Rename source folder `Sources/GemmaNotchKit/` → `Sources/LocalNotch/`
- [ ] Update bundle identifier `com.gemmanotchkit` → `com.localnotch` (or `app.localnotch`) throughout codesigning
- [ ] Update `~/Applications/GemmaNotchKit.app` references in any deploy scripts
- [ ] Update `Info.plist` (`CFBundleName`, `CFBundleIdentifier`, `CFBundleExecutable`, usage description)
- [ ] Update status-bar menu title ("Quit Gemma" → "Quit LocalNotch")
- [ ] Update the Markdown theme name (`Theme.gemma`) and any other "gemma" identifiers in code
- [ ] Reset TCC after renaming so the new bundle ID gets a fresh permission grant

### 2. Strip personal / hardcoded values

- [ ] **Brave API key** (currently in `BraveSearchService.swift`): remove, read from `UserDefaults` instead
- [ ] **User name** "Arshawn" in `WelcomeView`: replace with a Settings-driven display name (default to `NSFullUserName()` or system username)
- [ ] **Model names** `gemma4:e2b-nvfp4` / `llama3.2-vision:11b` in `OllamaAPI.swift`: replace static constants with `UserDefaults`-backed values, defaulted to empty until user picks
- [ ] **Code-signing identity** in any deploy scripts: parameterize or document that contributors use their own
- [ ] **Brave API key memory in repo**: ensure the key is purged from git history before publishing (use `git filter-repo` if any commits contain it)

### 3. Settings UI

Settings lives **inside the panel** (replaces the main content, just like the History view does). Drill-down navigation, one screen at a time, with the same fluid slide+fade transitions as onboarding.

- [ ] **Entry point**: add "Settings…" `NSMenuItem` to the status bar menu (above "Quit") with the standard macOS keyboard shortcut **⌘,**. Triggering it expands the notch panel (if collapsed) and swaps the main content for the Settings view.
- [ ] **Top-level list screen**: 4 glass-pill rows stacked vertically, each shows the section name on the left and a `chevron.right` SF symbol on the right. Hover/press feedback identical to other panel buttons.
  - Models · Web Search · Personality · About
- [ ] **Navigation pattern**: tapping a row slides that section's content in from the right (the list slides out to the left). Top-left `chevron.left` back button returns to the list (reverse animation). Top-right `xmark` closes Settings entirely.
- [ ] **Models section**:
  - Queries `GET http://localhost:11434/api/tags` for installed models
  - Two custom glass dropdowns: Text / Vision
  - "Refresh" sphere button to re-query
  - If Ollama isn't running, show a calm error state ("Ollama not detected" + small Retry button) — no scary alerts
- [ ] **Web Search section**:
  - Secure pill text field for Brave Search API key
  - Inline link to brave.com/search/api/
  - Plain-language note: "Free tier: 1,000 queries/month. Requires a credit card on file (Brave's policy, not ours)."
  - Empty key = search silently disabled
- [ ] **Personality section**:
  - Pill text field for display name (defaults to `NSFullUserName()`)
  - Larger rounded-rect text area for custom system prompt
  - Sphere button to "Reset to default" with confirmation feedback (button briefly fills then returns to idle)
- [ ] **About section**:
  - Version (from `Info.plist`)
  - GitHub link (opens in browser via `NSWorkspace.shared.open`)
  - License link → opens the LICENSE file or repo's MIT page
  - "Show onboarding again" sphere button — resets the `onboardingComplete` flag so the user can revisit setup

### 4. Onboarding (first-launch experience)

- [ ] On first launch, check:
  - Is Ollama installed? (probe `http://localhost:11434`)
  - Does the user have any text + vision-capable models?
  - Are display name / system prompt set?
- [ ] If anything missing, show onboarding sheet:
  - Step 1: "Install Ollama" (link to ollama.com, "Check again" button)
  - Step 2: "Pick your models" (dropdowns auto-populated)
  - Step 3: "(Optional) Enable web search" (Brave API key field, with skip)
  - Step 4: "Done — try saying 'hello'"
- [ ] Persist "has-onboarded" flag in `UserDefaults` so it doesn't show again
- [ ] Add a "Show onboarding again" button in Settings → About for users who want to revisit

### 5. Smart-search behavior — verify it works without a key

- [ ] Confirm `decideSearchQuery` returns nil cleanly when no Brave key configured (and the LLM classifier shouldn't even fire in that case — saves a token call)
- [ ] If search is disabled, skip the classifier entirely
- [ ] Document this gracefully — explain in Settings that web search needs a Brave key

### 5.5. App icon (`.icns`)

- [ ] Design a 1024×1024 master icon (could be the sparkles glyph on a notch-shaped background, or something cleaner)
- [ ] Generate the `.icns` at all required sizes (16, 32, 64, 128, 256, 512, 1024 @1x and @2x) via `iconutil`
- [ ] Add `Icon.icns` to `LocalNotch.app/Contents/Resources/`
- [ ] Reference it in `Info.plist` via `CFBundleIconFile`
- [ ] Replace the menu bar SF Symbol with a custom template image if we make one (optional, sparkles is fine)

### 6. Repository setup

- [ ] Create `LICENSE` file with MIT text (your name + 2026)
- [ ] Write `README.md` with:
  - One-paragraph summary + animated GIF/screenshot
  - **⚠ Beta badge / status section** — explicitly call out it's v0.x beta and link to the "Known limitations" subsection
  - **Privacy summary** — what leaves the user's machine and what doesn't:
    - LLM inference: **100% local via Ollama**, nothing sent to a server
    - Weather: anonymous IP-geolocated request to `wttr.in` every 10 min (no API key, no account)
    - Web search: only if the user provides a Brave Search API key — requests go to `api.search.brave.com` under their account; Brave's free tier is **1,000 queries/month** and **requires a credit card on file** (their policy)
    - No telemetry, no analytics, no crash reporting, no servers operated by us
  - Features list
  - **System requirements**: macOS 14+, Apple Silicon Mac, Ollama installed (link), models pulled
  - **Known limitations** section copied from this plan (no full-screen, no voice, single-display capture, no persistence, weekly screen-recording re-prompt, etc.)
  - **Installation** section with both paths:
    - Download from Releases → drag to Applications → right-click → Open (with screenshot of the Gatekeeper dialog)
    - Build from source: `swift build -c release` + signing notes
  - **Requirements** section: macOS 14+, Ollama, recommended models
  - **Setup** section: link to Ollama, recommended `ollama pull` commands, Brave API key signup
  - **Configuration** section: Settings overview
  - **Contributing** section: short
  - **Credits**: DynamicNotchKit, swift-markdown-ui, Brave Search
- [ ] Create `.gitignore` (Swift Package Manager defaults: `.build/`, `.swiftpm/`, `Package.resolved` may stay, `*.xcodeproj/` if any)
- [ ] Add `CHANGELOG.md` for future release notes
- [ ] Take a couple of screenshots / record a 10-second screen capture of the notch in action for the README
- [ ] Add `CONTRIBUTING.md` — short guide for would-be contributors: how to build (`swift build -c release`), code-style notes, how to test, PR description expectations
- [ ] Add `CODE_OF_CONDUCT.md` — use the standard Contributor Covenant v2.1 template (well-known, GitHub recognizes it and shows a badge)
- [ ] Add issue templates in `.github/ISSUE_TEMPLATE/`:
  - `bug_report.md` — fields: macOS version, LocalNotch version, Ollama version, models in use, steps to reproduce, expected vs actual behavior, logs
  - `feature_request.md` — fields: the problem you're solving, proposed solution, alternatives considered
- [ ] (Optional but nice) Add `.github/PULL_REQUEST_TEMPLATE.md` with a small checklist (what changed, tested on which macOS, screenshots if UI change)

### 7. Build & release pipeline (manual for v1)

- [ ] Write a `scripts/release.sh` that:
  - Runs `swift build -c release --arch arm64` (Apple Silicon only)
  - Bundles the binary into `LocalNotch.app/Contents/MacOS/` with Info.plist + Resources (icon)
  - Ad-hoc codesigns (`codesign --force --deep --sign - --identifier app.localnotch`)
  - Zips into `LocalNotch.zip` ready to upload
- [ ] Document the GitHub Release process: tag (e.g., `v0.1.0-beta`) → upload zip → publish, marked as **Pre-release** on GitHub while in beta
- [ ] Document the Gatekeeper "right-click → Open" workflow with a screenshot
- [ ] (Future / stretch) GitHub Actions workflow to automate this on every tag push

### 8. macOS 14/15 compatibility check

- [ ] Verify the Liquid Glass fallbacks render correctly on macOS 14/15 (we already have `#available(macOS 26, *)` branches)
- [ ] Verify `SCScreenshotManager` works on macOS 14 (it should — that's its minimum)
- [ ] Test on macOS 14 if a VM/test machine is available, otherwise rely on user reports

### 9. Quality checks before publishing

- [ ] Search the whole codebase for "Arshawn", "BSA054", `~/bin`, `~/Applications/GemmaNotchKit`, the Apple Dev cert hash, and any other personal identifiers — remove them all
- [ ] `git log` for any commit messages referencing personal data
- [ ] Delete `/tmp/gnk_capture.log` if it exists and ensure no log files get committed
- [ ] Make sure `Package.resolved` either is committed (reproducible builds) or is ignored (faster but less reproducible) — recommend committing it

---

## Version control / backup strategy

**Use `git init` in the `GemmaNotchKit/` folder immediately — do not use a parallel folder copy.**

- `git init` → commit current state as "Initial commit: pre-rename snapshot" → set remote to `https://github.com/s24b/LocalNotch`
- All subsequent changes are tracked granularly; revert any file at any time
- The initial commit serves as the backup; a folder copy adds confusion with no benefit
- Branch `main` is the working branch; create feature branches for large workstreams if desired

---

## Model compatibility

LocalNotch makes no assumptions about which models the user has installed or which quantization their hardware supports. All model selection is user-driven via Settings.

**In-app behavior:**
- Settings → Models queries `GET localhost:11434/api/tags` and shows only installed models in dropdowns
- No model names hardcoded anywhere in the app after Workstream 2
- If a model fails to load (Metal error, OOM, bad quantization), Ollama returns an error in the stream — **surface this error visibly in the chat area** (currently silently dropped); show the raw error text so the user knows what went wrong
- Settings must be accessible without a restart so the user can switch models immediately after an error

**README note (Workstream 6):**
- "If a model fails to load, try a smaller or differently-quantized variant (e.g., `modelname:q4_0`). Compatibility depends on your GPU and available RAM. See the Ollama documentation for model variant guidance."
- Model compatibility is an Ollama + hardware problem, not a LocalNotch problem; we document it, not own it

---

## Order of operations (rough)

1. **Workstream 2** (strip personal data) — non-destructive, can do today
2. **Workstream 3** (settings UI) — once #2 is done, the app needs UI to replace the hardcoded values
3. **Workstream 1** (rename) — once internals are clean, do the full rename pass
4. **Workstream 4** (onboarding) — depends on Settings UI being in place
5. **Workstream 5** (smart-search no-key behavior) — small, fits in alongside #4
6. **Workstream 6** (repo: LICENSE, README, screenshots)
7. **Workstream 7** (release script)
8. **Workstream 8** (compat testing)
9. **Workstream 9** (final scrub)
10. Push to GitHub, create first Release, share

---

## Design language (mandatory for new UI)

**Every new screen — onboarding, settings, any modal — must match the existing notch panel's aesthetic.** This is the "feel" of the app. Reviewers/users should not be able to tell the difference between a screen that's part of the notch panel and a separate window. Treat this as a hard constraint, not a polish item.

### The pieces that define the look

- **Surfaces**: dark (near-black) background, with Liquid Glass overlays on macOS 26 via `.glassEffect(.regular, in: <shape>)`. On macOS 14/15 fall back to a translucent white overlay (e.g., `Color.white.opacity(0.10)` with a `Color.white.opacity(0.15)` 0.5pt stroke). Already abstracted into `GlassPillModifier`, `GlassSphereModifier`, `GlassCircleModifier` — **reuse these, do not create new ad-hoc backgrounds.**
- **Shapes**: rounded everything. Pills for text fields, circles for action buttons, rounded rectangles for containers (corner radius ~12–18pt). No sharp corners anywhere.
- **Typography**: SF system font. White text with deliberate opacity hierarchy:
  - Primary content / active state: `Color.white` at full opacity
  - Secondary content / inactive state: `Color.white.opacity(0.75)` to `0.85`
  - Tertiary / placeholder: `Color.white.opacity(0.35)` to `0.50`
  - Body sizes 12–15pt, headings 22–28pt weight `.medium`/`.semibold`
- **Interactive feedback**: every clickable element must respond visually
  - Hover: `scaleEffect(1.08–1.14)` + `brightness(0.12)`, driven by an `AlwaysActiveHoverDetector`
  - Press: `scaleEffect(0.88)`, springs back on release
  - Always animated with `.spring(response: 0.22–0.25, dampingFraction: 0.65–0.68)`
- **Motion / animations** — this is what gives the app its "fluid" feel:
  - Primary spring: `.spring(response: 0.42, dampingFraction: 0.72)` for layout / state changes
  - Snappier spring: `.spring(response: 0.22, dampingFraction: 0.65)` for hover/press
  - Phase transitions (e.g., between onboarding steps): `.easeInOut(duration: 0.32)` with combined opacity + scale (`.transition(.opacity.combined(with: .scale(scale: 0.97)))`)
  - Loading states: reuse the same dot patterns — single pulsing dot in compact contexts (`ReactiveTypingDots`), three bouncing dots for heavier waits (`ImageProcessingDots`)
- **No sound effects**, no haptics — the visual motion does the work.

### How this applies to onboarding (Workstream 4)

**Onboarding lives INSIDE the notch panel itself — not in a separate window.** The panel becomes the teaching surface. This keeps everything cohesive and uses the small surface deliberately.

- **One thing at a time.** Each step occupies the entire panel content area on its own. Never multiple steps visible simultaneously. The panel stays its normal size (420×300); content adapts.
- **Fluid step transitions.** Going from step N → step N+1 uses a cross-fade with a slight upward slide (e.g., `.transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)).animation(.easeOut(duration: 0.32)), removal: .opacity.combined(with: .offset(y: -12)).animation(.easeIn(duration: 0.24))))`). Outgoing step fades up and out, incoming fades up into place. Never a hard cut.
- **Drives off panel hover.** First launch: the panel auto-expands and stays expanded throughout onboarding (overrides the normal collapse-on-mouse-out behavior — onboarding doesn't dismiss when the user moves the mouse away).
- **Layout per step** (all centered, generous vertical breathing room):
  - **Step 1 — Ollama check**: large white text "Looking for Ollama…" / "Ollama detected ✓" / "Ollama not running" with a single pulsing dot (reuse `ReactiveTypingDots`-style) while probing. If not running, a small pill-shaped link to ollama.com and a "Check again" sphere button.
  - **Step 2 — Pick models**: heading "Choose your models" + two custom glass dropdowns stacked (Text / Vision). Single arrow button at the bottom to continue once both are picked.
  - **Step 3 — Brave key (optional)**: heading "Web search (optional)" + secure pill text field for the key + two arrow buttons side-by-side: Skip / Continue.
  - **Step 4 — Done**: heading "Ready, sir." (or matching the system prompt's tone) + a tiny "Hover here anytime" hint that fades after 2 seconds, then onboarding closes and the normal welcome view appears.
- **Step indicator**: a thin row of 4 tiny horizontal pills along the top of the panel content area — current step opacity 1.0, others 0.35. Click-skip is not supported (steps are sequential).
- **Persistence**: an `onboardingComplete` `UserDefaults` flag set after step 4. Future launches go straight to the normal welcome view.
- **Skip pathway**: a small `Image(systemName: "xmark")` in the top-right corner of the panel content lets users dismiss onboarding entirely. Saves the flag and shows the normal welcome view (with empty model config — they'll see a friendly "Pick a model in Settings" hint).

### How this applies to settings (Workstream 3)

**Settings lives inside the notch panel**, not in a separate window. Same surface, same size, same motion language as the rest of the app.

- Triggered by menu bar "Settings…" / ⌘,. Expands the panel and swaps content to Settings view.
- **Top-level list**: 4 pill rows (Models / Web Search / Personality / About) using `GlassPillModifier`. Each row has hover+press feedback (1.08× scale, 0.88× press) identical to other panel buttons.
- **Drill-down navigation**: tapping a row slides that section in from the right (list slides out to the left); back button reverses the motion. Use SwiftUI `.transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))` driven by the primary spring.
- **Form fields**: text inputs are pills using `GlassPillModifier`; secure entry for the Brave API key; the system-prompt area is a larger rounded rectangle (`RoundedRectangle(cornerRadius: 12)` with the glass treatment).
- **Buttons**: reuse the existing sphere/circle action buttons. No native `Button` style with default chrome.
- **No native macOS form controls** — no default `Picker`, no default `Toggle`. All wrapped/replaced.
- **Close**: small `xmark` sphere in the top-right of the Settings root view. Fades the Settings content out and brings back whatever was in the panel before (welcome screen, response, etc.).

### Acceptance test

When the onboarding/settings windows are open next to the notch panel and a screenshot is taken, the three should look like the same app. If a stranger has to guess "is this one app or two?" they should answer "one."

---

## Welcome panel data sources (already working, just confirm)

The welcome screen on the expanded panel already shows weather + date auto-detected from the user's machine:

- **Date / time**: from `Date()` via SwiftUI `TimelineView` — purely local, no network.
- **Weather**: from `wttr.in/?format=j1` — public no-auth weather service that uses **IP-based geolocation** (approximate, may be wrong if user is on a VPN). No API key, no Apple location permission prompt. The trade-off: the user's IP is sent to wttr.in once every 10 minutes.

To-do for the release:
- [ ] In Settings → Privacy (or just the About tab), document the wttr.in dependency clearly so users on strict-privacy setups know
- [ ] Optionally add a toggle to disable the weather widget entirely (defer to v0.2)

---

## Open questions / future considerations

- **Auto-update**: not in v1. Users get a Watchtower-style "new version available" notification only if you set up Sparkle later.
- **Telemetry**: none. Privacy-first.
- **Multiple search providers**: only Brave for v1. Could add DuckDuckGo / Tavily / Google CSE later.
- **Voice input**: not in v1.
- **Conversation history persistence across launches**: currently in-memory only. Adding disk persistence is a nice-to-have, not blocking.
- **Multi-monitor / external display behavior**: untested.
- **App icon**: needs to be designed (currently uses `sparkles` SF symbol in the status bar — fine for menu-bar icon, but a proper `.icns` for the .app bundle is needed).
