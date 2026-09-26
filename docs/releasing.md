# GitHub 배포

`main` push 또는 Actions의 수동 실행은 Apple Silicon macOS runner에서 테스트와 앱 빌드를 실행합니다. 결과 ZIP은 `exanote-review` artifact에서 검토할 수 있습니다. 테스트용 ad-hoc 빌드이므로 일반 사용자 배포용이 아닙니다.

그다음 `release` environment가 사용자 승인을 기다립니다. **공증 전에 승인**하는 단계이며 자동으로 승인하지 않습니다. GitHub Actions 실행 페이지의 Review deployments에서 해당 커밋을 확인합니다. 공증과 공개는 승인 이후 연속으로 실행됩니다.

## 최초 인증 설정

저장소 Settings → Environments → release → Environment secrets에 다음 값을 등록합니다. 인증서나 개인키를 코드, 로그, 채팅에 붙여 넣지 않습니다.

| Secret | 내용 |
| --- | --- |
| CERTIFICATE_P12_BASE64 | Developer ID Application 인증서와 그 개인키를 함께 내보낸 .p12의 Base64 |
| CERTIFICATE_PASSWORD | 위 .p12 내보내기 암호 |
| NOTARY_KEY_P8 | Apple 공증용 App Store Connect API 개인키 파일 내용 |
| NOTARY_KEY_ID | 위 키의 Key ID |
| NOTARY_ISSUER_ID | 위 키의 Issuer ID |
| SPARKLE_PRIVATE_KEY | 현재 앱의 SUPublicEDKey와 짝인 Sparkle 개인키 |

API 키는 notarytool 인증이 가능한 팀 키를 사용합니다. 로컬 Keychain의 공증 프로필은 GitHub runner에 자동으로 전달되지 않습니다. Sparkle 키를 새로 만들지 말고 기존 `exanote` 계정의 키를 내보냅니다.

CI는 임시 keychain에 인증서를 불러오고 공증 자격을 등록합니다. 작업 종료 시 개인키 파일과 임시 keychain을 지웁니다. 인증서 만료/폐기 시 Secrets를 교체해야 합니다.

## 배포 결과

- 버전은 Info.plist의 제품 버전, 빌드 번호는 `100 + GitHub run number`로 증가합니다.
- 릴리스 태그는 `v0.1.1-build.101` 형태입니다. 생성된 태그를 다른 커밋에 재사용하지 않습니다.
- Developer ID 서명 → 앱 공증 → 티켓 첨부 → DMG 생성·공증 → Sparkle 서명 순서입니다.
- 모든 파일을 초안 릴리스에 업로드한 다음 공개합니다. 공증 실패 시 공개 단계는 실행되지 않습니다.
- 다운로드 URL은 `https://github.com/Atipico1/exanote/releases/latest/download/Exanote.dmg`로 고정됩니다.
- `gh-pages/appcast.xml`은 릴리스 공개 후 갱신합니다. 피드 게시 실패 시 다운로드는 가능하지만 자동업데이트 공지는 지연됩니다.
- 첫 성공 공개 후 README의 준비 중 문구를 제거합니다.

공증 승인은 최초 API 인증 등록과 다릅니다. 매 배포 승인 후 Apple 자동 검사를 다시 받습니다. 이미 완료된 run을 다시 실행할 때 같은 릴리스가 존재하면 기존 파일을 덮어쓰지 않고 중단합니다. 새 workflow_dispatch로 새 빌드 번호를 발급하세요.
