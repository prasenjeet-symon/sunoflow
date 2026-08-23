"""The personal dictionary.

Two different things live in here, and the difference decides who applies them:

* **corrections** — a word the transcript mis-hears, paired with its correct
  spelling (e.g. "cavach" -> "Kavach"). Learned automatically from what the user
  edits after a paste, or added by hand. Mechanical enough to apply ourselves,
  which we do after cleanup so they always win.
* **expansions** — a phrase the user says out loud, paired with the literal
  value it stands for (e.g. "my Instagram" -> a profile URL). Added by hand.
  Applying one takes judgement about whether the speaker is *giving* the value
  or just mentioning the thing — "I don't have an Instagram" must not sprout a
  URL — so only the cleanup model ever applies these, never ``apply()``.

The file stays on this machine. What leaves, per dictation, is the handful of
entries that look relevant to the transcript in hand (``relevant_for``), sent to
the cleanup gateway so the model can act on them. See docs/CONTRACT.md
§learn / §corrections.

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


KIND_CORRECTION = "correction"
KIND_EXPANSION = "expansion"

# What a "value" looks like: a URL, handle, email, bare domain, or phone number.
# These are the things a user saves so they never have to spell them out loud.
_VALUE_LIKE = re.compile(
    r"""(?xi)
      https?://
    | www\.
    | ^@[\w.]+$
    | [\w.+-]+@[\w-]+\.\w
    | \.(com|net|org|io|in|co|dev|me|ai|app|xyz)\b
    | ^\+?\d[\d\s().-]{7,}$
    """
)


def _norm_key(s: str) -> str:
    return s.strip().strip(".,!?;:\"'`()[]").lower()


def infer_kind(frm: str, to: str) -> str:
    """Classify an entry the user added without saying which kind it is.

    A correction is a re-spelling, so the two sides look alike; an expansion
    swaps a short spoken phrase for something structurally different and usually
    much longer. Both tests below are about *shape*, not meaning, which is why
    this can run on a manually-added pair with no other signal.

    Errs toward a correction: that is the conservative default, since a
    correction only ever changes a spelling, while an expansion inserts a
    personal value into the user's text.
    """
    to = to.strip()
    if _VALUE_LIKE.search(to):
        return KIND_EXPANSION
    if len(to) > max(24, len(frm) * 2):
        return KIND_EXPANSION
    if SequenceMatcher(None, _norm_key(frm), _norm_key(to)).ratio() < 0.5:
        return KIND_EXPANSION
    return KIND_CORRECTION


def _kind_of(entry: dict) -> str:
    """The stored kind, classifying on the fly for entries written before the
    field existed. Keeps old corrections.json files working untouched."""
    kind = entry.get("kind")
    if kind in (KIND_CORRECTION, KIND_EXPANSION):
        return kind
    return infer_kind(entry.get("from", ""), entry.get("to", ""))


def _distinctive_tokens(s: str) -> list:
    """The words in ``s`` that carry enough signal to match a transcript on.

    "my Instagram" reduces to ["instagram"], so the entry is offered whether the
    user said "my Instagram ID", "my Instagram handle", or just "my Instagram".
    """
    return [
        t for t in (w.lower() for w in re.findall(r"\w+", s))
        if len(t) >= 3 and t not in _COMMON_WORDS
    ]


def _contains_phrase(lowered_text: str, phrase: str) -> bool:
    return re.search(r"(?<!\w)" + re.escape(phrase.lower()) + r"(?!\w)", lowered_text) is not None


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
    """The user's dictionary, persisted to a JSON file.

    Keys are normalized "from" text; values are
    ``{"from", "to", "count", "kind"}``. ``kind`` is absent in files written
    before expansions existed and is inferred on read, so an old file needs no
    migration.
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
        """Full list sorted by normalized key, each with ``key/from/to/count/kind``."""
        return [
            {
                "key": k,
                "from": v["from"],
                "to": v["to"],
                "count": v.get("count", 1),
                "kind": _kind_of(v),
            }
            for k, v in sorted(self.data.items())
        ]

    def add(self, frm: str, to: str, kind: str = "") -> bool:
        """Manually add an entry. Preserves an existing entry's count.

        ``kind`` is optional: the UI does not ask, so an unset kind is inferred
        from the shape of the pair.
        """
        key = _norm_key(frm)
        if not key:
            return False
        count = self.data.get(key, {}).get("count", 0)
        self.data[key] = self._entry(frm, to, count, kind)
        self._save()
        return True

    def update(self, key: str, frm: str, to: str, kind: str = "") -> bool:
        """Edit an existing entry's from/to. Renormalizes the key."""
        old = self.data.pop(key, None)
        new_key = _norm_key(frm)
        if not new_key:
            # Restore the old entry if the new "from" is blank.
            if old is not None:
                self.data[key] = old
            return False
        count = (old or {}).get("count", self.data.get(new_key, {}).get("count", 0))
        self.data[new_key] = self._entry(frm, to, count, kind)
        self._save()
        return True

    @staticmethod
    def _entry(frm: str, to: str, count: int, kind: str = "") -> dict:
        frm, to = frm.strip(), to.strip()
        if kind not in (KIND_CORRECTION, KIND_EXPANSION):
            kind = infer_kind(frm, to)
        return {"from": frm, "to": to, "count": count, "kind": kind}

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
            # Always a correction: extract_correction_pairs only yields pairs
            # whose two sides look alike, which is what a mishearing is.
            entry["kind"] = KIND_CORRECTION
            self.data[key] = entry
            learned.append({"from": old, "to": new, "count": entry["count"]})
        if learned:
            self._save()
        return learned

    def apply(self, text: str) -> str:
        """Apply the *corrections* — longest-phrase-first, case-insensitive.

        Expansions are deliberately skipped. A blind global replace cannot tell
        "here's my Instagram" from "I don't have an Instagram", and getting that
        wrong drops the user's personal URL into a sentence that did not want
        it. The cleanup model decides those; see the DICTIONARY block in the
        gateway's system prompt.
        """
        if not self.data or not text:
            return text
        result = text
        entries = [v for v in self.data.values() if _kind_of(v) == KIND_CORRECTION]
        # Longer phrases first so multi-word fixes win over single-word ones.
        for entry in sorted(entries, key=lambda v: len(v["from"]), reverse=True):
            frm, to = entry["from"], entry["to"]
            # Lookarounds rather than \b: \b is a *transition*, so it silently
            # fails to match a "from" that starts or ends with punctuation.
            # The replacement is a function so that backslashes and \1-style
            # sequences in the user's text stay literal instead of being read as
            # group references.
            result = re.sub(
                r"(?<!\w)" + re.escape(frm) + r"(?!\w)",
                lambda _m, to=to: to,
                result,
                flags=re.IGNORECASE,
            )
        return result

    def relevant_for(self, text: str, limit: int = 40) -> list:
        """The entries worth sending to the cleanup model for this transcript.

        Filtering here rather than shipping the whole dictionary keeps the
        prompt small, and keeps every entry the user did not just say on this
        machine: a term only leaves when the transcript already looks like it.

        A correction has to appear literally — the mishearing *is* what the
        speech model produced. An expansion is matched on its distinctive words
        instead, since the spoken lead-in varies ("my Instagram ID", "my
        Instagram handle", "my Instagram").
        """
        if not self.data or not text:
            return []
        lowered = text.lower()
        out = []
        for key, entry in self.data.items():
            frm, kind = entry["from"], _kind_of(entry)
            if kind == KIND_EXPANSION:
                tokens = _distinctive_tokens(frm)
                hit = (
                    all(re.search(r"(?<!\w)" + re.escape(t), lowered) for t in tokens)
                    if tokens
                    else _contains_phrase(lowered, frm)
                )
            else:
                hit = _contains_phrase(lowered, frm)
            if hit:
                out.append({"from": frm, "to": entry["to"], "kind": kind, "count": entry.get("count", 0)})
        # Expansions first, then most-used, so the cap sheds the entries least
        # likely to matter. Expansions are always count 0 — they are added by
        # hand, never learned — so sorting on count alone would drop exactly the
        # entries the user took the trouble to type in.
        out.sort(key=lambda e: (e["kind"] != KIND_EXPANSION, -e["count"], len(e["from"])))
        return [{"from": e["from"], "to": e["to"], "kind": e["kind"]} for e in out[:limit]]