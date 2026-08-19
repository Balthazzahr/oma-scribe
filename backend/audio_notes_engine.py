#!/usr/bin/env python3
"""
Oma Scribe Audio Engine (Pure Groq Cloud Backend).
Handles:
- PipeWire / PulseAudio dual-track meeting recording & voice memos
- Voice-optimized Opus recording (24kbps VOIP, 16kHz)
- Ultra-fast Whisper Large v3 transcription on Groq LPUs (~2-4 seconds)
- High-accuracy structured meeting synthesis with Llama 3.3 70B Versatile
- Automatic audio chunking if file exceeds 25MB Groq API limit
- Clean two-phase separation of transcript.md and notes.md (zero delimiter issues)
- Real-time stage progress & time estimation
- Interactive process cancellation
- Full error extraction from Groq API
"""

import os
import sys
import json
import time
import signal
import uuid
import re
import urllib.request
import urllib.error
import urllib.parse
import subprocess
from pathlib import Path
from datetime import datetime

API_TIMEOUT = 90

APP_DIR = Path(__file__).resolve().parent.parent
CONFIG_FILE = Path.home() / ".config" / "omarchy" / "audio_notes.json"
CACHE_DIR = Path.home() / ".cache"
STATE_FILE = CACHE_DIR / "audio_notes_state.json"
META_CACHE_DIR = CACHE_DIR / "omarchy" / "oma_scribe_metadata"

DEFAULT_SETTINGS = {
    "groq_api_key": "",
    "groq_model": "llama-3.3-70b-versatile",
    "whisper_model": "whisper-large-v3",
    "storage_path": str(Path.home() / "Documents" / "AudioNotes"),
    "notes_format": "md",    # "md" | "txt" | "html"
    "audio_format": "opus",  # "opus" | "mp3" | "m4a" | "wav"
    "auto_transcribe_on_stop": True,
    "default_mode": "meeting",
    "notes_editor": "xdg-open"
}

def get_audio_mime_type(file_path):
    ext = Path(file_path).suffix.lower()
    if ext == ".mp3":
        return "audio/mp3"
    elif ext in (".m4a", ".mp4", ".aac"):
        return "audio/m4a"
    elif ext == ".wav":
        return "audio/wav"
    elif ext == ".opus":
        return "audio/ogg"
    else:
        return "audio/ogg"

