"""Workspace folders synced by iCloud Drive or Google Drive for desktop.

Exanote never talks to a cloud API here. Finished meetings are exported as
plain files into a folder that the user's own sync client already manages;
teammates and the user's other Macs read the same folder. Audio stays local.

Layout inside a workspace root::

    Exanote/
      2026-09-24 1530 주간회의 [1a2b3c4d]/
        transcript.md
        summary.md
        meeting.json   <- written last; a folder without it is still syncing
"""

from __future__ import annotations

import json
import os
import pwd
import re
from datetime import datetime, timezone
from pathlib import Path

from .paths import DATA

FOLDER = "Exanote"
# The folder name before the rename. Listing still reads it; the next export renames it to FOLDER,
# which the sync client uploads as a plain rename.
LEGACY_FOLDER = "Open Notes"
ICLOUD = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs"
CLOUD_STORAGE = Path.home() / "Library/CloudStorage"
SHARED_DRIVES = {"Shared drives", "공유 드라이브"}
MY_DRIVE = ("My Drive", "내 드라이브")
SKIPPED = {"Other computers", "다른 컴퓨터", ".shortcut-targets-by-id"}
# Written by the app when it creates a team folder through the Drive API (native/App/Teams.swift).
# Any synced folder holding it is offered as that team's workspace, including a teammate's shortcut.
TEAM_FILE = "exanote-team.json"


def workspaces() -> list[dict]:
    """Sync roots available on this Mac, in the order the app should offer them."""
    found = [{"kind": "local", "name": "이 Mac", "path": str(DATA / "workspace"), "account": _full_name()}]
    if ICLOUD.is_dir():
        found.append({"kind": "icloud", "name": "iCloud Drive", "path": str(ICLOUD), "account": _full_name()})
    teams = []
    for account in sorted(CLOUD_STORAGE.glob("GoogleDrive-*")):
        email = account.name.removeprefix("GoogleDrive-")
        # Probe the known folders by name: listing the account root itself is what macOS holds
        # back (about ten seconds) from a process that lacks the app's Google Drive permission.
        known = [account / name for name in (*MY_DRIVE, *sorted(SHARED_DRIVES)) if _is_dir(account / name)]
        for child in known or sorted(_dirs(account)):
            if child.name in SHARED_DRIVES:
                for drive in sorted(_dirs(child)):
                    found.append({"kind": "google-shared", "name": drive.name, "path": str(drive), "account": email})
                    teams += _teams_in(drive, email)
            elif child.name not in SKIPPED:
                found.append({"kind": "google", "name": "Google Drive", "path": str(child), "account": email})
                teams += _teams_in(child, email)
    return teams + found


def _teams_in(root: Path, account: str) -> list[dict]:
    """Team folders directly inside a drive root; a teammate's shortcut shows up there too."""
    teams = []
    # Only folders named like the app names them ("Exanote · 팀"), so a streamed My Drive is not
    # made to download every top-level folder just to look for a team file.
    for folder in sorted(folder for folder in _dirs(root) if folder.name.lower().startswith("exanote")):
        try:
            team = json.loads((folder / TEAM_FILE).read_text())
        except (OSError, json.JSONDecodeError):
            continue  # Not a team folder, or its file is still syncing.
        if isinstance(team, dict) and team.get("team_id"):
            teams.append({
                "kind": "team", "name": str(team.get("name") or folder.name), "path": str(folder), "account": account,
                "team_id": str(team["team_id"]), "folder_id": team.get("folder_id"), "owner": team.get("owner"),
            })
    return teams


def export_meeting(root: str | Path, meta: dict, result: dict, author: str) -> Path:
    """Write one finished meeting into a workspace. Re-exporting replaces it."""
    _claim_legacy_folder(Path(root))
    folder = _meeting_folder(Path(root), meta)
    for old in _dirs(Path(root) / FOLDER):
        if (old.name.endswith(f"[{meta['id'][:8]}]") and old != folder and not folder.exists()
                and _meeting_id(old) == meta["id"]):
            old.rename(folder)  # Title changed: move the same meeting, don't duplicate it.
    folder.mkdir(parents=True, exist_ok=True)
    existing = folder / "meeting.json"
    if existing.exists() and json.loads(existing.read_text()).get("author") != author:
        raise PermissionError("다른 사람이 작성한 회의는 덮어쓸 수 없습니다.")
    _atomic(folder / "transcript.md", _transcript_markdown(meta, result))
    _atomic(folder / "summary.md", _named_notes(result.get("notes", ""), meta.get("speaker_names", {})) + user_notes_markdown(meta))
    shared = {
        "id": meta["id"],
        "title": meta["title"],
        "created_at": meta["created_at"],
        "duration": result.get("duration"),
        "language": result.get("language"),
        "speakers": len({u["speaker"] for u in result.get("utterances", []) if u.get("speaker") is not None}),
        "author": author,
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "format": 1,
    }
    _atomic(existing, json.dumps(shared, ensure_ascii=False, indent=2))
    return folder


