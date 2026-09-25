"""Nemotron activity must cut ASR chunks at pauses and skip only quiet silence."""

import unittest

import numpy as np

from exanote.pipeline import ASR_CHUNK_SECONDS, speech_chunks

SR = 16000


def noise(seconds, seed=0):
    return np.random.default_rng(seed).normal(size=int(seconds * SR)).astype(np.float32)


class SpeechChunksTest(unittest.TestCase):
    def test_cuts_at_the_longest_pause_and_loses_no_audio(self):
        audio = noise(50)
        turns = [
            {"speaker": 0, "start": 0.0, "end": 12.0},
            {"speaker": 1, "start": 12.3, "end": 20.0},  # 0.3 s pause
            {"speaker": 0, "start": 20.8, "end": 50.0},  # 0.8 s pause: the cut
        ]
        chunks = speech_chunks(audio, turns)
        self.assertAlmostEqual(chunks[1][1], 20.4, places=2)
        self.assertTrue(all(len(piece) / SR <= ASR_CHUNK_SECONDS for piece, _ in chunks))
        self.assertAlmostEqual(sum(len(piece) for piece, _ in chunks) / SR, 50.0, places=2)

    def test_skips_quiet_silence(self):
        audio = np.zeros(60 * SR, dtype=np.float32)
        audio[1 * SR:9 * SR] = noise(8, 1)
        audio[40 * SR:44 * SR] = noise(4, 2)
        turns = [{"speaker": 0, "start": 1.0, "end": 9.0}, {"speaker": 0, "start": 40.0, "end": 44.0}]
        chunks = speech_chunks(audio, turns)
        self.assertLess(sum(len(piece) for piece, _ in chunks) / SR, 15)
        self.assertEqual(len(chunks), 2)

    def test_keeps_loud_audio_that_nemotron_missed(self):
        audio = np.zeros(60 * SR, dtype=np.float32)
        audio[1 * SR:50 * SR] = noise(49, 3)
        turns = [{"speaker": 0, "start": 1.0, "end": 5.0}, {"speaker": 0, "start": 45.0, "end": 50.0}]
        covered = sum(len(piece) for piece, _ in speech_chunks(audio, turns)) / SR
        self.assertGreater(covered, 49.0)  # the 40 s unlabeled but loud gap is decoded
        self.assertLess(covered, 50.5)  # the silent tail is not


if __name__ == "__main__":
    unittest.main()
