"""Nemotron 3 Diarization inference in MLX, using NVIDIA's original weights.

Architecture and cache policy follow the NVIDIA checkpoint's Hugging Face
Transformers reference implementation. The weights are downloaded into the
user's Hugging Face cache at first use; no model files live in this repository.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np
from huggingface_hub import hf_hub_download

MODEL_ID = "nvidia/Nemotron-3-Diarization"
SAMPLE_RATE = 16_000
HOP = 160
SUBSAMPLING = 8
SPEAKERS = 8


def log_mel(waveform: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Match NemotronAsrStreamingFeatureExtractor's 128-bin, 10-ms features."""
    if waveform.ndim != 1:
        raise ValueError("Expected mono audio")
    wave = np.asarray(waveform, dtype=np.float32)
    if len(wave) < HOP:
        raise ValueError("Audio is too short")
    emphasized = wave.copy()
    emphasized[1:] -= 0.97 * wave[:-1]
    padded = np.pad(emphasized, (256, 256))
    window = np.pad(np.hanning(400).astype(np.float32), (56, 56))
    filters = mel_filters(SAMPLE_RATE, 512, 128, 0.0, SAMPLE_RATE / 2)
    count = len(wave) // HOP + 1
    features = np.empty((count, 128), dtype=np.float32)
    # Bound the temporary FFT matrix for multi-hour recordings.
    for first in range(0, count, 4096):
        last = min(first + 4096, count)
        starts = np.arange(first, last)[:, None] * HOP
        frames = padded[starts + np.arange(512)[None, :]] * window
        power = np.abs(np.fft.rfft(frames, axis=1)).astype(np.float32) ** 2
        features[first:last] = np.log(power @ filters.T + 2**-24)
    valid = np.arange(count) < len(wave) // HOP
    features[~valid] = 0.0
    return features, valid


def _linear(x: mx.array, weights: dict[str, mx.array], prefix: str) -> mx.array:
    y = x @ weights[prefix + ".weight"].T
    bias = weights.get(prefix + ".bias")
    return y if bias is None else y + bias


def _norm(x: mx.array, weights: dict[str, mx.array], prefix: str) -> mx.array:
    mean = mx.mean(x, axis=-1, keepdims=True)
    variance = mx.mean(mx.square(x - mean), axis=-1, keepdims=True)
    return (x - mean) * mx.rsqrt(variance + 1e-5) * weights[prefix + ".weight"] + weights[prefix + ".bias"]


def _rotate_half(x: mx.array) -> mx.array:
    half = x.shape[-1] // 2
    return mx.concatenate((-x[..., half:], x[..., :half]), axis=-1)


class NemotronMLX:
    """A direct MLX forward port of the released 99M parameter checkpoint."""

    def __init__(self, weights_path: str | Path | None = None):
        if weights_path is None:
            weights_path = hf_hub_download(MODEL_ID, "model.safetensors")
        self.weights = mx.load(str(weights_path))
        self.silence = self.weights["silence_embeds"]
        inv_freq = 1.0 / (10000 ** (np.arange(0, 64, 2, dtype=np.float32) / 64))
        self.inv_freq = mx.array(inv_freq)

    def preencode(self, features: mx.array) -> mx.array:
        padding = (-features.shape[1]) % SUBSAMPLING
        if padding:
            features = mx.pad(features, [(0, 0), (0, padding), (0, 0)])
        stacked = features.reshape(features.shape[0], -1, 1024)
        return _linear(stacked, self.weights, "model.audio_tower.embedder.projection")

    def _encode(self, embeddings: mx.array, mask: mx.array | None = None) -> mx.array:
        w = self.weights
        length = embeddings.shape[1]
        positions = mx.arange(length, dtype=mx.float32)
        angles = positions[:, None] * self.inv_freq[None, :]
        angles = mx.concatenate((angles, angles), axis=-1)
        cos = mx.cos(angles)[None, None, :, :]
        sin = mx.sin(angles)[None, None, :, :]
        x = _norm(embeddings, w, "model.audio_tower.input_layer_norm")
        for index in range(31):
            root = f"model.audio_tower.layers.{index}"
            h = _norm(x, w, root + ".layer_norm1")
            q = _linear(h, w, root + ".self_attn.q_proj").reshape(h.shape[0], length, 8, 64).transpose(0, 2, 1, 3)
            k = _linear(h, w, root + ".self_attn.k_proj").reshape(h.shape[0], length, 8, 64).transpose(0, 2, 1, 3)
            v = _linear(h, w, root + ".self_attn.v_proj").reshape(h.shape[0], length, 8, 64).transpose(0, 2, 1, 3)
            q = q * cos + _rotate_half(q) * sin
            k = k * cos + _rotate_half(k) * sin
            attention_mask = None
            if mask is not None:
                attention_mask = mx.where(mask[:, None, None, :], 0.0, -1e9).astype(q.dtype)
            attended = mx.fast.scaled_dot_product_attention(q, k, v, scale=1 / math.sqrt(64), mask=attention_mask)
            attended = attended.transpose(0, 2, 1, 3).reshape(h.shape[0], length, 512)
            x = x + _linear(attended, w, root + ".self_attn.o_proj")
            h = _norm(x, w, root + ".layer_norm2")
            h = _linear(h, w, root + ".mlp.fc1")
            h = nn.gelu(h)
            x = x + _linear(h, w, root + ".mlp.fc2")
        return _norm(x, w, "model.audio_tower.layer_norm")

    def infer_embeds(self, embeddings: mx.array, mask: mx.array | None = None) -> mx.array:
        """Return 10-ms speaker logits for pre-encoded + cached frames."""
        x = self._encode(embeddings, mask)
        x = _linear(x, self.weights, "model.proj")
        conv_weight = self.weights["model.upsampler.conv.weight"].transpose(0, 2, 1)
        x = mx.conv1d(x, conv_weight, stride=1, padding=1)
        x = x + self.weights["model.upsampler.conv.bias"]
        x = x.reshape(x.shape[0], -1, 192)
        x = mx.maximum(x, 0)
        x = _linear(x, self.weights, "classifier.dense")
        x = mx.maximum(x, 0)
        return _linear(x, self.weights, "classifier.out_proj")


