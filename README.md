# Usageview

**Keep your AI usage limits visible — right in the menu bar.**

Usageview is a lightweight macOS menu bar app that tracks your AI quota across every major provider — so you always know how much you have left and when it resets.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![Latest Release](https://img.shields.io/github/v/release/ayangabryl/Usageview?style=flat-square&label=download&color=brightgreen)](https://github.com/ayangabryl/Usageview/releases/latest)
[![MIT License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

---

## Download

**[⬇ Download the latest release (DMG)](https://github.com/ayangabryl/Usageview/releases/latest)**

1. Download `Usageview-x.x.x.dmg`
2. Open the DMG and drag **Usageview** to your Applications folder
3. Open Usageview — it appears in your menu bar, no Dock icon

> **Requirements:** macOS 14 (Sonoma) or later · Apple Silicon or Intel

---

## Why Usageview?

If you use AI coding tools, you've hit rate limits mid-flow. Usageview sits in your menu bar and shows:

- **How much quota you've used** — per provider, per account
- **When it resets** — countdown timers for each rate window
- **Multiple accounts** — track personal + work accounts side by side
- **Codex account switching** — save sessions and switch between Codex accounts without logging out

No Dock icon. No background noise. Just a glance at your menu bar.

---

## Supported Providers

| Provider | Auth | What You See |
|:---------|:-----|:-------------|
| **Claude** | OAuth or API key | 5-hour + 7-day utilization with reset countdowns |
| **GitHub Copilot** | Device flow sign-in | Premium requests used (e.g. 142/300), reset date |
| **OpenAI / Codex** | OAuth or API key | Plan tier, Codex session switching |
| **Cursor** | Browser cookie | Usage stats and plan info |
| **Gemini** | API key or OAuth | Available models, Pro/Ultra detection |
| **Kimi AI** | API key | Connection status |
| **Kiro** | API key | Connection status |
| **Augment** | API key | Connection status |
| **JetBrains AI** | API key | Connection status |
| **OpenRouter** | API key | Connection status |
| **Zai** | API key | Connection status |

> Want another provider? [Open an issue](https://github.com/ayangabryl/Usageview/issues/new) or submit a PR.

---

## Features

| Feature | Details |
|:--------|:--------|
| Menu bar native | No Dock icon, minimal footprint |
| Multiple accounts | Personal + work accounts per provider |
| Codex account switching | Save sessions, switch without re-authenticating |
| Claude dual windows | 5-hour and 7-day rate limits shown simultaneously |
| Expanded & compact views | Toggle between detailed cards and dense rows |
| Auto-refresh | Configurable: 5m / 15m / 30m / 1h |
| Launch at login | Start with your Mac |
| Secure storage | macOS Keychain with team-bound access groups |
| Over-the-air updates | Built-in updater via Sparkle |
| OAuth + API key | Choose your preferred auth per provider |

---

## Getting Started

1. **Click the menu bar icon** to open Usageview
2. **Add Account** → pick a provider
3. **Sign in** via OAuth or paste an API key
4. **Done** — your usage appears instantly

Switch between **expanded** (detailed cards) and **compact** (dense rows) views with one click.

---

## Build from Source

```bash
git clone https://github.com/ayangabryl/Usageview.git
cd Usageview
open Usageview.xcodeproj
```

Hit **⌘R** in Xcode to build and run. Requires Xcode 16+ with Swift 6.2 toolchain.

---

## Contributing

```bash
git clone https://github.com/ayangabryl/Usageview.git
cd Usageview
make setup    # installs SwiftLint + git hooks (one-time)
make build    # build the project
make lint     # check code style
```

The pre-commit hook runs SwiftLint automatically — no extra steps needed.

---

## License

[MIT](LICENSE) — use it however you want.
