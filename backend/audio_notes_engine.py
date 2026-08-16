#!/usr/bin/env python3
"""
Audio Notes Engine for Omarchy Arch Linux Quickshell Plugin.
Handles:
- PipeWire / PulseAudio recording (Meeting dual-channel vs Voice memo mic-only)
- State management via ~/.cache/audio_notes_state.json
- Direct Gemini API transcription & structured notes generation
- Clean separation of Summary Notes and Pure Transcripts
- Notification integration and Editor launching
"""

import os
import sys
import json
import time
import signal
import base64
import urllib.request
import urllib.error
import urllib.parse
import subprocess
from pathlib import Path
from datetime import datetime

APP_DIR = Path(__file__).resolve().parent.parent
CONFIG_FILE = Path.home() / ".config" / "omarchy" / "audio_notes.json"
CACHE_DIR = Path.home() / ".cache"
STATE_FILE = CACHE_DIR / "audio_notes_state.json"

DEFAULT_SETTINGS = {
    "provider": "gemini",
    "gemini_api_key": "",
    "groq_api_key": "",
    "openai_api_key": "",
    "model": "gemini-3.7-flash",
    "groq_model": "llama-3.3-70b-versatile",
    "openai_model": "gpt-4o-mini",
    "local_model": "base",
    "storage_path": str(Path.home() / "Documents" / "AudioNotes"),
    "auto_transcribe_on_stop": True,
    "default_mode": "meeting",
    "notes_editor": "xdg-open"
}

def get_storage_path():
    settings = load_settings()
    custom_path = settings.get("storage_path", "").strip()
    if custom_path:
        p = Path(custom_path).expanduser()
        p.mkdir(parents=True, exist_ok=True)
        return p
    default_p = Path.home() / "Documents" / "AudioNotes"
    default_p.mkdir(parents=True, exist_ok=True)
    return default_p

def pick_directory():
    try:
        res = subprocess.run(["zenity", "--file-selection", "--directory", "--title=Select Storage Folder for Oma Scribe Notes"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if res.returncode == 0:
            chosen = res.stdout.strip()
            if chosen:
                return {"status": "ok", "path": chosen}
    except Exception:
        pass
    return {"status": "cancelled"}

def format_folder_datetime(dt=None):
    if dt is None:
        dt = datetime.now()
    hour = dt.strftime("%I").lstrip("0") or "12"
    minute = dt.strftime("%M")
    ampm = dt.strftime("%p").lower()
    date_str = dt.strftime("%Y-%m-%d")
    return f"{date_str} - {hour}-{minute}{ampm}"

def load_settings():
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "r") as f:
                data = json.load(f)
                return {**DEFAULT_SETTINGS, **data}
        except Exception:
            pass
    return DEFAULT_SETTINGS.copy()

def save_settings(settings):
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(settings, f, indent=2)

def notify(summary, body=""):
    try:
        subprocess.run(["notify-send", "-a", "Oma Scribe", "-i", "audio-input-microphone", summary, body], check=False)
    except Exception:
        pass

def get_state():
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE, "r") as f:
                state = json.load(f)
                if state.get("is_recording") and state.get("pid"):
                    pid = state["pid"]
                    try:
                        os.kill(pid, 0)
                    except OSError:
                        state["is_recording"] = False
                        state["pid"] = None
                        save_state(state)
                return state
        except Exception:
            pass
    default_state = {
        "is_recording": False,
        "is_processing": False,
        "mode": "meeting",
        "title": "",
        "start_time": 0,
        "pid": None,
        "current_audio_file": "",
        "current_folder": "",
        "last_processed_file": "",
        "last_notes_file": "",
        "last_transcript_file": "",
        "status_message": "Ready"
    }
    save_state(default_state)
    return default_state

def save_state(state):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)

