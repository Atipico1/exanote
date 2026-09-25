"""Background export keeps going when one meeting cannot be written."""

import json
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from exanote import storage, workspace_api


def _meeting(data: Path, title: str, created_at: str) -> dict:
    meta = {"id": str(uuid.uuid4()), "title": title, "created_at": created_at, "status": "done"}
    folder = data / meta["id"]
    folder.mkdir()
    (folder / "meeting.json").write_text(json.dumps(meta))
    (folder / "result.json").write_text(json.dumps({"notes": "", "utterances": []}))
    return meta


class WorkspaceSyncTest(unittest.TestCase):
    def test_one_blocked_meeting_does_not_stop_the_rest(self):
        with tempfile.TemporaryDirectory() as directory:
            data, root = Path(directory) / "data", Path(directory) / "team"
            data.mkdir()
            root.mkdir()
            workspace = {"kind": "google-shared", "name": "Team", "path": str(root), "account": "a@example.com"}
            blocked = _meeting(data, "막힌 회의", "2026-09-25T10:00:00+09:00")
            others = [_meeting(data, f"회의 {n}", f"2026-09-25T1{n}:00:00+09:00") for n in range(1, 4)]
            # A teammate's meeting already occupies the blocked meeting's folder.
            taken = storage.meeting_folder(root, blocked)
            taken.mkdir(parents=True)
            (taken / "meeting.json").write_text(json.dumps({"id": blocked["id"], "author": "b@example.com"}))

            with (
                patch.object(workspace_api, "DATA", data),
                patch.object(workspace_api, "STATE", data / "sync-state.json"),
                patch.object(workspace_api, "_selected", return_value=workspace),
                patch.dict(workspace_api._status, {"last_sync": None, "error": None}),
            ):
                workspace_api.sync_once()
                status = dict(workspace_api._status)

            for meta in others:
                self.assertEqual(json.loads((storage.meeting_folder(root, meta) / "meeting.json").read_text())["author"], "a@example.com")
            self.assertEqual(json.loads((taken / "meeting.json").read_text())["author"], "b@example.com")
            exported = json.loads((data / "sync-state.json").read_text())[str(root)]
            self.assertEqual(set(exported), {meta["id"] for meta in others})
            self.assertIn("막힌 회의", status["error"])
            self.assertIsNotNone(status["last_sync"])


if __name__ == "__main__":
    unittest.main()