def load_note_metadata(folder_or_file):
    p = Path(folder_or_file)
    folder = p if p.is_dir() else p.parent

    hidden_p = folder / ".metadata.json"
    if hidden_p.exists():
        try:
            with open(hidden_p, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass

    legacy_p = folder / "metadata.json"
    if legacy_p.exists():
        try:
            with open(legacy_p, "r", encoding="utf-8") as f:
                data = json.load(f)
                save_note_metadata(folder, data)
                try:
                    legacy_p.unlink(missing_ok=True)
                except Exception:
                    pass
                return data
        except Exception:
            pass

    return {}

def save_note_metadata(folder_or_file, meta):
    p = Path(folder_or_file)
    folder = p if p.is_dir() else p.parent
    META_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    hidden_p = folder / ".metadata.json"
    try:
        with open(hidden_p, "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2)
    except Exception:
        pass

    try:
        (folder / "metadata.json").unlink(missing_ok=True)
    except Exception:
        pass

def get_audio_codec_args(audio_format):
    fmt = (audio_format or "opus").lower()
    if fmt == "mp3":
        return ".mp3", ["-c:a", "libmp3lame", "-b:a", "64k", "-ar", "16000"]
    elif fmt == "m4a":
        return ".m4a", ["-c:a", "aac", "-b:a", "64k", "-ar", "16000"]
    elif fmt == "wav":
        return ".wav", ["-c:a", "pcm_s16le", "-ar", "16000"]
    else:
        # Voice-optimized Opus: 24kbps VOIP application, 16kHz, VBR (75-80% smaller)
        return ".opus", ["-c:a", "libopus", "-b:a", "24k", "-application", "voip", "-vbr", "on", "-ar", "16000"]

def format_notes_content(text, notes_format):
    fmt = (notes_format or "md").lower()
    if fmt == "txt":
        clean = re.sub(r'#+\s*', '', text)
        clean = re.sub(r'\*\*(.*?)\*\*', r'\1', clean)
        clean = re.sub(r'\*(.*?)\*', r'\1', clean)
        clean = re.sub(r'`(.*?)`', r'\1', clean)
        return clean
    elif fmt == "html":
        return f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
body {{ font-family: system-ui, -apple-system, sans-serif; line-height: 1.6; max-width: 800px; margin: 40px auto; padding: 0 20px; color: #222; background: #fafafa; }}
h1, h2, h3 {{ color: #111; margin-top: 1.5em; }}
code {{ background: #eee; padding: 2px 5px; border-radius: 3px; font-family: monospace; }}
pre {{ background: #f4f4f4; padding: 12px; border-radius: 6px; overflow-x: auto; }}
ul, ol {{ padding-left: 24px; }}
li {{ margin-bottom: 6px; }}
</style>
</head>
<body>
<pre style="white-space: pre-wrap; font-family: inherit;">{text}</pre>
</body>
</html>"""
    else:
        return text

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

def extract_http_error(e):
    """Parses full JSON error messages from Groq API rather than generic HTTP codes."""
    try:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            data = json.loads(raw)
            if isinstance(data, dict) and "error" in data:
                err = data["error"]
                if isinstance(err, dict):
                    msg = err.get("message") or str(err)
                    code = err.get("code") or e.code
                    return f"Groq Error ({code}): {msg}"
                elif isinstance(err, str):
                    return f"Groq Error ({e.code}): {err}"
        except Exception:
            pass
        if raw:
            return f"HTTP {e.code} ({e.reason}): {raw[:400]}"
        return f"HTTP {e.code}: {e.reason}"
    except Exception:
        return f"HTTP {e.code}: {e.reason}"

def get_audio_duration(file_path):
    try:
        cmd = ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(file_path)]
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if res.returncode == 0 and res.stdout.strip():
            return float(res.stdout.strip())
    except Exception:
        pass
    try:
        cmd = ["ffmpeg", "-i", str(file_path)]
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        match = re.search(r"Duration:\s*(\d+):(\d+):(\d+\.?\d*)", res.stderr)
        if match:
            h, m, s = match.groups()
            return int(h) * 3600 + int(m) * 60 + float(s)
    except Exception:
        pass
    return 0.0

def split_audio_if_needed(file_path, max_size_bytes=24 * 1024 * 1024):
    """If file exceeds max_size_bytes (24MB for Groq), splits into smaller overlapping chunks."""
    p = Path(file_path)
    file_size = p.stat().st_size
    if file_size <= max_size_bytes:
        return [str(p)], False

    duration = get_audio_duration(p)
    if duration <= 0:
        return [str(p)], False

    num_chunks = max(2, int((file_size / max_size_bytes) * 1.25) + 1)
    chunk_duration = duration / num_chunks
    overlap_sec = 2.0

    scratch_dir = p.parent / ".temp_chunks"
    scratch_dir.mkdir(parents=True, exist_ok=True)
    chunk_paths = []

    for i in range(num_chunks):
        start_time = max(0.0, i * chunk_duration - (overlap_sec if i > 0 else 0))
        chunk_file = scratch_dir / f"chunk_{i:03d}.opus"
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-ss", str(start_time),
            "-i", str(p),
            "-t", str(chunk_duration + (overlap_sec if i > 0 else 0)),
            "-c:a", "libopus", "-b:a", "24k", "-application", "voip", "-vbr", "on", "-ar", "16000",
            str(chunk_file)
        ]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        chunk_paths.append(str(chunk_file))

    return chunk_paths, True

def cleanup_temp_chunks(file_path):
    scratch_dir = Path(file_path).parent / ".temp_chunks"
    if scratch_dir.exists():
        try:
            for f in scratch_dir.glob("*"):
                f.unlink(missing_ok=True)
            scratch_dir.rmdir()
        except Exception:
            pass

def get_state():
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE, "r") as f:
                state = json.load(f)
                if state.get("is_recording") and state.get("pid"):
                    try:
                        os.kill(state["pid"], 0)
                    except OSError:
                        state["is_recording"] = False
                        state["pid"] = None
                        save_state(state)
                if state.get("is_processing") and state.get("transcribe_pid"):
                    try:
                        os.kill(state["transcribe_pid"], 0)
                    except OSError:
                        state["is_processing"] = False
                        state["transcribe_pid"] = None
                        state["processing_stage"] = ""
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
        "transcribe_pid": None,
        "current_audio_file": "",
        "current_folder": "",
        "last_processed_file": "",
        "last_notes_file": "",
        "last_transcript_file": "",
        "status_message": "Ready",
        "processing_stage": "",
        "progress_percent": 0,
        "processing_start_time": 0,
        "estimated_duration": 0,
        "last_error": "",
        "current_model": ""
    }
    save_state(default_state)
    return default_state

def save_state(state):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)

def update_progress(stage, percent=None, current_model=None):
    try:
        state = get_state()
        state["processing_stage"] = stage
        if percent is not None:
            state["progress_percent"] = percent
        if current_model is not None:
            state["current_model"] = current_model
        save_state(state)
    except Exception:
        pass

def clear_error():
    state = get_state()
    state["last_error"] = ""
    save_state(state)
    return {"status": "ok"}

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
    clean_title = (title or "").strip()

    if clean_title:
        folder_name = f"{clean_title} - {date_time_str}"
    else:
        folder_name = date_time_str

    safe_folder_name = "".join(c for c in folder_name if c not in r'\/<>:"|?*').strip()
    note_dir = storage / safe_folder_name
    note_dir.mkdir(parents=True, exist_ok=True)

    settings = load_settings()
    audio_fmt = settings.get("audio_format", "opus")
    audio_ext, codec_flags = get_audio_codec_args(audio_fmt)
    audio_path = note_dir / f"recording{audio_ext}"

    meta_obj["mode"] = mode
    meta_obj["title"] = title
    meta_obj["created_at"] = now.strftime("%Y-%m-%d %H:%M")
    meta_obj["date_time_str"] = date_time_str
    save_note_metadata(note_dir, meta_obj)

    if mode == "meeting":
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "pulse", "-i", "default",
            "-f", "pulse", "-i", "default.monitor",
            "-filter_complex", "[0:a]pan=mono|c0=c0[a0];[1:a]pan=mono|c0=c0[a1];[a0][a1]amerge=inputs=2[out]",
            "-map", "[out]"
        ] + codec_flags + [str(audio_path)]
    else:
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "pulse", "-i", "default"
        ] + codec_flags + [str(audio_path)]

    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    state.update({
        "is_recording": True,
        "mode": mode,
        "title": title or ("Meeting" if mode == "meeting" else "Voice Memo"),
        "start_time": time.time(),
        "pid": proc.pid,
        "current_audio_file": str(audio_path),
        "current_folder": str(note_dir),
        "status_message": f"Recording {mode}...",
        "last_error": ""
    })
    save_state(state)
    notify("Recording Started", f"Folder: {safe_folder_name}")
    return {"status": "ok", "state": state}

def stop_recording(metadata=None):
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
    title = state.get("title", "")

    meta_obj = {}
    if metadata:
        if isinstance(metadata, str):
            try:
                meta_obj = json.loads(metadata)
            except Exception:
                meta_obj = {"title": metadata}
        elif isinstance(metadata, dict):
            meta_obj = metadata

    if meta_obj.get("title") and meta_obj["title"].strip():
        title = meta_obj["title"].strip()

    if audio_file and os.path.exists(audio_file):
        note_dir = Path(audio_file).parent
        existing_meta = load_note_metadata(note_dir)
        existing_meta.update(meta_obj)
        if title:
            existing_meta["title"] = title
        save_note_metadata(note_dir, existing_meta)

        if title and title not in ("Meeting", "Voice Memo"):
            date_time_str = existing_meta.get("date_time_str") or format_folder_datetime(datetime.fromtimestamp(note_dir.stat().st_mtime))
            expected_folder_name = f"{title} - {date_time_str}"
            safe_expected = "".join(c for c in expected_folder_name if c not in r'\/<>:"|?*').strip()
            storage = get_storage_path()
            if note_dir.parent == storage and note_dir.name != safe_expected:
                new_note_dir = storage / safe_expected
                try:
                    note_dir.rename(new_note_dir)
                    note_dir = new_note_dir
                    audio_file = str(note_dir / Path(audio_file).name)
                except Exception:
                    pass

    state.update({
        "is_recording": False,
        "pid": None,
        "status_message": "Recording saved",
        "current_audio_file": audio_file,
        "title": title
    })
    save_state(state)

    if audio_file and os.path.exists(audio_file):
        folder_name = Path(audio_file).parent.name
        notify("Recording Saved", f"Saved to {folder_name}")

    return {"status": "ok", "audio_file": audio_file, "state": state, "title": title}

def cancel_transcription():
    state = get_state()
    tpid = state.get("transcribe_pid")
    if tpid:
        try:
            os.kill(tpid, signal.SIGKILL)
        except OSError:
            pass

    audio_file = state.get("current_audio_file")
    if audio_file:
        cleanup_temp_chunks(audio_file)

    state.update({
        "is_processing": False,
        "transcribe_pid": None,
        "current_model": "",
        "progress_percent": 0,
        "processing_stage": "",
        "status_message": "Transcription cancelled",
        "last_error": ""
    })
    save_state(state)
    notify("Oma Scribe", "Transcription stopped")
    return {"status": "ok", "message": "Transcription cancelled"}

# =========================================================================
# GROQ CLOUD PIPELINE: WHISPER-LARGE-V3 + LLAMA-3.3-70B
# =========================================================================
def build_multipart_form(fields, files):
    """Builds multipart/form-data payload without external libraries."""
    boundary = f"----WebKitFormBoundary{uuid.uuid4().hex}"
    body = bytearray()

    for name, value in fields.items():
        body.extend(f"--{boundary}\r\n".encode("utf-8"))
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
        body.extend(f"{value}\r\n".encode("utf-8"))

    for name, (filename, filedata, content_type) in files.items():
        body.extend(f"--{boundary}\r\n".encode("utf-8"))
        body.extend(f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'.encode("utf-8"))
        body.extend(f"Content-Type: {content_type}\r\n\r\n".encode("utf-8"))
        body.extend(filedata)
        body.extend(b"\r\n")

    body.extend(f"--{boundary}--\r\n".encode("utf-8"))
    content_type = f"multipart/form-data; boundary={boundary}"
    return body, content_type

def transcribe_audio_with_groq(audio_path, api_key, prompt=""):
    """
    Submits audio to Groq Whisper Large v3 LPU endpoint.
    Transcribes a full meeting in ~2-4 seconds.
    """
    url = "https://api.groq.com/openai/v1/audio/transcriptions"
    clean_key = (api_key or "").strip()

    chunk_files, was_split = split_audio_if_needed(audio_path, max_size_bytes=24 * 1024 * 1024)
    all_transcripts = []

    for idx, cf in enumerate(chunk_files):
        cf_path = Path(cf)
        mime_type = get_audio_mime_type(cf)
        filename = cf_path.name

        with open(cf, "rb") as f:
            file_bytes = f.read()

        fields = {
            "model": "whisper-large-v3",
            "response_format": "verbose_json",
            "temperature": "0.0"
        }
        if prompt:
            fields["prompt"] = prompt[:400]

        files = {
            "file": (filename, file_bytes, mime_type)
        }

        body, content_type = build_multipart_form(fields, files)
        req = urllib.request.Request(
            url,
            data=body,
            headers={
                "Authorization": f"Bearer {clean_key}",
                "Content-Type": content_type,
                "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
            }
        )

        try:
            with urllib.request.urlopen(req, timeout=API_TIMEOUT) as resp:
                res_data = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raise RuntimeError(extract_http_error(e))
        except Exception as e:
            raise RuntimeError(f"Groq Whisper transcription failed: {str(e)}")

        segments = res_data.get("segments", [])
        if segments:
            for s in segments:
                start_sec = int(s.get("start", 0))
                hh = start_sec // 3600
                mm = (start_sec % 3600) // 60
                ss = start_sec % 60
                ts = f"[{hh:02d}:{mm:02d}:{ss:02d}]" if hh > 0 else f"[{mm:02d}:{ss:02d}]"
                text = s.get("text", "").strip()
                if text:
                    all_transcripts.append(f"{ts} {text}")
        else:
            raw_text = res_data.get("text", "").strip()
            if raw_text:
                all_transcripts.append(raw_text)

    if was_split:
        cleanup_temp_chunks(audio_path)

    full_transcript = "\n".join(all_transcripts).strip()
    if not full_transcript:
        raise RuntimeError("Groq Whisper returned an empty transcript for this audio.")

    return full_transcript

def get_available_groq_models(api_key):
    """Dynamically fetches active chat models directly from the user's Groq account."""
    url = "https://api.groq.com/openai/v1/models"
    clean_key = (api_key or "").strip()
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {clean_key}",
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            models = [m.get("id") for m in data.get("data", []) if m.get("id")]
            # Exclude guardrails, safety classifiers, audio, speech, compound pipelines, and restricted models
            excluded = [
                "guard", "whisper", "orpheus", "tts", "embedding", "safeguard",
                "moderation", "canopylabs", "allam", "compound"
            ]
            chat_models = [m for m in models if not any(k in m.lower() for k in excluded)]
            return chat_models
    except Exception:
        return ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.6-27b"]

def strip_think_tags(text):
    """Strips internal thinking/reasoning blocks emitted by reasoning models like GPT-OSS / DeepSeek."""
    if not text:
        return ""
    cleaned = re.sub(r"<think>[\s\S]*?</think>", "", text, flags=re.DOTALL)
    cleaned = re.sub(r"</?think>", "", cleaned)
    lines = cleaned.split("\n")
    first_content_idx = 0
    for i, line in enumerate(lines):
        s = line.strip()
        if re.match(r"^\[\d{1,2}:\d{2}", s) or s.startswith("## ") or s.startswith("{") or s.startswith("["):
            first_content_idx = i
            break
    if first_content_idx > 0:
        cleaned = "\n".join(lines[first_content_idx:])
    return cleaned.strip()

def call_groq_chat(messages, api_key, model_list=None, max_tokens=1500):
    """Calls Groq chat completion with automatic model fallback and rate-limit backoff across active LLMs."""
    url = "https://api.groq.com/openai/v1/chat/completions"
    clean_key = (api_key or "").strip()

    if not model_list:
        model_list = get_available_groq_models(clean_key)
        if not model_list:
            model_list = [
                "openai/gpt-oss-120b",
                "openai/gpt-oss-20b",
                "qwen/qwen3.6-27b"
            ]

    last_errors = []
    for m in model_list:
        payload = {
            "model": m,
            "messages": messages,
            "temperature": 0.1,
            "max_tokens": max_tokens
        }
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {clean_key}",
                "Content-Type": "application/json",
                "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
            }
        )
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=API_TIMEOUT) as resp:
                    res_data = json.loads(resp.read().decode("utf-8"))
                    choices = res_data.get("choices", [])
                    if choices and choices[0].get("message"):
                        raw_content = choices[0]["message"].get("content", "").strip()
                        cleaned_content = strip_think_tags(raw_content)
                        return cleaned_content, m
            except urllib.error.HTTPError as e:
                err_msg = extract_http_error(e)
                last_errors.append(f"{m} (att {attempt+1}) -> {err_msg}")
                if e.code in (429, 413, 503):
                    time.sleep(3.0 * (attempt + 1))
                    continue
                break
            except Exception as e:
                last_errors.append(f"{m} -> {str(e)}")
                time.sleep(1.0)
                continue

    err_summary = " | ".join(last_errors) if last_errors else "All models failed"
    raise RuntimeError(f"Groq note synthesis failed: {err_summary}")

def sanitize_whisper_prompt(raw_text):
    """
    Strips brackets, metadata labels, and gender keywords so Whisper receives
    only clean proper nouns and terminology, preventing Whisper decoder prompt looping.
    """
    if not raw_text:
        return ""
    # Remove bracketed metadata like (Male), (Female), [Host]
    t = re.sub(r'[\(\[\{][^\)\]\}]*[\)\]\}]', ' ', str(raw_text))
    # Remove gender words and special symbols
    t = re.sub(r'\b(male|female|host|attendee|attendees)\b', ' ', t, flags=re.IGNORECASE)
    t = re.sub(r'[^a-zA-Z0-9\s,.-]', ' ', t)
    # Collapse multiple commas / spaces
    t = ", ".join([w.strip() for w in t.split(",") if w.strip()])
    return t[:350]

def normalize_dialogue_line(pl, default_speaker="Unknown Speaker"):
    """Normalizes any dialogue line strictly to: [TIME] - SPEAKER - Spoken words"""
    pl = pl.strip()
    # Match [TIME] - Speaker Name - Spoken text (allowing hyphens in spoken text)
    m = re.match(r"^(\[\d{1,2}:\d{2}(?::\d{2})?\])\s*-\s*([A-Za-z\s\(\)\'\.\/]+?)\s*-\s*(.+)$", pl)
    if m and m.group(2).strip() and m.group(3).strip():
        return f"{m.group(1)} - {m.group(2).strip()} - {m.group(3).strip()}"
    m = re.match(r"^(\[\d{1,2}:\d{2}(?::\d{2})?\])\s*([A-Za-z\s\(\)\'\.\/]+?)\s*:\s*(.+)$", pl)
    if m and m.group(2).strip() and m.group(3).strip():
        return f"{m.group(1)} - {m.group(2).strip()} - {m.group(3).strip()}"
    m = re.match(r"^(\[\d{1,2}:\d{2}(?::\d{2})?\])\s*([A-Za-z\s\(\)\'\.\/]+?)\s*-\s*(.+)$", pl)
    if m and m.group(2).strip() and m.group(3).strip():
        return f"{m.group(1)} - {m.group(2).strip()} - {m.group(3).strip()}"
    m = re.match(r"^(\[\d{1,2}:\d{2}(?::\d{2})?\])\s*(.+)$", pl)
    if m and m.group(2).strip():
        return f"{m.group(1)} - {default_speaker} - {m.group(2).strip()}"
    return pl

def merge_consecutive_speaker_turns(text):
    """
    Merges consecutive dialogue snippets from the same speaker into a single coherent paragraph,
    retaining the starting timestamp and speaker label.
    """
    if not text or not text.strip():
        return text

    lines = [l.strip() for l in text.split("\n") if l.strip()]
    merged = []
    current_speaker = None
    current_time = None
    current_texts = []

    for line in lines:
        m = re.match(r"^(\[\d{1,2}:\d{2}(?::\d{2})?\])\s*-\s*([A-Za-z\s\(\)\'\.\/]+?)\s*-\s*(.+)$", line)
        if m:
            ts, speaker, text_part = m.group(1), m.group(2).strip(), m.group(3).strip()
            if speaker == current_speaker and current_speaker is not None:
                current_texts.append(text_part)
            else:
                if current_speaker is not None and current_texts:
                    combined_text = " ".join(current_texts)
                    merged.append(f"{current_time} - {current_speaker} - {combined_text}")
                current_speaker = speaker
                current_time = ts
                current_texts = [text_part]
        else:
            if current_speaker is not None and current_texts:
                combined_text = " ".join(current_texts)
                merged.append(f"{current_time} - {current_speaker} - {combined_text}")
                current_speaker = None
                current_time = None
                current_texts = []
            merged.append(line)

    if current_speaker is not None and current_texts:
        combined_text = " ".join(current_texts)
        merged.append(f"{current_time} - {current_speaker} - {combined_text}")

    return "\n\n".join(merged)

def attribute_speakers_in_transcript(raw_transcript, attendees_meta, api_key):
    """
    Takes timestamped Whisper output ([MM:SS] Text) and formats strictly as:
    [TIME] - SPEAKER - Spoken text
    Assigns speaker names based on confidence threshold and merges consecutive turns.
    """
    if not raw_transcript or not raw_transcript.strip():
        return raw_transcript

    if not attendees_meta:
        formatted_lines = []
        for line in raw_transcript.split("\n"):
            line = line.strip()
            if not line:
                continue
            formatted_lines.append(normalize_dialogue_line(line, "Unknown Speaker"))
        raw_combined = "\n".join(formatted_lines)
        return merge_consecutive_speaker_turns(raw_combined)

    # Format attendee guidance for LLM
    if isinstance(attendees_meta, list):
        att_desc = []
        for a in attendees_meta:
            if isinstance(a, dict) and a.get("name"):
                sex = a.get("sex", "")
                att_desc.append(f"- {a['name']}" + (f" ({sex})" if sex else ""))
            elif isinstance(a, str) and a.strip():
                att_desc.append(f"- {a.strip()}")
        att_str = "\n".join(att_desc)
    else:
        att_str = str(attendees_meta).strip()

    if not att_str or "AttendeeONE" in att_str:
        return merge_consecutive_speaker_turns(raw_transcript)

    lines = [l.strip() for l in raw_transcript.split("\n") if l.strip()]
    if not lines:
        return raw_transcript

    # Chunk lines into batches of ~25 lines (~2,000 chars) for reliable attribution
    batch_size = 25
    batches = [lines[i:i+batch_size] for i in range(0, len(lines), batch_size)]
    attributed_lines = []

    sys_prompt = (
        "You are a professional meeting transcriptionist and diarization editor.\n"
        "Your task is to take raw timestamped snippets and convert them into natural, beautifully formatted conversational dialogue.\n\n"
        "RULES:\n"
        "1. DIALOGUE TURNS & PARAGRAPHS:\n"
        "   - When a speaker speaks or takes a turn, start the entry with:\n"
        "     [MM:SS] - Speaker Name - Spoken text...\n"
        "   - Combine continuous speech from the same speaker into natural sentences and paragraphs.\n"
        "   - For long speech blocks, break them into readable paragraphs (2-4 sentences each) with their timestamp so it is comfortable and easy for humans to read.\n"
        "2. SPEAKER ATTRIBUTION & CONFIDENCE:\n"
        "   - Attribute speakers based on context, greetings, and conversational flow.\n"
        "   - If not confident in a specific attendee, label as 'Unknown Male Speaker' or 'Unknown Female Speaker' (or 'Unknown Speaker').\n"
        "3. FIDELITY:\n"
        "   - Preserve all verbatim spoken words. Do not summarize or omit text.\n"
        "4. FORMAT:\n"
        "   - Start immediately with the first dialogue turn. No introductory remarks."
    )

    models_to_try = [
        "openai/gpt-oss-120b",
        "openai/gpt-oss-20b",
        "qwen/qwen3.6-27b"
    ]

    for idx, batch in enumerate(batches):
        batch_text = "\n".join(batch)
        user_prompt = f"Meeting Attendees:\n{att_str}\n\nRaw Audio Snippets:\n{batch_text}"
        try:
            res, _ = call_groq_chat(
                [
                    {"role": "system", "content": sys_prompt},
                    {"role": "user", "content": user_prompt}
                ],
                api_key=api_key,
                model_list=models_to_try,
                max_tokens=1800
            )
            clean_res = res.strip()
            for l in clean_res.split("\n"):
                l_str = l.strip()
                if not l_str:
                    continue
                if re.match(r"^\[\d{1,2}:\d{2}", l_str):
                    attributed_lines.append(normalize_dialogue_line(l_str))
                else:
                    attributed_lines.append(l_str)
        except Exception:
            for bl in batch:
                attributed_lines.append(normalize_dialogue_line(bl, "Unknown Speaker"))

        if idx < len(batches) - 1:
            time.sleep(1.0)

    unmerged_raw = "\n\n".join([l for l in attributed_lines if l.strip()]).strip()
    return unmerged_raw

def prepare_gemini_prompt_and_open(transcript_path, title="", attendees=""):
    """
    Formats the complete transcript into a professional prompt for Google Gemini Web,
    copies it directly to the system clipboard (wl-copy / xclip), and opens Gemini in browser.
    """
    transcript_content = ""
    p = Path(transcript_path) if transcript_path else None
    if p and p.exists():
        try:
            with open(p, "r", encoding="utf-8") as f:
                transcript_content = f.read().strip()
        except Exception:
            pass

    if not transcript_content:
        return {"status": "error", "message": "Transcript file not found"}

    meta_title = title or p.parent.name.split(" - ")[0] if p else "Meeting"

    prompt = f"""Please analyze this meeting transcript and generate comprehensive, structured executive meeting notes.

Meeting Title: {meta_title}
Attendees: {attendees or "Listed in transcript"}

=====================
VERBATIM TRANSCRIPT:
=====================
{transcript_content}

=====================
REQUESTED OUTPUT FORMAT:
=====================
1. Executive Summary & Overview
2. Key Discussion Points & Insights
3. Explicit Agreements & Decisions Log
4. Action Items Table (Action Item | Owner | Target Date | Context)
5. Next Steps & Follow-ups"""

    # 1. Copy formatted prompt to clipboard
    try:
        proc = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE)
        proc.communicate(input=prompt.encode("utf-8"))
    except Exception:
        try:
            proc = subprocess.Popen(["xclip", "-selection", "clipboard"], stdin=subprocess.PIPE)
            proc.communicate(input=prompt.encode("utf-8"))
        except Exception:
            pass

    # 2. Open Gemini Web in default browser
    try:
        subprocess.Popen(
            ["xdg-open", "https://gemini.google.com/app"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
    except Exception:
        pass

    return {"status": "ok", "message": "Prompt copied to clipboard and Gemini opened"}

def run_transcription_job(audio_path, mode="meeting", title="", speakers=""):
    state = get_state()
    settings = load_settings()

    api_key = settings.get("groq_api_key", "").strip() or os.environ.get("GROQ_API_KEY", "").strip()

    if not api_key:
        err_msg = "Groq API key is not configured. Please open Oma Scribe Settings."
        notify("Oma Scribe Error", err_msg)
        state.update({
            "is_processing": False,
            "transcribe_pid": None,
            "current_model": "",
            "status_message": f"Error: {err_msg}",
            "last_error": err_msg
        })
        save_state(state)
        return

    p = Path(audio_path)
    note_dir = p.parent
    meta = load_note_metadata(note_dir)

    if speakers and isinstance(speakers, str) and speakers.strip().startswith("{"):
        try:
            extra_meta = json.loads(speakers)
            meta.update(extra_meta)
            if extra_meta.get("title") and not title:
                title = extra_meta.get("title")
            save_note_metadata(note_dir, meta)
            speakers = ""
        except Exception:
            pass

    if not title and meta.get("title"):
        title = meta.get("title")

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

        meta["title"] = title.strip()
        meta["date_time_str"] = date_time_str
        save_note_metadata(note_dir, meta)

    audio_duration = get_audio_duration(audio_path)
    estimated_duration = max(4, int(audio_duration / 120) + 3)

    state.update({
        "is_processing": True,
        "transcribe_pid": os.getpid(),
        "processing_start_time": time.time(),
        "estimated_duration": estimated_duration,
        "current_audio_file": str(audio_path),
        "current_folder": str(note_dir),
        "current_model": "Whisper Large v3",
        "progress_percent": 15,
        "processing_stage": "Uploading to Groq LPU (Whisper Large v3)...",
        "status_message": "Transcribing with Groq...",
        "last_error": ""
    })
    save_state(state)
    notify("Processing Audio", f"Transcribing {note_dir.name} on Groq LPUs...")

    try:
        # 1. Transcribe audio with Whisper Large v3 (clean prompt="" to prevent decoder looping)
        update_progress("Transcribing audio on Groq LPUs (Whisper Large v3)...", 40, current_model="Whisper Large v3")
        raw_transcript = transcribe_audio_with_groq(str(audio_path), api_key=api_key, prompt="")

        # 2. Attribute Speakers & Format as: [TIME] - SPEAKER - Spoken text
        update_progress("Attributing speakers and formatting transcript...", 75, current_model="Groq LLM")
        attendees = meta.get("attendees", [])
        transcript_text = attribute_speakers_in_transcript(raw_transcript, attendees, api_key=api_key)

        # 3. SAVE TRANSCRIPT IMMEDIATELY
        notes_fmt = settings.get("notes_format", "md").lower()
        formatted_trans = format_notes_content(transcript_text, notes_fmt)
        transcript_file = note_dir / f"transcript.{notes_fmt}"
        with open(transcript_file, "w", encoding="utf-8") as f:
            f.write(formatted_trans)

        meta["has_transcript"] = True
        meta["title"] = title
        meta["notes_format"] = notes_fmt
        save_note_metadata(note_dir, meta)

        state.update({
            "is_processing": False,
            "transcribe_pid": None,
            "progress_percent": 100,
            "processing_stage": "Complete",
            "last_processed_file": str(audio_path),
            "last_notes_file": "",
            "last_transcript_file": str(transcript_file),
            "status_message": "Transcript Ready",
            "last_error": ""
        })
        save_state(state)
        notify("Transcription Complete", f"Transcript ready for {note_dir.name}")

    except Exception as e:
        err_str = str(e)
        state.update({
            "is_processing": False,
            "transcribe_pid": None,
            "current_model": "",
            "progress_percent": 0,
            "processing_stage": "",
            "status_message": f"Error: {err_str}",
            "last_error": err_str
        })
        save_state(state)
        notify("Groq Transcription Error", err_str)

def list_history():
    storage = get_storage_path()
    storage.mkdir(parents=True, exist_ok=True)
    items = []

    for d in sorted(storage.iterdir(), key=os.path.getmtime, reverse=True):
        if d.is_dir() and d.name not in ("recordings", "notes", "transcripts"):
            audio_files = list(d.glob("*.opus")) + list(d.glob("*.mp3")) + list(d.glob("*.m4a")) + list(d.glob("*.wav"))
            if not audio_files:
                continue
            audio_p = audio_files[0]

            notes_files = list(d.glob("notes.*"))
            notes_p = notes_files[0] if notes_files else None
            has_notes = notes_p is not None and notes_p.exists()

            trans_files = list(d.glob("transcript.*"))
            trans_p = trans_files[0] if trans_files else None
            has_transcript = trans_p is not None and trans_p.exists()

            meta = load_note_metadata(d)

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

    return items[:50]

def open_file_in_editor(file_path):
    if not file_path or not os.path.exists(file_path):
        return
    try:
        res = subprocess.run(["which", "omarchy-launch-editor"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0:
            subprocess.Popen(["omarchy-launch-editor", file_path])
            return
    except Exception:
        pass
    try:
        subprocess.Popen(["xdg-open", file_path])
    except Exception:
        pass

def open_storage_folder():
    storage = get_storage_path()
    try:
        subprocess.Popen(["xdg-open", str(storage)])
    except Exception:
        pass

def rename_note(target_folder_or_audio, new_title):
    p = Path(target_folder_or_audio)
    folder = p if p.is_dir() else p.parent
    if not folder.exists() or not new_title or not new_title.strip():
        return {"status": "error", "message": "Invalid folder or title"}

    meta = load_note_metadata(folder)
    meta["title"] = new_title.strip()
    save_note_metadata(folder, meta)

    date_time_str = meta.get("date_time_str") or format_folder_datetime(datetime.fromtimestamp(folder.stat().st_mtime))
    expected_folder_name = f"{new_title.strip()} - {date_time_str}"
    safe_expected = "".join(c for c in expected_folder_name if c not in r'\/<>:"|?*').strip()

    storage = get_storage_path()
    if folder.parent == storage and folder.name != safe_expected:
        new_folder = storage / safe_expected
        try:
            folder.rename(new_folder)
            folder = new_folder
        except Exception as e:
            return {"status": "error", "message": str(e)}

    return {"status": "ok", "new_folder": str(folder), "title": new_title.strip()}

def delete_recording(target_folder_or_audio):
    p = Path(target_folder_or_audio)
    folder = p if p.is_dir() else p.parent
    if folder.exists() and folder.parent == get_storage_path():
        import shutil
        shutil.rmtree(folder, ignore_errors=True)
        return {"status": "ok"}
    elif p.exists():
        p.unlink(missing_ok=True)
        return {"status": "ok"}
    return {"status": "error", "message": "File not found"}

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
        metadata_raw = sys.argv[2] if len(sys.argv) > 2 else ""
        print(json.dumps(stop_recording(metadata_raw)))

    elif cmd == "cancel":
        print(json.dumps(cancel_transcription()))

    elif cmd == "clear-error":
        print(json.dumps(clear_error()))

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

    elif cmd == "pick-directory":
        print(json.dumps(pick_directory()))

    elif cmd == "read-file":
        target = sys.argv[2]
        if os.path.exists(target):
            with open(target, "r", encoding="utf-8") as f:
                print(f.read())
        else:
            print("")

    elif cmd == "open-gemini":
        target = sys.argv[2] if len(sys.argv) > 2 else ""
        title = sys.argv[3] if len(sys.argv) > 3 else ""
        attendees = sys.argv[4] if len(sys.argv) > 4 else ""
        print(json.dumps(prepare_gemini_prompt_and_open(target, title, attendees)))

    else:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))

if __name__ == "__main__":
    main()
