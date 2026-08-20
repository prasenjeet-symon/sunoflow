"""The personal corrections dictionary.

We watch what the user edits after each paste and learn recurring word/short-
phrase substitutions (e.g. "cavach" -> "Kavach"), then apply them to future
transcripts. Stored locally; nothing leaves the machine. See
docs/CONTRACT.md §learn / §corrections.

This module is pure logic (no FastAPI) so it can be unit-tested in isolation and
shared by every sidecar. A sidecar instance owns one ``Corrections`` object and
persists it to a JSON path next to the sidecar binary.
"""
import json
import os
import re
from difflib import SequenceMatcher

# Common words we won't auto-learn as global replacements: swapping these is
# context-dependent (there/their) and a blanket replace would do harm.
_COMMON_WORDS = {
    "a", "an", "the", "and", "or", "but", "if", "then", "so", "to", "of", "in",
    "on", "at", "for", "with", "by", "as", "is", "are", "was", "were", "be",
    "it", "its", "this", "that", "these", "those", "there", "their", "theyre",
    "they", "your", "youre", "you", "our", "we", "he", "she", "him", "her",
    "his", "hers", "them", "i", "me", "my", "no", "not", "yes", "do", "does",
    "did", "has", "have", "had", "will", "would", "can", "could", "should",
    "than", "then", "too", "two", "to", "here", "hear", "where", "were",
}


def _norm_key(s: str) -> str:
    return s.strip().strip(".,!?;:\"'`()[]").lower()


def _worth_learning(old: str, new: str) -> bool:
    """Bias toward distinctive names / technical terms, which are safe to replace
    globally, and away from context-dependent common-word swaps."""
    if not re.search(r"\w", old) or not re.search(r"\w", new):
        return False
    # Proper nouns, acronyms, and terms with digits are safe global replacements.
    if any(c.isupper() for c in new) or any(c.isdigit() for c in new):
        return True
    # Otherwise, don't learn if either side is a common word (e.g. there/their).
    if _norm_key(new) in _COMMON_WORDS or _norm_key(old) in _COMMON_WORDS:
        return False
    return True


def extract_correction_pairs(original: str, edited: str):
    """Word-level diff -> short, mishearing-like substitutions only."""
    o = original.split()
    e = edited.split()
    matcher = SequenceMatcher(a=o, b=e, autojunk=False)
    pairs = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag != "replace":
            continue
        if not (0 < (i2 - i1) <= 3) or not (0 < (j2 - j1) <= 3):
            continue  # too big -> a rewrite, not a term fix
        old = " ".join(o[i1:i2]).strip(".,!?;:\"'`()[]").strip()
        new = " ".join(e[j1:j2]).strip(".,!?;:\"'`()[]").strip()
        if not old or not new or _norm_key(old) == _norm_key(new):
            continue
        # Mishearings are character-similar; rewrites are not.
        if SequenceMatcher(None, _norm_key(old), _norm_key(new)).ratio() < 0.5:
            continue
        if not _worth_learning(old, new):
            continue
        pairs.append((old, new))
    return pairs


class Corrections:
    """A learned-substitution dictionary persisted to a JSON file.

    Keys are normalized "from" text; values are ``{"from", "to", "count"}``.
    """

    def __init__(self, path: str):
        self.path = path
        self.data = self._load()

    def _load(self) -> dict:
        try:
            with open(self.path) as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def _save(self) -> None:
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.data, f, indent=2, ensure_ascii=False)
        os.replace(tmp, self.path)

    def list(self) -> list:
        """Full list sorted by normalized key, each with ``key/from/to/count``."""
        return [
            {"key": k, "from": v["from"], "to": v["to"], "count": v.get("count", 1)}
            for k, v in sorted(self.data.items())
        ]

    def add(self, frm: str, to: str) -> bool:
        """Manually add a correction. Preserves an existing entry's count."""
        key = _norm_key(frm)
        if not key:
            return False
        count = self.data.get(key, {}).get("count", 0)
        self.data[key] = {"from": frm.strip(), "to": to.strip(), "count": count}
        self._save()
        return True

    def update(self, key: str, frm: str, to: str) -> bool:
        """Edit an existing correction's from/to. Renormalizes the key."""
        old = self.data.pop(key, None)
        new_key = _norm_key(frm)
        if not new_key:
            # Restore the old entry if the new "from" is blank.
            if old is not None:
                self.data[key] = old
            return False
        count = (old or {}).get("count", self.data.get(new_key, {}).get("count", 0))
        self.data[new_key] = {"from": frm.strip(), "to": to.strip(), "count": count}
        self._save()
        return True

    def delete(self, key: str) -> bool:
        existed = self.data.pop(key, None) is not None
        if existed:
            self._save()
        return existed

    def clear(self) -> None:
        self.data.clear()
        self._save()

    def learn_from_edit(self, original: str, edited: str) -> list:
        """Learn from a user's edit of a pasted transcript.

        Returns the list of ``{"from", "to", "count"}`` learned this call (no
        ``key`` field — see docs/CONTRACT.md §learn).
        """
        learned = []
        for old, new in extract_correction_pairs(original, edited):
            key = _norm_key(old)
            entry = self.data.get(key, {"from": old, "to": new, "count": 0})
            entry["from"] = old
            entry["to"] = new
            entry["count"] = entry.get("count", 0) + 1
            self.data[key] = entry
            learned.append({"from": old, "to": new, "count": entry["count"]})
        if learned:
            self._save()
        return learned

    def apply(self, text: str) -> str:
        """Apply learned corrections, longest-phrase-first, case-insensitive."""
        if not self.data or not text:
            return text
        result = text
        # Longer phrases first so multi-word fixes win over single-word ones.
        for key in sorted(self.data, key=len, reverse=True):
            frm = self.data[key]["from"]
            to = self.data[key]["to"]
            result = re.sub(r"\b" + re.escape(frm) + r"\b", to, result, flags=re.IGNORECASE)
        return result