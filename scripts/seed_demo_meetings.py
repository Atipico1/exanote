"""Populate Exanote with removable, local-only example meetings for UI review.

Run with ``.venv/bin/python scripts/seed_demo_meetings.py``. The ``--clear`` option
removes only records and folders created by this script. Real meetings are untouched.
"""

from __future__ import annotations

import argparse
import json
import shutil
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from exanote.paths import DATA


# Title, folder, days ago, time, duration in minutes, finding, decision, next step.
EXAMPLES = [
    ("주간 제품 회의", "제품", 0, "10:30", 48, "첫 실행 후 녹음 시작까지의 단계가 길다", "권한 안내를 한 화면으로 모은다", "설정 흐름 시안 검토"),
    ("고객 인터뷰 · 첫 회의 기록", "고객 인터뷰", 0, "09:00", 34, "전사보다 결정 사항을 다시 찾는 일이 더 잦다", "결정 항목을 요약 상단에 배치한다", "인터뷰 대상 3명에게 시안 확인"),
    ("디자인 리뷰 · 회의 목록", "제품", 1, "15:00", 56, "회의가 늘어나면 날짜만으로 탐색하기 어렵다", "폴더와 검색을 함께 노출한다", "목록 밀도와 제목 길이 점검"),
    ("운영 주간 점검", "운영", 1, "11:00", 41, "완료 알림을 놓치면 노트를 다시 찾게 된다", "처리 완료 시 앱 안에도 상태를 남긴다", "알림 권한이 없는 경우 문구 작성"),
    ("파트너 미팅 · 협업 범위", "프로젝트", 2, "16:30", 63, "공유할 내용과 내부 메모를 구분해야 한다", "요약만 공유하는 선택지를 검토한다", "공유 범위 표 작성"),
    ("고객 인터뷰 · 검색 사용성", "고객 인터뷰", 2, "10:00", 29, "사용자는 화자 이름으로도 검색하고 싶어 한다", "화자 이름을 검색 인덱스에 넣는다", "검색 결과 시안 제작"),
    ("음성 인식 품질 리뷰", "제품", 3, "14:00", 52, "고유명사 교정이 반복된다", "자주 쓰는 이름을 개인 사전에 저장한다", "교정 사례 20개 정리"),
    ("팀 정기 회의", "운영", 3, "09:30", 47, "안건이 길어질수록 다음 행동의 담당자가 흐려진다", "담당자와 기한을 회의에서 바로 확인한다", "담당자 확인 방식 결정"),
    ("온보딩 문구 검토", "제품", 4, "13:00", 37, "모델 다운로드 중 기다리는 이유가 잘 안 보인다", "예상 용량과 진행률을 함께 보여준다", "다운로드 화면 문구 수정"),
    ("고객 인터뷰 · 공유 경험", "고객 인터뷰", 4, "10:30", 32, "외부 공유 전에 개인 메모를 숨기고 싶어 한다", "내 메모는 기본적으로 공유 대상에서 뺀다", "공유 미리보기 설계"),
    ("프로젝트 킥오프", "프로젝트", 5, "15:30", 68, "한 회의에 여러 주제가 섞여 있다", "주제별 소제목을 자동 요약에 반영한다", "첫 주 마일스톤 확정"),
    ("주간 제품 회의", "제품", 6, "10:30", 44, "메뉴 막대에서 녹음 중임을 알아보기 어렵다", "녹음 상태와 시간을 함께 표시한다", "작은 화면에서 가독성 확인"),
    ("팀 정기 회의", "운영", 7, "09:30", 51, "반복 회의가 목록에 흩어져 있다", "같은 일정의 노트를 한 폴더에 모은다", "자동 분류 규칙 점검"),
    ("고객 인터뷰 · 회의 후 정리", "고객 인터뷰", 8, "14:00", 38, "녹음 후 바로 요약을 확인하는 비율이 높다", "완료된 노트를 최근 회의 첫 줄에 둔다", "완료 알림에서 노트 열기 테스트"),
    ("검색 결과 화면 리뷰", "제품", 9, "11:30", 42, "검색어가 포함된 맥락이 너무 짧다", "전사 문장의 앞뒤를 함께 보여준다", "결과 줄 높이 조정"),
    ("프로젝트 진행 상황", "프로젝트", 10, "16:00", 55, "결정 변경의 이유가 기록에 남지 않는다", "요약에 결정 이유를 한 줄 남긴다", "이전 결정과 연결 방식 검토"),
    ("월간 운영 회고", "운영", 12, "13:00", 72, "긴 회의에서는 중요한 시점을 다시 듣기 어렵다", "북마크를 노트와 전사에 함께 표시한다", "북마크 위치 재생 테스트"),
    ("고객 인터뷰 · 모바일 공유", "고객 인터뷰", 14, "10:00", 31, "모바일에서는 긴 전사보다 핵심 요약이 먼저 필요하다", "모바일 첫 화면에 요약을 우선한다", "공유 화면 폭별 확인"),
    ("제품 방향 논의", "제품", 16, "15:00", 84, "실시간 전사는 회의 집중을 방해할 수도 있다", "녹음 중 전사는 접을 수 있게 한다", "전사 표시 기본값 결정"),
    ("프로젝트 일정 조정", "프로젝트", 19, "11:00", 46, "외부 일정 변경이 회의 제목에 반영되지 않았다", "캘린더 제목을 시작 시점에 다시 읽는다", "변경된 일정으로 녹음 시작 테스트"),
    ("고객 인터뷰 · 전사 교정", "고객 인터뷰", 22, "14:30", 36, "화자 이름이 잘못 붙으면 요약도 읽기 어렵다", "화자 이름을 노트 전반에 반영한다", "화자 변경 뒤 내보내기 확인"),
    ("운영 체크인", "운영", 25, "09:30", 27, "회의가 없는 날에는 홈이 비어 보인다", "최근 7일 기록을 간단한 그래프로 보여준다", "빈 상태 문구 점검"),
    ("베타 사용자 피드백", "제품", 29, "16:00", 64, "초기 사용자가 저장 위치를 자주 묻는다", "저장 위치를 노트 상세에 표시한다", "동기화 설정 도움말 정리"),
    ("프로젝트 데모 리허설", "프로젝트", 34, "13:30", 49, "발표 순서가 바뀌면 노트 구조도 다시 편집한다", "소제목을 수동 편집할 수 있게 한다", "데모 시나리오 정리"),
    ("고객 인터뷰 · 알림", "고객 인터뷰", 38, "10:00", 33, "통화 감지를 놓치면 녹음을 시작하지 못한다", "회의 감지 알림을 눈에 띄게 보낸다", "알림 빈도 선호도 추가 조사"),
    ("월간 제품 리뷰", "제품", 43, "15:00", 78, "회의별 주요 결정이 여러 문서에 흩어져 있다", "노트 상단에 결정 요약을 모은다", "지난달 결정 목록 대조"),
    ("운영 프로세스 정리", "운영", 48, "11:00", 58, "회의 제목이 들쭉날쭉하면 나중에 찾기 어렵다", "일정 제목을 기본값으로 사용한다", "제목 변경 동작 확인"),
    ("프로젝트 초기 기획", "프로젝트", 55, "14:00", 91, "팀마다 회의록 형식이 조금씩 다르다", "공통 구조부터 시작한다", "필수 섹션 합의"),
    ("고객 인터뷰 · 첫인상", "고객 인터뷰", 62, "10:30", 28, "앱이 무엇을 저장하는지 처음에는 잘 모른다", "로컬 저장 안내를 짧게 보여준다", "첫 실행 설명 검토"),
    ("제품 아이디어 정리", "제품", 75, "16:00", 53, "아이디어와 확정된 일을 구별해야 한다", "결정과 제안을 다른 제목으로 묶는다", "요약 템플릿 초안 작성"),
]

