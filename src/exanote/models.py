"""The AI models Exanote runs, each in its own folder under DATA/models.

Keeping every model in a folder the app owns lets Settings list, download and delete them
without touching the shared Hugging Face cache other tools use, and lets removing Exanote take
every model with it.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path

from .paths import DATA

MODELS = DATA / "models"
# Written once the first start has looked for these models in the shared Hugging Face cache, so a
# model the user deleted in Settings does not come back on the next launch.
_ADOPTED_MARKER = MODELS / ".hf-cache-checked"


@dataclass(frozen=True)
class Model:
    id: str
    role: str
    name: str
    repo: str
    folder: str
    files: tuple[str, ...]
    approx_bytes: int
    override: str  # Environment variable that points the pipeline at another checkpoint.

    @property
    def path(self) -> Path:
        return MODELS / self.folder

    @property
    def installed(self) -> bool:
        return all((self.path / name).is_file() for name in self.files)


CATALOG = (
    Model("diarization", "화자 구분", "Nemotron 3 Diarization", "nvidia/Nemotron-3-Diarization",
          "nemotron-3-diarization", ("model.safetensors",), 397_000_000, "EXANOTE_DIARIZATION_WEIGHTS"),
    Model("asr", "음성 인식", "Qwen3-ASR 1.7B", "moona3k/mlx-qwen3-asr-1.7b-8bit", "qwen3-asr-1.7b-8bit",
          ("config.json", "tokenizer_config.json", "vocab.json", "merges.txt", "quantization_config.json", "weights.safetensors"),
          2_180_000_000, "EXANOTE_ASR_MODEL"),
    # The published full-8-bit copy quantizes the audio encoder as well as the text decoder.
    Model("aligner", "단어 시간 맞춤", "Qwen3-ForcedAligner 0.6B", "ethansipark/Qwen3-ForcedAligner-0.6B-8bit-full-MLX",
          "qwen3-forcedaligner-0.6b-8bit",
          ("config.json", "tokenizer_config.json", "vocab.json", "merges.txt", "preprocessor_config.json",
           "generation_config.json", "chat_template.json", "model.safetensors"),
          985_000_000, "EXANOTE_ALIGNER_MODEL"),
    # Only the text-only PLE L files; the repo's vision and audio towers are never downloaded.
    Model("notes", "요약", "Gemma 4 E2B PLE L", "TheStageAI/gemma-4-E2B-it-qat", "gemma-4-e2b-ple-l",
          ("config.json", "tokenizer.json", "tokenizer_config.json", "model_l.safetensors", "ple_l.safetensors"),
          1_770_000_000, "EXANOTE_NOTES_MODEL"),
)
BY_ID = {model.id: model for model in CATALOG}

_locks = {model.id: threading.Lock() for model in CATALOG}
_state = threading.Lock()
_downloading: dict[str, int] = {}  # model id -> expected bytes
# Bytes the current download has written to disk, and received from the network. Xet downloads
# report both; the network count moves first, the written count is exact.
_received: dict[str, int] = {}
_transferred: dict[str, int] = {}
_errors: dict[str, str] = {}


class ModelInUse(Exception):
    pass


def ensure(model_id: str) -> Path:
    """Return the model's folder, downloading it first if it is not installed."""
    model = BY_ID[model_id]
    with _locks[model_id]:
        if model.installed:
            return model.path
        with _state:
            _downloading[model_id] = model.approx_bytes
            _errors.pop(model_id, None)
        try:
            if not _clone_from_hf_cache(model):
                _download(model)
            if not model.installed:
                raise RuntimeError(f"{model.name} 파일을 모두 받지 못했어요.")
        except Exception as error:
            with _state:
                _errors[model_id] = str(error)
            raise
        finally:
            with _state:
                _downloading.pop(model_id, None)
        return model.path


def start_install(model_id: str) -> None:
    model = BY_ID[model_id]
    if model.installed:
        return
    with _state:
        if model_id in _downloading:
            return
        _downloading[model_id] = model.approx_bytes  # Shown right away; ensure() refines it.
        _errors.pop(model_id, None)

    def run() -> None:
        try:
            ensure(model_id)
        except Exception:
            pass  # Recorded in _errors and shown in Settings.
        finally:
            with _state:
                _downloading.pop(model_id, None)

    threading.Thread(target=run, name=f"install-{model_id}", daemon=True).start()


