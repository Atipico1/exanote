"""Compare hosted ASR on the same ten clips used by the README (paid API calls).

Run with OPENROUTER_API_KEY or --env-file. Results resume from local saved files.
No audio, transcript, or credential is included in the shareable score report.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import time
import unicodedata

import requests
from rapidfuzz.distance import Levenshtein

MODELS = ["google/gemini-3.5-transcribe", "meta/muse-voice-transcribe-1.0", "microsoft/mai-transcribe-2"]
ROOT = Path(__file__).resolve().parents[1]


def normalize(text):
    return "".join(c for c in unicodedata.normalize("NFKC", text).casefold() if c.isalnum())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, default=ROOT / "data/aihub464/single_source_10clips")
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--score-only", action="store_true")
    parser.add_argument("--models", nargs="+", choices=MODELS, default=MODELS)
    args = parser.parse_args()
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key and args.env_file:
        for line in args.env_file.read_text().splitlines():
            name, sep, value = line.partition("=")
            if sep and name.strip().removeprefix("export ") == "OPENROUTER_API_KEY":
                key = value.strip().strip("\"'")
    if not key and not args.score_only:
        parser.error("Set OPENROUTER_API_KEY or pass --env-file; use --score-only for saved results")
    data = json.loads((args.dataset / "combined_10clips.json").read_text())
    out = args.dataset / "hosted_comparison"
    out.mkdir(exist_ok=True)
    report = {"dataset": data["dataset"], "source_id": data["source_id"],
              "normalization": "NFKC, casefold, keep alphanumeric characters",
              "aggregation": "total character edits / total reference characters", "models": {}}
    for model in args.models:
        folder = out / model.replace("/", "--")
        folder.mkdir(exist_ok=True)
        scores = []
        for clip in data["clips"]:
            stem = clip["id"]
            path = folder / f"{stem}.json"
            if not path.exists() and not args.score_only:
                payload = {"model": model, "input_audio": {
                    "data": base64.b64encode((args.dataset / clip["audio_file"]).read_bytes()).decode(),
                    "format": "wav"}, "language": "ko"}
                if model == "microsoft/mai-transcribe-2":
                    payload["provider"] = {"options": {"azure": {"enhancedMode": {"modelOptions": {"transcribeStyle": "verbatim"}}}}}
                started = time.monotonic()
                response = requests.post("https://openrouter.ai/api/v1/audio/transcriptions",
                    headers={"Authorization": f"Bearer {key}"}, json=payload, timeout=300)
                # Do not dump response/request bodies: they can contain sensitive diagnostics.
                if not response.ok:
                    raise SystemExit(f"{model} {stem}: HTTP {response.status_code}; saved results retained, no automatic retry")
                result = response.json()
                if not isinstance(result.get("text"), str) or not result["text"].strip():
                    raise SystemExit(f"{model} {stem}: missing transcript; no score written")
                result["_benchmark"] = {"model": model, "clip_id": stem, "language": "ko",
                    "seconds": time.monotonic() - started, "generation_id": response.headers.get("X-Generation-Id")}
                path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
                print(f"Saved {model} {stem}", flush=True)
            if not path.exists():
                continue
            result = json.loads(path.read_text())
            ref = normalize(" ".join(u["text"] for u in data["utterances"] if u["clip_id"] == stem))
            edits = Levenshtein.distance(ref, normalize(result["text"]))
            scores.append({"clip": stem, "reference_characters": len(ref), "edits": edits})
        n = sum(s["reference_characters"] for s in scores)
        edits = sum(s["edits"] for s in scores)
        complete = len(scores) == len(data["clips"])
        report["models"][model] = {"complete": complete, "clips": scores, "reference_characters": n,
            "edits": edits, "cer_percent": 100 * edits / n if complete and n else None}
    (out / ("scores.json" if args.models == MODELS else "scores-selected.json")).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: {"completed_clips": len(v["clips"]), "cer_percent": v["cer_percent"]}
                      for k, v in report["models"].items()}, indent=2))


if __name__ == "__main__":
    main()
