"""Workspace endpoints for the app: choose a synced folder, export finished
meetings into it in the background, and read meetings that the user's other
Macs or teammates exported there. No cloud API is called; iCloud Drive or
Google Drive for desktop moves the files."""

from __future__ import annotations

import json
import shutil
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from . import storage
from .paths import DATA

SETTINGS = DATA / "settings.json"
STATE = DATA / "sync-state.json"
POLL_SECONDS = 15

router = APIRouter(prefix="/api")
_wake = threading.Event()
_lock = threading.Lock()
_status: dict = {"last_sync": None, "error": None}
_deleted: set[str] = set()  # Deleted this session; never re-export them.


class WorkspaceChoice(BaseModel):
    path: str | None = None


class TitleChange(BaseModel):
    title: str


class SpeakerNameChange(BaseModel):
    speaker: int
    name: str


def _load(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return default


def _save(path: Path, value) -> None:
    temp = path.with_name(f".{path.name}.workspace.tmp")  # Never shares a temp name with server.py.
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    temp.replace(path)


def _selected() -> dict | None:
    chosen = _load(SETTINGS, {}).get("workspace")
    if not chosen:
        return None
    # Refresh labels from what this Mac detects now; keep the saved copy if the folder is offline.
    return next((item for item in storage.workspaces() if item["path"] == chosen["path"]), chosen)


def _exported(workspace: dict | None) -> dict:
    return _load(STATE, {}).get(workspace["path"], {}) if workspace else {}


def sync_once() -> None:
    """Export every finished local meeting that changed since its last export."""
    workspace = _selected()
    if not workspace:
        return
    root = Path(workspace["path"])
    with _lock:
        if not root.is_dir():
            _status["error"] = "동기화 폴더를 찾을 수 없습니다. iCloud Drive 또는 Google Drive가 실행 중인지 확인하세요."
            return
        state = _load(STATE, {})
        done = state.setdefault(workspace["path"], {})
        failed = []
        for meta_path in DATA.glob("*/meeting.json"):
            meta = _load(meta_path, {})
            result_path = meta_path.parent / "result.json"
            # Demo meetings (scripts/seed_demo_meetings.py) never leave this Mac.
            if meta.get("status") != "done" or not result_path.exists() or meta.get("id") in _deleted or meta.get("demo"):
                continue
            # One meeting that cannot be exported must not hold back the others.
            try:
                names = json.dumps(meta.get("speaker_names", {}), ensure_ascii=False, sort_keys=True)
                own = json.dumps([meta.get("memo") or "", meta.get("bookmarks") or []], ensure_ascii=False)
                signature = f"{meta['title']}|{names}|{own}|{result_path.stat().st_mtime_ns}"
                if done.get(meta["id"]) == signature and (storage.meeting_folder(root, meta) / "meeting.json").exists():
                    continue  # Still there; re-export if someone removed the copy in Finder/Drive.
                storage.export_meeting(root, meta, json.loads(result_path.read_text()), workspace["account"])
                done[meta["id"]] = signature
            except (OSError, ValueError, KeyError) as error:
                failed.append(f"{meta.get('title') or meta_path.parent.name}: {error}")
        try:
            _save(STATE, state)
        except OSError as error:
            failed.append(f"동기화 상태 저장: {error}")
        _status.update(
            last_sync=datetime.now(timezone.utc).isoformat(),
            error=f"내보내기 실패 {len(failed)}건 — {'; '.join(failed)}" if failed else None,
        )


def start_background_sync() -> None:
    def loop() -> None:
        while True:
            sync_once()
            _wake.wait(POLL_SECONDS)
            _wake.clear()

    threading.Thread(target=loop, name="workspace-sync", daemon=True).start()


def _overview() -> dict:
    workspace = _selected()
    return {
        "options": storage.workspaces(),
        "selected": workspace,
        "status": {**_status, "exported_ids": list(_exported(workspace))},
    }


@router.get("/workspaces")
def workspaces():
    return _overview()


@router.put("/workspace")
def choose_workspace(choice: WorkspaceChoice):
    settings = _load(SETTINGS, {})
    if choice.path is None:
        settings.pop("workspace", None)
    else:
        # Only folders this Mac actually syncs can be chosen; never an arbitrary path.
        option = next((item for item in storage.workspaces() if item["path"] == choice.path), None)
        if option is None:
            raise HTTPException(404, "이 Mac에서 찾을 수 없는 동기화 폴더입니다.")
        settings["workspace"] = option
    _save(SETTINGS, settings)
    _status.update(error=None)
    _wake.set()
    return _overview()


@router.get("/shared")
def shared_meetings():
    workspace = _selected()
    if not workspace or not Path(workspace["path"]).is_dir():
        return []
    local = {path.parent.name for path in DATA.glob("*/meeting.json")}
    entries = []
    for entry in storage.list_meetings(workspace["path"]):
        if entry["id"] in local:
            continue  # Already listed under this Mac's own meetings.
        entry["mine"] = entry.get("author") == workspace["account"]
        entries.append(entry)
    return entries


@router.get("/shared/{meeting_id}")
def shared_meeting(meeting_id: str):
    workspace = _selected()
    if not workspace:
        raise HTTPException(404, "동기화 폴더가 선택되지 않았습니다.")
    # Resolve by ID from the listing so a request can never name a folder directly.
    entry = next((item for item in storage.list_meetings(workspace["path"]) if item["id"] == meeting_id), None)
    if entry is None:
        raise HTTPException(404, "공유 회의를 찾을 수 없습니다.")
    meeting = storage.read_meeting(entry["folder"])
    meeting["mine"] = meeting.get("author") == workspace["account"]
    meeting["folder"] = entry["folder"]
    return meeting

@router.post("/meetings/{meeting_id}/title")
def rename_meeting(meeting_id: str, change: TitleChange):
    """Used when a note starts from a calendar event, so it carries the event title."""
    try:
        uuid.UUID(meeting_id)
    except ValueError as error:
        raise HTTPException(400, "Invalid meeting ID") from error
    path = DATA / meeting_id / "meeting.json"
    meta = _load(path, None)
    if meta is None:
        raise HTTPException(404, "Meeting not found")
    title = " ".join(change.title.split())[:200]
    if not title:
        raise HTTPException(400, "제목이 비어 있습니다.")
    meta["title"] = title
    _save(path, meta)
    _wake.set()
    return meta


@router.post("/meetings/{meeting_id}/speakers")
def rename_speaker(meeting_id: str, change: SpeakerNameChange):
    try:
        uuid.UUID(meeting_id)
    except ValueError as error:
        raise HTTPException(400, "Invalid meeting ID") from error
    path = DATA / meeting_id / "meeting.json"
    meta = _load(path, None)
    if meta is None:
        raise HTTPException(404, "Meeting not found")
    result = _load(path.parent / "result.json", {})
    speakers = {item["speaker"] for item in result.get("utterances", []) if item.get("speaker") is not None}
    if meta.get("status") != "done" or change.speaker not in speakers:
        raise HTTPException(400, "이 회의에 없는 화자입니다.")
    name = " ".join(change.name.split())
    if not name or len(name) > 80:
        raise HTTPException(400, "화자 이름은 1~80자로 입력해 주세요.")
    names = dict(meta.get("speaker_names", {}))
    key = str(change.speaker)
    if name == f"화자 {change.speaker + 1}":
        names.pop(key, None)
    else:
        names[key] = name
    labels = [names.get(str(speaker), f"화자 {speaker + 1}") for speaker in speakers]
    if len(labels) != len(set(labels)):
        raise HTTPException(400, "이미 다른 화자가 사용 중인 이름입니다.")
    meta["speaker_names"] = names
    _save(path, meta)
    _wake.set()
    return meta


@router.delete("/meetings/{meeting_id}")
def delete_meeting(meeting_id: str):
    """Remove this meeting's copy from the sync folder and return the local folder
    for the app to move to the macOS Trash (so the user can restore it)."""
    try:
        uuid.UUID(meeting_id)
    except ValueError as error:
        raise HTTPException(400, "Invalid meeting ID") from error
    folder = DATA / meeting_id
    meta = _load(folder / "meeting.json", None)
    if meta is None:
        raise HTTPException(404, "Meeting not found")
    if meta.get("status") in {"recording", "queued", "processing"}:
        raise HTTPException(409, "녹음 중이거나 처리 중인 회의는 삭제할 수 없어요.")
    removed_copy = False
    with _lock:
        _deleted.add(meeting_id)
        workspace = _selected()
        if workspace:
            state = _load(STATE, {})
            state.get(workspace["path"], {}).pop(meeting_id, None)
            _save(STATE, state)
            for copy in (item for root in storage.folders(workspace["path"]) if root.is_dir() for item in root.iterdir()):
                entry = _load(copy / "meeting.json", {})
                if entry.get("id") == meeting_id and entry.get("author") == workspace["account"]:
                    shutil.rmtree(copy)  # iCloud/Drive keep deleted files recoverable.
                    removed_copy = True
    return {"id": meeting_id, "folder": str(folder), "removed_copy": removed_copy}
