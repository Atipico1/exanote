"""Build a standalone HTML report from actual sequential QA evidence."""
from __future__ import annotations

import argparse
import base64
import html
import json
import mimetypes
from pathlib import Path


def esc(value: object) -> str:
    return html.escape(str(value))


def pictures(paths: list[str], root: Path) -> str:
    result = []
    for name in paths:
        path = Path(name)
        if not path.is_absolute():
            path = root / path
        if not path.is_file():
            result.append(f'<p class="missing">Missing evidence: {esc(name)}</p>')
            continue
        mime = mimetypes.guess_type(path.name)[0] or "image/png"
        encoded = base64.b64encode(path.read_bytes()).decode()
        result.append(f'<figure><img loading="lazy" src="data:{mime};base64,{encoded}" alt="{esc(path.name)}"><figcaption>{esc(path.name)}</figcaption></figure>')
    return "".join(result)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    batches = [json.loads(p.read_text()) for p in sorted(args.evidence.glob("batch-*.json"))]
    # A later isolated/regression pass replaces the scenario verdict, while the
    # original issue and its before screenshots remain in the report.
    latest = {case["id"]: case for batch in batches for case in batch.get("cases", [])}
    plan = Path(__file__).resolve().parents[1] / "docs/qa-scenarios-2026-09-25.md"
    missing = []
    for line in plan.read_text().splitlines():
        cells = [cell.strip() for cell in line.split("|")]
        if len(cells) > 3 and len(cells[1]) == 3 and cells[1][0] in "ABCDEF" and cells[1][1:].isdigit():
            if cells[1] not in latest:
                case = {"id": cells[1], "status": "NOT_RUN", "expected": cells[3], "actual": "아직 실행하지 않음", "steps": [], "screenshots": []}
                missing.append(case)
                latest[case["id"]] = case
    if missing:
        batches.append({"batch": "미실행", "cases": missing})
    fixes_path = args.evidence / "fixes.json"
    fixes = json.loads(fixes_path.read_text()) if fixes_path.exists() else {}
    cases = list(latest.values())
    counts = {status: sum(c.get("status") == status for c in cases) for status in ("PASS", "PARTIAL", "FAIL", "BLOCKED", "NOT_RUN")}
    summary = " · ".join(f"{key} {value}" for key, value in counts.items())
    sections = []
    for batch in batches:
        rows = []
        for case in batch.get("cases", []):
            if latest[case["id"]] is not case:
                continue
            detail = '<ol>' + ''.join(f'<li>{esc(step)}</li>' for step in case.get("steps", [])) + '</ol>'
            detail += f'<p><b>기대</b> {esc(case.get("expected", ""))}</p><p><b>관찰</b> {esc(case.get("actual", ""))}</p>'
            detail += pictures(case.get("screenshots", []), args.evidence)
            rows.append(f'<tr data-status="{esc(case.get("status", "NOT_RUN"))}"><td>{esc(case.get("id", ""))}</td><td><span class="badge">{esc(case.get("status", "NOT_RUN"))}</span></td><td><details><summary>{esc(case.get("title") or case.get("actual", "기록 보기"))}</summary>{detail}</details></td></tr>')
        sections.append(f'<section><h2>배치 {esc(batch.get("batch", ""))}</h2><pre>{esc(json.dumps(batch.get("environment", {}), ensure_ascii=False, indent=2))}</pre><table><thead><tr><th>ID</th><th>결과</th><th>관찰 및 증거</th></tr></thead><tbody>{"".join(rows)}</tbody></table></section>')
    issues = []
    seen_issues = set()
    for batch in batches:
        for issue in batch.get("issues", []):
            if issue["id"] in seen_issues:
                continue
            seen_issues.add(issue["id"])
            fix = fixes.get(issue["id"], {})
            issues.append(f'<article><h3>{esc(issue["id"])} · {esc(issue.get("title", ""))}</h3><p>{esc(issue.get("severity", ""))} · {esc(", ".join(issue.get("case_ids", [])))}</p><p><b>기대</b> {esc(issue.get("expected", ""))}</p><p><b>문제</b> {esc(issue.get("actual", ""))}</p><ol>{"".join(f"<li>{esc(s)}</li>" for s in issue.get("steps", []))}</ol><p><b>원인과 수정</b> {esc(fix.get("description", "미수정 / 확인 중"))}</p><p><b>재검증</b> {esc(fix.get("verification", "미실행"))}</p><div class="comparison"><div><h4>수정 전</h4>{pictures(issue.get("before", []), args.evidence)}</div><div><h4>수정 후</h4>{pictures(fix.get("after", []), args.evidence) or "<p>수정 후 화면 없음</p>"}</div></div></article>')
    document = '''<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Exanote 사용자 QA</title><style>
    :root{font-family:-apple-system,BlinkMacSystemFont,sans-serif;color:#242424;background:#f4f3ef}body{max-width:1240px;margin:auto;padding:48px 28px}h1{font-size:38px;letter-spacing:-1.5px}h2{margin-top:40px}p,li{line-height:1.7}section,article{padding:24px;background:white;border:1px solid #deddd7;border-radius:10px;margin:20px 0}table{width:100%;border-collapse:collapse;text-align:left}td,th{padding:14px 10px;border-bottom:1px solid #e9e8e2;vertical-align:top}td:first-child{white-space:nowrap}summary{cursor:pointer;line-height:1.6}img{width:100%;height:auto;border:1px solid #ddd;border-radius:4px}figure{margin:20px 0}figcaption{font-size:12px;color:#777;overflow-wrap:anywhere}.comparison{display:grid;grid-template-columns:1fr 1fr;gap:24px}.badge{font-size:12px;font-weight:600}tr[data-status=FAIL] .badge,.missing{color:#a12f24}tr[data-status=PASS] .badge{color:#25734b}tr[data-status=BLOCKED] .badge{color:#8a621d}pre{white-space:pre-wrap;overflow-wrap:anywhere;color:#777;font-size:12px}button{padding:9px 15px;border:1px solid #bbb;background:white;border-radius:6px;cursor:pointer}@media(max-width:700px){body{padding:20px 12px}.comparison{grid-template-columns:1fr}section,article{padding:14px}}@media print{details{display:block}button{display:none}}
    </style><header><p>EXANOTE / 실제 화면 조작 기록</p><h1>사용자 관점 QA</h1><p>SUMMARY</p><p>발견 문제 5건 중 4건 수정 후 실제 화면에서 재검증. 캘린더 연결은 권한 목록에 Exanote가 나타나지 않아 미해결입니다. Python 테스트 20개 통과, macOS 앱 빌드 성공. 로컬 QA 빌드 기준이며 배포 완료를 뜻하지 않습니다.</p><p>개별 테스트: GPT-6 Luna 한 개씩 순차 실행. PASS는 기록된 조작 범위에만 적용되며, BLOCKED와 미실행은 검증 완료를 뜻하지 않습니다.</p><button onclick="document.querySelectorAll('details').forEach(d=>d.open=true)">모든 증거 펼치기</button></header><h2>문제와 수정 결과</h2>ISSUES<h2>시나리오별 실행 기록</h2>SECTIONS</html>'''
    document = document.replace("SUMMARY", esc(summary)).replace("ISSUES", "".join(issues) or "<p>아직 등록된 문제 기록이 없습니다.</p>").replace("SECTIONS", "".join(sections))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(document)
    print(args.output)


if __name__ == "__main__":
    main()
