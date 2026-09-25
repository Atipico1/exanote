"""Live translation must release its models before offline processing starts."""

import os
import subprocess
import sys
import tempfile
import textwrap


SCRIPT = textwrap.dedent('''
    import json
    import time
    from concurrent.futures import Future
    from pathlib import Path

    from exanote import models, pipeline

    models.adopt_from_hf_cache_once = lambda: None
    calls = []
    pipeline.process_recording = lambda *args, **kwargs: (
        calls.append("processed") or
        {"duration": 1.0, "language": "en", "speaker_turns": [], "utterances": [],
         "transcript": "", "notes": "", "self_speaker": None}
    )
    from exanote import server
    from fastapi.testclient import TestClient

    class FakeLiveMeeting:
        def __init__(self, meeting_id, archive_path, offset_seconds):
            self.meeting_id = meeting_id
            self.archive_path = archive_path
            self.translation_done = Future()

        def snapshot(self):
            return {"meeting_id": self.meeting_id, "status": "finished", "rows": []}

        def finish(self):
            self.archive_path.write_text(json.dumps(self.snapshot()))
            return self.snapshot()

    server.LiveMeeting = FakeLiveMeeting
    with TestClient(server.app, headers={"X-Exanote-Token": server.IPC_TOKEN}) as client:
        meeting = client.post("/api/record/start").json()
        meeting_id = meeting["id"]
        (Path(server.DATA) / meeting_id / "audio.caf").write_bytes(b"0" * 9_000)
        assert client.post(f"/api/live/{meeting_id}/start").status_code == 200
        assert server.inference_lock.locked()
        assert client.post(f"/api/live/{meeting_id}/finish").status_code == 200
        assert client.post("/api/record/stop", params={"meeting_id": meeting_id}).status_code == 200
        time.sleep(.1)
        assert not calls, "offline model work overlapped live translation"
        server.live_meetings[meeting_id].translation_done.set_result(None)
        deadline = time.monotonic() + 5
        while (server.inference_lock.locked() or not calls) and time.monotonic() < deadline:
            time.sleep(.02)
        assert calls == ["processed"]
        assert meeting_id not in server.live_meetings
        assert client.get(f"/api/live/{meeting_id}").json()["meeting_id"] == meeting_id

        interrupted = client.post("/api/record/start").json()["id"]
        (Path(server.DATA) / interrupted / "audio.caf").write_bytes(b"0" * 9_000)
        assert client.post(f"/api/live/{interrupted}/start").status_code == 200
        assert client.post("/api/record/recover").status_code == 200
        time.sleep(.1)
        assert calls == ["processed"], "recovery overlapped live translation"
        server.live_meetings[interrupted].translation_done.set_result(None)
        deadline = time.monotonic() + 5
        while (server.inference_lock.locked() or len(calls) < 2) and time.monotonic() < deadline:
            time.sleep(.02)
        assert calls == ["processed", "processed"]
        assert interrupted not in server.live_meetings
    server.jobs.shutdown(wait=True)
''')


def test_live_models_finish_before_offline_models_start():
    with tempfile.TemporaryDirectory() as directory:
        run = subprocess.run(
            [sys.executable, "-c", SCRIPT],
            env={**os.environ, "EXANOTE_DATA": directory},
            capture_output=True, text=True, timeout=30,
        )
        assert run.returncode == 0, run.stderr