def start_recording(mode="meeting", title="", metadata=None):
    state = get_state()
    if state.get("is_recording"):
        return {"status": "error", "message": "Already recording"}

    storage = get_storage_path()
    storage.mkdir(parents=True, exist_ok=True)

    meta_obj = {}
    if metadata:
        if isinstance(metadata, str):
            try:
                meta_obj = json.loads(metadata)
            except Exception:
                meta_obj = {"title": metadata}
        elif isinstance(metadata, dict):
            meta_obj = metadata

    if not title and meta_obj.get("title"):
        title = meta_obj.get("title")

    now = datetime.now()
    date_time_str = format_folder_datetime(now)
    clean_title = title.strip()

    if clean_title:
        folder_name = f"{clean_title} - {date_time_str}"
    else:
        folder_name = date_time_str

    safe_folder_name = "".join(c for c in folder_name if c not in r'\/<>:"|?*').strip()
    note_dir = storage / safe_folder_name
    note_dir.mkdir(parents=True, exist_ok=True)

    audio_path = note_dir / "recording.opus"

    # Save pre-meeting metadata
    meta_obj["mode"] = mode
    meta_obj["title"] = title
    meta_obj["created_at"] = now.strftime("%Y-%m-%d %H:%M")
    meta_obj["date_time_str"] = date_time_str
    meta_path = note_dir / "metadata.json"
    try:
        with open(meta_path, "w", encoding="utf-8") as f:
            json.dump(meta_obj, f, indent=2)
    except Exception:
        pass

    # Build ffmpeg command
    if mode == "meeting":
        # Left channel = Default Microphone, Right channel = Default Sink Monitor (Teams/System output)
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "pulse", "-i", "default",
            "-f", "pulse", "-i", "default.monitor",
            "-filter_complex", "[0:a]pan=mono|c0=c0[a0];[1:a]pan=mono|c0=c0[a1];[a0][a1]amerge=inputs=2[out]",
            "-map", "[out]",
            "-c:a", "libopus", "-b:a", "96k",
            str(audio_path)
        ]
    else:
        # Voice memo mode: Microphone only
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "pulse", "-i", "default",
            "-c:a", "libopus", "-b:a", "96k",
            str(audio_path)
        ]

    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    state.update({
        "is_recording": True,
        "mode": mode,
        "title": title or ("Meeting" if mode == "meeting" else "Voice Memo"),
        "start_time": time.time(),
        "pid": proc.pid,
        "current_audio_file": str(audio_path),
        "current_folder": str(note_dir),
        "status_message": f"Recording {mode}..."
    })
    save_state(state)
    notify("Recording Started", f"Folder: {safe_folder_name}")
    return {"status": "ok", "state": state}

def stop_recording():
    state = get_state()
    if not state.get("is_recording"):
        return {"status": "error", "message": "Not recording"}

    pid = state.get("pid")
    if pid:
        try:
            os.kill(pid, signal.SIGINT)
            time.sleep(0.5)
        except OSError:
            pass

    audio_file = state.get("current_audio_file", "")
    mode = state.get("mode", "meeting")
    title = state.get("title", "")

    state.update({
        "is_recording": False,
        "pid": None,
        "status_message": "Recording saved"
    })
    save_state(state)

    if audio_file and os.path.exists(audio_file):
        folder_name = Path(audio_file).parent.name
        notify("Recording Saved", f"Saved to {folder_name}")

    settings = load_settings()
    if settings.get("auto_transcribe_on_stop") and audio_file and os.path.exists(audio_file):
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "transcribe", audio_file, mode, title],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    return {"status": "ok", "audio_file": audio_file, "state": state}

# --- HTTP MULTIPART HELPER ---
def post_multipart_file(url, api_key, file_path, fields):
    boundary = f"----AudioNotesBoundary{os.urandom(16).hex()}"
    body = bytearray()
    for k, v in fields.items():
        body.extend(f"--{boundary}\r\n".encode("utf-8"))
        body.extend(f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode("utf-8"))
        body.extend(f"{v}\r\n".encode("utf-8"))

    filename = os.path.basename(file_path)
    body.extend(f"--{boundary}\r\n".encode("utf-8"))
    body.extend(f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode("utf-8"))
    body.extend(b"Content-Type: audio/ogg\r\n\r\n")
    with open(file_path, "rb") as f:
        body.extend(f.read())
    body.extend(b"\r\n")
    body.extend(f"--{boundary}--\r\n".encode("utf-8"))

    req = urllib.request.Request(
        url,
        data=bytes(body),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}"
        }
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode("utf-8"))

# =========================================================================
# PROVIDER 1: GOOGLE GEMINI (DIRECT MULTIMODAL AUDIO)
# =========================================================================
def upload_file_to_gemini(api_key, file_path, mime_type="audio/ogg"):
    file_size = os.path.getsize(file_path)
    display_name = os.path.basename(file_path)

    init_url = f"https://generativelanguage.googleapis.com/upload/v1beta/files?key={api_key}"
    metadata = {"file": {"display_name": display_name}}
    body_data = json.dumps(metadata).encode("utf-8")
    req = urllib.request.Request(init_url, data=body_data, headers={
        "X-Goog-Upload-Protocol": "resumable",
        "X-Goog-Upload-Command": "start",
        "X-Goog-Upload-Header-Content-Length": str(file_size),
        "X-Goog-Upload-Header-Content-Type": mime_type,
        "Content-Type": "application/json"
    })

    with urllib.request.urlopen(req) as resp:
        upload_url = resp.headers.get("X-Goog-Upload-URL") or resp.headers.get("x-goog-upload-url")

    if not upload_url:
        raise RuntimeError("Failed to obtain Gemini File API upload URL")

    with open(file_path, "rb") as f:
        file_bytes = f.read()

    upload_req = urllib.request.Request(upload_url, data=file_bytes, headers={
        "Content-Length": str(file_size),
        "X-Goog-Upload-Offset": "0",
        "X-Goog-Upload-Command": "upload, finalize"
    })

    with urllib.request.urlopen(upload_req) as resp:
        res_json = json.loads(resp.read().decode("utf-8"))
        file_obj = res_json.get("file", {})
        file_uri = file_obj.get("uri")
        file_name = file_obj.get("name")

    if file_name:
        for _ in range(15):
            try:
                check_url = f"https://generativelanguage.googleapis.com/v1beta/{file_name}?key={api_key}"
                with urllib.request.urlopen(check_url) as check_resp:
                    check_json = json.loads(check_resp.read().decode("utf-8"))
                    state = check_json.get("state")
                    if state == "ACTIVE":
                        break
                    elif state == "FAILED":
                        raise RuntimeError("Uploaded audio file processing failed on Gemini server.")
            except Exception:
                pass
            time.sleep(1)

    return file_uri

