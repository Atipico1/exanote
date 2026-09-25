"""Renaming a speaker keeps the diarization ID and updates exported text."""

import json
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from fastapi import HTTPException

from exanote import storage, workspace_api


class SpeakerNamesTest(unittest.TestCase):
    def test_rename_persists_and_exports_without_changing_speaker_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            meeting_id = str(uuid.uuid4())
            folder = root / meeting_id
            folder.mkdir()
            meta = {
                "id": meeting_id,
                "title": "회의",
                "created_at": "2026-09-25T00:00:00+00:00",
                "status": "done",
            }
            result = {
                "utterances": [
                    {"start": 0, "speaker": 0, "text": "안녕하세요"},
                    {"start": 4, "speaker": 1, "text": "반갑습니다"},
                ],
                "notes": "- 인사 — 화자 1 [00:00]",
            }
            (folder / "meeting.json").write_text(json.dumps(meta))
            (folder / "result.json").write_text(json.dumps(result))
            with patch.object(workspace_api, "DATA", root):
                changed = workspace_api.rename_speaker(
                    meeting_id, workspace_api.SpeakerNameChange(speaker=0, name="  지민  ")
                )
                self.assertEqual(changed["speaker_names"], {"0": "지민"})
                self.assertEqual(json.loads((folder / "meeting.json").read_text())["speaker_names"], {"0": "지민"})
                with self.assertRaises(HTTPException) as error:
                    workspace_api.rename_speaker(
                        meeting_id, workspace_api.SpeakerNameChange(speaker=1, name="지민")
                    )
                self.assertEqual(error.exception.status_code, 400)

            self.assertEqual(result["utterances"][0]["speaker"], 0)
            export = storage.export_meeting(root / "workspace", changed, result, "owner")
            transcript = (export / "transcript.md").read_text()
            self.assertIn("[00:00] 지민", transcript)
            self.assertIn("[00:04] 화자 2", transcript)
            self.assertIn("인사 — 지민 [00:00]", (export / "summary.md").read_text())


if __name__ == "__main__":
    unittest.main()
