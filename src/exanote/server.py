"""Loopback-only IPC API for the SwiftUI app and local recording controller."""

from __future__ import annotations

import json
import asyncio
import os
import secrets
import shutil
import subprocess
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse
from fastapi.responses import FileResponse
from pydantic import BaseModel

from .pipeline import process_recording
from .live import LiveMeeting, shared_translator
from . import models
from . import folders
from .integrations import router as integrations_router
from .paths import DATA
from .workspace_api import router as workspace_router, start_background_sync

ROOT = Path(__file__).resolve().parents[2]
DATA.mkdir(parents=True, exist_ok=True)
TOKEN_PATH = DATA / "ipc-token"
if TOKEN_PATH.exists():
    IPC_TOKEN = TOKEN_PATH.read_text().strip()
else:
    IPC_TOKEN = secrets.token_urlsafe(32)
    descriptor = os.open(TOKEN_PATH, os.O_CREAT | os.O_WRONLY | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as token_file:
        token_file.write(IPC_TOKEN)
os.chmod(TOKEN_PATH, 0o600)

app = FastAPI(title="Exanote", docs_url=None, redoc_url=None)
app.include_router(workspace_router)
app.include_router(integrations_router)
app.include_router(folders.router)
start_background_sync()
threading.Thread(target=models.adopt_from_hf_cache_once, name="adopt-models", daemon=True).start()
jobs = ThreadPoolExecutor(max_workers=1)
live_jobs = ThreadPoolExecutor(max_workers=1, thread_name_prefix="live-audio")
live_meetings: dict[str, LiveMeeting] = {}
# Prepare translation while the user opens the app. It has its own serial MLX
# thread. Do not start a model download merely by opening the app.
if models.BY_ID["notes"].installed or os.getenv(models.BY_ID["notes"].override):
    shared_translator()
recording: str | None = None
processing: str | None = None  # The meeting whose models are loaded right now.
waiting: list[str] = []  # Meetings submitted to jobs and not started yet, in order.
progress: dict[str, dict] = {}  # meeting id -> {"stage", "fraction", "started_at"} while processing.
lock = threading.Lock()
meta_lock = threading.Lock()  # Serialises read-modify-write of meeting.json within this worker.
# Exanote's own recordings are written as uncompressed CAF so a crash keeps everything up to the
# last buffer (an unfinished AAC .m4a has no index and cannot be opened), then compressed here.
RECORDING_FILE = "audio.caf"


@app.middleware("http")
async def require_local_token(request: Request, call_next):
    if not secrets.compare_digest(request.headers.get("X-Exanote-Token", ""), IPC_TOKEN):
        return JSONResponse({"detail": "Unauthorized local client"}, status_code=401)
    return await call_next(request)


def _folder(meeting_id: str) -> Path:
    try:
        uuid.UUID(meeting_id)
    except ValueError as error:
        raise HTTPException(400, "Invalid meeting ID") from error
    return DATA / meeting_id


def _read(meeting_id: str) -> dict:
    path = _folder(meeting_id) / "meeting.json"
    if not path.exists():
        raise HTTPException(404, "Meeting not found")
    return json.loads(path.read_text())


def _write(meta: dict) -> None:
    path = _folder(meta["id"]) / "meeting.json"
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(meta, ensure_ascii=False, indent=2))
    temp.replace(path)


def _modify(meeting_id: str, change) -> dict:
    """Re-read meeting.json, apply change(meta) and save, so edits made meanwhile are kept."""
    with meta_lock:
        meta = _read(meeting_id)
        change(meta)
        _write(meta)
        return meta


def _new_meeting(title: str, filename: str) -> dict:
    meeting_id = str(uuid.uuid4())
    _folder(meeting_id).mkdir(parents=True)
    meta = {"id": meeting_id, "title": title, "created_at": datetime.now(timezone.utc).isoformat(), "status": "queued", "filename": filename}
    _write(meta)
    return meta


def _submit(meeting_id: str) -> None:
    with lock:
        if meeting_id not in waiting:
            waiting.append(meeting_id)
    jobs.submit(_process, meeting_id)


