"""Personal folders for meetings, kept on this Mac in DATA/folders.json.

A meeting sits in at most one folder. Assignments live here instead of in meeting.json, so a
teammate's synced meeting can be filed too and nothing in the shared sync folder changes.
Rules file future recordings of a recurring calendar event into the folder the user chose once.
"""

from __future__ import annotations

import json
import threading
import uuid

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from .paths import DATA

FILE = DATA / "folders.json"
_lock = threading.Lock()
router = APIRouter(prefix="/api/folders")


def load() -> dict:
    try:
        state = json.loads(FILE.read_text())
    except (OSError, ValueError):
        state = {}
    return {"folders": state.get("folders", []), "assignments": state.get("assignments", {}), "rules": state.get("rules", [])}


def _save(state: dict) -> None:
    temp = FILE.with_suffix(".tmp")
    temp.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    temp.replace(FILE)


def _folder(state: dict, folder_id: str) -> dict:
    for folder in state["folders"]:
        if folder["id"] == folder_id:
            return folder
    raise HTTPException(404, "폴더를 찾을 수 없어요.")


def folder_for_series(series_id: str | None) -> str | None:
    """The folder a rule files this recurring event into, if the folder still exists."""
    if not series_id:
        return None
    state = load()
    ids = {folder["id"] for folder in state["folders"]}
    return next((rule["folder_id"] for rule in state["rules"] if rule["series_id"] == series_id and rule["folder_id"] in ids), None)


def assign(meeting_id: str, folder_id: str | None) -> None:
    with _lock:
        state = load()
        if folder_id:
            state["assignments"][meeting_id] = folder_id
        else:
            state["assignments"].pop(meeting_id, None)
        _save(state)


def names() -> dict[str, str]:
    """meeting id -> folder name, for the MCP server."""
    state = load()
    by_id = {folder["id"]: folder["name"] for folder in state["folders"]}
    return {meeting: by_id[folder] for meeting, folder in state["assignments"].items() if folder in by_id}


class NewFolder(BaseModel):
    name: str


class Move(BaseModel):
    meeting_ids: list[str]
    folder_id: str | None = None


class Rule(BaseModel):
    series_id: str
    title: str
    folder_id: str


def _clean(name: str) -> str:
    name = name.strip()
    if not name:
        raise HTTPException(400, "폴더 이름을 입력하세요.")
    return name[:60]


@router.get("")
def overview():
    return load()


@router.post("")
def create(body: NewFolder):
    with _lock:
        state = load()
        folder = {"id": uuid.uuid4().hex[:12], "name": _clean(body.name)}
        state["folders"].append(folder)
        _save(state)
    return {**state, "created": folder}


@router.patch("/{folder_id}")
def rename(folder_id: str, body: NewFolder):
    with _lock:
        state = load()
        _folder(state, folder_id)["name"] = _clean(body.name)
        _save(state)
    return state


@router.delete("/{folder_id}")
def delete(folder_id: str):
    """Removes the folder and its rules; its meetings go back to having no folder."""
    with _lock:
        state = load()
        _folder(state, folder_id)
        state["folders"] = [folder for folder in state["folders"] if folder["id"] != folder_id]
        state["assignments"] = {meeting: folder for meeting, folder in state["assignments"].items() if folder != folder_id}
        state["rules"] = [rule for rule in state["rules"] if rule["folder_id"] != folder_id]
        _save(state)
    return state


@router.put("/assignments")
def move(body: Move):
    """Files meetings (or takes them out with folder_id null). When one meeting from a recurring
    calendar event is filed, the response suggests a rule so later occurrences go there too."""
    with _lock:
        state = load()
        if body.folder_id:
            _folder(state, body.folder_id)
        for meeting_id in body.meeting_ids:
            if body.folder_id:
                state["assignments"][meeting_id] = body.folder_id
            else:
                state["assignments"].pop(meeting_id, None)
        _save(state)
    suggestion = None
    if body.folder_id and len(body.meeting_ids) == 1:
        try:
            meta = json.loads((DATA / body.meeting_ids[0] / "meeting.json").read_text())
        except (OSError, ValueError):
            meta = {}
        event = meta.get("calendar") or {}
        series = event.get("series_id")
        if series and not any(rule["series_id"] == series and rule["folder_id"] == body.folder_id for rule in state["rules"]):
            suggestion = {"series_id": series, "title": event.get("title") or meta.get("title", ""), "folder_id": body.folder_id}
    return {**state, "suggestion": suggestion}


@router.post("/rules")
def learn(body: Rule):
    with _lock:
        state = load()
        _folder(state, body.folder_id)
        state["rules"] = [rule for rule in state["rules"] if rule["series_id"] != body.series_id]
        state["rules"].append({"series_id": body.series_id, "title": body.title, "folder_id": body.folder_id})
        _save(state)
    return state


@router.delete("/rules/{series_id}")
def forget(series_id: str):
    with _lock:
        state = load()
        state["rules"] = [rule for rule in state["rules"] if rule["series_id"] != series_id]
        _save(state)
    return state