FOLDER_NAMES = ("제품", "고객 인터뷰", "운영", "프로젝트")
FOLDERS_FILE = DATA / "folders.json"


def meeting_id(index: int) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"exanote-demo-meeting-v1-{index}"))


def folder_id(name: str) -> str:
    return uuid.uuid5(uuid.NAMESPACE_URL, f"exanote-demo-folder-v1-{name}").hex[:12]


def read_folders() -> dict:
    try:
        state = json.loads(FOLDERS_FILE.read_text())
    except (OSError, ValueError):
        state = {}
    return {"folders": state.get("folders", []), "assignments": state.get("assignments", {}), "rules": state.get("rules", [])}


def write_folders(state: dict) -> None:
    temp = FOLDERS_FILE.with_suffix(".demo.tmp")
    temp.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    temp.replace(FOLDERS_FILE)


def clear() -> int:
    removed = 0
    for index in range(len(EXAMPLES)):
        folder = DATA / meeting_id(index)
        try:
            meta = json.loads((folder / "meeting.json").read_text())
        except (OSError, ValueError):
            continue
        if meta.get("demo") is True:
            shutil.rmtree(folder)
            removed += 1
    state = read_folders()
    demo_ids = {folder_id(name) for name in FOLDER_NAMES}
    state["assignments"] = {
        meeting: folder for meeting, folder in state["assignments"].items()
        if meeting not in {meeting_id(i) for i in range(len(EXAMPLES))}
    }
    state["folders"] = [folder for folder in state["folders"] if folder.get("id") not in demo_ids]
    write_folders(state)
    return removed


