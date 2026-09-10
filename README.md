# NotchNotch

A refined MacBook Pro notch companion panel for macOS. Transforms the hardware notch into an interactive productivity dynamic island — with media controls, drop shelf, clipboard history, calendar schedule reminders, and real-time AI Agent lifecycle monitoring.

![macOS 13+](https://img.shields.io/badge/macOS-13.0%2B-blue?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)
![Xcode 16+](https://img.shields.io/badge/Xcode-16%2B-blue?logo=xcode)
![License](https://img.shields.io/badge/License-Proprietary-lightgrey)

---

## ✨ Features

- **Dynamic Notch HUD**:
  - Native volume & display brightness indicators seamlessly extending from the physical notch cutout without obstructing the camera or status bar.
  - Interactive schedule start/end reminders with instant click-to-expand action.
  - Real-time AI agent status banners (Waiting for input, subagent active, task completed).

- **Media Player (Now Playing)**:
  - Supports Apple Music and Spotify via low-overhead AppleScript bridge.
  - Displays album artwork, animated sound wave visualizer, track titles, and transport controls.

- **Drop Shelf**:
  - Drag and drop files directly onto the notch to temporarily stage them.
  - Quick share, copy, or drag out to any folder, application, or terminal.

- **Clipboard History**:
  - Automatic clipboard history tracking with customizable retention (5 to 20 items).
  - One-click copy, individual item removal, and full history clear.

- **Calendar Schedule Timeline**:
  - Live timeline ruler showing elapsed and remaining meeting progress.
  - Configurable advance reminders (5, 10, 15, 30 minutes before start / 5, 10, 15 minutes before end).

- **AI Agent Lifecycle Integration**:
  - Real-time detection of local CLI agents: **Claude Code**, **Antigravity**, **Codex**, **OpenCode**, and **Aider**.
  - Lightweight embedded HTTP server (`127.0.0.1:7823/event`) for millisecond-level lifecycle webhook ingestion.
  - Deep ancestor process tree analysis to automatically locate and focus the parent terminal window (Ghostty, Zed ACP, iTerm, Terminal, Warp, VS Code).
  - Fully toggleable in Settings with zero background overhead when disabled.

- **Native macOS Experience**:
  - Designed for Apple Silicon ProMotion displays with fluid 120Hz spring physics.
  - Dedicated native Settings window.
  - Launch at login support via `SMAppService`.
  - Multi-display and notch geometry dynamic re-detection.

---

## 🚀 Installation

### Via Homebrew

```bash
# Add the JianyueLab tap
brew tap JianyueLab/tap

# Install NotchNotch
brew install --cask jianyuelab/tap/notchnotch
# or install formula
brew install jianyuelab/tap/notchnotch
```

### Build from Source

```bash
git clone https://github.com/JianyueLab-Org/notch.git
cd notch

# Build release application
xcodebuild -scheme NotchNotch -configuration Release build
```

The compiled application will be in `./build` or `~/Library/Developer/Xcode/DerivedData/`. Copy `NotchNotch.app` to `/Applications/`.

---

## ⚙️ Requirements

- macOS 13.0 (Ventura) or later
- Designed for MacBook Pro with notch (14" / 16", M1/M2/M3/M4), with fallback support for notchless external displays

---

## 📄 License

© 2026 JianyueLab LTD. All Rights Reserved.
