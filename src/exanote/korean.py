"""Korean word splitter for the forced aligner, in place of soynlp's LTokenizer.

The aligner needs each space-separated word split into a dictionary stem and the rest (a particle
or ending). The rule: in a word longer than two characters, the longest prefix of two or more
characters found in the dictionary is the stem; without a match the word stays whole. Written here
so the app needs neither soynlp's GPL code nor the scipy and scikit-learn stack it imports.
"""

from __future__ import annotations

from pathlib import Path


class KoreanSplitter:
    def __init__(self, words: set[str]):
        self.words = words
        self.longest = max((len(word) for word in words), default=0)

    def tokenize(self, text: str) -> list[str]:
        tokens: list[str] = []
        for word in text.split():
            if len(word) <= 2:
                tokens.append(word)
                continue
            cut = next((end for end in range(min(len(word), self.longest), 1, -1) if word[:end] in self.words), len(word))
            tokens.extend(part for part in (word[:cut], word[cut:]) if part)
        return tokens


def install_for_aligner() -> None:
    """Give mlx-qwen3-asr's aligner this splitter, so it never imports soynlp."""
    from mlx_qwen3_asr import forced_aligner

    processor = forced_aligner.ForcedAlignTextProcessor
    if isinstance(processor._ko_tokenizer, KoreanSplitter):
        return
    dictionary = Path(forced_aligner.__file__).parent / "assets" / "korean_dict_jieba.dict"
    words = {line.split()[0] for line in dictionary.read_text(encoding="utf-8").splitlines() if line.strip()}
    processor._ko_tokenizer = KoreanSplitter(words)
    processor._ko_tokenizer_error = None