def seed() -> int:
    DATA.mkdir(parents=True, exist_ok=True)
    state = read_folders()
    existing_folder_ids = {folder.get("id") for folder in state["folders"]}
    for name in FOLDER_NAMES:
        if folder_id(name) not in existing_folder_ids:
            state["folders"].append({"id": folder_id(name), "name": name})

    now = datetime.now().astimezone()
    created = 0
    for index, (title, category, days, clock, minutes, finding, decision, next_step) in enumerate(EXAMPLES):
        mid = meeting_id(index)
        folder = DATA / mid
        if folder.exists():
            try:
                if json.loads((folder / "meeting.json").read_text()).get("demo") is not True:
                    raise RuntimeError(f"Refusing to replace a real meeting: {folder}")
            except FileNotFoundError as error:
                raise RuntimeError(f"Refusing to replace an unknown folder: {folder}") from error
        folder.mkdir(exist_ok=True)
        hour, minute = map(int, clock.split(":"))
        local_date = (now - timedelta(days=days)).replace(hour=hour, minute=minute, second=0, microsecond=0)
        # Swift's Meeting.createdAt expects fractional seconds and a UTC Z suffix.
        created_at = local_date.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        duration = minutes * 60 + (index * 17) % 59
        notes = (
            f"## 핵심 요약\n\n{finding}. 이번 회의에서는 사용 흐름을 검토하고 다음 변경을 정했다.\n\n"
            f"## 결정 사항\n\n- {decision}.\n\n"
            f"## 다음 할 일\n\n- {next_step} · 다음 회의 전까지\n\n"
            f"## 논의 내용\n\n현재 화면과 실제 사용 상황을 비교했다. 화자 1은 발견한 문제를 설명했고, "
            f"화자 2는 해결 방향과 확인할 항목을 정리했다."
        )
        utterances = [
            {"start": 24.0, "end": 32.5, "speaker": 0, "text": f"오늘은 {title}에서 확인한 내용을 먼저 정리해 볼게요."},
            {"start": 41.0, "end": 52.0, "speaker": 1, "text": f"지금 가장 눈에 띄는 부분은 {finding}는 점이에요."},
            {"start": 67.0, "end": 76.0, "speaker": 0, "text": "실제 사용 흐름에서 어디가 불편한지 다시 살펴보죠."},
            {"start": duration * 0.48, "end": duration * 0.48 + 11, "speaker": 1, "text": f"그럼 {decision}는 방향으로 진행하면 되겠네요."},
            {"start": duration * 0.78, "end": duration * 0.78 + 9, "speaker": 0, "text": f"다음 회의 전에는 {next_step}을 확인하겠습니다."},
        ]
        transcript = "\n".join(f"화자 {row['speaker'] + 1}: {row['text']}" for row in utterances)
        meta = {
            "id": mid, "title": title, "created_at": created_at, "status": "done",
            "filename": "audio.m4a", "duration": duration, "language": "ko", "speakers": 2,
            "speaker_names": {"0": "진행자", "1": "동료"}, "demo": True,
            "memo": "예시 데이터 · 실제 녹음이 아닙니다.",
            "bookmarks": [{"time": round(duration * 0.48, 1), "note": "결정 사항"}],
        }
        result = {"duration": duration, "language": "ko", "utterances": utterances,
                  "transcript": transcript, "notes": notes}
        (folder / "meeting.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))
        (folder / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
        state["assignments"][mid] = folder_id(category)
        created += 1
    write_folders(state)
    return created


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clear", action="store_true", help="remove only this script's demo records and folders")
    args = parser.parse_args()
    print(f"Removed {clear()} demo meetings" if args.clear else f"Seeded {seed()} local-only demo meetings")
