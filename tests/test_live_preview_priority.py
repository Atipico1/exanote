"""A live chunk returns its provisional transcript before turn re-decoding."""

import asyncio
import threading
from concurrent.futures import ThreadPoolExecutor
from types import MethodType, SimpleNamespace

import numpy as np

from exanote.live import LiveMeeting


def test_live_meeting_defers_turn_decode_until_refine():
    meeting = object.__new__(LiveMeeting)
    meeting.audio = np.empty((0, 2), dtype=np.float32)
    meeting.duration = 0.0
    meeting.diarizer = SimpleNamespace(feed=lambda _: calls.append("diarize"), covered_seconds=1.0)
    meeting.asr = SimpleNamespace(feed_audio=lambda _, state: setattr(state, "text", "hello"))
    meeting.asr_state = SimpleNamespace(text="")
    meeting.finished = False
    meeting.error = None
    calls = []
    meeting.pending_diarization = []
    meeting._update_preview = MethodType(lambda self: calls.append("preview"), meeting)
    meeting._finalize_turns = MethodType(lambda self, before: calls.append("finalize"), meeting)

    meeting._consume(np.zeros((16_000, 2), dtype=np.float32))
    assert meeting.asr_state.text == "hello"
    assert calls == ["preview"]

    meeting.refine()
    assert calls == ["preview", "diarize", "finalize", "preview"]


def test_live_http_chunk_returns_before_refinement(monkeypatch):
    from exanote import server

    started = threading.Event()
    release = threading.Event()
    refined = threading.Event()

    class FakeMeeting:
        def feed(self, raw, sample_rate, sequence):
            assert raw == b"pcm"
            return {"preview": {"text": "hello"}, "rows": []}

        def refine(self):
            started.set()
            release.wait(timeout=5)
            refined.set()

    class FakeRequest:
        async def body(self):
            return b"pcm"

    with ThreadPoolExecutor(max_workers=1) as executor:
        monkeypatch.setattr(server, "live_jobs", executor)
        monkeypatch.setitem(server.live_meetings, "test-meeting", FakeMeeting())
        try:
            result = asyncio.run(server.live_chunk("test-meeting", FakeRequest(), 16_000, 0))
            assert result["preview"]["text"] == "hello"
            assert started.wait(timeout=2)
            assert not refined.is_set()
        finally:
            release.set()
    assert refined.is_set()


def test_remote_preview_is_visible_before_diarizer_catches_up():
    meeting = object.__new__(LiveMeeting)
    meeting.finished = False
    meeting.asr_state = SimpleNamespace(text="Hello there")
    meeting.asr_committed_words = 0
    meeting.committed_until = 0.0
    meeting.diarizer = SimpleNamespace(
        covered_seconds=0.0,
        dominant=lambda *_: (None, 0.0),
        activity=lambda *_: np.empty((0, 8)),
    )
    meeting.preview_speaker_id = None
    meeting.speaker_channel = {}
    meeting.audio = np.column_stack((np.zeros(16_000), np.full(16_000, 0.1)))
    preview = meeting._current_preview()
    assert preview["speaker"] == "상대방"
    assert preview["text"] == "Hello there"
