"""Local audio -> words -> speakers -> meeting notes."""

from __future__ import annotations

import gc
import os
import re
import shutil
import subprocess
import tempfile
import unicodedata
from functools import lru_cache
from pathlib import Path

import numpy as np
from mlx_qwen3_asr import ForcedAligner, Session

from .diarization import NemotronMLX, diarize
from .korean import install_for_aligner
from . import models

EDGE_NOTES_MODEL = "TheStageAI/gemma-4-E2B-it-qat"


def _model(model_id: str) -> str:
    """The checkpoint for one stage: an environment override, else the app's own copy.

    Resolved on every run, so a model deleted in Settings is downloaded again when needed.
    """
    return os.getenv(models.BY_ID[model_id].override) or str(models.ensure(model_id))


def _is_edge_notes_model(model_id: str) -> bool:
    local = Path(model_id)
    return model_id == EDGE_NOTES_MODEL or (local.is_dir() and (local / "model_l.safetensors").exists())


def _notes_generator(model_id: str):
    """Load the selected notes model and return a prompt-to-text function."""
    if _is_edge_notes_model(model_id):
        import mlx.core as mx
        from edge_lm import load as load_edge
        from mlx_vlm import stream_generate

        model, tokenizer = load_edge(model_id, size="l")

        def generate_notes(system: str, user: str, max_tokens: int) -> str:
            # Gemma 4's canonical system/user template for text-only generation.
            # Keep it local: the compressed checkpoint has no chat_template file.
            prompt = f"<bos><|turn>system\n{system.strip()}<turn|>\n<|turn>user\n{user.strip()}<turn|>\n<|turn>model\n"
            tokens = [int(token) for token in tokenizer.encode(prompt)]
            chunks = stream_generate(
                model, tokenizer, "", input_ids=mx.array([tokens], dtype=mx.int32),
                max_tokens=max_tokens, temperature=0,
            )
            return "".join(chunk.text for chunk in chunks).strip()

        return generate_notes

    from mlx_lm import generate, load

    model, tokenizer = load(model_id)

    def generate_notes(system: str, user: str, max_tokens: int) -> str:
        messages = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        prompt = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False)
        return generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens, verbose=False).strip()

    return generate_notes


def decode_audio(path: str | Path) -> np.ndarray:
    """Decode to 16 kHz mono float32 with macOS's built-in afconvert.

    afconvert reads wav, mp3, m4a/aac, flac, aiff, caf, ogg and the audio of mp4/mov, so the app
    needs no ffmpeg. ffmpeg is used only when it is installed and needed: webm, which afconvert
    cannot open, and older two-track recordings (system audio + microphone) that must be mixed.
    """
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if ffmpeg and ffprobe and _audio_streams(ffprobe, path) > 1:
        return _checked(_ffmpeg_decode(ffmpeg, path, mix_two=True))
    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder) / "audio.wav"
        result = subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEF32@16000", "-c", "1", str(path), str(output)], capture_output=True, text=True)
        if result.returncode == 0:
            return _checked(_read_float_wav(output))
    if ffmpeg:
        return _checked(_ffmpeg_decode(ffmpeg, path))
    raise ValueError("이 파일 형식은 열 수 없어요. wav, mp3, m4a, flac, aiff, ogg, mp4, mov 파일을 사용하세요.")


