"""A diarizer slot may be reused by speech arriving on the other channel."""

from types import SimpleNamespace
from types import MethodType

import numpy as np

from exanote.live import LiveMeeting


def test_turn_channel_overrides_stale_speaker_slot():
    meeting = object.__new__(LiveMeeting)
    meeting.speaker_channel = {0: True}
    meeting.audio_start = 0.0
    meeting.audio = np.zeros((16_000, 2), dtype=np.float32)
    meeting.audio[:, 1] = 0.1
    probabilities = np.zeros((100, 8), dtype=np.float32)
    probabilities[:, 0] = 1
    meeting.diarizer = SimpleNamespace(probabilities=probabilities)

    assert meeting._channel_for_turn(0, 0, 1, meeting.audio) is False
    assert meeting.speaker_channel[0] is False


def test_missing_audio_chunk_preserves_following_timestamps():
    meeting = object.__new__(LiveMeeting)
    meeting.finished = False
    meeting.next_sequence = 0
    meeting.duration = 0.0
    meeting._consume = MethodType(lambda self, pair: setattr(self, "duration", self.duration + len(pair) / 16_000), meeting)
    meeting.snapshot = MethodType(lambda self: {"duration": self.duration}, meeting)
    one_second = np.zeros((16_000, 2), dtype="<f4").tobytes()

    assert meeting.feed(one_second, sequence=2)["duration"] == 3
    assert meeting.next_sequence == 3
    assert meeting.feed(one_second, sequence=2)["duration"] == 3