def generate_notes_and_transcript_with_gemini(audio_path, mode="meeting", title="", api_key="", model="gemini-3.7-flash", speakers=""):
    if not api_key:
        api_key = os.environ.get("GEMINI_API_KEY", "")
    if not api_key:
        raise ValueError("Google Gemini API key is required. Please set it in Audio Notes settings.")

    file_uri = upload_file_to_gemini(api_key, audio_path, mime_type="audio/ogg")

    speaker_context = ""
    if speakers and speakers.strip():
        speaker_context = f"\n\nCRITICAL CONTEXT - Known Participants/Speakers in this recording: {speakers.strip()}.\nIdentify their voices and attribute their dialogue and action items to these specific names."

    if mode == "meeting":
        system_instruction = (
            "You are an expert audio transcriptionist and executive assistant. "
            "Listen to the provided audio recording of a meeting.\n"
            "Note: The audio may have local and remote participants." + speaker_context + "\n\n"
            "You must output TWO distinct sections separated by the delimiter string '===TRANSCRIPT_DELIMITER===':\n\n"
            "SECTION 1: Meeting Summary Notes (in Markdown format):\n"
            "# 📋 Meeting Summary: " + (title or "Team Meeting") + "\n\n"
            "**Date:** " + datetime.now().strftime("%Y-%m-%d %H:%M") + "\n\n"
            "## 📌 Executive Summary\n"
            "A concise synthesis of the meeting purpose, key discussions, and overall outcomes.\n\n"
            "## 🎯 Key Decisions Made\n"
            "- Bullet points of all agreed decisions\n\n"
            "## ✅ Action Items & Owners\n"
            "- [ ] **[Owner/Name]**: Action item description with context (if mentioned)\n\n"
            "## 💡 Topics Discussed\n"
            "- Key insights and discussion points\n\n"
            "===TRANSCRIPT_DELIMITER===\n\n"
            "SECTION 2: Pure Audio Transcription:\n"
            "# 📝 Verbatim Transcript: " + (title or "Team Meeting") + "\n"
            "**Date:** " + datetime.now().strftime("%Y-%m-%d %H:%M") + "\n\n"
            "Follow these strict speaker identification rules:\n"
            "1. If a speaker's name is known, introduced, or mentioned in the audio, use their actual name.\n"
            "2. If names are not known, label them as 'Male Speaker 1', 'Female Speaker 1', etc.\n"
            "3. If a name is heard or learned later in the recording, attribute all of that speaker's turns to their real name.\n"
            "4. Provide a pure, clean verbatim chronological transcript with timestamps in the format: `[HH:MM:SS] Speaker Name: Spoken text`.\n"
        )
    else:
        system_instruction = (
            "You are an expert audio transcriptionist and note synthesizer. "
            "Listen to the provided voice memo / audio dictation." + speaker_context + "\n\n"
            "You must output TWO distinct sections separated by the delimiter string '===TRANSCRIPT_DELIMITER===':\n\n"
            "SECTION 1: Spoken Audio Summary (in Markdown format):\n"
            "# 🎙️ Summary: " + (title or "Audio Note") + "\n\n"
            "**Date:** " + datetime.now().strftime("%Y-%m-%d %H:%M") + "\n\n"
            "## 📝 Overview & Summary\n"
            "A natural, well-written synthesis of what was spoken, capturing the thoughts, explanations, and core message clearly.\n\n"
            "## 💡 Key Points & Ideas\n"
            "- Bullet points of the main ideas, takeaways, or concepts expressed in the recording.\n\n"
            "## 📌 Next Steps / Reminders\n"
            "- [ ] Any follow-ups, to-dos, or reminders mentioned (omit if none).\n\n"
            "===TRANSCRIPT_DELIMITER===\n\n"
            "SECTION 2: Pure Audio Transcription:\n"
            "# 📝 Verbatim Transcript: " + (title or "Audio Note") + "\n"
            "**Date:** " + datetime.now().strftime("%Y-%m-%d %H:%M") + "\n\n"
            "Provide a pure, clean verbatim chronological transcript with timestamps in the format: `[HH:MM:SS] Spoken text`.\n"
        )

    payload = {
        "contents": [
            {
                "role": "user",
                "parts": [
                    {"file_data": {"mime_type": "audio/ogg", "file_uri": file_uri}},
                    {"text": system_instruction}
                ]
            }
        ],
        "generationConfig": {"temperature": 0.2, "maxOutputTokens": 8192}
    }

    models_to_try = [model]
    if model != "gemini-2.5-flash":
        models_to_try.append("gemini-2.5-flash")

    last_error = None
    res = None

    for m in models_to_try:
        for attempt in range(4):
            gen_url = f"https://generativelanguage.googleapis.com/v1beta/models/{m}:generateContent?key={api_key}"
            req = urllib.request.Request(
                gen_url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"}
            )
            try:
                with urllib.request.urlopen(req) as resp:
                    res = json.loads(resp.read().decode("utf-8"))
                    break
            except urllib.error.HTTPError as e:
                last_error = f"HTTP {e.code}: {e.reason}"
                if e.code in (503, 500, 429) and attempt < 3:
                    time.sleep(2 * (attempt + 1))
                    continue
                else:
                    break
            except Exception as e:
                last_error = str(e)
                if attempt < 3:
                    time.sleep(2 * (attempt + 1))
                    continue
                else:
                    break

        if res:
            break

    if not res:
        raise RuntimeError(f"Gemini service error ({last_error}). Please try again in a moment.")

    candidates = res.get("candidates", [])
    if not candidates:
        raise RuntimeError("No response candidates returned from Gemini.")

    parts = candidates[0].get("content", {}).get("parts", [])
    raw_output = "".join(part.get("text", "") for part in parts)

    if "===TRANSCRIPT_DELIMITER===" in raw_output:
        summary_section, transcript_section = raw_output.split("===TRANSCRIPT_DELIMITER===", 1)
    else:
        summary_section = raw_output
        transcript_section = raw_output

    return summary_section.strip(), transcript_section.strip()

