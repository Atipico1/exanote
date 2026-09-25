"""Meetings exported under the old "Open Notes" folder name stay visible after the rename."""

import json
import tempfile
import unittest
from pathlib import Path

from exanote import storage

META = {"id": "1a2b3c4d-0000-0000-0000-000000000000", "title": "주간회의", "created_at": "2026-09-24T15:30:00+09:00"}
RESULT = {"notes": "- 요약", "utterances": [{"start": 0, "speaker": 0, "text": "안녕하세요"}]}


class LegacyFolderTest(unittest.TestCase):
    def test_old_folder_is_listed_then_renamed_on_export(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / storage.LEGACY_FOLDER / "2026-09-24 1530 주간회의 [1a2b3c4d]"
            old.mkdir(parents=True)
            (old / "meeting.json").write_text(json.dumps({"id": META["id"], "author": "a@example.com", "created_at": META["created_at"]}))

            self.assertEqual([entry["id"] for entry in storage.list_meetings(root)], [META["id"]])
            self.assertTrue(old.exists(), "listing must not move folders")

            folder = storage.export_meeting(root, META, RESULT, "a@example.com")

            self.assertEqual(folder.parent, root / storage.FOLDER)
            self.assertFalse((root / storage.LEGACY_FOLDER).exists())
            self.assertEqual([entry["id"] for entry in storage.list_meetings(root)], [META["id"]])


if __name__ == "__main__":
    unittest.main()
