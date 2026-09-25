"""Speaker cache drift must not merge distinct returning remote voices."""

import numpy as np

from exanote.live import LiveMeeting


def test_remote_pitch_repairs_confident_cache_drift():
    meeting = object.__new__(LiveMeeting)
    meeting.remote_pitch_hz = {}
    meeting.remote_model_to_speaker = {}
    time = np.arange(32_000) / 16_000
    # Two distinct remote pitches; the model assigns the second voice's
    # returning turn to the first voice's slot.
    observed_model_ids = [1, 2, 1, 1]
    expected = [1, 2, 1, 2]
    result = []
    for model_id, pitch in zip(observed_model_ids, [200, 115, 200, 115]):
        audio = (0.15 * np.sin(2 * np.pi * pitch * time)).astype(np.float32)
        result.append(meeting._stable_remote_speaker(model_id, audio))
    assert result == expected


def test_new_model_slot_does_not_reuse_a_split_display_identity():
    meeting = object.__new__(LiveMeeting)
    meeting.remote_pitch_hz = {}
    meeting.remote_model_to_speaker = {}
    pitches = iter([200.0, 115.0, 180.0])
    meeting._median_pitch_hz = lambda audio: next(pitches)
    empty = np.empty(0, dtype=np.float32)

    assert [meeting._stable_remote_speaker(slot, empty) for slot in (0, 0, 1)] == [0, 1, 2]
