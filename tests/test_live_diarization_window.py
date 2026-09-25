"""Recent-turn scanning keeps absolute timestamps in a long recording."""

import numpy as np

from exanote.live_diarization import LiveDiarizer


def test_turns_after_preserves_meeting_time():
    diarizer = object.__new__(LiveDiarizer)
    diarizer.threshold = 0.5
    diarizer._probability_buffer = np.zeros((3000, 8), dtype=np.float32)
    diarizer._probability_count = 3000
    diarizer._probability_buffer[110:160, 0] = 0.9
    diarizer._probability_buffer[2510:2570, 1] = 0.9

    assert diarizer.turns(after=20) == [{"start": 25.1, "end": 25.7, "speaker": 1}]
