# LocalNotch

An AI assistant that lives in your Mac's notch. Hover to open, type to ask anything. Fully local — powered by [Ollama](https://ollama.com), nothing leaves your machine.

> **Beta (v0.1.0)** — See [Known limitations](#known-limitations) before installing.

---

## Features

- **Lives in the notch** — expands on hover, collapses on mouse-out, stays out of your way
- **100% local inference** — runs any model you have installed in Ollama
- **Vision** — long-press the camera button to capture your screen and ask questions about it
- **Optional web search** — bring your own Brave Search API key; if absent, web search is silently disabled
- **Guided onboarding** — detects Ollama on first launch, walks you through model selection
- **In-panel Settings** — switch models, update your API key, customize the system prompt, all without leaving the notch
- **Liquid Glass UI** — native macOS 26 Tahoe glass effect; clean fallback on macOS 14/15

---

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon Mac (M1 or newer)
- [Ollama](https://ollama.com) installed and running

---

## Installation

### Option A — Download (recommended)

1. Download `LocalNotch.zip` from [Releases](https://github.com/s24b/LocalNotch/releases)
2. Unzip and drag `LocalNotch.app` to your Applications folder
3. **Right-click → Open** the first time (required to bypass Gatekeeper — the app is unsigned)
4. Grant Screen Recording permission when prompted

### Option B — Build from source

```bash
git clone https://github.com/s24b/LocalNotch.git
cd LocalNotch
swift build -c release --arch arm64
```

Then run `scripts/release.sh` to bundle the binary into a proper `.app`.

---

## Setup

### 1. Install Ollama

Download from [ollama.com](https://ollama.com) and make sure it's running.

### 2. Pull a model

LocalNotch works with any model Ollama supports. Some starting points:

```bash
# Text (fast, good quality)
ollama pull gemma3:4b

# Text (higher quality)
ollama pull gemma3:12b

# Vision (for screenshot analysis)
ollama pull llama3.2-vision
```

> **Note on model compatibility:** If a model fails to load (Metal error, out of memory), try a smaller or differently-quantized variant — e.g. `ollama pull modelname:q4_0`. Compatibility depends on your GPU and available RAM. This is an Ollama + hardware issue, not a LocalNotch issue.

### 3. Open LocalNotch

On first launch, the onboarding flow walks you through picking your models and optionally adding a Brave Search API key.

### 4. (Optional) Enable web search

Sign up for a [Brave Search API key](https://api.search.brave.com/register). The free tier provides 1,000 queries/month and requires a credit card on file with Brave.

Add your key in **Settings → Web Search** (open Settings with ⌘, from the menu bar icon).

---

## Privacy

LocalNotch is privacy-first by design:

| What | Where it goes |
|---|---|
| Your messages and AI responses | Nowhere — processed entirely by Ollama on your machine |
| Screenshots | Nowhere — encoded locally and sent only to your local Ollama model |
| Weather | One anonymous request to [wttr.in](https://wttr.in) every 10 minutes using your IP for geolocation. No account, no API key. |
| Web search | Only if you provide a Brave API key — requests go to `api.search.brave.com` under your account |
| Your Brave API key | Stored in `UserDefaults` on your Mac (not in Keychain — v1 limitation) |

No telemetry. No analytics. No crash reporting. No servers operated by us.

---

## Known limitations

These are documented accepted limitations for the v0.1.0 beta:

- **No full-screen Space support.** When another app occupies a macOS full-screen Space, the notch panel's input area doesn't reliably receive click events. Workaround: leave full-screen before using LocalNotch. Root cause is a known interaction between DynamicNotchKit's NSPanel and full-screen Spaces.
- **Text and image input only.** No voice, no audio, no file or PDF attachments. Image input requires the in-app screenshot button.
- **Single-display capture.** The screenshot button captures only the main display.
- **No conversation persistence.** Chat history lives in memory — quitting the app loses it.
- **No auto-update.** Check [Releases](https://github.com/s24b/LocalNotch/releases) manually.
- **Screen Recording re-prompt.** macOS 15 and 26 re-prompt for Screen Recording permission roughly every 7 days for unsigned apps. This is a macOS policy; not fixable without Apple's enterprise entitlements.
- **Apple Silicon only.** Intel Macs are not supported.
- **Localhost Ollama only.** Remote Ollama instances are not supported in v1.

---

## Credits

- [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) by Kai — the notch panel framework (MIT)
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) by Guillermo Gonzalez (MIT)
- [Brave Search API](https://api.search.brave.com) for optional web search

---

## License

MIT — see [LICENSE](LICENSE).