def delete(model_id: str) -> None:
    model = BY_ID[model_id]
    lock = _locks[model_id]
    if not lock.acquire(blocking=False):
        raise ModelInUse(model_id)
    try:
        with _state:
            if model_id in _downloading:
                raise ModelInUse(model_id)
            _errors.pop(model_id, None)
        if model.path.exists():
            shutil.rmtree(model.path)
    finally:
        lock.release()


def overview() -> dict:
    items = []
    for model in CATALOG:
        with _state:
            expected = _downloading.get(model.id)
            received = max(_received.get(model.id, 0), _transferred.get(model.id, 0))
            error = _errors.get(model.id)
        size = _tree_size(model.path)
        items.append({
            "id": model.id,
            "role": model.role,
            "name": model.name,
            "repo": model.repo,
            "installed": expected is None and model.installed,
            "downloading": expected is not None,
            "bytes": max(size, received) if expected is not None else size,
            "expected_bytes": expected or model.approx_bytes,
            "error": error,
            "overridden": bool(os.getenv(model.override)),
        })
    return {"folder": str(MODELS), "total_bytes": _tree_size(MODELS), "models": items}


def adopt_from_hf_cache_once() -> None:
    """Earlier versions downloaded some models into ~/.cache/huggingface. Clone them in once."""
    if _ADOPTED_MARKER.exists():
        return
    for model in CATALOG:
        with _locks[model.id]:
            if not model.installed:
                try:
                    _clone_from_hf_cache(model)
                except OSError:
                    pass
    MODELS.mkdir(parents=True, exist_ok=True)
    _ADOPTED_MARKER.touch()


def _clone_from_hf_cache(model: Model) -> bool:
    """Copy the model out of the shared Hugging Face cache when every file is already there.

    On APFS "cp -c" makes a clone that shares the cache's blocks, so this is instant and takes
    no extra space until one of the copies is deleted.
    """
    from huggingface_hub import try_to_load_from_cache

    sources = []
    for name in model.files:
        found = try_to_load_from_cache(model.repo, name)
        if not isinstance(found, str):
            return False
        sources.append((name, Path(found).resolve()))
    model.path.mkdir(parents=True, exist_ok=True)
    for name, source in sources:
        target = model.path / name
        if target.is_file():
            continue
        partial = target.with_name(name + ".partial")
        if subprocess.run(["/bin/cp", "-c", str(source), str(partial)], capture_output=True).returncode != 0:
            shutil.copyfile(source, partial)
        partial.replace(target)
    return True


def _download(model: Model) -> None:
    from huggingface_hub import HfApi, hf_hub_download

    try:
        total = sum(getattr(info, "size", 0) or 0 for info in HfApi().get_paths_info(model.repo, list(model.files)))
        if total:
            with _state:
                _downloading[model.id] = total
    except Exception:
        pass  # Progress falls back to the approximate size.
    done = sum((model.path / name).stat().st_size for name in model.files if (model.path / name).is_file())
    with _state:
        _received[model.id] = done
        _transferred[model.id] = done
    try:
        for name in model.files:
            hf_hub_download(model.repo, name, local_dir=model.path, tqdm_class=_progress_counter(model.id))
    finally:
        with _state:
            _received.pop(model.id, None)
            _transferred.pop(model.id, None)
    # huggingface_hub's resume bookkeeping; the finished files no longer need it.
    shutil.rmtree(model.path / ".cache", ignore_errors=True)


def _progress_counter(model_id: str):
    """A silent tqdm that adds each progress bar's bytes to _received or _transferred.

    Xet downloads write into a partial file the folder size does not show, and report network
    transfer on a second bar; counting the two bars separately avoids adding them together.
    """
    from tqdm import tqdm

    class Counter(tqdm):
        def __init__(self, *args, **kwargs):
            self._tally = _transferred if str(kwargs.get("desc", "")).endswith("downloading bytes") else _received
            kwargs["disable"] = True
            super().__init__(*args, **kwargs)

        def update(self, n=1):
            if n:
                with _state:
                    self._tally[model_id] = self._tally.get(model_id, 0) + int(n)
            return super().update(n)

    return Counter


def _tree_size(path: Path) -> int:
    """Bytes under path, including partial downloads, counting hard links once."""
    if not path.exists():
        return 0
    seen: set[tuple[int, int]] = set()
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                info = os.lstat(os.path.join(root, name))
            except OSError:
                continue
            if (info.st_dev, info.st_ino) not in seen:
                seen.add((info.st_dev, info.st_ino))
                total += info.st_size
    return total
