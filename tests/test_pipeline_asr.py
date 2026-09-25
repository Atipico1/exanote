"""Qwen word alignment must preserve readable transcript text and speakers."""

import unittest

from exanote.pipeline import align_words, group_utterances


class QwenAlignmentTest(unittest.TestCase):
    def test_restores_spacing_punctuation_and_zero_duration_speaker(self):
        asr = {
            "text": "안녕, 다음 문장!",
            "segments": [
                {"text": "안녕", "start": 0.0, "end": 0.5},
                {"text": "다음", "start": 0.7, "end": 0.8},
                {"text": "문장", "start": 0.8, "end": 0.8},
            ],
        }
        turns = [
            {"speaker": 0, "start": 0.0, "end": 0.6},
            {"speaker": 1, "start": 0.7, "end": 1.2},
        ]

        words = align_words(asr, turns)
        self.assertEqual("".join(word["text"] for word in words), asr["text"])
        self.assertEqual([word["speaker"] for word in words], [0, 1, 1])
        self.assertAlmostEqual(words[-1]["end"], 0.85)
        self.assertEqual(
            [utterance["text"] for utterance in group_utterances(words)],
            ["안녕,", "다음 문장!"],
        )

    def test_rejects_mismatched_word_alignment(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            align_words(
                {"text": "원문", "segments": [{"text": "다름", "start": 0, "end": 1}]},
                [],
            )


if __name__ == "__main__":
    unittest.main()