# =========================================================================
# PROVIDER 2: GROQ CLOUD (WHISPER LARGE V3 + LLAMA 3.3 70B)
# =========================================================================
def generate_notes_and_transcript_with_groq(audio_path, mode="meeting", title="", api_key="", model="llama-3.3-70b-versatile", speakers=""):
    if not api_key:
        api_key = os.environ.get("GROQ_API_KEY", "")
    if not api_key:
        raise ValueError("Groq API key is required. Please set it in Audio Notes settings.")

    # 1. Transcribe via Groq Whisper Large v3
    trans_url = "https://api.groq.com/openai/v1/audio/transcriptions"
    trans_fields = {
        "model": "whisper-large-v3",
        "response_format": "text",
        "temperature": "0.0"
    }
    if speakers and speakers.strip():
        trans_fields["prompt"] = f"Speakers: {speakers.strip()[:200]}"

    raw_transcript = post_multipart_file(trans_url, api_key, audio_path, trans_fields)
    transcript_text = raw_transcript if isinstance(raw_transcript, str) else raw_transcript.get("text", "")

    # 2. Summarize via Groq Llama 3.3
    chat_url = "https://api.groq.com/openai/v1/chat/completions"
    if mode == "meeting":
        sys_prompt = f"You are an expert executive meeting assistant. Analyze this transcript for '{title or 'Meeting'}' and generate structured Markdown meeting summary notes with Executive Summary, Key Decisions, Action Items & Owners, and Topics Discussed."
    else:
        sys_prompt = f"You are an expert notes synthesizer. Summarize this spoken audio note for '{title or 'Audio Note'}' into clean Markdown with Overview, Key Points, and Next Steps."

    chat_payload = {
        "model": model or "llama-3.3-70b-versatile",
        "messages": [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": f"Transcript:\n\n{transcript_text}"}
        ],
        "temperature": 0.2
    }

    req = urllib.request.Request(
        chat_url,
        data=json.dumps(chat_payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        }
    )
    with urllib.request.urlopen(req) as resp:
        chat_res = json.loads(resp.read().decode("utf-8"))
        summary_md = chat_res.get("choices", [{}])[0].get("message", {}).get("content", "")

    transcript_md = f"# 📝 Verbatim Transcript: {title or 'Recording'}\n**Date:** {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n{transcript_text}"
    return summary_md.strip(), transcript_md.strip()

