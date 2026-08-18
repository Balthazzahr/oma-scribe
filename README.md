# omaSCRIBE

> **Smart Meeting Recorder, Verbatim Transcriber & AI Structured Notes Synthesizer for Omarchy Linux Desktop (Quickshell).**

[![Omarchy Plugin](https://img.shields.io/badge/Omarchy-Plugin-blue.svg)](https://omarchyplugins.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Arch%20Linux%20%2F%20PipeWire-orange.svg)](#requirements)

**omaSCRIBE** is an intelligent, privacy-first audio recording and note-taking widget for the Omarchy Linux desktop. It captures dual-channel online meetings (Microsoft Teams, Zoom, Google Meet, Signal) and voice memos directly from your local PipeWire / PulseAudio server, transcribes verbatim dialog with speaker identification, and generates structured executive markdown notes.

---

## Release Notes: Complete Visual & Architectural Overhaul

### 1. Pure JetBrainsMono Nerd Font & Zero Emojis
- Standardized all UI glyphs on native **JetBrainsMono Nerd Font** (`\ued03`, `󰎚`, `󰒓`, `󱐋`, `󰋋`, `󰔊`, `󰆏`, `󰏫`, `󰉋`, `󰅖`, `󰆓`, `󰁍`).
- Zero emoji glyphs across all controls, status badges, and notifications.

### 2. Native Omarchy Theme Colors
- Fully integrated with Omarchy theme tokens (`Color.background`, `Color.foreground`, `Color.accent`, `Color.muted`, `Color.urgent`, `Util.alpha()`).
- Automatically adapts to any desktop theme palette (Catppuccin, Tokyo Night, Gruvbox, Nord, Solarized, etc.).

### 3. Integrated In-App Note & Verbatim Transcript Reader
- **Direct In-App Reading**: Click any meeting in your library to read the generated executive summary and verbatim dialog directly inside Oma Scribe.
- **Dual Sub-Tabs**:
  - `󰎚 Notes`: Structured executive summary, topics discussed, decision log, and markdown action items table.
  - `󰔊 Transcript`: Timestamped verbatim dialog (`[HH:MM:SS] Speaker: dialog`).
- **1-Click Clipboard Copy**: Instantly copy formatted notes or transcripts with real-time toast confirmation.
- **Desktop Actions**: Quick buttons to open the raw files in your default markdown editor (`omarchy-launch-editor` / `code`) or file manager.

### 4. High-Performance Groq Cloud LPU Pipeline
- **Whisper Large v3 (Audio)**: Transcribes 30-minute meetings in **under 8 seconds** on Groq LPUs.
- **Map-Reduce Section Synthesis**: Automatically chunks transcripts over 18,000 characters into parallel sections, eliminating Tokens-Per-Minute (TPM) rate limit errors on long meetings.
- **Immediate Transcript Save**: `transcript.md` is written to disk immediately after Whisper completes so dialog is never lost.
- **Dynamic Model Selection**: Filters out security classifiers, guardrails, and speech models, dynamically selecting the highest-performing chat LLMs available.

### 5. Streamlined Controls & Form Handling
- **Icon-Only Bar Widget**: Displays the studio microphone (`\ued03`) with active timer during recordings, remaining minimal when idle.
- **Clean Attendees Input**: Disappearing instruction placeholder allowing flexible attendee entry with host and role descriptors.
- **Non-Crushed Settings Layout**: Responsive pill selectors for document formats (`.md`, `.txt`, `.html`) and voice audio codecs (`Opus`, `AAC`, `MP3`).

---

## Features

- **Dual-Channel Online Meeting Capture**: Simultaneously records local microphone and system audio (`default.monitor`) so all remote participants are captured with crystal clarity without requiring meeting bots or browser extensions.
- **Voice Memo Mode**: 1-click solo dictation capturing your microphone for thoughts, ideas, and reminders.
- **Voice-Optimized Audio (`24k VOIP Opus`)**: Compresses voice recordings by ~75–80% (~8–10MB per hour) for rapid uploads without losing transcription accuracy.
- **Organized Note Storage**: Saves every recording into a dedicated, clean folder under `~/Documents/AudioNotes/<Title> - <YYYY-MM-DD> - <h-mma>/` containing:
  - `recording.opus` (Voice-optimized audio)
  - `notes.md` (Executive Summary, Key Decisions, Action Items with Owners, Topics Discussed)
  - `transcript.md` (Pure timestamped verbatim transcript: `[HH:MM:SS] Speaker: text`)
- **Desktop Integration**:
  - Top bar live duration indicator and right-click quick-toggle recording.
  - Native Linux desktop notifications on recording start, completion, and transcription ready.
  - 1-click open in default markdown editor or file manager.

---

## Requirements

Oma Scribe uses standard Linux tools available by default on Arch Linux / Omarchy:

- **PipeWire / PulseAudio** with `ffmpeg` (for system loopback & microphone capture)
- **Python 3** (standard library only; no external pip dependencies required)
- **Quickshell / Omarchy desktop**

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

- **Left-Click Top Bar Icon (`\ued03`)**: Opens the Oma Scribe popup window.
- **Right-Click Top Bar Icon**: Instant Start / Stop recording toggle.
- **Tab Key Navigation**: Cycle through Title $\rightarrow$ Topics $\rightarrow$ Attendees in the pre-meeting form.

---

## Privacy & Security

- **Invisible in Meetings**: Oma Scribe records local audio directly from your Linux sound server. Meeting platforms (Teams, Zoom, Google Meet) cannot detect that a recording is running.
- **Zero Hard-Coded Keys**: All API keys and preferences are stored locally in your private `~/.config/omarchy/audio_notes.json`.
- **Local Storage**: All recordings and notes reside strictly on your local disk (`~/Documents/AudioNotes/`).

---

## License

This project is licensed under the [MIT License](LICENSE) - see the LICENSE file for details.

Developed with care for the [Omarchy](https://omarchy.org) / Arch Linux community by **[@Balthazzahr](https://github.com/Balthazzahr)**.
