"""Send the synthetic meeting through the real loopback streaming API.

Run with `.venv/bin/python scripts/check_live_stream.py`. This uses the already
installed local model weights, writes temporary meeting state outside the
user's Exanote data folder, and never calls a hosted inference API.
"""

from __future__ import annotations

import json
import argparse
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / ".build/live_synthetic"
MODEL_DIR = Path.home() / ".local/share/exanote/models"


def free_port() -> int:
    with socket.socket() as connection:
        connection.bind(("127.0.0.1", 0))
        return connection.getsockname()[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--warm", action="store_true", help="Wait until the translator is ready before audio starts")
    parser.add_argument("--pace", action="store_true", help="Feed audio at real-time speed")
    parser.add_argument("--fixture", choices=["three_speakers", "overlap_channels", "overlap_remote", "long_turn", "demo_thirty_seconds", "held_out_voices"],
                        default="three_speakers")
    parser.add_argument("--final", action="store_true", help="Also run the normal post-recording pipeline")
    parser.add_argument("--trace", action="store_true", help="Print provisional source and translation timing")
    parser.add_argument("--offset", type=float, default=0, help="Start live translation this many seconds into an existing recording")
    args = parser.parse_args()
    fixture = FIXTURES / f"{args.fixture}.wav"
    if not fixture.is_file():
        parser.error("Local audio fixture is missing; run `python scripts/generate_live_synthetic.py` first")
    with tempfile.TemporaryDirectory(prefix="exanote-live-test-") as folder:
        data = Path(folder)
        (data / "models").symlink_to(MODEL_DIR)
        port = free_port()
        env = {**os.environ, "EXANOTE_DATA": str(data), "PYTHONDONTWRITEBYTECODE": "1"}
        with (data / "worker.log").open("w") as log:
            worker = subprocess.Popen([sys.executable, "-m", "exanote.cli", "serve", "--port", str(port)],
                                      cwd=ROOT, env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if (data / "ipc-token").exists():
                        try:
                            request(port, data, "GET", "api/status")
                            break
                        except (urllib.error.URLError, OSError):
                            pass
                    if worker.poll() is not None:
                        raise RuntimeError("Worker stopped before opening its API")
                    time.sleep(0.1)
                else:
                    raise RuntimeError("Worker did not open its API")
                run_stream(port, data, fixture=fixture, warm=args.warm,
                           pace=args.pace, final=args.final, trace=args.trace, offset=args.offset)
            finally:
                worker.terminate()
                try:
                    worker.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    worker.kill()


def request(port: int, data: Path, method: str, path: str, body: bytes | None = None,
            content_type: str = "application/octet-stream") -> dict:
    token = (data / "ipc-token").read_text().strip()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/{path}", data=body, method=method,
                                 headers={"X-Exanote-Token": token, "Content-Type": content_type})
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)


