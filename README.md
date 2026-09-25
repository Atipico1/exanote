<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/exanote-lockup-dark.png">
    <img src="docs/brand/exanote-lockup-light.png" alt="Exanote" width="360">
  </picture>
</p>

# Exanote

회의를 녹음하거나 녹음 파일을 가져오면 화자별 전사와 회의 노트를 만들어주는 Mac 앱입니다. 영어 회의에서는 녹음 중 한국어 번역을 볼 수 있습니다. 음성 처리는 Mac에서 이뤄집니다.

![Exanote 홈 화면](docs/screenshots/home.jpg)

## 주요 기능

### 녹음 파일 전사와 화자 구분

파일을 가져오면 누가 언제 말했는지 나눠 적어줍니다. 발화 시각을 누르면 그 부분부터 다시 들을 수 있고, 회의 노트도 함께 만듭니다.

### 회의 자동 감지

Zoom, Teams, Slack, FaceTime이나 브라우저에서 통화가 시작되면 녹음을 제안합니다. 알림을 눌러야 녹음이 시작됩니다.

### Google Drive로 팀에서 쓰기 (Beta)

팀 폴더를 Google Drive로 동기화해 전사와 회의 노트를 함께 볼 수 있습니다. 원본 오디오는 각자의 Mac에 남습니다.

### 실시간 전사와 번역

녹음 중 **실시간 번역 켜기**를 누르면 영어 발화와 한국어 번역이 실시간 노트에 쌓입니다. 현재 영어 → 한국어를 지원합니다.

![녹음 중 실시간 번역 켜기 버튼](docs/screenshots/recording-live-toggle-closeup.jpg)

**상단에 띄우기**를 누르면 다른 앱을 보면서도 실시간 노트를 볼 수 있습니다.

<p align="center"><img src="docs/screenshots/live-floating.jpg" alt="화면 상단에 띄운 실시간 노트" width="560"></p>

녹음 후에는 전사와 번역을 다시 볼 수 있습니다. 실시간 문장은 녹음 후 완성되는 전사와 다를 수 있습니다.

![실시간 전사와 번역 화면](docs/screenshots/live-translation.jpg)

## 사용 환경

macOS 15 이상을 설치한 Apple Silicon Mac이 필요합니다. 처음 사용할 때 음성 처리 모델을 내려받습니다.

| 저장 공간 | 크기 |
| --- | ---: |
| 설치 파일 | 약 186MB |
| 설치된 앱 | 약 493MB |
| 음성 처리 모델 | 약 5.3GB |

앱과 모델을 합쳐 약 5.8GB가 필요하며, 녹음 파일은 별도 공간을 사용합니다.

## 성능 측정

Apple M4, 메모리 32GB인 Mac에서 측정했습니다. 한국어 토론 녹음 10개(총 48분 23초)를 같은 기준으로 전사한 결과입니다. 글자 오류율은 낮을수록 정확합니다.

| 전사 정확도 | Exanote | T사 |
| --- | ---: | ---: |
| 글자 오류율 | 7.68% | 6.51% |

공백과 문장부호를 제외하고 비교했습니다. 별도 녹음 8개에서 Exanote의 글자 오류율은 9.24%였습니다. T사는 이 녹음으로 측정하지 않았습니다.

- **처리 시간:** 48분 23초 분량의 전사에 8분 1초가 걸렸습니다. 화자 구분과 회의 노트 작성 시간은 제외한 수치입니다.
- **작업 중 메모리:** 약 5분짜리 파일을 전사하고 화자를 구분해 회의 노트까지 만들 때, 작업 프로세스가 사용한 최대 메모리는 약 4GB였습니다.

## 라이선스

앱 코드는 Apache-2.0 라이선스를 따릅니다. 다운로드되는 모델에는 각각의 라이선스가 적용됩니다.

[개발 및 빌드 안내](docs/development.md)