def list_meetings(root: str | Path) -> list[dict]:
    """Read only the small meeting.json files so listing never pulls transcripts."""
    entries = []
    for path in (found for folder in folders(root) for found in folder.glob("*/meeting.json")):
        try:
            entry = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue  # Partially synced or placeholder file; the next poll retries.
        entry["folder"] = str(path.parent)
        entries.append(entry)
    return sorted(entries, key=lambda item: item.get("created_at", ""), reverse=True)


def folders(root: str | Path) -> list[Path]:
    """Folders in a workspace that can hold exported meetings, the current name first."""
    return [Path(root) / FOLDER, Path(root) / LEGACY_FOLDER]


def _claim_legacy_folder(root: Path) -> None:
    folder, legacy = root / FOLDER, root / LEGACY_FOLDER
    if legacy.is_dir() and not folder.exists():
        try:
            legacy.rename(folder)
        except OSError:
            pass  # e.g. still downloading; new exports go to FOLDER and listing reads both.


def read_meeting(folder: str | Path) -> dict:
    folder = Path(folder)
    meta = json.loads((folder / "meeting.json").read_text())
    for name in ("transcript", "summary"):
        path = folder / f"{name}.md"
        meta[name] = path.read_text() if path.exists() else None  # None: still syncing.
    return meta


def _meeting_folder(root: Path, meta: dict) -> Path:
    return meeting_folder(root, meta)


def meeting_folder(root: str | Path, meta: dict) -> Path:
    """Where this meeting's copy lives in a workspace (title and time are part of the name)."""
    created = datetime.fromisoformat(meta["created_at"]).astimezone()
    title = " ".join(re.sub(r"[/:\\\x00-\x1f]+", " ", meta["title"]).split())[:80] or "회의"
    return Path(root) / FOLDER / f"{created:%Y-%m-%d %H%M} {title} [{meta['id'][:8]}]"


def _transcript_markdown(meta: dict, result: dict) -> str:
    lines = [f"# {meta['title']}", ""]
    for item in result.get("utterances", []):
        seconds = int(item["start"])
        speaker_id = item.get("speaker")
        speaker = meta.get("speaker_names", {}).get(str(speaker_id), f"화자 {speaker_id + 1}") if speaker_id is not None else "미확인"
        lines += [f"**[{seconds // 60:02d}:{seconds % 60:02d}] {speaker}** {item['text'].strip()}", ""]
    return "\n".join(lines)


def _named_notes(notes: str, names: dict[str, str]) -> str:
    return re.sub(
        r"화자 (\d+)(?!\d)",
        lambda match: names.get(str(int(match.group(1)) - 1), match.group(0)),
        notes,
    )


def user_notes_markdown(meta: dict) -> str:
    """The user's own memo and bookmarks, appended after the generated notes ("" when none)."""
    parts = []
    memo = (meta.get("memo") or "").strip()
    if memo:
        parts += ["## 내 메모", "", memo]
    marks = meta.get("bookmarks") or []
    if marks:
        if parts:
            parts.append("")
        parts += ["## 북마크", ""]
        for mark in marks:
            seconds = int(mark.get("time", 0))
            note = (mark.get("note") or "").strip()
            parts.append(f"- [{seconds // 60:02d}:{seconds % 60:02d}]" + (f" {note}" if note else ""))
    return "\n\n" + "\n".join(parts) + "\n" if parts else ""


def _atomic(path: Path, text: str) -> None:
    temp = path.with_name(f".{path.name}.tmp")
    temp.write_text(text)
    temp.replace(path)


def _dirs(path: Path) -> list[Path]:
    try:
        children = [child for child in path.iterdir() if not child.name.startswith(".")]
    except OSError:
        return []
    # Hidden entries are skipped before stat: Drive's .shortcut-targets-by-id can stall for seconds.
    return [child for child in children if _is_dir(child)]


def _is_dir(path: Path) -> bool:
    try:
        return path.is_dir()
    except OSError:
        return False


def _full_name() -> str:
    return _gecos()


def _meeting_id(folder: Path) -> str | None:
    try:
        return json.loads((folder / "meeting.json").read_text()).get("id")
    except (OSError, json.JSONDecodeError):
        return None


def _gecos() -> str:
    try:
        return pwd.getpwuid(os.getuid()).pw_gecos or os.getlogin()
    except (KeyError, OSError):
        return "unknown"


if __name__ == "__main__":
    print(json.dumps(workspaces(), ensure_ascii=False, indent=2))
