"""Recording lifecycle in the worker: crash recovery, CAF compression, memo/bookmarks, progress.

The server starts finishing interrupted work as soon as it is imported, so each run uses its own
process and a temporary EXANOTE_DATA folder; the models are replaced by a fake pipeline.
"""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import time
import uuid
import wave
from pathlib import Path

import numpy as np

SCRIPT = textwrap.dedent('''
    import json, sys, time
    from pathlib import Path
    from exanote import models, pipeline

    models.adopt_from_hf_cache_once = lambda: None
    stages = []

    def fake_process(path, *, two_channel=False, progress=None, **_):
        assert Path(path).suffix == ".m4a", path  # compressed before the models run
        for stage, fraction in (("diarize", 0.1), ("transcribe", 0.5), ("summarize", 0.9)):
            progress(stage, fraction)
            stages.append(stage)
        # The user renames the meeting while it is processing (workspace_api writes meeting.json).
        meta_path = Path(path).parent / "meeting.json"
        meta = json.loads(meta_path.read_text())
        meta["title"] = "처리 중에 바꾼 이름"
        meta_path.write_text(json.dumps(meta, ensure_ascii=False))
        return {"duration": 2.0, "language": "ko", "speaker_turns": [], "utterances": [], "transcript": "", "notes": "요약", "self_speaker": None}

    pipeline.process_recording = fake_process
    from exanote import server
    from fastapi.testclient import TestClient

    client = TestClient(server.app, headers={"X-Exanote-Token": server.IPC_TOKEN})
    server.jobs.shutdown(wait=True)  # finish the recovery started at import
    server.jobs = __import__("concurrent.futures").futures.ThreadPoolExecutor(max_workers=1)
    out = {"stages": list(stages), "after_recovery": client.get("/api/meetings").json()}

    started = client.post("/api/record/start").json()
    Path(server.DATA, started["id"], started["filename"]).write_bytes(Path(sys.argv[1]).read_bytes())
    client.post("/api/record/start")  # a second start is refused
    client.put(f"/api/meetings/{started['id']}/memo", json={"text": "가격 다시 확인"})
    client.post(f"/api/meetings/{started['id']}/bookmarks", json={"time": 42.26, "note": "결정"})
    client.post(f"/api/meetings/{started['id']}/bookmarks", json={"time": 3})
    stopped = client.post("/api/record/stop", params={"meeting_id": started["id"]})
    out["stopped"] = stopped.status_code
    server.jobs.shutdown(wait=True)
    out["recorded"] = client.get(f"/api/meetings/{started['id']}").json()
    out["files"] = sorted(p.name for p in Path(server.DATA, started["id"]).iterdir())
    opted = client.post("/api/record/start", json={"live_translation": True}).json()
    out["selected_modes"] = [started["live_translation"], opted["live_translation"]]
    client.post("/api/record/cancel")
    print(json.dumps(out, ensure_ascii=False))
''')


def _caf(folder: Path, seconds: float) -> Path:
    """Exanote's recording format: 16-bit two-channel CAF."""
    rate = 48000
    samples = (0.2 * np.sin(np.arange(int(seconds * rate)) * 0.05) * 32767).astype("<i2")
    source = folder / "tone.wav"
    with wave.open(str(source), "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(np.repeat(samples, 2).tobytes())
    target = folder / "tone.caf"
    subprocess.run(["/usr/bin/afconvert", "-f", "caff", "-d", "LEI16", str(source), str(target)], check=True)
    return target


def _left_recording(data: Path, audio: Path | None) -> str:
    meeting_id = str(uuid.uuid4())
    folder = data / meeting_id
    folder.mkdir(parents=True)
    meta = {"id": meeting_id, "title": "끊긴 회의", "created_at": "2026-09-25T01:00:00+00:00", "status": "recording", "source": "recording", "filename": "audio.caf"}
    (folder / "meeting.json").write_text(json.dumps(meta, ensure_ascii=False))
    target = folder / "audio.caf"
    target.write_bytes(audio.read_bytes() if audio else b"\0" * 4096)
    old = time.time() - 120  # not being written any more
    os.utime(target, (old, old))
    return meeting_id


def test_worker_recovers_compresses_and_keeps_user_edits():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        data = root / "data"
        tone = _caf(root, 2.0)
        crashed = _left_recording(data, tone)
        empty = _left_recording(data, None)

        run = subprocess.run(
            [sys.executable, "-c", SCRIPT, str(tone)],
            env={**os.environ, "EXANOTE_DATA": str(data)}, capture_output=True, text=True, timeout=120, check=False,
        )
        assert run.returncode == 0, run.stderr
        out = json.loads(run.stdout.strip().splitlines()[-1])

        recovered = {item["id"]: item for item in out["after_recovery"]}
        assert empty not in recovered and not (data / empty).exists()  # nothing was captured
        assert recovered[crashed]["status"] == "done" and recovered[crashed]["recovered"] is True
        assert recovered[crashed]["filename"] == "audio.m4a"
        assert recovered[crashed]["title"] == "처리 중에 바꾼 이름"  # not overwritten by the result
        assert not (data / crashed / "audio.caf").exists()
        assert out["stages"] == ["diarize", "transcribe", "summarize"]

        recorded = out["recorded"]
        assert out["stopped"] == 200 and recorded["status"] == "done"
        assert out["selected_modes"] == [False, True]
        assert recorded["memo"] == "가격 다시 확인"
        assert recorded["bookmarks"] == [{"time": 3.0, "note": ""}, {"time": 42.3, "note": "결정"}]
        assert "progress" not in recorded
        assert out["files"] == ["audio.m4a", "meeting.json", "result.json"]
