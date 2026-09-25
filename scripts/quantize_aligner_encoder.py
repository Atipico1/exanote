"""Quantize the BF16 audio encoder of Qwen3-ForcedAligner-0.6B-8bit to 8 bits (group 64).

The published "8bit" checkpoint only quantized the text decoder; its audio encoder (~605 MB)
is still BF16. mlx-qwen3-asr quantizes exactly the modules that carry .scales, so a checkpoint
with the encoder's Linear layers quantized loads without code changes.
"""
import json, shutil, sys
from pathlib import Path
import mlx.core as mx
import mlx.nn as nn
from huggingface_hub import snapshot_download
from mlx_qwen3_asr.load_models import _ModelHolder

SOURCE = "mlx-community/Qwen3-ForcedAligner-0.6B-8bit"
SOURCE_REVISION = "0e1a68e91d815300c7c9754b2a7639378b23db15"
target = Path(sys.argv[1])
source = Path(snapshot_download(SOURCE, revision=SOURCE_REVISION))

model, _ = _ModelHolder.get(str(source), dtype=mx.float16)
linears = {name for name, module in model.named_modules() if name.startswith("audio_tower") and isinstance(module, nn.Linear)}
_ModelHolder.clear()

weights = mx.load(str(source / "model.safetensors"))
quantized = 0
for path in sorted(linears):
    weight = weights.get(f"{path}.weight")
    if weight is None or f"{path}.scales" in weights or weight.ndim != 2 or weight.shape[-1] % 64:
        continue
    packed, scales, biases = mx.quantize(weight, group_size=64, bits=8)
    weights[f"{path}.weight"], weights[f"{path}.scales"], weights[f"{path}.biases"] = packed, scales, biases
    quantized += 1

target.mkdir(parents=True, exist_ok=True)
for item in source.iterdir():
    if item.name not in {"model.safetensors", "model.safetensors.index.json", "README.md", ".gitattributes"}:
        shutil.copy2(item, target / item.name)
mx.save_safetensors(str(target / "model.safetensors"), weights, metadata={"format": "mlx"})
script_dir = Path(__file__).resolve().parent
project_root = script_dir.parent
card = project_root / "docs/model-cards/forcedaligner-full-8bit.md"
license_file = project_root / "LICENSE"
shutil.copy2(card if card.is_file() else script_dir / "README.md", target / "README.md")
shutil.copy2(license_file if license_file.is_file() else script_dir / "LICENSE", target / "LICENSE")
splitter = project_root / "src/exanote/korean.py"
shutil.copy2(splitter if splitter.is_file() else script_dir / "korean_splitter.py", target / "korean_splitter.py")
print(json.dumps({"encoder_linear_layers": len(linears), "quantized_now": quantized,
                  "source_MB": round((source / "model.safetensors").stat().st_size / 1e6),
                  "target_MB": round((target / "model.safetensors").stat().st_size / 1e6)}))
