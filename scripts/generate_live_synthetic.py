"""Rebuild the local three-voice streaming fixtures with macOS speech synthesis."""

from __future__ import annotations

import json
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

from exanote.pipeline import _read_float_wav


OUT = Path(__file__).resolve().parents[1] / ".build/live_synthetic"


def voice(voice_name: str, text: str, folder: Path, rate: int = 165) -> np.ndarray:
    aiff = folder / f"{voice_name}.aiff"
    wav = folder / f"{voice_name}.wav"
    subprocess.run(["say", "-v", voice_name, "-r", str(rate), "-o", str(aiff), text], check=True)
    subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEF32@16000", "-c", "1", str(aiff), str(wav)], check=True)
    return _read_float_wav(wav)


def save(name: str, entries: list[tuple[float, str, str, str, np.ndarray]], duration: float | None = None) -> None:
    length = int((duration or max(start + len(audio) / 16_000 for start, _, _, _, audio in entries) + 0.6) * 16_000)
    stereo = np.zeros((length, 2), np.float32)
    truth = []
    for start, channel, voice_name, text, audio in entries:
        first = int(start * 16_000)
        stereo[first:first + len(audio), 0 if channel == "mic" else 1] += audio
        truth.append({"start": round(start, 2), "end": round(start + len(audio) / 16_000, 2),
                      "channel": channel, "voice": voice_name, "text": text})
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(16_000)
        output.writeframes(np.int16(np.clip(stereo, -1, 1) * 32767).tobytes())
    (OUT / f"{name}.json").write_text(json.dumps(truth, ensure_ascii=False, indent=2) + "\n")


def main() -> None:
    lines = [
        ("Daniel", "mic", "Hello, I am Daniel. I will send the report tomorrow."),
        ("Samantha", "system", "Thank you, Daniel. I will review it on Friday."),
        ("Fred", "system", "Please include the final budget in that report."),
    ]
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        recordings = [(name, channel, text, voice(name, text, folder)) for name, channel, text in lines]
        sequential = []
        start = 0.0
        for name, channel, text, audio in recordings:
            sequential.append((start, channel, name, text, audio))
            start += len(audio) / 16_000 + 0.6
        save("three_speakers", sequential, duration=start)
        def at(start: float, item: tuple[str, str, str, np.ndarray]):
            name, channel, text, audio = item
            return (start, channel, name, text, audio)

        save("overlap_channels", [at(0.0, recordings[0]), at(2.0, recordings[1]), at(6.0, recordings[2])], duration=9.6)
        save("overlap_remote", [at(0.0, recordings[1]), at(1.5, recordings[2])], duration=5.8)
        long_text = ("Good morning everyone. First, we need to review the budget for next month. "
                     "Then I will send the updated schedule to the team. Please check the numbers "
                     "carefully and tell me if anything has changed before Friday.")
        save("long_turn", [(0.0, "mic", "Daniel", long_text, voice("Daniel", long_text, folder))])
        demo_lines = [
            ("Daniel", "mic", "Good morning. Let's check the launch plan and the customer feedback from yesterday."),
            ("Samantha", "system", "The first interviews went well. People liked the simple dashboard and the faster search."),
            ("Fred", "system", "I agree. We should fix the confusing export button before inviting the next group."),
            ("Daniel", "mic", "That makes sense. Samantha, can you send me the interview notes after this call?"),
            ("Samantha", "system", "Yes, I will share them today. I also found two bugs in the mobile layout."),
            ("Fred", "system", "I can handle those bugs. Please put the screenshots in the project folder."),
            ("Daniel", "mic", "Great. Let's review the changes tomorrow morning and decide if we are ready to launch."),
        ]
        demo_recordings = [(name, channel, text, voice(name, text, folder, 200)) for name, channel, text in demo_lines]
        demo_entries = []
        start = 0.0
        for index, (name, channel, text, audio) in enumerate(demo_recordings):
            demo_entries.append((start, channel, name, text, audio))
            start += len(audio) / 16_000 + (0.65 if index < len(demo_recordings) - 1 else 0.4)
        save("demo_thirty_seconds", demo_entries, duration=start)
        # Held-out voices and wording: exercise returning remote speakers without
        # relying on the three voices or sentences used in the screen demo.
        alternate_lines = [
            ("Moira", "mic", "Could you check the delivery date for the prototype?"),
            ("Karen", "system", "The supplier confirmed next Tuesday for the first batch."),
            ("Rishi", "system", "I will prepare the review document before then."),
            ("Karen", "system", "Please send me the updated drawings this afternoon."),
            ("Rishi", "system", "Sure, I will attach them to the project notes."),
        ]
        alternate_entries = []
        start = 0.0
        for name, channel, text in alternate_lines:
            audio = voice(name, text, folder, 185)
            alternate_entries.append((start, channel, name, text, audio))
            start += len(audio) / 16_000 + 0.55
        save("held_out_voices", alternate_entries, duration=start)
    for path in sorted(OUT.glob("*.wav")):
        print(path, round(path.stat().st_size / 1024), "KiB")


if __name__ == "__main__":
    main()
