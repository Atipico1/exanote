"""Two-channel recordings: the microphone (left) marks the Mac's user, the system audio (right) the others."""
import numpy as np

from exanote.pipeline import attribute_self

RATE = 16000


def tone(seconds: float, level: float) -> np.ndarray:
    t = np.arange(int(seconds * RATE)) / RATE
    return (level * np.sqrt(2) * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


def channels(mic_parts, system_parts):
    return np.stack([np.concatenate(mic_parts), np.concatenate(system_parts)])


def word(start, end, speaker, text="단어"):
    return {"start": start, "end": end, "speaker": speaker, "text": text}


def test_microphone_words_become_one_self_speaker():
    # 0-1 s I talk (mic loud); 1-2 s a remote person talks, leaking into the mic at 20 %.
    audio = channels([tone(1, 0.05), tone(1, 0.01)], [tone(1, 0.0), tone(1, 0.05)])
    words, me = attribute_self([word(0.1, 0.9, 0), word(1.1, 1.9, 1)], audio)
    assert me == 2
    assert [w["speaker"] for w in words] == [2, 1]


def test_no_self_speaker_when_the_microphone_is_silent():
    audio = channels([tone(2, 0.0)], [tone(2, 0.05)])
    original = [word(0.1, 0.9, 0), word(1.1, 1.9, 1)]
    words, me = attribute_self(original, audio)
    assert me is None and words == original


def test_my_voice_cluster_does_not_claim_quiet_remote_words():
    # Diarization put a quiet remote word (2.1-2.4 s) into my cluster 0; the system side is louder there.
    audio = channels([tone(1, 0.05), tone(1, 0.05), tone(1, 0.002)], [tone(1, 0.0), tone(1, 0.0), tone(1, 0.004)])
    words, me = attribute_self([word(0.1, 0.9, 0), word(1.1, 1.9, 0), word(2.1, 2.4, 0)], audio)
    assert [w["speaker"] for w in words] == [me, me, None]