def _audio_streams(ffprobe: str, path: str | Path) -> int:
    probe = subprocess.run([ffprobe, "-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    return len([line for line in probe.stdout.splitlines() if line.strip()])


def _ffmpeg_decode(ffmpeg: str, path: str | Path, mix_two: bool = False) -> np.ndarray:
    mix = ["-filter_complex", "[0:a:0][0:a:1]amix=inputs=2:duration=longest:normalize=0"] if mix_two else []
    command = [ffmpeg, "-nostdin", "-v", "error", "-i", str(path), *mix, "-ac", "1", "-ar", "16000", "-f", "f32le", "pipe:1"]
    return np.frombuffer(subprocess.run(command, capture_output=True, check=True).stdout, dtype="<f4").copy()


def _read_float_wav(path: Path) -> np.ndarray:
    """Read the 32-bit float PCM samples afconvert writes (the stdlib wave module cannot)."""
    data = path.read_bytes()
    position = 12
    while position + 8 <= len(data):
        chunk, size = data[position : position + 4], int.from_bytes(data[position + 4 : position + 8], "little")
        if chunk == b"data":
            return np.frombuffer(data[position + 8 : position + 8 + size], dtype="<f4").copy()
        position += 8 + size + (size & 1)
    raise ValueError("WAV file has no audio data")


def decode_channels(path: str | Path) -> np.ndarray | None:
    """Microphone and system audio (2, samples) at 16 kHz from Exanote's own two-channel recordings.

    Returns None for mono files, so older recordings and imports keep voice-only attribution.
    """
    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder) / "channels.wav"
        result = subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEF32@16000", "-c", "2", str(path), str(output)], capture_output=True, text=True)
        if result.returncode != 0:
            return None
        channels = _read_float_wav(output).reshape(-1, 2).T
    return None if np.array_equal(channels[0], channels[1]) else channels  # afconvert duplicates mono input


SELF_NAME = "나"


def attribute_self(words: list[dict], channels: np.ndarray, *, ratio: float = 2.0, floor: float = 0.005) -> tuple[list[dict], int | None]:
    """Give the recording Mac's user one speaker id, using which channel each word is loud in.

    A word is "mine" when the microphone is at least `ratio` (6 dB) louder than the system audio
    over the word and at least `floor` (about -46 dBFS, above room noise); speaker echo reaches the
    microphone quieter than the system channel it came
    from, so remote speech stays remote. A voice cluster whose words are mostly mine is me too,
    which also covers the moments both sides talk at once.
    """
    microphone, system = channels
    def level(signal: np.ndarray, word: dict, lead: float = 0.0) -> float:
        start = max(0, int((word["start"] - lead) * 16000))
        end = max(int(word["end"] * 16000), int(word["start"] * 16000) + 160)
        chunk = signal[start:end]
        return float(np.sqrt(np.mean(chunk * chunk))) if len(chunk) else 0.0
    levels = [(level(microphone, word), level(system, word, lead=0.3)) for word in words]
    # Look 0.3 s back on the system side: the room keeps echoing a remote voice after it stops.
    mine = [mic > floor and mic > ratio * remote for mic, remote in levels]
    if not any(mine):
        return words, None
    totals: dict = {}
    for word, is_mine in zip(words, mine):
        counts = totals.setdefault(word["speaker"], [0, 0])
        counts[0] += len(word["text"])
        counts[1] += len(word["text"]) if is_mine else 0
    my_clusters = {speaker for speaker, (total, own) in totals.items() if speaker is not None and total and own / total > 0.5}
    self_id = 1 + max((word["speaker"] for word in words if word["speaker"] is not None), default=-1)
    labelled: list[dict] = []
    for word, is_mine, (mic, remote) in zip(words, mine, levels):
        speaker = word["speaker"]
        if is_mine or (speaker in my_clusters and mic >= remote):
            speaker = self_id
        elif speaker in my_clusters:
            # My voice cluster, but the other side is louder here: not me. Continue the previous
            # remote speaker if they were talking within a second, otherwise leave it unknown.
            previous = labelled[-1] if labelled else None
            recent = previous and previous["speaker"] != self_id and word["start"] - previous["end"] < 1.0
            speaker = previous["speaker"] if recent else None
        labelled.append({**word, "speaker": speaker})
    return labelled, self_id


def _checked(audio: np.ndarray) -> np.ndarray:
    if len(audio) < 160:
        raise ValueError("The recording has no usable audio")
    return audio


@lru_cache(maxsize=2)
def _asr_session(model: str) -> Session:
    return Session(model=model)


@lru_cache(maxsize=2)
def _forced_aligner(model: str) -> ForcedAligner:
    return ForcedAligner(model_path=model)


ASR_CHUNK_SECONDS = 30.0  # mlx-qwen3-asr's own chunk limit.
MIN_CHUNK_SECONDS = 10.0  # Do not cut earlier than this when a pause is available later.
MIN_PAUSE_SECONDS = 0.2  # Shorter gaps between Nemotron activity are not treated as pauses.
DROP_SILENCE_SECONDS = 2.0  # Longer pauses may be skipped, but only when they are also quiet.
SILENCE_KEEP_SECONDS = 0.3  # Audio kept on each side of a skipped silence.
QUIET_RMS_RATIO = 0.1  # A gap is silence only if it is also this quiet relative to the recording.


def speech_chunks(waveform: np.ndarray, speaker_turns: list[dict], sr: int = 16000) -> list[tuple[np.ndarray, float]]:
    """Cut ASR chunks at pauses in Nemotron speaker activity.

    Each chunk ends at the middle of the longest Nemotron pause between 10 and 30 seconds into
    it, so no audio falls between chunks. Nemotron can miss a speaker for tens of seconds, so a
    long pause is skipped only when its audio is also quiet. Without a usable pause, the span
    falls back to the library's low-energy split.
    """
    from mlx_qwen3_asr.chunking import split_audio_into_chunks

    duration = len(waveform) / sr
    loudness = float(np.sqrt(np.mean(np.square(waveform)))) or 1.0

    def quiet(start: float, end: float) -> bool:
        gap = waveform[int(start * sr):int(end * sr)]
        return len(gap) == 0 or float(np.sqrt(np.mean(np.square(gap)))) < QUIET_RMS_RATIO * loudness

    activity: list[list[float]] = []
    for turn in sorted(speaker_turns, key=lambda item: item["start"]):
        if activity and turn["start"] - activity[-1][1] < MIN_PAUSE_SECONDS:
            activity[-1][1] = max(activity[-1][1], turn["end"])
        else:
            activity.append([turn["start"], turn["end"]])
    pauses = [(0.0, activity[0][0])] if activity else [(0.0, duration)]
    pauses += [(left[1], right[0]) for left, right in zip(activity, activity[1:])]
    if activity:
        pauses.append((activity[-1][1], duration))

    # Spans of audio to decode: everything except long, quiet pauses.
    spans: list[list[float]] = []
    position = 0.0
    for start, end in pauses:
        if end - start >= DROP_SILENCE_SECONDS and quiet(start, end):
            if start > 0 and start + SILENCE_KEEP_SECONDS > position:
                spans.append([position, min(duration, start + SILENCE_KEEP_SECONDS)])
            position = duration if end >= duration else max(position, end - SILENCE_KEEP_SECONDS)
    if position < duration:
        spans.append([position, duration])

    cuts = [((start + end) / 2, end - start) for start, end in pauses if end - start >= MIN_PAUSE_SECONDS]
    chunks = []
    for span_start, span_end in spans:
        begin = span_start
        while span_end - begin > ASR_CHUNK_SECONDS:
            options = [(length, point) for point, length in cuts if begin + MIN_CHUNK_SECONDS <= point <= begin + ASR_CHUNK_SECONDS]
            end = max(options)[1] if options else next((point for point, _ in cuts if point > begin + ASR_CHUNK_SECONDS), span_end)
            end = min(end, span_end)
            chunks.append((begin, end))
            begin = end
        chunks.append((begin, span_end))
    pieces = []
    for start, end in chunks:
        audio = waveform[int(start * sr):int(end * sr)]
        if len(audio) < sr // 10:
            continue
        for piece, offset in split_audio_into_chunks(audio, sr=sr, max_chunk_sec=ASR_CHUNK_SECONDS):
            pieces.append((piece, start + offset))
    return pieces


def _decode(session: Session, audio: np.ndarray, language: str = "Korean") -> tuple[str, list[str]]:
    result = session.transcribe(audio, language=language, return_chunks=True)
    return result.text, [item.get("finish_reason") for item in result.chunks or []]


def asr_chunks(waveform: np.ndarray, model: str | None = None, speaker_turns: list[dict] | None = None,
               progress=None, *, language: str = "Korean") -> list[tuple[np.ndarray, float, str]]:
    """Decode chunk by chunk and return (audio, offset, text) for each decoded piece.

    mlx-qwen3-asr stops a chunk when a 2-10 token pattern repeats twice, which also fires on a
    speaker genuinely repeating a phrase and drops the rest of that chunk. Such a chunk is split
    at its quietest point near the middle and decoded again; the longer transcript wins.
    """
    from mlx_qwen3_asr.chunking import split_audio_into_chunks

    waveform = np.asarray(waveform, dtype=np.float32)
    session = _asr_session(model or _model("asr"))
    chunks = speech_chunks(waveform, speaker_turns) if speaker_turns else split_audio_into_chunks(waveform, sr=16000)
    pieces = []
    for index, (audio, offset) in enumerate(chunks):
        if progress:
            progress(index / max(1, len(chunks)))
        text, reasons = _decode(session, audio, language)
        if "repetition" in reasons and len(audio) >= 2 * 16000:
            halves = split_audio_into_chunks(audio, sr=16000, max_chunk_sec=len(audio) / 32000 + 0.01)
            retried = [(half, offset + start, _decode(session, half, language)[0]) for half, start in halves]
            if len(_alphanumeric("".join(item[2] for item in retried))) > len(_alphanumeric(text)):
                pieces.extend(retried)
                continue
        pieces.append((audio, offset, text))
    return pieces


def transcribe(waveform: np.ndarray, model: str | None = None, speaker_turns: list[dict] | None = None,
               progress=None, *, language: str = "Korean") -> dict:
    """Transcribe, then align words in a second pass.

    With speaker_turns (Nemotron activity), chunks follow speech pauses and non-speech is skipped.
    Decoding every chunk first, releasing the ASR model (2.2 GB), and then aligning the same
    chunks keeps the ASR model and the aligner (~1.0 GB) out of memory at the same time.
    """
    from mlx_qwen3_asr.tokenizer import join_text_parts
    import mlx.core as mx

    report = progress or (lambda stage, fraction: None)
    pieces = asr_chunks(waveform, model, speaker_turns, lambda fraction: report("transcribe", fraction), language=language)
    release_models()
    install_for_aligner()
    aligner = _forced_aligner(_model("aligner"))
    segments = []
    for index, (chunk_audio, offset, text) in enumerate(pieces):
        report("align", index / max(1, len(pieces)))
        if text.strip():
            for item in aligner.align(chunk_audio, text, language):
                segments.append({"text": item.text, "start": item.start_time + offset, "end": item.end_time + offset})
            mx.clear_cache()  # The library does this per chunk too; otherwise freed buffers pile up.
    return {"text": join_text_parts([text for _, _, text in pieces], language),
            "language": "en" if language == "English" else "ko", "segments": segments}


def _alphanumeric(text: str) -> str:
    return "".join(
        normalized
        for char in text
        for normalized in unicodedata.normalize("NFKC", char).casefold()
        if normalized.isalnum()
    )


def _render_aligned_words(text: str, segments: list[dict]) -> list[str]:
    """Put the ASR's spaces and punctuation back on the aligner's word units."""
    offsets = [
        index
        for index, char in enumerate(text)
        for normalized in unicodedata.normalize("NFKC", char).casefold()
        if normalized.isalnum()
    ]
    clean_words = [_alphanumeric(segment["text"]) for segment in segments]
    if not all(clean_words) or _alphanumeric(text) != "".join(clean_words):
        raise ValueError("Qwen word alignment does not match its transcription")

    rendered: list[str] = []
    cursor = 0
    character_count = 0
    for clean_word in clean_words:
        character_count += len(clean_word)
        end = offsets[character_count - 1] + 1
        while end < len(text) and not _alphanumeric(text[end]):
            end += 1
        rendered.append(text[cursor:end])
        cursor = end
    return rendered


def _speaker_for_interval(start: float, end: float, turns: list[dict]) -> int | None:
    score: dict[int, float] = {}
    for turn in turns:
        overlap = max(0.0, min(end, turn["end"]) - max(start, turn["start"]))
        if overlap:
            score[turn["speaker"]] = score.get(turn["speaker"], 0.0) + overlap
    return max(score, key=score.get) if score else None


def align_words(asr: dict, speaker_turns: list[dict]) -> list[dict]:
    """Attribute Qwen words by maximum overlap with Nemotron activity."""
    words: list[dict] = []
    segments = asr.get("segments", [])
    for segment, token in zip(segments, _render_aligned_words(asr["text"], segments)):
        start, end = float(segment["start"]), float(segment["end"])
        end = max(end, start + 0.05)
        words.append({"start": start, "end": end, "text": token, "speaker": _speaker_for_interval(start, end, speaker_turns)})
    return words


def group_utterances(words: list[dict]) -> list[dict]:
    utterances: list[dict] = []
    for word in words:
        if utterances and utterances[-1]["speaker"] == word["speaker"] and word["start"] - utterances[-1]["end"] < 1.5:
            utterances[-1]["end"] = max(utterances[-1]["end"], word["end"])
            utterances[-1]["text"] += word["text"]
        else:
            utterances.append({"start": word["start"], "end": word["end"], "speaker": word["speaker"], "text": word["text"]})
    for utterance in utterances:
        utterance["text"] = utterance["text"].strip()
    return utterances


def transcript_text(utterances: list[dict], names: dict[int, str] | None = None) -> str:
    lines = []
    for item in utterances:
        minute, second = divmod(int(item["start"]), 60)
        if item["speaker"] is None:
            speaker = "화자 미확인"
        else:
            speaker = (names or {}).get(item["speaker"], f"화자 {item['speaker'] + 1}")
        lines.append(f"[{minute:02d}:{second:02d}] {speaker}: {item['text']}")
    return "\n".join(lines)


def _summary_body(response: str) -> str:
    body = response.strip()
    if body.startswith("```markdown\n") and body.endswith("```"):
        body = body[len("```markdown\n"):-3].strip()
    lines = body.splitlines()
    if lines and re.fullmatch(r"#{1,6}\s*(?:회의\s*)?요약\s*", lines[0].strip()):
        lines.pop(0)
    while lines and not lines[0].strip():
        lines.pop(0)
    if lines and re.match(r"^(?:네[,，]?\s*)?(?:다음은|아래는).*(?:요약|정리).*(?:입니다|드립니다)[:：]?\s*$", lines[0].strip()):
        lines.pop(0)
    return "\n".join(lines).strip()


def summarize(transcript: str, model_id: str | None = None) -> str:
    if not transcript.strip():
        return "전사된 발화가 없어 요약할 수 없습니다."
    generate_notes = _notes_generator(model_id or _model("notes"))
    system = (
        "회의 전사에 있는 사실만 한국어 마크다운으로 요약하세요. "
        "요약문 본문만 출력하고 인사, 안내 문구, 제목, 코드 블록, 지시 수행 설명, 할 일 목록은 쓰지 마세요."
    )
    if len(transcript) > 7_000:
        instruction = (
            "아래 긴 회의의 주요 논점과 서로 다른 입장을 6~10개 짧은 마크다운 불릿으로 바로 요약하세요. "
            "특정 화자의 주장을 전체 합의로 쓰지 말고, 확정되지 않은 내용을 결정으로 쓰지 마세요.\n\n전사:\n"
        )
        max_tokens = 900
    else:
        instruction = (
            "아래 회의를 한국어 2~4문장으로 바로 요약하세요. 확정된 결정과 미정인 사항을 구분하고, "
            "제안을 결정으로 쓰지 마세요. 별도 머리말이나 제목 없이 첫 문장부터 시작하세요.\n\n전사:\n"
        )
        max_tokens = 350
    return _summary_body(generate_notes(system, instruction + transcript, max_tokens))


def release_models() -> None:
    """Drop every loaded model and MLX's freed-buffer cache.

    Each stage loads only its own model, so peak memory is the largest single stage instead of
    all models at once, and an idle worker holds no weights. Reloading from the disk cache costs
    a few seconds per meeting.
    """
    import mlx.core as mx

    _asr_session.cache_clear()
    _forced_aligner.cache_clear()
    try:  # mlx-qwen3-asr keeps its own process-wide model and tokenizer caches.
        from mlx_qwen3_asr.load_models import _ModelHolder
        from mlx_qwen3_asr.tokenizer import _TokenizerHolder

        _ModelHolder.clear()
        _TokenizerHolder.clear()
    except (ImportError, AttributeError):
        pass
    gc.collect()
    mx.clear_cache()


# Share of the whole job each stage takes, measured roughly on Apple Silicon: (start, width).
STAGES = {"decode": (0.0, 0.02), "diarize": (0.02, 0.18), "transcribe": (0.2, 0.45), "align": (0.65, 0.15), "summarize": (0.8, 0.2)}


def process_recording(path: str | Path, *, asr_model: str | None = None, notes_model: str | None = None,
                      diarization_weights: str | Path | None = None, two_channel: bool = False,
                      progress=None, language: str = "Korean") -> dict:
    """two_channel: the file is Exanote's own recording (microphone left, system audio right).

    progress(stage, overall_fraction) is called as each stage moves, with a stage name from STAGES.
    """
    def report(stage: str, fraction: float) -> None:
        if progress:
            start, width = STAGES[stage]
            progress(stage, start + width * min(1.0, max(0.0, fraction)))

    report("decode", 0.0)
    audio = decode_audio(path)
    channels = decode_channels(path) if two_channel else None
    if channels is not None:
        # Sum both sides like a single-channel recording would; afconvert's downmix averages them,
        # which makes a lone speaker 6 dB quieter and easier for diarization to miss.
        audio = np.clip(channels[0][: len(audio)] + channels[1][: len(audio)], -1.0, 1.0)
    self_speaker = None
    try:
        weights = diarization_weights or os.getenv("EXANOTE_DIARIZATION_WEIGHTS") or models.ensure("diarization") / "model.safetensors"
        report("diarize", 0.0)
        speaker_turns = diarize(audio, NemotronMLX(weights), progress=lambda fraction: report("diarize", fraction))
        release_models()
        report("transcribe", 0.0)
        asr = transcribe(audio, asr_model, speaker_turns, report, language=language)
        release_models()
        words = align_words(asr, speaker_turns)
        if channels is not None:
            words, self_speaker = attribute_self(words, channels)
        utterances = group_utterances(words)
        transcript = transcript_text(utterances, {self_speaker: SELF_NAME} if self_speaker is not None else None)
        report("summarize", 0.0)
        notes = summarize(transcript, notes_model)
    finally:
        release_models()
    return {"duration": round(len(audio) / 16000, 2), "language": asr.get("language"), "speaker_turns": speaker_turns, "utterances": utterances, "transcript": transcript, "notes": notes, "self_speaker": self_speaker}
