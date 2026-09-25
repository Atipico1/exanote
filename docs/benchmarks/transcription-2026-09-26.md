# 한국어 전사 CER 비교 — 2026-09-26

README의 성능 측정과 동일한 AI Hub 464 샘플을 사용합니다. 하나의 토론 녹음 `DGBAH21000196`에서 추출한 10개 WAV(16 kHz, mono), 총 2,903.008초입니다. 서로 다른 주제의 토론 10개를 뜻하지 않습니다.

정답과 전사 결과에 Unicode NFKC 및 casefold를 적용하고 문자와 숫자만 남깁니다. CER은 전체 클립의 Levenshtein 문자 편집 거리 합계를 정답 문자 수 합계(17,385자)로 나눈 값입니다. 삽입·삭제·치환을 모두 포함하며, 음원별 오류율의 단순 평균이 아닙니다. 화자 구분과 타임스탬프 정확도는 평가하지 않습니다.

API 모델은 OpenRouter의 `/api/v1/audio/transcriptions`에 동일한 WAV를 각각 전달했습니다. 모두 `language=ko`를 지정했으며 MAI는 기존 비교와 동일하게 Azure `transcribeStyle=verbatim` 옵션을 사용했습니다. Exanote와 T사의 값은 기존 저장된 결과를 같은 기준으로 재계산했습니다. Exanote는 이 데이터로 개선한 파이프라인이므로 독립적인 미사용 평가 데이터에 대한 결과가 아닙니다.

## 재현

로컬 평가 데이터가 있는 체크아웃에서 다음 명령을 실행합니다. 첫 실행은 유료 API 요청을 하며 음원을 해당 서비스에 전송합니다. 저장된 응답은 재사용합니다. 키를 명령 인자에 직접 넣지 않습니다.

```sh
.venv/bin/python scripts/benchmark_transcription.py --env-file /path/to/private.env
.venv/bin/python scripts/benchmark_transcription.py --score-only
```

원본 음원과 전사 응답은 저장소에 게시하지 않습니다. 공개 집계에는 클립 ID, 정답 문자 수, 편집 거리 및 CER만 포함합니다.

API 사양: [Gemini 3.5 Transcribe](https://openrouter.ai/google/gemini-3.5-transcribe), [Muse Voice Transcribe 1.0](https://openrouter.ai/meta/muse-voice-transcribe-1.0), [MAI-Transcribe 2](https://openrouter.ai/microsoft/mai-transcribe-2).

## 결과

| 모델 / 서비스 | CER |
| --- | ---: |
| Exanote | 7.68% |
| T사 | 6.51% |
| google/gemini-3.5-transcribe | 7.39% |
| meta/muse-voice-transcribe-1.0 | 6.61% |
| microsoft/mai-transcribe-2 | 6.48% |

[문자 수와 편집 거리 집계](transcription-2026-09-26.json)