@dataclass
class SpeakerCache:
    """Arrival-order speaker cache + FIFO, with the reference selection policy."""

    fifo_length: int = 40
    update_period: int = 300
    cache_length: int = 264
    cache_embeds: np.ndarray | None = None
    cache_probs: np.ndarray | None = None
    fifo_embeds: np.ndarray | None = None
    compressed: bool = False

    def get(self) -> np.ndarray:
        parts = [part for part in (self.cache_embeds, self.fifo_embeds) if part is not None and len(part)]
        return np.concatenate(parts, axis=0) if parts else np.empty((0, 512), np.float32)

    def update(self, all_embeds: mx.array, logits: mx.array, silence: mx.array, own_frames: int, mask: np.ndarray | None) -> None:
        embeds = np.asarray(all_embeds[0])
        probabilities = np.asarray(mx.sigmoid(logits[0])).reshape(-1, SUBSAMPLING, SPEAKERS).mean(axis=1)
        if mask is not None:
            probabilities *= mask[:, None]
        cached = len(self.cache_embeds) if self.cache_embeds is not None else 0
        fifo = len(self.fifo_embeds) if self.fifo_embeds is not None else 0
        fresh = embeds[cached + fifo:cached + fifo + own_frames]
        combined_fifo = np.concatenate((self.fifo_embeds, fresh), axis=0) if fifo else fresh
        if len(combined_fifo) <= self.fifo_length:
            self.fifo_embeds = combined_fifo
            return
        pop_count = min(max(self.update_period, len(combined_fifo) - self.fifo_length), len(combined_fifo))
        fifo_probs = probabilities[cached:cached + len(combined_fifo)]
        old_probs = self.cache_probs if self.compressed else probabilities[:cached]
        old_embeds = self.cache_embeds if cached else np.empty((0, 512), np.float32)
        cache_embeds = np.concatenate((old_embeds, combined_fifo[:pop_count]), axis=0)
        cache_probs = np.concatenate((old_probs, fifo_probs[:pop_count]), axis=0) if cached else fifo_probs[:pop_count]
        if len(cache_embeds) > self.cache_length:
            cache_embeds, cache_probs = self._compress(cache_embeds, cache_probs, np.asarray(silence))
            self.compressed = True
        self.cache_embeds, self.cache_probs = cache_embeds, cache_probs
        self.fifo_embeds = combined_fifo[pop_count:]

    def _compress(self, embeds: np.ndarray, probs: np.ndarray, silence: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        threshold = 0.25
        log_probs = np.log(np.maximum(probs, threshold))
        log_complements = np.log(np.maximum(1 - probs, threshold))
        scores = log_probs - log_complements + log_complements.sum(axis=-1, keepdims=True) - math.log(0.5)
        speech = probs > 0.5
        scores[~speech] = -np.inf
        positive = scores > 0
        enough = positive.sum(axis=0) >= 16
        scores[(~positive) & speech & enough[None, :]] = -np.inf
        scores[self.cache_length:] += 0.05
        # The reference gives its highest frames two boosts before selecting the
        # cache. Sorting is only used to select frames, not to reorder their time.
        for count, boost in ((24, -2 * math.log(0.5)), (48, -math.log(0.5))):
            top = np.argsort(scores, axis=0)[-count:, :]
            np.put_along_axis(scores, top, np.take_along_axis(scores, top, axis=0) + boost, axis=0)
        padded_scores = np.pad(scores, ((0, 1), (0, 0)), constant_values=np.inf)
        flat = padded_scores.T.reshape(-1)
        chosen = np.argsort(flat)[-self.cache_length:]
        sentinel = len(flat)
        chosen[flat[chosen] == -np.inf] = sentinel
        chosen = np.sort(chosen)
        frame_indices = np.where(chosen == sentinel, len(embeds), chosen % padded_scores.shape[0])
        padded_embeds = np.concatenate((embeds, silence.reshape(1, -1)), axis=0)
        padded_probs = np.pad(probs, ((0, 1), (0, 0)))
        return padded_embeds[frame_indices], padded_probs[frame_indices]


def diarize_probabilities(waveform: np.ndarray, model: NemotronMLX | None = None, progress=None) -> tuple[np.ndarray, np.ndarray]:
    """Return 10-ms activity probabilities and a valid-frame mask."""
    model = model or NemotronMLX()
    features, valid = log_mel(waveform)
    embedded = model.preencode(mx.array(features[None]))
    count = embedded.shape[1]
    cache = SpeakerCache()
    chunks: list[np.ndarray] = []
    for start in range(0, count, 340):
        end = min(start + 340, count)
        chunk = embedded[:, start:min(end + 40, count)]
        cached = cache.get()
        all_embeds = mx.concatenate((mx.array(cached[None]), chunk), axis=1)
        chunk_mask = valid[::SUBSAMPLING][start:start + chunk.shape[1]]
        full_mask = np.concatenate((np.ones(len(cached), dtype=bool), chunk_mask))
        logits = model.infer_embeds(all_embeds, mx.array(full_mask[None]))
        mx.eval(logits)
        cache.update(all_embeds, logits, model.silence, end - start, full_mask)
        selected = logits[0, len(cached) * SUBSAMPLING:(len(cached) + end - start) * SUBSAMPLING]
        chunks.append(np.asarray(mx.sigmoid(selected)))
        if progress:
            progress(end / count)
    probabilities = np.concatenate(chunks, axis=0)[:len(features)]
    return probabilities, valid


def diarize(waveform: np.ndarray, model: NemotronMLX | None = None, threshold: float = 0.5, progress=None) -> list[dict]:
    """Run offline inference and return overlapping speaker activity segments."""
    probabilities, valid = diarize_probabilities(waveform, model, progress)
    active = probabilities > threshold
    active[~valid] = False
    segments: list[dict] = []
    for speaker in range(SPEAKERS):
        changes = np.diff(np.pad(active[:, speaker].astype(np.int8), (1, 1)))
        for begin, end in zip(np.flatnonzero(changes == 1), np.flatnonzero(changes == -1)):
            segments.append({"start": round(float(begin) * 0.01, 2), "end": round(float(end) * 0.01, 2), "speaker": speaker})
    return sorted(segments, key=lambda item: (item["start"], item["speaker"]))
def _hz_to_mel(hz: np.ndarray) -> np.ndarray:
    """Slaney mel scale: linear below 1 kHz, logarithmic above."""
    hz = np.asarray(hz, dtype=np.float64)
    linear = hz / (200.0 / 3)
    log_part = 15.0 + np.log(np.maximum(hz, 1e-10) / 1000.0) / (np.log(6.4) / 27.0)
    return np.where(hz >= 1000.0, log_part, linear)


def _mel_to_hz(mel: np.ndarray) -> np.ndarray:
    mel = np.asarray(mel, dtype=np.float64)
    linear = mel * (200.0 / 3)
    log_part = 1000.0 * np.exp((np.log(6.4) / 27.0) * (mel - 15.0))
    return np.where(mel >= 15.0, log_part, linear)


def mel_filters(sr: int, n_fft: int, n_mels: int, fmin: float, fmax: float) -> np.ndarray:
    """Slaney-normalised triangular mel filterbank (the same values as librosa.filters.mel)."""
    fft_freqs = np.fft.rfftfreq(n_fft, 1.0 / sr)
    mel_freqs = _mel_to_hz(np.linspace(_hz_to_mel(fmin), _hz_to_mel(fmax), n_mels + 2))
    widths = np.diff(mel_freqs)
    ramps = mel_freqs[:, None] - fft_freqs[None, :]
    lower = -ramps[:-2] / widths[:-1, None]
    upper = ramps[2:] / widths[1:, None]
    weights = np.maximum(0.0, np.minimum(lower, upper))
    weights *= (2.0 / (mel_freqs[2 : n_mels + 2] - mel_freqs[:n_mels]))[:, None]
    return weights.astype(np.float32)
