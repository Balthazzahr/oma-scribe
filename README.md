# omaSCRIBE

> **Privacy-First Meeting Recorder, Speaker-Diarized Verbatim Transcriber & 1-Click Google Gemini Web Integration for Omarchy Linux Desktop (Quickshell).**

[![Omarchy Plugin](https://img.shields.io/badge/Omarchy-Plugin-blue.svg)](https://omarchyplugins.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Arch%20Linux%20%2F%20PipeWire-orange.svg)](#requirements)

**omaSCRIBE** is a lightweight, privacy-focused audio recording and transcription widget for the Omarchy Linux desktop. It captures dual-channel online meetings (Microsoft Teams, Zoom, Google Meet, Signal) and voice memos directly from your local PipeWire / PulseAudio server, produces speaker-attributed verbatim transcripts formatted with natural conversational paragraphs, and provides a 1-click pipeline to generate executive summaries in **Google Gemini Web**.

---

## What's New in v1.1.0

### 1. Speaker Attribution & Natural Dialogue Paragraphing
- **Accurate Speaker Diarization**: Leverages high-confidence conversational context, greeting cues, and attendee lists to attribute dialogue turns (`[MM:SS] - Speaker - Dialogue`).
- **Safe Fallback**: Unlisted or ambiguous speakers automatically default to `Unknown Male Speaker`, `Unknown Female Speaker`, or `Unknown Speaker`.
- **Readable Paragraphs**: Long monologues and continuous turns are automatically formatted into readable, natural paragraphs instead of chopped-up fragments.

### 2. 1-Click Google Gemini Web Summarization (`✦ Gemini Web`)
- Generates a structured executive prompt containing the meeting title, attendees, and full verbatim transcript.
- Automatically copies the prompt to your clipboard (`wl-copy`) and opens [Google Gemini Web](https://gemini.google.com/app) in your default browser.
- Simply paste (`Ctrl + V`) into Gemini to produce in-depth executive summaries, action item tables, and key decision logs with zero API rate limits or costs.

### 3. Native Obsidian & Yazi Desktop Integrations
- **Obsidian (`obsidian://open`)**: 1-click `[ 󰏫 Open ]` button in the transcript reader navigates directly to the transcript in your Obsidian vault.
- **Yazi File Manager**: 1-click `[ 󰉋 Folder ]` button opens the meeting directory directly in the **Yazi** terminal file manager with `transcript.md` focused and selected.
- **Auto-Dismiss**: Launching Obsidian or Yazi automatically dismisses the Quickshell popup panel.

### 4. Pure JetBrainsMono Nerd Font & Native Omarchy Theming
- Standardized all UI glyphs on native **JetBrainsMono Nerd Font** (`\udb81\uded3`, `\ued03`, `󰋋`, `󰔊`, `󰆏`, `󰏫`, `󰉋`, `󰆴`, `󰁍`, `✦`).
- Fully integrated with Omarchy theme tokens (`Color.background`, `Color.foreground`, `Color.accent`, `Color.muted`, `Color.urgent`).
- Animated feather quill (`\udb81\uded3`) indicator with live recording timer.

---

## Features

- **Dual-Channel Online Meeting Capture**: Simultaneously records local microphone and system audio (`default.monitor`) so all remote participants are captured with crystal clarity without requiring meeting bots or browser extensions.
- **Voice Memo Mode**: 1-click solo dictation capturing your microphone for quick thoughts, ideas, and reminders.
- **Voice-Optimized Audio (`24k VOIP Opus`)**: Compresses voice recordings by ~75–80% (~8–10MB per hour) for rapid uploads without losing transcription accuracy.
- **Clean File Storage**: Saves every recording into a dedicated, clean folder under `~/Documents/Notes/Audio Notes/<Title> - <YYYY-MM-DD> - <h-mma>/` containing:
  - `recording.opus` (Voice-optimized audio)
  - `transcript.md` (Speaker-attributed verbatim transcript)
  - `.metadata.json` (Meeting title, attendees, topics, and timestamps)
- **Top Bar Integration**:
  - Live duration indicator during recordings.
  - Right-click quick-toggle recording.
  - Animated transcription indicator.

---

## Requirements

Oma Scribe uses standard Linux tools available by default on Arch Linux / Omarchy:

- **PipeWire / PulseAudio** with `ffmpeg` (for system loopback & microphone capture)
- **Python 3** (standard library only; no external pip dependencies required)
- **Quickshell / Omarchy desktop**
- *(Optional)* **Obsidian** & **Yazi** for native note and file browsing

---

## Installation

### Option 1: Via Omarchy Plugin Manager
```bash
omarchy plugin install balthazzahr.oma-scribe
```

### Option 2: Manual Installation from Git
```bash
git clone https://github.com/Balthazzahr/oma-scribe.git ~/.config/omarchy/plugins/balthazzahr.oma-scribe
omarchy-restart-shell
```

---

## Removal / Uninstallation

### Option 1: Via Omarchy Plugin Manager
```bash
omarchy plugin uninstall balthazzahr.oma-scribe
```

### Option 2: Manual Removal
```bash
rm -rf ~/.config/omarchy/plugins/balthazzahr.oma-scribe
omarchy-restart-shell
```

---

## Groq Cloud Setup

Open the **Settings** tab in Oma Scribe to configure your Groq API Key:

1. Visit [console.groq.com](https://console.groq.com) and sign in (Free tier, no credit card required).
2. Click **API Keys** in the left sidebar $\rightarrow$ **Create API Key**.
3. Paste the key (`gsk_...`) into Oma Scribe settings.
4. Save Settings.

---

## Keyboard & Mouse Controls

- **Left-Click Top Bar Icon (`\udb81\uded3` / `\ued03`)**: Opens the Oma Scribe popup window.
- **Right-Click Top Bar Icon**: Instant Start / Stop recording toggle.
- **Tab Key Navigation**: Cycle through Title $\rightarrow$ Topics $\rightarrow$ Attendees in the pre-meeting form.

---

## Privacy & Security

- **Invisible in Meetings**: Oma Scribe records local audio directly from your Linux sound server. Meeting platforms (Teams, Zoom, Google Meet) cannot detect that a recording is running.
- **Zero Hard-Coded Keys**: All API keys and preferences are stored locally in your private `~/.config/omarchy/audio_notes.json`.
- **Local Storage**: All recordings and transcripts reside strictly on your local disk (`~/Documents/Notes/Audio Notes/`).

---

## License

This project is licensed under the [MIT License](LICENSE) - see the LICENSE file for details.

Developed with care for the [Omarchy](https://omarchy.org) / Arch Linux community by **[@Balthazzahr](https://github.com/Balthazzahr)**.