def run_stream(port: int, data: Path, *, fixture: Path, warm: bool, pace: bool, final: bool, trace: bool, offset: float) -> None:
    with wave.open(str(fixture), "rb") as audio:
        assert audio.getframerate() == 16_000 and audio.getnchannels() == 2 and audio.getsampwidth() == 2
        stereo = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").reshape(-1, 2).astype(np.float32) / 32768
    meeting = request(port, data, "POST", "api/record/start", b"{}", "application/json")
    meeting_id = meeting["id"]
    model_started = time.monotonic()
    request(port, data, "POST", f"api/live/{meeting_id}/start", b"")
    state = request(port, data, "POST", f"api/live/{meeting_id}/offset?seconds={offset}", b"")
    model_start_seconds = time.monotonic() - model_started
    assert json.loads((data / meeting_id / "meeting.json").read_text())["live_translation"] is True
    if warm:
        deadline = time.monotonic() + 90
        while not state["translation_ready"]:
            assert time.monotonic() < deadline, state["translation_error"] or "Translation model not ready"
            time.sleep(1)
            state = request(port, data, "GET", f"api/live/{meeting_id}")
    started = time.monotonic()
    first_seen: dict[int, float] = {}
    first_translation: dict[int, float] = {}
    last_preview = None
    first_preview = None

    def observe(state: dict) -> None:
        nonlocal last_preview, first_preview
        elapsed = round(time.monotonic() - started, 2)
        preview = state.get("preview")
        if fixture.stem == "demo_thirty_seconds" and preview:
            if preview["text"].startswith(("I agree", "I can handle")):
                assert preview["speaker"] == "화자 3", preview
        if preview and first_preview is None:
            first_preview = elapsed
        if trace and preview != last_preview:
            print(f"preview wall={elapsed:.2f}s {preview}", flush=True)
            last_preview = preview
        for index, row in enumerate(state["rows"]):
            first_seen.setdefault(index, elapsed)
            if row["translation"]:
                first_translation.setdefault(index, elapsed)

    for sample_offset in range(0, len(stereo), 16_000):
        one_second = stereo[sample_offset:sample_offset + 16_000]
        if pace:
            target = started + (sample_offset + len(one_second)) / 16_000
            while time.monotonic() < target:
                time.sleep(min(0.2, max(0, target - time.monotonic())))
                if trace:
                    observe(request(port, data, "GET", f"api/live/{meeting_id}"))
        # The native recorder sends 48 kHz float32. Repeat this 16 kHz test
        # signal 3x to exercise the transport path; this does not test real
        # 48 kHz resampling quality or a physical capture device.
        sent = np.repeat(one_second, 3, axis=0).astype("<f4")
        chunk_path = f"api/live/{meeting_id}/chunk?sample_rate=48000&sequence={sample_offset // 16000}"
        state = request(port, data, "POST", chunk_path, sent.tobytes())
        if sample_offset == 0:
            duplicate = request(port, data, "POST", chunk_path, sent.tobytes())
            assert duplicate["duration"] == state["duration"], "Retry duplicated one second of audio"
        observe(state)
        print(f"audio={min((sample_offset + len(one_second)) / 16000, len(stereo) / 16000):4.1f}s "
              f"wall={time.monotonic() - started:5.1f}s rows={len(state['rows'])}", flush=True)
    state = request(port, data, "POST", f"api/live/{meeting_id}/finish", b"")
    if final:
        subprocess.run(["/usr/bin/afconvert", "-f", "caff", "-d", "LEI16@48000", "-c", "2",
                        str(fixture), str(data / meeting_id / "audio.caf")], check=True)
        request(port, data, "POST", f"api/record/stop?meeting_id={meeting_id}", b"")
    deadline = time.monotonic() + 90
    while any(row["translation"] is None and row["translation_error"] is None for row in state["rows"]):
        if time.monotonic() > deadline:
            raise AssertionError("Live translation did not finish in 90 seconds")
        time.sleep(1)
        state = request(port, data, "GET", f"api/live/{meeting_id}")
    expected = json.loads(fixture.with_suffix(".json").read_text())
    rows = state["rows"]
    if fixture.stem == "demo_thirty_seconds":
        assert len(rows) == len(expected), f"Expected {len(expected)} rows, got {len(rows)}"
        assert [row["speaker"] for row in rows] == ["나", "화자 2", "화자 3", "나", "화자 2", "화자 3", "나"], rows
        for row, ground_truth in zip(rows, expected):
            assert ground_truth["text"].split()[0].casefold().strip(",.") in row["text"].casefold(), row
    elif fixture.stem in {"three_speakers", "overlap_channels"}:
        assert len(rows) == len(expected), f"Expected {len(expected)} rows, got {len(rows)}"
        assert [row["speaker"] for row in rows] == ["나", "화자 2", "화자 3"]
        for row, ground_truth in zip(rows, expected):
            assert ground_truth["text"].split()[0].casefold().strip(",.") in row["text"].casefold(), row
            assert abs(row["start"] - ground_truth["start"] - offset) < 0.5, row
    elif fixture.stem == "overlap_remote":
        assert len(rows) == 2 and [row["speaker"] for row in rows] == ["화자 1", "화자 2"]
        assert all(row["overlap"] for row in rows), "Same-channel overlap must be visibly marked uncertain"
    elif fixture.stem == "held_out_voices":
        assert len(rows) == len(expected), rows
        labels: dict[str, str] = {}
        for row, ground_truth in zip(rows, expected):
            assert ground_truth["text"].split()[0].casefold().strip(",.") in row["text"].casefold(), row
            if ground_truth["channel"] == "mic":
                assert row["speaker"] == "나", row
            else:
                prior = labels.setdefault(ground_truth["voice"], row["speaker"])
                assert row["speaker"] == prior, rows
        assert len(set(labels.values())) == 2, rows
    else:
        assert len(rows) >= 2 and all(row["speaker"] == "나" for row in rows)
        assert "Friday" in " ".join(row["text"] for row in rows)
    for row in rows:
        assert row["translation"] and any("가" <= char <= "힣" for char in row["translation"])
        print(f"{row['speaker']} [{row['start']:.2f}-{row['end']:.2f}] overlap={row['overlap']}: {row['text']}\n  → {row['translation']}")
    archived = json.loads((data / meeting_id / "live.json").read_text())
    assert archived["rows"] == rows, "Saved translations differ from live results"
    assert request(port, data, "GET", f"api/meetings/{meeting_id}")["live"]["rows"] == rows
    assert all(row["start"] >= offset for row in rows)
    if fixture.stem == "overlap_remote":
        print("LIMITATION: two remote voices overlap on one system channel; speaker activity is distinct, "
              "but the second voice's words can be misattributed. Both rows are flagged for review.")
    print(f"PASS ({fixture.stem}): {len(rows)} caption rows, English ASR, Korean translations; "
          f"live model startup {model_start_seconds:.1f}s, "
          f"first preview at wall {first_preview}s, "
          f"first row at wall {first_seen.get(0)}s, first final translation at wall {first_translation.get(0)}, "
          f"all translations at wall {time.monotonic() - started:.1f}s")
    if final:
        deadline = time.monotonic() + 120
        while True:
            meeting = request(port, data, "GET", f"api/meetings/{meeting_id}")
            if meeting["status"] in {"done", "error"}:
                assert meeting["status"] == "done", meeting.get("error")
                assert meeting["result"]["utterances"]
                assert meeting["language"] == "en", "Final transcription changed the English source language"
                if fixture.stem in {"three_speakers", "overlap_channels"}:
                    final_text = meeting["result"]["transcript"]
                    assert "Hello" in final_text and "Friday" in final_text and "budget" in final_text, final_text
                print(f"PASS final pipeline: {meeting['result']['duration']}s, "
                      f"{len(meeting['result']['utterances'])} utterances, summary ready")
                break
            if time.monotonic() > deadline:
                raise AssertionError("Final pipeline did not finish in 120 seconds")
            time.sleep(1)


if __name__ == "__main__":
    main()
