"""Chunked transcript correction with nearby context and strict edit acceptance.

The model sees one ~200-character target span plus a little text before and
after it, the meeting title, terms that recur in this transcript, and the words
the ASR was least sure about. It returns only "heard -> intended" pairs.

Code accepts a pair only when it is a same-length, sound-alike substitution that
touches a low-confidence ASR word and, when decoder alternatives are available,
starts with a token the ASR itself considered. The model therefore cannot
rewrite clean text, drop fillers, change particles or negations.

Measured on AI Hub 464 (see data/aihub464/single_source_10clips/CORRECTION_TRIAL.md):
safe, but with Gemma 4 E2B the CER gain was negligible.
"""

from __future__ import annotations

import json
import re
from collections import Counter
from dataclasses import dataclass, field

FILLERS = {"어", "음", "그", "아", "에", "뭐", "저", "이", "좀", "예", "네", "막", "인제", "이제", "저기"}
NEGATIONS = ("않", "없", "아니", "말고", "말자", "말라")
# Final syllables that are usually particles or verb endings; swapping one for another is grammar, not mishearing.
ENDINGS = set("이가은는을를에의도로와과서고요다죠지게며면나니까데야네")

PREFIX = """음성 인식이 잘못 들은 단어를 찾는 작업입니다.
[대상]에서 발음이 비슷한 다른 단어로 잘못 적혀 뜻이 통하지 않는 단어만 고치세요.
말한 그대로 받아 적은 글입니다. 문법, 조사, 어미, 말버릇(어, 그, 뭐), 반복, 띄어쓰기, 숫자 표기는 틀려 보여도 고치지 마세요.
[의심]은 음성 인식기가 자신 없어 한 단어입니다. 그 단어나 바로 옆 단어만 고칠 수 있습니다.
확실하지 않으면 고치지 마세요. [앞]과 [뒤]는 참고만 하세요. 최대 2개까지만 답하세요.
JSON 배열 한 줄로만 답하세요. 형식: [{{"원문": "대상에 있는 그대로", "수정": "고친 말"}}]. 고칠 것이 없으면 [].

예시
[대상] 어 그 결재 모듈에서 에러가 나서 환불이 안 됐어요
[의심] 결재
답: [{{"원문": "결재 모듈", "수정": "결제 모듈"}}]
[대상] 그래서 저는 그 부분에 관하여서는 좀 더 봐야 된다고 생각을 합니다
[의심] 관하여서는
답: []
[대상] 서버 비용이 너무 커서 이번 달에는 개발 서버를 줄이는 방한을 검토해 보겠습니다
[의심] 방한을, 검토해
답: [{{"원문": "방한을", "수정": "방안을"}}]

회의 제목: {title}
이 회의에 자주 나온 말: {terms}
"""

SUFFIX = """[앞] {left}
[대상] {target}
[의심] {suspects}
[뒤] {right}
답:"""

SPLIT = "\u0000SPLIT\u0000"


@dataclass
class Unit:
    index: int
    text: str
    group: str = ""
    meeting: str = ""
    start: int = 0
    min_prob: float = 1.0
    corrected: str = ""
    raw: str = ""
    suspects: list[str] = field(default_factory=list)
    proposals: list[dict] = field(default_factory=list)
    accepted: list[dict] = field(default_factory=list)
    rejected: list[dict] = field(default_factory=list)


def split_units(text: str, target_chars: int = 200) -> list[tuple[int, int]]:
    """Split on word boundaries into [start, end) word ranges of about target_chars characters."""
    words = text.split()
    ranges, start, length = [], 0, 0
    for i, word in enumerate(words):
        length += len(word) + 1
        if length >= target_chars and (re.search(r"[.?!]$", word) or length >= target_chars * 1.3):
            ranges.append((start, i + 1))
            start, length = i + 1, 0
    if start < len(words):
        ranges.append((start, len(words)))
    return ranges


