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

## 자동 업데이트 배포

Sparkle 2.10.0을 사용합니다. 앱의 일반 설정에서 자동 확인·다운로드를 조절하고,
Exanote 메뉴에서 수동으로 업데이트를 확인합니다. 녹음·처리가 끝나고 메모를 저장한 뒤
로컬 Python 워커를 종료하고 앱을 교체합니다. 회의와 모델 데이터 디렉터리는 교체하지 않습니다.

- `project.yml`의 `CFBundleVersion`은 매 배포마다 증가시킵니다.
- 업데이트 피드: `https://atipico1.github.io/exanote/appcast.xml`
- 개인 EdDSA 키는 배포 Mac 키체인의 `exanote` 계정에 보관합니다. 저장소에는 공개키만 있습니다.
- Sparkle 패키지 버전과 `Package.resolved`를 함께 고정합니다.
- Developer ID 서명 후 Apple 공증을 받고, 공증 티켓을 붙인 앱으로 DMG와 업데이트 ZIP을 만듭니다.
- `SPARKLE_BIN=.build/sparkle-2.10.0/bin scripts/prepare_update.sh build/release-VERSION vVERSION`
  명령은 공증 상태를 검사한 뒤 ZIP, EdDSA 서명된 appcast, 체크섬을 생성합니다.
- GitHub Release에 DMG·ZIP·체크섬을 먼저 게시하고, GitHub Pages의 `appcast.xml`을 마지막에 갱신합니다.
- Xcode 계정으로 공증할 때는 Organizer의 Direct Distribution을 사용하고 승인 후 Export Notarized App으로 내보냅니다.
  CLI 경로는 `scripts/notarize_app.sh`와 별도로 등록한 키체인 프로필을 사용합니다.

## 글자 표시 설정

일반 설정의 글자 섹션에서 설치된 글꼴, 본문 크기(12–20pt), 사이드바 크기(13–22pt)를 조절합니다. 기본값은 시스템 글꼴, 본문 14pt, 사이드바 16pt입니다. 변경사항은 즉시 반영되고 앱을 다시 실행해도 유지됩니다. 회의 시작 알림 사용 여부와 macOS 알림 권한은 권한 화면에서 함께 관리합니다.