# =========================================================================
# PROVIDER 3: OPENAI (WHISPER-1 + GPT-4O / GPT-4O-MINI)
# =========================================================================
def generate_notes_and_transcript_with_openai(audio_path, mode="meeting", title="", api_key="", model="gpt-4o-mini", speakers=""):
    if not api_key:
        api_key = os.environ.get("OPENAI_API_KEY", "")
    if not api_key:
        raise ValueError("OpenAI API key is required. Please set it in Audio Notes settings.")

    # 1. Transcribe via Whisper-1
    trans_url = "https://api.openai.com/v1/audio/transcriptions"
    trans_fields = {
        "model": "whisper-1",
        "response_format": "text"
    }
    if speakers and speakers.strip():
        trans_fields["prompt"] = f"Speakers: {speakers.strip()[:200]}"

    raw_transcript = post_multipart_file(trans_url, api_key, audio_path, trans_fields)
    transcript_text = raw_transcript if isinstance(raw_transcript, str) else raw_transcript.get("text", "")

    # 2. Summarize via GPT-4o / GPT-4o-mini
    chat_url = "https://api.openai.com/v1/chat/completions"
    if mode == "meeting":
        sys_prompt = f"You are an expert executive meeting assistant. Analyze this transcript for '{title or 'Meeting'}' and generate structured Markdown meeting summary notes with Executive Summary, Key Decisions, Action Items & Owners, and Topics Discussed."
    else:
        sys_prompt = f"You are an expert notes synthesizer. Summarize this spoken audio note for '{title or 'Audio Note'}' into clean Markdown with Overview, Key Points, and Next Steps."

    chat_payload = {
        "model": model or "gpt-4o-mini",
        "messages": [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": f"Transcript:\n\n{transcript_text}"}
        ],
        "temperature": 0.2
    }

    req = urllib.request.Request(
        chat_url,
        data=json.dumps(chat_payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        }
    )
    with urllib.request.urlopen(req) as resp:
        chat_res = json.loads(resp.read().decode("utf-8"))
        summary_md = chat_res.get("choices", [{}])[0].get("message", {}).get("content", "")

    transcript_md = f"# 📝 Verbatim Transcript: {title or 'Recording'}\n**Date:** {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n{transcript_text}"
    return summary_md.strip(), transcript_md.strip()