def recurring_terms(texts: list[str], limit: int = 30) -> list[str]:
    """Content words (2+ syllables) repeated in the transcript, as a cheap term memory."""
    counts: Counter[str] = Counter()
    for text in texts:
        for word in re.findall(r"[가-힣A-Za-z0-9]{2,}", text):
            stem = re.sub(r"(은|는|이|가|을|를|에|의|도|로|으로|에서|에게|와|과|이라고|라고|라는|이라는|하고|까지|부터|만|들)$", "", word)
            if len(stem) >= 2 and stem not in FILLERS:
                counts[stem] += 1
    common = {"그러니까", "그래서", "그런데", "그렇게", "이렇게", "저희", "우리", "지금", "생각", "말씀", "부분", "문제", "경우", "때문", "정도", "있는", "하는", "합니다", "있습니다", "것이", "거죠", "그런", "이런", "어떤", "그리고", "사실", "하면은", "그렇지만", "아니라", "것은", "같은"}
    return [term for term, n in counts.most_common(limit * 3) if n >= 3 and term not in common][:limit]


def _jamo(text: str) -> str:
    out = []
    for char in text:
        code = ord(char) - 0xAC00
        if 0 <= code < 11172:
            out.append(chr(0x1100 + code // 588))
            out.append(chr(0x1161 + (code % 588) // 28))
            if code % 28:
                out.append(chr(0x11A7 + code % 28))
        elif not char.isspace():
            out.append(char)
    return "".join(out)


def _levenshtein(a: str, b: str) -> int:
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def sound_similarity(a: str, b: str) -> float:
    ja, jb = _jamo(a), _jamo(b)
    if not ja or not jb:
        return 0.0
    return 1 - _levenshtein(ja, jb) / max(len(ja), len(jb))


def _negations(text: str) -> int:
    return sum(word in ("안", "못") or any(mark in word for mark in NEGATIONS) for word in text.split())


def _plain(text: str) -> str:
    return re.sub(r"[^0-9A-Za-z가-힣]", "", text)


def _content(text: str) -> str:
    return " ".join(word for word in text.split() if word not in FILLERS)


def check_edit(target: str, heard: str, intended: str, *, min_similarity: float = 0.5, max_chars: int = 16) -> str | None:
    """Return a rejection reason, or None when the edit is acceptable."""
    heard, intended = heard.strip(), intended.strip()
    if not heard or heard == intended:
        return "empty_or_same"
    if heard not in target:
        return "not_in_target"
    if len(heard.replace(" ", "")) > max_chars:
        return "too_long"
    if _content(heard) == _content(intended) or _plain(heard) == _plain(intended):
        return "style_only"
    if len(_plain(heard)) != len(_plain(intended)):
        return "length_change"
    h_words, i_words = heard.split(), intended.split()
    if len(i_words) < len(h_words):
        return "drops_word"
    changed = sum(1 for a, b in zip(h_words, i_words) if a != b) + abs(len(h_words) - len(i_words))
    if changed > 2:
        return "too_many_words"
    for a, b in zip(h_words, i_words):
        if a == b:
            continue
        if a in FILLERS or b in FILLERS or a == "요":
            return "filler_change"
        if len(a) >= 2 and len(b) >= 2 and a[:-1] == b[:-1] and a[-1] in ENDINGS and b[-1] in ENDINGS:
            return "ending_only"
    if re.search(r"[A-Za-z0-9%]", intended) and not re.search(r"[A-Za-z0-9%]", heard):
        return "changes_number"
    if re.search(r"\d", heard + intended) and re.sub(r"\D", "", heard) != re.sub(r"\D", "", intended):
        return "changes_number"
    if _negations(heard) != _negations(intended):
        return "changes_negation"
    if sound_similarity(heard, intended) < min_similarity:
        return "not_sound_alike"
    return None


def parse_pairs(raw: str) -> list[dict]:
    match = re.search(r"\[.*\]", raw, re.S)
    if not match:
        return []
    try:
        data = json.loads(match.group(0))
    except json.JSONDecodeError:
        data = [[a, b] for a, b in re.findall(r'\[\s*"([^"]*)"\s*,\s*"([^"]*)"\s*\]', match.group(0))]
    pairs = []
    for item in data if isinstance(data, list) else []:
        if isinstance(item, dict) and isinstance(item.get("원문"), str) and isinstance(item.get("수정"), str):
            pairs.append({"heard": item["원문"], "intended": item["수정"]})
        elif isinstance(item, list) and len(item) == 2 and all(isinstance(x, str) for x in item):
            pairs.append({"heard": item[0], "intended": item[1]})
    return pairs


class AsrAlternatives:
    """Top-k decoder alternatives recorded while the ASR transcribed one group.

    segments: [{"text", "ids", "alts": [[[token_id, prob], ...] per token]}]; the
    group text is the segment texts joined by single spaces. An edit is
    acoustically supported when, after re-tokenizing the edited segment, the
    first token that differs from the ASR output was one of the ASR's own
    candidates at that position with at least min_prob."""

    def __init__(self, segments: list[dict], tokenizer, min_prob: float = 0.01):
        self.segments, self.tokenizer, self.min_prob = segments, tokenizer, min_prob
        self.word_pos: list[tuple[int, int]] = []
        for si, segment in enumerate(segments):
            position = 0
            for word in segment["text"].split():
                start = segment["text"].index(word, position)
                position = start + len(word)
                self.word_pos.append((si, start))

    def supports(self, unit: "Unit", heard: str, intended: str) -> bool:
        at = unit.text.find(heard)
        parts = unit.text[:at].split(" ")
        word_index = unit.start + len(parts) - 1
        if word_index >= len(self.word_pos):
            return False
        si, word_start = self.word_pos[word_index]
        segment = self.segments[si]
        position = word_start + len(parts[-1])
        if segment["text"][position:position + len(heard)] != heard:
            return False
        edited = segment["text"][:position] + intended + segment["text"][position + len(heard):]
        new_ids = self.tokenizer.encode(edited, add_special_tokens=False)
        old_ids = segment["ids"]
        j = next((k for k, (a, b) in enumerate(zip(old_ids, new_ids)) if a != b), None)
        if j is None:
            return False
        return any(token == new_ids[j] and prob >= self.min_prob for token, prob in segment["alts"][j])


def touches_suspect(heard: str, suspects: list[str]) -> bool:
    return any(s in heard or heard in s for s in suspects)


def apply_edits(unit: Unit, pairs: list[dict], *, max_change_ratio: float = 0.3, require_suspect: bool = True, acoustic: "AsrAlternatives | None" = None, **check_args) -> None:
    text = unit.text
    budget = max_change_ratio * max(1, len(text.replace(" ", "")))
    spent = 0
    for pair in pairs:
        reason = check_edit(text, pair["heard"], pair["intended"], **check_args)
        if reason is None and require_suspect and not touches_suspect(pair["heard"].strip(), unit.suspects):
            reason = "no_suspect"
        if reason is None and acoustic is not None and not acoustic.supports(unit, pair["heard"].strip(), pair["intended"].strip()):
            reason = "not_asr_candidate"
        cost = _levenshtein(pair["heard"].replace(" ", ""), pair["intended"].replace(" ", ""))
        if reason is None and spent + cost > budget:
            reason = "unit_budget"
        if reason:
            unit.rejected.append({**pair, "reason": reason})
            continue
        text = text.replace(pair["heard"], pair["intended"], 1)
        spent += cost
        unit.accepted.append(pair)
    unit.corrected = text


def unit_suffixes(units: list[Unit], *, context_chars: int = 120) -> list[str]:
    suffixes = []
    for i, unit in enumerate(units):
        left = units[i - 1].text[-context_chars:] if i > 0 and units[i - 1].group == unit.group else "(없음)"
        right = units[i + 1].text[:context_chars] if i + 1 < len(units) and units[i + 1].group == unit.group else "(없음)"
        suffixes.append(SUFFIX.format(left=left, target=unit.text, suspects=", ".join(unit.suspects) or "(없음)", right=right))
    return suffixes


class Corrector:
    """Gemma-based proposer. The meeting-level prompt prefix is prefilled once
    and its KV cache is shared by every chunk of that meeting."""

    def __init__(self, model_path: str):
        from mlx_lm import load

        self.model, self.tokenizer = load(model_path)
        self.last_terms: dict[str, list[str]] = {}
        self.stats: list = []

    def _split_template(self, prefix: str) -> tuple[list[int], str]:
        messages = [{"role": "user", "content": prefix + SPLIT}]
        rendered = self.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        head, tail = rendered.split(SPLIT)
        return self.tokenizer.encode(head, add_special_tokens=False), tail

    def _prefix_cache(self, head_ids: list[int]):
        import mlx.core as mx
        from mlx_lm.models.cache import make_prompt_cache

        cache = make_prompt_cache(self.model)
        self.model(mx.array(head_ids)[None], cache=cache)
        mx.eval([c.state for c in cache])
        return cache

    def propose(self, prefix: str, suffixes: list[str], *, max_tokens: int = 80, prefill_batch_size: int = 16, completion_batch_size: int = 64) -> list[str]:
        from mlx_lm import batch_generate

        head_ids, tail_template = self._split_template(prefix)
        cache = self._prefix_cache(head_ids)
        tails = [self.tokenizer.encode(suffix + tail_template + "[", add_special_tokens=False) for suffix in suffixes]
        response = batch_generate(
            self.model, self.tokenizer, tails, prompt_caches=[cache] * len(tails), max_tokens=max_tokens,
            prefill_batch_size=prefill_batch_size, completion_batch_size=completion_batch_size,
        )
        self.stats.append(response.stats)
        return ["[" + text for text in response.texts]

    def correct(self, groups: list[tuple[str, str, str]], *, titles: dict[str, str] | None = None, confidences: dict[str, list[float]] | None = None, threshold: float = 0.6, unit_threshold: float | None = 0.4, alternatives: dict[str, "AsrAlternatives"] | None = None, unit_chars: int = 200, context_chars: int = 60, use_terms: bool = True, max_tokens: int = 48, prefill_batch_size: int = 16, completion_batch_size: int = 64, **accept_args) -> list[Unit]:
        """groups: (group_id, meeting_id, text) in order. Context never crosses groups;
        the title and term memory are per meeting.

        confidences: per group, one ASR probability per whitespace word of its text.
        When given, only units containing a word below unit_threshold (default:
        threshold) are sent to the model, and an edit must touch a word below
        threshold."""
        titles = titles or {}
        units: list[Unit] = []
        for group, meeting, text in groups:
            words = text.split()
            probs = (confidences or {}).get(group)
            for a, b in split_units(text, unit_chars):
                unit = Unit(index=len(units), text=" ".join(words[a:b]), group=group, meeting=meeting, start=a)
                if probs is not None:
                    unit.suspects = [words[i] for i in range(a, b) if probs[i] < threshold]
                    unit.min_prob = min(probs[a:b])
                units.append(unit)
        gated = confidences is not None
        accept_args.setdefault("require_suspect", gated)
        self.last_terms = {}
        for unit in units:
            unit.corrected = unit.text
        for meeting in dict.fromkeys(m for _, m, _ in groups):
            meeting_units = [u for u in units if u.meeting == meeting]
            cutoff = threshold if unit_threshold is None else unit_threshold
            send = [u for u in meeting_units if not gated or (u.suspects and u.min_prob < cutoff)]
            terms = recurring_terms([text for _, m, text in groups if m == meeting]) if use_terms else []
            self.last_terms[meeting] = terms
            prefix = PREFIX.format(title=titles.get(meeting) or "(없음)", terms=", ".join(terms) or "(없음)")
            suffixes = unit_suffixes(meeting_units, context_chars=context_chars)
            chosen = [suffixes[meeting_units.index(u)] for u in send]
            raw = self.propose(prefix, chosen, max_tokens=max_tokens, prefill_batch_size=prefill_batch_size, completion_batch_size=completion_batch_size) if chosen else []
            for unit, output in zip(send, raw):
                unit.raw = output
                unit.proposals = parse_pairs(output)
                apply_edits(unit, unit.proposals, acoustic=(alternatives or {}).get(unit.group), **accept_args)
        return units
