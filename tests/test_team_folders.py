"""Team folders created by the app are offered as sync locations wherever Drive syncs them."""

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from exanote import storage


def _team(folder: Path, **fields) -> None:
    folder.mkdir(parents=True)
    (folder / storage.TEAM_FILE).write_text(json.dumps({"format": 1, **fields}))


class TeamFolderTest(unittest.TestCase):
    def test_team_folders_in_my_drive_shortcuts_and_shared_drives(self):
        with tempfile.TemporaryDirectory() as directory:
            cloud = Path(directory) / "CloudStorage"
            my_drive = cloud / "GoogleDrive-b@example.com" / "My Drive"
            my_drive.mkdir(parents=True)
            # The owner's folder as Drive for desktop keeps a shortcut target, linked into My Drive.
            target = cloud / "GoogleDrive-b@example.com" / ".shortcut-targets-by-id" / "abc" / "Exanote · 제품팀"
            _team(target, team_id="t1", name="제품팀", folder_id="abc", owner="a@example.com")
            os.symlink(target, my_drive / "Exanote · 제품팀")
            _team(cloud / "GoogleDrive-b@example.com" / "Shared drives" / "회사" / "Exanote · 영업", team_id="t2", name="영업")
            (my_drive / "Exanote · 동기화 중").mkdir()  # No team file yet.
            (my_drive / "Exanote · 동기화 중" / storage.TEAM_FILE).write_text("{")
            (my_drive / "그냥 폴더").mkdir()

            with patch.object(storage, "CLOUD_STORAGE", cloud), patch.object(storage, "ICLOUD", Path(directory) / "none"):
                options = storage.workspaces()

        teams = [option for option in options if option["kind"] == "team"]
        self.assertEqual([(t["team_id"], t["name"], t["account"]) for t in teams],
                         [("t1", "제품팀", "b@example.com"), ("t2", "영업", "b@example.com")])
        self.assertEqual(teams[0]["owner"], "a@example.com")
        self.assertEqual(teams[0]["folder_id"], "abc")
        self.assertEqual(teams[0]["path"], str(my_drive / "Exanote · 제품팀"))
        # The drives themselves stay available after the teams.
        self.assertEqual([o["kind"] for o in options if o["kind"] != "team"], ["local", "google", "google-shared"])


if __name__ == "__main__":
    unittest.main()
