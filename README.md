# 🎙️ Oma Scribe

> **Smart Meeting Recorder, Verbatim Transcriber & AI Structured Notes Synthesizer for Omarchy Linux Desktop (Quickshell).**

[![Omarchy Plugin](https://img.shields.io/badge/Omarchy-Plugin-blue.svg)](https://omarchyplugins.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Arch%20Linux%20%2F%20PipeWire-orange.svg)](#requirements)

**Oma Scribe** is an intelligent, privacy-first audio recording and note-taking widget for the Omarchy Linux desktop. It captures dual-channel online meetings (Microsoft Teams, Zoom, Signal, Google Meet) and voice memos directly from your local PipeWire / PulseAudio server, transcribes verbatim dialog with speaker identification, and generates structured executive markdown notes.

---

## ✨ Features

- 🎧 **Dual-Channel Online Meeting Capture**: Simultaneously captures your local microphone and system speaker playback (`default.monitor`) so every participant is recorded with crystal clarity without needing meeting bots or plugins.
- 🎙️ **Voice Memo Mode**: 1-click solo dictation capturing your microphone for quick thoughts, ideas, and reminders.
- 🤖 **Multi-AI Provider Support**:
  - **Google Gemini** (*Default*): Direct multimodal audio understanding with speaker pitch & intonation recognition (**Free tier: 1,500 req/day**).
  - **Groq Cloud**: Blazing-fast Whisper Large v3 + Llama 3.3 70B (transcribes 1-hour audio in ~3 seconds).
  - **Local Whisper**: 100% Free & Offline transcription with complete privacy (zero data leaves your device).
  - **OpenAI**: Industry-standard Whisper-1 + GPT-4o / GPT-4o-mini.
- 👥 **Pre-Meeting Context & Speaker Diarization**: Add meeting titles, agenda topics, and expected attendees with gender/voice profiles to guide AI speaker attribution.
- 📁 **Organized Note Storage**: Saves every recording into a dedicated, clean folder under `~/Documents/AudioNotes/<Title> - <YYYY-MM-DD> - <h-mma>/` containing:
  - `recording.opus` (High-efficiency audio)
  - `notes.md` (Executive Summary, Key Decisions, Action Items with Owners, Topics Discussed)
  - `transcript.md` (Pure timestamped verbatim transcript: `[HH:MM:SS] Speaker: text`)
  - `metadata.json` (Structured meeting metadata)
- ⚡ **Desktop Integration**:
  - Top bar live duration indicator and right-click quick-toggle recording.
  - Native Linux notifications on recording start, completion, and transcription ready.
  - 1-click open in default markdown editor or file manager.

---

## 📋 Requirements

Oma Scribe uses standard Linux tools available by default on Arch Linux / Omarchy:

- **PipeWire / PulseAudio** with `ffmpeg` (for system loopback & microphone capture)
- **Python 3** (standard library only; no external pip dependencies required for cloud providers)
- **Quickshell / Omarchy desktop**

Optional for 100% offline local transcription:
```bash
sudo pacman -S python-openai-whisper   # or sudo pacman -S whisper-cpp
```

---

## 🚀 Installation

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

## ⚙️ AI Provider Setup

Open the **Settings** tab in Oma Scribe to select your preferred AI engine:

| Provider | Cost / Tier | Setup Steps |
| :--- | :--- | :--- |
| **Google Gemini** *(Recommended)* | **Free Tier** (1,500 req/day)<br>No credit card required | 1. Visit [aistudio.google.com](https://aistudio.google.com)<br>2. Click **Get API Key** and paste your key (`AIzaSy...`). |
| **Groq Cloud** | **Free Tier Available**<br>Ultra-Fast LPUs | 1. Visit [console.groq.com](https://console.groq.com)<br>2. Create a key (`gsk_...`) and paste in settings. |
| **Local Whisper** | **100% Free & Offline**<br>Zero API key needed | 1. Select Local Whisper in settings.<br>2. Models automatically cache to `~/.cache/whisper/` on first run. |
| **OpenAI** | **Pay-As-You-Go** | 1. Visit [platform.openai.com/api-keys](https://platform.openai.com/api-keys)<br>2. Create a key (`sk-...`). |

---

## ⌨️ Keyboard & Mouse Controls

- **Left-Click Top Bar Icon (``)**: Opens the Oma Scribe popup window.
- **Right-Click Top Bar Icon**: Instant Start / Stop recording toggle.
- **Tab Key Navigation**: Cycle through Title $\rightarrow$ Topics $\rightarrow$ Attendees $\rightarrow$ Notes in the pre-meeting form.

---

## 🔒 Privacy & Security

- **Invisible in Meetings**: Oma Scribe records local audio directly from your Linux kernel/sound server. Meeting platforms (Teams, Zoom, Google Meet) cannot detect that a recording is running.
- **Zero Hard-Coded Keys**: All API keys and preferences are stored locally in your private `~/.config/omarchy/audio_notes.json`.
- **Local Storage**: All recordings and notes reside strictly on your local disk (`~/Documents/AudioNotes/`).

---

## 📄 License

This project is licensed under the [MIT License](LICENSE) - see the LICENSE file for details.

Developed with ❤️ for the [Omarchy](https://omarchy.org) / Arch Linux community by **[@Balthazzahr](https://github.com/Balthazzahr)**.
