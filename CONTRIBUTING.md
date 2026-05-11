# Contributing to LocalNotch

Thanks for your interest. This is a small project — contributions are welcome, but please read this first.

## Before you open a PR

- Check the open issues to see if your idea or bug is already being tracked.
- For anything beyond a small bug fix, open an issue first to discuss. This avoids wasted effort on PRs that won't be merged.

## Building from source

**Requirements:** macOS 14+, Apple Silicon Mac, Xcode 15+ (for Swift toolchain), [Ollama](https://ollama.com) installed.

```bash
git clone https://github.com/s24b/LocalNotch.git
cd LocalNotch
swift build
```

For a release build:

```bash
swift build -c release --arch arm64
```

See `scripts/release.sh` for the full bundle + signing workflow.

## Code style

- Swift 6, strict concurrency. All state that touches the UI must be `@MainActor`.
- No new dependencies without discussion — the dependency surface is intentionally small.
- Match the existing design language exactly: `GlassPillModifier`, `GlassSphereModifier`, `AlwaysActiveHoverDetector`, spring animations. No native macOS form controls in new UI.
- Default to writing no comments. Only add one when the *why* is genuinely non-obvious.

## Pull request checklist

- Builds cleanly (`swift build -c release`)
- Tested on macOS 14 or 15 if you have access (or note that you don't)
- No hardcoded personal data, API keys, or model names
- UI changes include a screenshot in the PR description
- `CHANGELOG.md` updated if user-facing

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Include your macOS version, Ollama version, and the models you have installed — most issues are model- or permission-specific.
