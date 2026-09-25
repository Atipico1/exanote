"""Stateful, low-latency Nemotron diarization for a 16 kHz mono PCM stream."""

from __future__ import annotations

import numpy as np
import mlx.core as mx

from .diarization import NemotronMLX, SpeakerCache, SUBSAMPLING, SPEAKERS, log_mel


class LiveDiarizer:
    """Keep the speaker cache across chunks so a speaker keeps one number.

    NVIDIA's recommended low-latency geometry is nine 80 ms frames plus four
    look-ahead frames. The current offline path uses 340 + 40 frames instead.
    """

    sample_rate = 16_000
    frame_samples = 1_280  # Eight 10 ms mel frames per encoder frame.
    chunk_frames = 9
    right_frames = 4

    def __init__(self, model: NemotronMLX | None = None, threshold: float = 0.5):
        self.model = model or NemotronMLX()
        self.cache = SpeakerCache(fifo_length=264, update_period=222)
        self.threshold = threshold
        self.buffer = np.empty(0, dtype=np.float32)
        self._probability_buffer = np.empty((1024, SPEAKERS), dtype=np.float32)
        self._probability_count = 0
        self.processed_samples = 0

    def feed(self, pcm: np.ndarray) -> None:
        samples = np.asarray(pcm, dtype=np.float32).reshape(-1)
        if samples.size:
            self.buffer = np.concatenate((self.buffer, samples))
        required = (self.chunk_frames + self.right_frames) * self.frame_samples
        while len(self.buffer) >= required:
            self._infer(self.chunk_frames, self.right_frames)

    def finish(self) -> None:
        while len(self.buffer) >= self.frame_samples:
            own = min(self.chunk_frames, len(self.buffer) // self.frame_samples)
            right = min(self.right_frames, len(self.buffer) // self.frame_samples - own)
            self._infer(own, right)
        if len(self.buffer) >= 160:
            self._infer(1, 0, final=True)

    def _infer(self, own: int, right: int, *, final: bool = False) -> None:
        wanted = (own + right) * self.frame_samples
        audio = self.buffer if final else self.buffer[:wanted]
        features, valid = log_mel(audio)
        embedded = self.model.preencode(mx.array(features[None]))[:, :own + right]
        cached = self.cache.get()
        all_embeds = mx.concatenate((mx.array(cached[None]), embedded), axis=1)
        chunk_mask = valid[::SUBSAMPLING][:own + right]
        full_mask = np.concatenate((np.ones(len(cached), dtype=bool), chunk_mask))
        logits = self.model.infer_embeds(all_embeds, mx.array(full_mask[None]))
        mx.eval(logits)
        self.cache.update(all_embeds, logits, self.model.silence, own, full_mask)
        selected = logits[0, len(cached) * SUBSAMPLING:(len(cached) + own) * SUBSAMPLING]
        probabilities = np.asarray(mx.sigmoid(selected)).astype(np.float32)
        needed = self._probability_count + len(probabilities)
        if needed > len(self._probability_buffer):
            grown = np.empty((max(needed, len(self._probability_buffer) * 2), SPEAKERS), dtype=np.float32)
            grown[:self._probability_count] = self.probabilities
            self._probability_buffer = grown
        self._probability_buffer[self._probability_count:needed] = probabilities
        self._probability_count = needed
        consumed = len(self.buffer) if final else own * self.frame_samples
        self.buffer = self.buffer[consumed:]
        self.processed_samples += consumed
        mx.clear_cache()

    @property
    def covered_seconds(self) -> float:
        return self.processed_samples / self.sample_rate

    @property
    def probabilities(self) -> np.ndarray:
        return self._probability_buffer[:self._probability_count]

    def activity(self, start: float, end: float) -> np.ndarray:
        first = max(0, int(start * 100))
        last = min(len(self.probabilities), int(np.ceil(end * 100)))
        return self.probabilities[first:last]

    def dominant(self, start: float, end: float) -> tuple[int | None, float]:
        activity = self.activity(start, end)
        if not len(activity):
            return None, 0.0
        active = activity >= self.threshold
        fractions = active.mean(axis=0)
        speaker = int(np.argmax(fractions))
        confidence = float(fractions[speaker])
        return (speaker if confidence >= 0.15 else None), confidence

    def turns(self, *, min_duration: float = 0.16, after: float = 0) -> list[dict]:
        first_frame = max(0, int(after * 100))
        active = self.probabilities[first_frame:] >= self.threshold
        result: list[dict] = []
        for speaker in range(SPEAKERS):
            changes = np.diff(np.pad(active[:, speaker].astype(np.int8), (1, 1)))
            for begin, end in zip(np.flatnonzero(changes == 1), np.flatnonzero(changes == -1)):
                if (end - begin) / 100 >= min_duration:
                    result.append({"start": round(float(begin + first_frame) / 100, 2), "end": round(float(end + first_frame) / 100, 2), "speaker": speaker})
        return sorted(result, key=lambda turn: (turn["start"], turn["speaker"]))