def _set_progress(meeting_id: str, stage: str, fraction: float) -> None:
    with lock:
        started = progress.get(meeting_id, {}).get("started_at") or time.time()
        progress[meeting_id] = {"stage": stage, "fraction": round(min(1.0, max(0.0, fraction)), 3), "started_at": started}


def _compress_recording(meeting_id: str) -> None:
    """Turn a finished CAF recording into AAC .m4a; keep the CAF if conversion fails."""
    meta = _read(meeting_id)
    source = _folder(meeting_id) / meta["filename"]
    if source.suffix != ".caf" or not source.exists():
        return
    target = source.with_name("audio.m4a")
    temp = target.with_name(".audio.tmp.m4a")
    converted = subprocess.run(
        ["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", str(source), str(temp)],
        capture_output=True, check=False,
    )
    if converted.returncode != 0 or not temp.exists() or temp.stat().st_size == 0:
        temp.unlink(missing_ok=True)
        return
    temp.replace(target)
    _modify(meeting_id, lambda meta: meta.update(filename=target.name))
    source.unlink(missing_ok=True)


def _process(meeting_id: str) -> None:
    global processing
    with lock:
        if meeting_id in waiting:
            waiting.remove(meeting_id)
        processing = meeting_id
    _set_progress(meeting_id, "decode", 0.0)
    try:
        def start(meta: dict) -> None:
            meta["status"] = "processing"
            meta.pop("error", None)

        _modify(meeting_id, start)
        _compress_recording(meeting_id)
        meta = _read(meeting_id)
        # Only the app's own recordings carry microphone (left) and system audio (right) apart.
        result = process_recording(
            _folder(meeting_id) / meta["filename"],
            two_channel=meta.get("source") == "recording",
            language="English" if meta.get("live_translation") or (_folder(meeting_id) / "live.json").exists() else "Korean",
            progress=lambda stage, fraction: _set_progress(meeting_id, stage, fraction),
        )
        (_folder(meeting_id) / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
        speakers = {u["speaker"] for u in result["utterances"] if u["speaker"] is not None}

        def finish(meta: dict) -> None:
            meta.update({"status": "done", "duration": result["duration"], "language": result["language"], "speakers": len(speakers)})
            if result.get("self_speaker") is not None:
                meta.setdefault("speaker_names", {}).setdefault(str(result["self_speaker"]), "나")

        _modify(meeting_id, finish)
    except Exception as error:
        message = str(error)
        try:
            _modify(meeting_id, lambda meta: meta.update({"status": "error", "error": message}))
        except HTTPException:
            pass  # The meeting folder is gone.
    finally:
        with lock:
            processing = None
            progress.pop(meeting_id, None)


def _with_progress(meta: dict) -> dict:
    """Adds live processing progress, queue position and any model download to a meeting."""
    with lock:
        current = progress.get(meta["id"])
        position = waiting.index(meta["id"]) + (1 if processing else 0) if meta["id"] in waiting else None
    if current:
        download = [item for item in models.overview()["models"] if item["downloading"]]
        meta = {**meta, "progress": {
            **current,
            "elapsed": round(time.time() - current["started_at"], 1),
            "download": {"name": download[0]["name"], "bytes": download[0]["bytes"], "expected_bytes": download[0]["expected_bytes"]} if download else None,
        }}
    if position is not None:
        meta = {**meta, "queue_position": position}
    return meta


def _audio_recorded(meeting_id: str, meta: dict) -> bool:
    audio = _folder(meeting_id) / meta["filename"]
    # A CAF header alone is 4 KB; anything beyond it is sound.
    return audio.exists() and audio.stat().st_size > (8192 if audio.suffix == ".caf" else 0)


def _finish_recording(meeting_id: str, *, recovered: bool = False) -> dict:
    """Queue a recording whose audio is on disk. recovered: the app or worker stopped unexpectedly."""
    meta = _read(meeting_id)
    if not _audio_recorded(meeting_id, meta):
        error = "Audio capture produced no file. Check Microphone and System Audio Recording permissions."
        _modify(meeting_id, lambda meta: meta.update({"status": "error", "error": error}))
        raise HTTPException(500, error)

    def queue(meta: dict) -> None:
        meta["status"] = "queued"
        if recovered:
            meta["recovered"] = True

    meta = _modify(meeting_id, queue)
    _submit(meeting_id)
    return meta


def _resume_interrupted() -> None:
    """At worker start, finish work a previous worker left behind (it crashed or was killed).

    A recording whose file changed in the last 15 s may still be written by a running app; that
    app finishes it through /api/record/stop with its meeting id.
    """
    for path in DATA.glob("*/meeting.json"):
        try:
            meta = json.loads(path.read_text())
            status = meta.get("status")
            if status in {"queued", "processing"}:
                _submit(meta["id"])
            elif status == "recording":
                audio = path.parent / meta["filename"]
                if audio.exists() and time.time() - audio.stat().st_mtime < 15:
                    continue
                if _audio_recorded(meta["id"], meta):
                    _finish_recording(meta["id"], recovered=True)
                else:
                    shutil.rmtree(path.parent, ignore_errors=True)
        except (OSError, json.JSONDecodeError, KeyError, HTTPException):
            continue


_resume_interrupted()


@app.get("/api/status")
def status():
    with lock:
        current = {"id": recording} if recording else None
        busy = processing
    return {"recording": current, "processing": busy, "local": True, "protocol_version": 2}


@app.get("/api/meetings")
def meetings():
    entries = []
    for path in DATA.glob("*/meeting.json"):
        try:
            entries.append(_with_progress(json.loads(path.read_text())))
        except (OSError, json.JSONDecodeError):
            continue
    return sorted(entries, key=lambda item: item["created_at"], reverse=True)


@app.get("/api/meetings/{meeting_id}")
def meeting(meeting_id: str):
    meta = _with_progress(_read(meeting_id))
    result = _folder(meeting_id) / "result.json"
    if result.exists():
        meta["result"] = json.loads(result.read_text())
    live = _folder(meeting_id) / "live.json"
    if live.exists():
        meta["live"] = json.loads(live.read_text())
    return meta


@app.get("/api/meetings/{meeting_id}/audio")
def audio(meeting_id: str):
    meta = _read(meeting_id)
    return FileResponse(_folder(meeting_id) / meta["filename"])


@app.post("/api/live/{meeting_id}/start")
async def start_live(meeting_id: str, offset_seconds: float = 0):
    if _read(meeting_id).get("status") != "recording":
        raise HTTPException(409, "Meeting is not recording")
    if not 0 <= offset_seconds < 86_400:
        raise HTTPException(400, "Invalid recording offset")
    if meeting_id not in live_meetings:
        loop = asyncio.get_running_loop()
        live_meetings[meeting_id] = await loop.run_in_executor(
            live_jobs, LiveMeeting, meeting_id, _folder(meeting_id) / "live.json", offset_seconds)
    return live_meetings[meeting_id].snapshot()


@app.post("/api/live/{meeting_id}/offset")
async def set_live_offset(meeting_id: str, seconds: float):
    session = live_meetings.get(meeting_id)
    if session is None:
        raise HTTPException(404, "Live session not found")
    if not 0 <= seconds < 86_400:
        raise HTTPException(400, "Invalid recording offset")
    loop = asyncio.get_running_loop()
    try:
        snapshot = await loop.run_in_executor(live_jobs, session.set_offset, seconds)
        _modify(meeting_id, lambda meta: meta.update(live_translation=True))
        return snapshot
    except ValueError as error:
        raise HTTPException(409, str(error)) from error


@app.post("/api/live/{meeting_id}/chunk")
async def live_chunk(meeting_id: str, request: Request, sample_rate: int = 16_000, sequence: int | None = None):
    session = live_meetings.get(meeting_id)
    if session is None:
        raise HTTPException(409, "Live session has not started")
    raw = await request.body()
    loop = asyncio.get_running_loop()
    try:
        return await loop.run_in_executor(live_jobs, session.feed, raw, sample_rate, sequence)
    except ValueError as error:
        raise HTTPException(400, str(error)) from error


@app.get("/api/live/{meeting_id}")
async def live_status(meeting_id: str):
    session = live_meetings.get(meeting_id)
    if session is None:
        raise HTTPException(404, "Live session not found")
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(live_jobs, session.snapshot)


@app.post("/api/live/{meeting_id}/finish")
async def finish_live(meeting_id: str):
    session = live_meetings.get(meeting_id)
    if session is None:
        raise HTTPException(404, "Live session not found")
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(live_jobs, session.finish)


@app.post("/api/import")
def import_audio(file: UploadFile = File(...)):
    suffix = Path(file.filename or "audio.wav").suffix.lower()
    # What afconvert reads (see pipeline.decode_audio); webm needs ffmpeg if it is installed.
    if suffix not in {".wav", ".mp3", ".m4a", ".aac", ".mp4", ".mov", ".flac", ".aiff", ".aif", ".caf", ".ogg", ".webm"}:
        raise HTTPException(400, "Unsupported audio format")
    meta = _new_meeting(Path(file.filename or "Recording").stem, "audio" + suffix)
    with (_folder(meta["id"]) / meta["filename"]).open("wb") as output:
        shutil.copyfileobj(file.file, output)
    _submit(meta["id"])
    return meta


class RecordStart(BaseModel):
    """The calendar event happening now, if any: it names the meeting and, for a recurring event
    with a folder rule, files it."""
    title: str | None = None
    event_id: str | None = None
    series_id: str | None = None
    live_translation: bool = False


@app.post("/api/record/start")
def start_recording(start: RecordStart | None = None):
    global recording
    with lock:
        if recording:
            raise HTTPException(409, "A recording is already in progress")
        title = (start.title or "").strip() if start else ""
        meta = _new_meeting(title or datetime.now().strftime("회의 %Y-%m-%d %H:%M"), RECORDING_FILE)
        recording = meta["id"]
        meta["status"] = "recording"
        meta["source"] = "recording"
        meta["live_translation"] = bool(start and start.live_translation)
        if start and (start.event_id or start.series_id):
            meta["calendar"] = {"event_id": start.event_id, "series_id": start.series_id, "title": title or None}
        _write(meta)
        if start and (folder := folders.folder_for_series(start.series_id)):
            folders.assign(meta["id"], folder)
    return meta


@app.post("/api/record/stop")
def stop_recording(meeting_id: str | None = None):
    """meeting_id lets the app finish its recording even if this worker restarted meanwhile."""
    global recording
    with lock:
        if recording and (meeting_id is None or meeting_id == recording):
            meeting_id, recording = recording, None
        elif meeting_id is None:
            raise HTTPException(409, "No recording is in progress")
    if _read(meeting_id).get("status") != "recording":
        raise HTTPException(409, "No recording is in progress")
    return _finish_recording(meeting_id)


@app.post("/api/record/recover")
def recover_recording():
    """The app started and found a recording its previous run never stopped (it crashed or quit)."""
    global recording
    with lock:
        meeting_id, recording = recording, None
    if meeting_id is None:
        return {"recovered": None}
    meta = _read(meeting_id)
    if not _audio_recorded(meeting_id, meta):
        shutil.rmtree(_folder(meeting_id), ignore_errors=True)
        return {"recovered": None}
    return {"recovered": _finish_recording(meeting_id, recovered=True)}


@app.post("/api/record/cancel")
def cancel_recording():
    global recording
    with lock:
        if not recording:
            raise HTTPException(409, "No recording is in progress")
        meeting_id = recording
        recording = None
    meta = _read(meeting_id)
    audio = _folder(meeting_id) / meta["filename"]
    if not audio.exists() or audio.stat().st_size == 0:
        # Nothing was captured (for example a denied permission), so leave no empty meeting behind.
        shutil.rmtree(_folder(meeting_id), ignore_errors=True)
        return {**meta, "status": "cancelled"}
    meta.update({"status": "error", "error": "Audio capture was cancelled before it started."})
    _write(meta)
    return meta


@app.post("/api/meetings/{meeting_id}/retry")
def retry(meeting_id: str):
    meta = _read(meeting_id)
    _submit(meeting_id)
    return meta


class MemoChange(BaseModel):
    text: str


class BookmarkChange(BaseModel):
    time: float
    note: str = ""


@app.put("/api/meetings/{meeting_id}/memo")
def set_memo(meeting_id: str, change: MemoChange):
    """What the user typed during or after the meeting; kept beside the generated notes."""
    return _modify(meeting_id, lambda meta: meta.update(memo=change.text))


@app.post("/api/meetings/{meeting_id}/bookmarks")
def add_bookmark(meeting_id: str, change: BookmarkChange):
    """A moment marked while recording, in seconds of recorded audio."""
    def add(meta: dict) -> None:
        marks = meta.setdefault("bookmarks", [])
        marks.append({"time": round(max(0.0, change.time), 1), "note": change.note.strip()})
        marks.sort(key=lambda item: item["time"])

    return _modify(meeting_id, add)


@app.delete("/api/meetings/{meeting_id}/bookmarks/{index}")
def delete_bookmark(meeting_id: str, index: int):
    def remove(meta: dict) -> None:
        marks = meta.get("bookmarks", [])
        if not 0 <= index < len(marks):
            raise HTTPException(404, "Bookmark not found")
        marks.pop(index)

    return _modify(meeting_id, remove)


def _busy() -> bool:
    with lock:
        return processing is not None or recording is not None


def _catalog_model(model_id: str) -> models.Model:
    if model_id not in models.BY_ID:
        raise HTTPException(404, "Unknown model")
    return models.BY_ID[model_id]


@app.get("/api/models")
def list_models():
    return {**models.overview(), "busy": _busy()}


@app.get("/api/search")
def search(q: str = ""):
    """Meetings whose title, transcript or summary contains q, each with its first matching line.

    Reads the same files as the MCP server's search_meetings; this is a plain scan, which is quick
    for hundreds of meetings. Thousands would want an index (SQLite FTS) instead.
    """
    from . import mcp_server

    needle = q.strip().lower()
    if len(needle) < 2:
        return []
    results = []
    for summary, locator in mcp_server._catalog():
        if summary["status"] != "done":
            continue
        notes, lines = mcp_server._content(locator)
        spoken = [line for line in lines if needle in line["text"].lower()]
        written = [note for note in notes.splitlines() if needle in note.lower() and not note.lstrip().startswith("#")]
        if not spoken and not written and needle not in summary["title"].lower():
            continue
        if spoken:
            first = spoken[0]
            snippet = f"[{mcp_server._clock(first['start'])}] {first['speaker']}: {first['text']}"
        elif written:
            snippet = mcp_server.BULLET.sub("", written[0]).strip()
        else:
            snippet = None
        results.append({"id": summary["id"], "matches": len(spoken) + len(written), "snippet": snippet})
    return results


@app.post("/api/models/{model_id}")
def install_model(model_id: str):
    models.start_install(_catalog_model(model_id).id)
    return list_models()


@app.delete("/api/models/{model_id}")
def delete_model(model_id: str):
    model = _catalog_model(model_id)
    with lock:
        if processing is not None:
            raise HTTPException(409, "회의를 처리하는 중에는 모델을 지울 수 없어요. 처리가 끝난 뒤 다시 시도하세요.")
    try:
        models.delete(model.id)
    except models.ModelInUse as error:
        raise HTTPException(409, f"{model.name} 모델을 받거나 쓰는 중이에요. 끝난 뒤 다시 시도하세요.") from error
    return list_models()


@app.post("/api/shutdown")
def shutdown():
    """Used by Settings ▸ Exanote 제거 so no model is being read or downloaded while it is deleted."""
    if _busy():
        raise HTTPException(409, "녹음하거나 회의를 처리하는 중이에요. 끝난 뒤 다시 시도하세요.")
    threading.Timer(0.3, os._exit, args=(0,)).start()
    return {"ok": True}
