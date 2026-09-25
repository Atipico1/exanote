"""Read-only MCP server so Claude Code, Codex and other MCP clients can read meeting notes.

Runs over stdio (`exanote mcp`), opens no network port, and never changes a meeting.
It reads this Mac's meetings and, when a sync folder is chosen, teammates' synced notes.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ToolAnnotations

from . import folders, storage
from .paths import DATA

READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
TRANSCRIPT_LINE = re.compile(r"^\*\*\[(\d+):(\d{2})\] (.+?)\*\* (.*)$")
BULLET = re.compile(r"^\s*(?:[-*]\s+)?(?:\[[ xX]\]\s*)?")


def _load(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return default


def _clock(seconds: float) -> str:
    total = int(seconds)
    return f"{total // 60:02d}:{total % 60:02d}"


def _local_date(value: str) -> str:
    try:
        return datetime.fromisoformat(value).astimezone().strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return value


def _speaker(meta: dict, speaker: int | None) -> str:
    if speaker is None:
        return "미확인"
    return meta.get("speaker_names", {}).get(str(speaker), f"화자 {speaker + 1}")


def _workspace() -> dict | None:
    chosen = _load(DATA / "settings.json", {}).get("workspace")
    return chosen if chosen and Path(chosen.get("path", "")).is_dir() else None


def _summary(meta: dict, source: str, author: str | None = None) -> dict:
    return {
        "id": meta["id"],
        "title": meta.get("title", ""),
        "date": _local_date(meta.get("created_at", "")),
        "duration_seconds": round(meta["duration"]) if meta.get("duration") else None,
        "status": meta.get("status", "done"),
        "speakers": meta.get("speakers"),
        "language": meta.get("language"),
        "source": source,
        "author": author,
    }


def _catalog() -> list[tuple[dict, dict]]:
    """Every readable meeting as (public summary, private locator), newest first."""
    entries: list[tuple[dict, dict]] = []
    local_ids = set()
    for path in DATA.glob("*/meeting.json"):
        meta = _load(path, None)
        if not meta or "id" not in meta:
            continue
        local_ids.add(meta["id"])
        entries.append((_summary(meta, "this_mac"), {"kind": "local", "folder": path.parent, "meta": meta}))
    workspace = _workspace()
    if workspace:
        for entry in storage.list_meetings(workspace["path"]):
            if entry.get("id") in local_ids:
                continue  # This Mac's own copy is richer than the synced text.
            mine = entry.get("author") == workspace.get("account")
            summary = _summary(entry, "my_other_mac" if mine else "shared", None if mine else entry.get("author"))
            entries.append((summary, {"kind": "shared", "folder": Path(entry["folder"]), "meta": entry}))
    filed = folders.names()
    for summary, _ in entries:
        summary["folder"] = filed.get(summary["id"])
    return sorted(entries, key=lambda item: item[0]["date"], reverse=True)


def _find(meeting_id: str) -> tuple[dict, dict]:
    key = meeting_id.strip().lower()
    matches = [item for item in _catalog() if item[0]["id"].lower() == key or item[0]["id"].lower().startswith(key)]
    if len(key) < 6 or not matches:
        raise ToolError(f"'{meeting_id}' 회의를 찾을 수 없어요. list_meetings로 ID를 확인하세요.")
    if len(matches) > 1:
        raise ToolError("ID 앞부분이 여러 회의와 겹쳐요. 더 긴 ID를 쓰세요.")
    return matches[0]


def _content(locator: dict) -> tuple[str, list[dict]]:
    """Notes Markdown and transcript lines with named speakers."""
    meta, folder = locator["meta"], locator["folder"]
    if locator["kind"] == "local":
        result = _load(folder / "result.json", {})
        names = meta.get("speaker_names", {})
        notes = storage._named_notes(result.get("notes", ""), names) if names else result.get("notes", "")
        notes += storage.user_notes_markdown(meta)
        lines = [
            {"start": item.get("start", 0.0), "end": item.get("end"), "speaker": _speaker(meta, item.get("speaker")), "text": item.get("text", "").strip()}
            for item in result.get("utterances", [])
        ]
        return notes, lines
    shared = storage.read_meeting(folder)
    lines = []
    for raw in (shared.get("transcript") or "").splitlines():
        match = TRANSCRIPT_LINE.match(raw.strip())
        if match:
            minutes, seconds, speaker, text = match.groups()
            lines.append({"start": int(minutes) * 60 + int(seconds), "end": None, "speaker": speaker, "text": text.strip()})
    return shared.get("summary") or "", lines


def _speaker_share(lines: list[dict], duration: float | None) -> list[dict]:
    spoken: dict[str, float] = {}
    for index, line in enumerate(lines):
        following = lines[index + 1]["start"] if index + 1 < len(lines) else (duration or line["start"] + 5)
        end = line["end"] if line.get("end") is not None else min(following, line["start"] + max(1.5, len(line["text"]) / 5))
        spoken[line["speaker"]] = spoken.get(line["speaker"], 0.0) + max(0.0, end - line["start"])
    total = sum(spoken.values()) or 1.0
    return [
        {"speaker": name, "seconds": round(seconds), "share_percent": round(seconds * 100 / total)}
        for name, seconds in sorted(spoken.items(), key=lambda item: -item[1])
    ]


def _within(summary: dict, since_days: int | None) -> bool:
    if not since_days:
        return True
    try:
        created = datetime.strptime(summary["date"], "%Y-%m-%d %H:%M")
    except ValueError:
        return True
    return created >= datetime.now() - timedelta(days=since_days)

server = MCPServer(
    name="exanote",
    title="Exanote",
    instructions=(
        "Exanote holds meeting summaries and speaker-labelled transcripts recorded on this Mac, plus "
        "meetings teammates shared through a synced folder. Everything is read-only. Find meetings with "
        "list_meetings (by title or date) or search_meetings (exact keyword in what was said), then read "
        "get_summary first and get_transcript only when the exact wording matters. Timestamps are mm:ss "
        "from the start of the recording."
    ),
)


def _ready(meeting_id: str) -> tuple[dict, dict]:
    summary, locator = _find(meeting_id)
    if summary["status"] != "done":
        state = {"recording": "녹음 중", "queued": "처리 대기 중", "processing": "전사와 요약을 만드는 중", "error": "처리 실패"}
        raise ToolError(f"이 회의는 아직 읽을 수 없어요 ({state.get(summary['status'], summary['status'])}).")
    return summary, locator


@server.tool(title="회의 목록", annotations=READ_ONLY)
def list_meetings(query: str = "", since_days: int | None = None, folder: str = "", limit: int = 20) -> list[dict]:
    """List meetings, newest first. Filter by a word in the title, the last N days and/or the
    user's folder name (e.g. "채용").

    Returns id, title, local date, duration, speaker count, language and source
    (this_mac, my_other_mac or shared with the teammate's name in author), and the folder.
    """
    found = [
        summary for summary, _ in _catalog()
        if _within(summary, since_days) and query.lower() in summary["title"].lower()
        and (not folder or (summary["folder"] or "").lower() == folder.strip().lower())
    ]
    return found[: max(1, min(limit, 200))]


@server.tool(title="회의 요약", annotations=READ_ONLY)
def get_summary(meeting_id: str) -> dict:
    """Read one meeting's summary notes (Markdown) with who spoke and each speaker's share of talk time.

    meeting_id may be the full ID or its first 8 characters. Cheap to call; use get_transcript
    when you need the exact words.
    """
    summary, locator = _ready(meeting_id)
    notes, lines = _content(locator)
    return {
        **summary,
        "speaker_share": _speaker_share(lines, locator["meta"].get("duration")),
        "summary": notes.strip() or None,
    }


@server.tool(title="회의 전사", annotations=READ_ONLY)
def get_transcript(meeting_id: str, speaker: str | None = None, offset: int = 0, limit: int = 400) -> dict:
    """Read a meeting's transcript as "[mm:ss] Speaker: text" lines.

    Long meetings come in pages: when next_offset is set, call again with offset=next_offset.
    speaker keeps only that person's lines (a name from get_summary's speaker_share).
    """
    summary, locator = _ready(meeting_id)
    _, lines = _content(locator)
    if speaker:
        wanted = speaker.strip().lower()
        lines = [line for line in lines if line["speaker"].lower() == wanted]
    offset = max(0, offset)
    page = lines[offset : offset + max(1, min(limit, 2000))]
    following = offset + len(page)
    return {
        "id": summary["id"],
        "title": summary["title"],
        "date": summary["date"],
        "total_lines": len(lines),
        "offset": offset,
        "next_offset": following if following < len(lines) else None,
        "lines": [f"[{_clock(line['start'])}] {line['speaker']}: {line['text']}" for line in page],
    }


@server.tool(title="키워드 검색", annotations=READ_ONLY)
def search_meetings(query: str, since_days: int | None = None, limit: int = 30) -> list[dict]:
    """Keyword search: lines in transcripts and summaries that contain the query text (case-insensitive).

    It matches the exact characters, not meaning, so try the words people would actually say
    (for Korean, a stem such as "배포" also finds "배포는"). Each hit has the meeting id, title,
    date, the mm:ss time and speaker for transcript lines, and the matching text.
    """
    needle = query.strip().lower()
    if not needle:
        raise ToolError("검색어를 입력하세요.")
    hits: list[dict] = []
    for summary, locator in _catalog():
        if summary["status"] != "done" or not _within(summary, since_days):
            continue
        notes, lines = _content(locator)
        base = {"meeting_id": summary["id"], "title": summary["title"], "date": summary["date"]}
        for line in lines:
            if needle in line["text"].lower():
                hits.append({**base, "time": _clock(line["start"]), "speaker": line["speaker"], "text": line["text"], "in": "transcript"})
        for note in notes.splitlines():
            if needle in note.lower() and not note.lstrip().startswith("#"):
                hits.append({**base, "time": None, "speaker": None, "text": BULLET.sub("", note).strip(), "in": "summary"})
        if len(hits) >= limit:
            break
    return hits[: max(1, min(limit, 200))]


def main() -> None:
    server.run("stdio")
