---
license: apache-2.0
base_model: mlx-community/Qwen3-ForcedAligner-0.6B-8bit
library_name: mlx
tags:
- mlx
- forced-alignment
- speech
- korean
- 8-bit
---

# Qwen3 ForcedAligner 0.6B, full 8-bit MLX

This checkpoint is a smaller derivative of [mlx-community/Qwen3-ForcedAligner-0.6B-8bit](https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-8bit) (revision `0e1a68e91d815300c7c9754b2a7639378b23db15`), itself converted from [Qwen/Qwen3-ForcedAligner-0.6B](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B). Both source model pages mark their models Apache-2.0. This is a quantized checkpoint, not a fine-tune.

The source MLX 8-bit checkpoint leaves its audio encoder in BF16. We applied MLX affine 8-bit quantization with group size 64 to 147 `audio_tower` Linear weight tensors. Their 147 scale and 147 bias tensors were added. The other 957 source tensors have unchanged values. The reproducible conversion script is included as `quantize_aligner_encoder.py`.

| Weight file | Source | This checkpoint |
|---|---:|---:|
| `model.safetensors` | 1,271,924,386 bytes | 979,502,446 bytes |

The weight file is 292.4 MB (23.0%) smaller. This does not establish an equivalent reduction in total app download or peak runtime memory.

## Use

Tested on Apple Silicon with `mlx-qwen3-asr==0.4.4`:

```python
from mlx_qwen3_asr import ForcedAligner

aligner = ForcedAligner(model_path="<downloaded model folder>")
words = aligner.align(audio_16khz_mono, transcript, "Korean")
```

`audio_16khz_mono` is a NumPy float waveform. For Korean, the evaluation below used `src/exanote/korean.py` in place of the library's optional `soynlp` tokenizer. To reproduce this setup, import `install_for_aligner` from `exanote.korean` and call it before `align`. The splitter is application code, not part of the model weights.

## Validation and limitations

Two Korean broadcast excerpts from AI Hub 464 (288.07 and 295.93 seconds) were aligned with the same fixed Qwen3-ASR 1.7B transcripts on both checkpoints. In one run per excerpt, all 1,643 returned alignment units matched in text and order. Both boundaries were identical for 1,617 units (98.4%). Thirteen units (0.8%) shifted by more than 100 ms; one shifted by more than 500 ms, with a maximum shift of 880 ms. The 99th percentile boundary difference was 80 ms. Alignment times were 10.51 versus 10.50 seconds and 11.17 versus 10.76 seconds (source versus this checkpoint), respectively. These timings are one-run observations, not a speed benchmark.

The fixed input transcript means matching word text does not measure transcription quality. We did not compare timestamps against human ground truth or validate other languages. Some changed boundaries can be material, so evaluate this checkpoint on your own audio before relying on precise word timings. No AI Hub audio or transcript is included in this repository.
