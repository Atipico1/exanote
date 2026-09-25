# 개발 및 빌드

macOS 15 이상인 Apple Silicon Mac, Python 3.12 또는 3.13, `uv`, `xcodegen`, Xcode 명령줄 도구가 필요합니다.

## 로컬 실행

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e .
xcodegen generate
xcodebuild -project Exanote.xcodeproj -scheme Exanote -configuration Debug -derivedDataPath .build/DerivedData build
open .build/DerivedData/Build/Products/Debug/Exanote.app
```

Xcode에서 `Exanote.xcodeproj`를 열어 실행할 수도 있습니다.

## 앱 빌드

```bash
scripts/build_app.sh
```

`build/Exanote.app`과 `build/Exanote.dmg`가 만들어집니다. 이 빌드에는 Python 워커가 포함돼 있어 앱 사용자는 Python을 따로 설치할 필요가 없습니다. 모델은 첫 사용 때 내려받습니다.

배포용 서명과 공증이 필요하면 다음 명령을 사용합니다.

```bash
SIGN_IDENTITY="Developer ID Application: …" scripts/build_app.sh
NOTARY_PROFILE=exanote scripts/notarize_app.sh
```

공증 자격 증명은 미리 macOS 키체인에 등록해야 합니다.

## 명령줄에서 파일 처리

```bash
.venv/bin/exanote process /path/to/meeting.m4a --output result.json
```

녹음과 모델은 `~/.local/share/exanote`에 저장됩니다. **설정 ▸ AI 모델**에서 모델을 설치하거나 삭제할 수 있습니다.

## 테스트

```bash
.venv/bin/python -m pytest tests
```

실시간 처리 점검용 음성은 저장소에 포함하지 않습니다. macOS 음성 합성으로 로컬에서 생성한 뒤 스트리밍 테스트에 사용할 수 있습니다.

```bash
.venv/bin/python scripts/generate_live_synthetic.py
.venv/bin/python scripts/check_live_stream.py --fixture held_out_voices --pace
```