# =========================================================================
# PROVIDER 4: LOCAL WHISPER (100% OFFLINE / ZERO API KEY)
# =========================================================================
def generate_notes_and_transcript_with_local(audio_path, mode="meeting", title="", model="base", speakers=""):
    # Check for whisper CLI or whisper-cpp
    which_whisper = subprocess.run(["which", "whisper"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    which_whisper_cpp = subprocess.run(["which", "whisper-cpp"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    if which_whisper.returncode == 0:
        cmd = ["whisper", str(audio_path), "--model", model, "--output_format", "txt", "--output_dir", str(Path(audio_path).parent)]
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        txt_path = Path(audio_path).parent / f"{Path(audio_path).stem}.txt"
        transcript_text = txt_path.read_text(encoding="utf-8") if txt_path.exists() else "Local transcription completed."
    elif which_whisper_cpp.returncode == 0:
        cmd = ["whisper-cpp", "-m", f"/usr/share/whisper-models/ggml-{model}.bin", "-f", str(audio_path), "-otxt"]
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        txt_path = Path(audio_path).parent / f"{Path(audio_path).name}.txt"
        transcript_text = txt_path.read_text(encoding="utf-8") if txt_path.exists() else "Local transcription completed."
    else:
        raise RuntimeError("Local Whisper is not installed. To use offline mode, run: pip install openai-whisper (or sudo pacman -S whisper.cpp)")

    summary_md = f"# 🎙️ Local Note: {title or 'Recording'}\n**Date:** {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n## 📝 Transcript Overview\n{transcript_text[:500]}..."
    transcript_md = f"# 📝 Verbatim Transcript: {title or 'Recording'}\n**Date:** {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n{transcript_text}"
    return summary_md, transcript_md

def run_transcription_job(audio_path, mode="meeting", title="", speakers=""):
    state = get_state()
    settings = load_settings()
    provider = settings.get("provider", "gemini")

    if provider == "groq":
        api_key = settings.get("groq_api_key", "").strip() or os.environ.get("GROQ_API_KEY", "").strip()
        model = settings.get("groq_model", "llama-3.3-70b-versatile")
        if not api_key:
            notify("Audio Notes Error", "Groq API key is not configured. Please open Audio Notes settings.")
            state.update({"is_processing": False, "status_message": "Error: Missing Groq API key"})
            save_state(state)
            return
    elif provider == "openai":
        api_key = settings.get("openai_api_key", "").strip() or os.environ.get("OPENAI_API_KEY", "").strip()
        model = settings.get("openai_model", "gpt-4o-mini")
        if not api_key:
            notify("Audio Notes Error", "OpenAI API key is not configured. Please open Audio Notes settings.")
            state.update({"is_processing": False, "status_message": "Error: Missing OpenAI API key"})
            save_state(state)
            return
    elif provider == "local":
        api_key = ""
        model = settings.get("local_model", "base")
    else:  # gemini
        api_key = settings.get("gemini_api_key", "").strip() or os.environ.get("GEMINI_API_KEY", "").strip()
        model = settings.get("model", "gemini-3.7-flash")
        if not api_key:
            notify("Audio Notes Error", "Gemini API key is not configured. Please open Audio Notes settings.")
            state.update({"is_processing": False, "status_message": "Error: Missing Gemini API key"})
            save_state(state)
            return

    p = Path(audio_path)
    note_dir = p.parent

    # Check for metadata.json or <stem>.meta.json
    meta = {}
    meta_path = note_dir / "metadata.json"
    if not meta_path.exists():
        meta_path = p.with_suffix(".meta.json")

    if meta_path.exists():
        try:
            with open(meta_path, "r", encoding="utf-8") as f:
                meta = json.load(f)
        except Exception:
            pass

    if not title and meta.get("title"):
        title = meta.get("title")

    # If title was updated/provided, rename the folder if appropriate
    if title and title.strip():
        date_time_str = meta.get("date_time_str") or format_folder_datetime(datetime.fromtimestamp(p.stat().st_mtime))
        expected_folder_name = f"{title.strip()} - {date_time_str}"
        safe_expected = "".join(c for c in expected_folder_name if c not in r'\/<>:"|?*').strip()

        storage = get_storage_path()
        if note_dir.parent == storage and note_dir.name != safe_expected:
            new_note_dir = storage / safe_expected
            try:
                note_dir.rename(new_note_dir)
                note_dir = new_note_dir
                audio_path = str(note_dir / p.name)
                p = Path(audio_path)
            except Exception:
                pass

    # Build rich context for LLM
    parts = []
    if title:
        parts.append(f"Meeting Title: {title}")
    if meta.get("topics"):
        parts.append(f"Planned Topics / Agenda: {meta['topics']}")

    attendees = meta.get("attendees", [])
    if attendees:
        att_strs = []
        for a in attendees:
            if isinstance(a, dict) and a.get("name"):
                sex_str = f" (Sex/Voice: {a.get('sex')})" if a.get('sex') else ""
                att_strs.append(f"  * {a.get('name')}{sex_str}")
            elif isinstance(a, str) and a.strip():
                att_strs.append(f"  * {a.strip()}")
        if att_strs:
            parts.append("Known Meeting Attendees & Voice Profiles:\n" + "\n".join(att_strs))

    if meta.get("notes"):
        parts.append(f"Pre-Meeting Notes / Additional Context: {meta['notes']}")

    if parts:
        meta_context = "\n".join(parts)
        speakers = (meta_context + "\n\n" + speakers).strip() if speakers else meta_context

    provider_name = "Gemini" if provider == "gemini" else ("Groq" if provider == "groq" else ("OpenAI" if provider == "openai" else "Local Whisper"))
    state.update({
        "is_processing": True,
        "status_message": f"Transcribing with {provider_name} ({model})..."
    })
    save_state(state)
    notify("Processing Audio", f"Transcribing {note_dir.name} with {provider_name}...")

    try:
        if provider == "groq":
            summary_md, transcript_md = generate_notes_and_transcript_with_groq(
                audio_path=str(audio_path), mode=mode, title=title, api_key=api_key, model=model, speakers=speakers
            )
        elif provider == "openai":
            summary_md, transcript_md = generate_notes_and_transcript_with_openai(
                audio_path=str(audio_path), mode=mode, title=title, api_key=api_key, model=model, speakers=speakers
            )
        elif provider == "local":
            summary_md, transcript_md = generate_notes_and_transcript_with_local(
                audio_path=str(audio_path), mode=mode, title=title, model=model, speakers=speakers
            )
        else:
            summary_md, transcript_md = generate_notes_and_transcript_with_gemini(
                audio_path=str(audio_path), mode=mode, title=title, api_key=api_key, model=model, speakers=speakers
            )

        notes_file = note_dir / "notes.md"
        with open(notes_file, "w", encoding="utf-8") as f:
            f.write(summary_md)

        transcript_file = note_dir / "transcript.md"
        with open(transcript_file, "w", encoding="utf-8") as f:
            f.write(transcript_md)

        # Update metadata.json with completed info
        meta["has_notes"] = True
        meta["has_transcript"] = True
        meta["title"] = title
        try:
            with open(note_dir / "metadata.json", "w", encoding="utf-8") as f:
                json.dump(meta, f, indent=2)
        except Exception:
            pass

        state.update({
            "is_processing": False,
            "last_processed_file": str(audio_path),
            "last_notes_file": str(notes_file),
            "last_transcript_file": str(transcript_file),
            "status_message": "Transcription & Notes ready!"
        })
        save_state(state)
        notify("Processing Complete", f"Saved Notes & Transcript in {note_dir.name}")

    except Exception as e:
        state.update({
            "is_processing": False,
            "status_message": f"Processing error: {str(e)[:40]}"
        })
        save_state(state)
        notify("Transcription Error", str(e))

def list_history():
    storage = get_storage_path()
    storage.mkdir(parents=True, exist_ok=True)
    items = []

    # 1. Look for subfolders in storage (each folder is one note)
    for d in sorted(storage.iterdir(), key=os.path.getmtime, reverse=True):
        if d.is_dir() and d.name not in ("recordings", "notes", "transcripts"):
            opus_files = list(d.glob("*.opus"))
            if not opus_files:
                continue
            audio_p = opus_files[0]

            notes_p = d / "notes.md"
            has_notes = notes_p.exists()

            trans_p = d / "transcript.md"
            has_transcript = trans_p.exists()

            meta = {}
            meta_p = d / "metadata.json"
            if meta_p.exists():
                try:
                    with open(meta_p, "r", encoding="utf-8") as f:
                        meta = json.load(f)
                except Exception:
                    pass

            mode = meta.get("mode") or ("mic" if "memo" in d.name.lower() or "_mic_" in audio_p.name else "meeting")
            display_title = meta.get("title") or d.name.split(" - ")[0] or d.name
            size_kb = round(audio_p.stat().st_size / 1024, 1)
            mod_time = datetime.fromtimestamp(audio_p.stat().st_mtime).strftime("%Y-%m-%d %H:%M")

            items.append({
                "audio_file": str(audio_p),
                "folder": str(d),
                "filename": d.name,
                "title": display_title,
                "mode": mode,
                "date": mod_time,
                "size_kb": size_kb,
                "notes_file": str(notes_p) if has_notes else "",
                "transcript_file": str(trans_p) if has_transcript else "",
                "has_notes": has_notes,
                "has_transcript": has_transcript
            })

    # 2. Also check legacy recordings dir if any exist
    legacy_rec = storage / "recordings"
    if legacy_rec.exists():
        for p in sorted(legacy_rec.glob("*.opus"), key=os.path.getmtime, reverse=True):
            stem = p.stem
            note_p = storage / "notes" / f"{stem}.md"
            trans_p = storage / "transcripts" / f"{stem}_transcript.md"
            if not trans_p.exists():
                trans_p = storage / "transcripts" / f"{stem}.md"

            mode = "mic" if ("_mic_" in stem or stem.endswith("_mic")) else "meeting"
            size_kb = round(p.stat().st_size / 1024, 1)
            mod_time = datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
            parts = stem.split("_")
            display_title = parts[-1] if len(parts) >= 3 else stem

            items.append({
                "audio_file": str(p),
                "folder": str(p.parent),
                "filename": p.name,
                "title": display_title,
                "mode": mode,
                "date": mod_time,
                "size_kb": size_kb,
                "notes_file": str(note_p) if note_p.exists() else "",
                "transcript_file": str(trans_p) if trans_p.exists() else "",
                "has_notes": note_p.exists(),
                "has_transcript": trans_p.exists()
            })

    return items[:40]

def open_file_in_editor(file_path):
    if not file_path or not os.path.exists(file_path):
        return
    try:
        res = subprocess.run(["which", "omarchy-launch-editor"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0:
            subprocess.Popen(["omarchy-launch-editor", file_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        else:
            subprocess.Popen(["xdg-open", file_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        subprocess.Popen(["xdg-open", file_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

def open_storage_folder():
    storage = get_storage_path()
    storage.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.Popen(["xdg-open", str(storage)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        pass

def rename_note(target_path, new_title):
    if not target_path or not new_title or not new_title.strip():
        return {"status": "error", "message": "Missing path or title"}

    new_title = new_title.strip()
    p = Path(target_path)
    folder = p if p.is_dir() else p.parent
    storage = get_storage_path()

    if not folder.exists():
        return {"status": "error", "message": "Folder not found"}

    meta = {}
    meta_p = folder / "metadata.json"
    if meta_p.exists():
        try:
            with open(meta_p, "r", encoding="utf-8") as f:
                meta = json.load(f)
        except Exception:
            pass

    date_time_str = meta.get("date_time_str")
    if not date_time_str:
        parts = folder.name.split(" - ")
        if len(parts) >= 2 and any(c.isdigit() for c in parts[-1]):
            date_time_str = " - ".join(parts[1:])
        else:
            try:
                date_time_str = format_folder_datetime(datetime.fromtimestamp(folder.stat().st_mtime))
            except Exception:
                date_time_str = format_folder_datetime()

    meta["title"] = new_title
    meta["date_time_str"] = date_time_str

    expected_folder_name = f"{new_title} - {date_time_str}"
    safe_folder_name = "".join(c for c in expected_folder_name if c not in r'\/<>:"|?*').strip()

    if folder.parent == storage and folder != storage:
        new_folder = storage / safe_folder_name
        if new_folder != folder:
            try:
                folder.rename(new_folder)
                folder = new_folder
            except Exception as e:
                return {"status": "error", "message": f"Rename failed: {str(e)}"}

    # Update metadata.json
    try:
        with open(folder / "metadata.json", "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2)
    except Exception:
        pass

    return {"status": "ok", "new_folder": str(folder), "new_title": new_title}

def delete_recording(audio_path):
    if not audio_path:
        return {"status": "error", "message": "No file path provided"}
    try:
        p = Path(audio_path)
        parent_dir = p.parent
        storage = get_storage_path()

        # If it's a dedicated note directory inside storage, delete the entire folder
        if parent_dir.parent == storage and parent_dir != storage:
            import shutil
            shutil.rmtree(parent_dir)
            return {"status": "ok", "deleted": parent_dir.name}

        # Otherwise delete individual files (legacy)
        stem = p.stem
        if p.exists():
            p.unlink()

        meta_p = p.with_suffix(".meta.json")
        if meta_p.exists():
            meta_p.unlink()

        note_p = storage / "notes" / f"{stem}.md"
        if note_p.exists():
            note_p.unlink()

        trans_p = storage / "transcripts" / f"{stem}_transcript.md"
        if trans_p.exists():
            trans_p.unlink()
        trans_p_alt = storage / "transcripts" / f"{stem}.md"
        if trans_p_alt.exists():
            trans_p_alt.unlink()

        return {"status": "ok", "deleted": stem}
    except Exception as e:
        return {"status": "error", "message": str(e)}

def check_local_whisper():
    which_whisper = subprocess.run(["which", "whisper"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    which_whisper_cpp = subprocess.run(["which", "whisper-cpp"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    has_python_whisper = False
    try:
        res = subprocess.run([sys.executable, "-c", "import whisper; print('ok')"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if res.stdout.strip() == "ok":
            has_python_whisper = True
    except Exception:
        pass

    installed = (which_whisper.returncode == 0) or (which_whisper_cpp.returncode == 0) or has_python_whisper
    engine_name = "whisper.cpp" if which_whisper_cpp.returncode == 0 else ("openai-whisper" if (which_whisper.returncode == 0 or has_python_whisper) else None)

    # Check cached models in ~/.cache/whisper
    whisper_cache = Path.home() / ".cache" / "whisper"
    cached = []
    if whisper_cache.exists():
        for f in whisper_cache.glob("*.pt"):
            cached.append(f.stem)

    return {
        "installed": installed,
        "engine": engine_name,
        "cached_models": cached,
        "install_command": "sudo pacman -S python-openai-whisper"
    }

def main():
    if len(sys.argv) < 2:
        print(json.dumps(get_state()))
        return

    cmd = sys.argv[1]

    if cmd == "start":
        mode = sys.argv[2] if len(sys.argv) > 2 else "meeting"
        metadata_raw = sys.argv[3] if len(sys.argv) > 3 else ""
        try:
            meta = json.loads(metadata_raw)
            title = meta.get("title", "")
            print(json.dumps(start_recording(mode, title, meta)))
        except Exception:
            title = metadata_raw
            print(json.dumps(start_recording(mode, title)))

    elif cmd == "stop":
        print(json.dumps(stop_recording()))

    elif cmd == "status":
        print(json.dumps(get_state()))

    elif cmd == "list":
        print(json.dumps(list_history()))

    elif cmd == "delete":
        target = sys.argv[2] if len(sys.argv) > 2 else ""
        print(json.dumps(delete_recording(target)))

    elif cmd == "rename":
        target = sys.argv[2] if len(sys.argv) > 2 else ""
        new_title = sys.argv[3] if len(sys.argv) > 3 else ""
        print(json.dumps(rename_note(target, new_title)))

    elif cmd == "transcribe":
        audio_file = sys.argv[2]
        mode = sys.argv[3] if len(sys.argv) > 3 else "meeting"
        title = sys.argv[4] if len(sys.argv) > 4 else ""
        speakers = sys.argv[5] if len(sys.argv) > 5 else ""
        run_transcription_job(audio_file, mode, title, speakers)

    elif cmd == "open-editor":
        target = sys.argv[2]
        open_file_in_editor(target)
        print(json.dumps({"status": "ok"}))

    elif cmd == "open-storage-folder":
        open_storage_folder()
        print(json.dumps({"status": "ok"}))

    elif cmd == "get-settings":
        print(json.dumps(load_settings()))

    elif cmd == "save-settings":
        new_settings = json.loads(sys.argv[2])
        save_settings(new_settings)
        print(json.dumps({"status": "ok"}))

    elif cmd == "check-local-whisper":
        print(json.dumps(check_local_whisper()))

    elif cmd == "pick-directory":
        print(json.dumps(pick_directory()))

    elif cmd == "read-file":
        target = sys.argv[2]
        if os.path.exists(target):
            with open(target, "r", encoding="utf-8") as f:
                print(f.read())
        else:
            print("")

    else:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))

if __name__ == "__main__":
    main()

