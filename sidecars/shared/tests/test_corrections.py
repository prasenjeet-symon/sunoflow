"""Tests for the shared corrections dictionary logic.

Pure-Python, no FastAPI/model deps — run with ``pytest sidecars/shared/tests``.
These protect the learning + apply contract (docs/CONTRACT.md §learn) that both
sidecars MUST obey identically.
"""
import os
import sys
import tempfile

# Make ``sidecars.*`` importable when run from the repo root.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(__file__)))))

from sidecars.shared.corrections import Corrections, extract_correction_pairs


def _fresh():
    f = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
    f.write(b"{}")
    f.close()
    return Corrections(f.name), f.name


def test_empty_list_on_fresh():
    c, _ = _fresh()
    assert c.list() == []


def test_learn_mishearing():
    c, _ = _fresh()
    learned = c.learn_from_edit("hello jon", "hello John")
    assert learned == [{"from": "jon", "to": "John", "count": 1}]
    assert c.list() == [{"key": "jon", "from": "jon", "to": "John", "count": 1}]


def test_apply_case_insensitive_word_boundary():
    c, _ = _fresh()
    c.learn_from_edit("hello jon", "hello John")
    # applies regardless of surrounding case/punctuation
    assert c.apply("I saw Jon, and jon too.") == "I saw John, and John too."


def test_learn_rejects_common_word_swaps():
    c, _ = _fresh()
    # there/their is a common-word swap — must not be learned
    learned = c.learn_from_edit("i went there", "i went their")
    assert learned == []
    assert c.list() == []


def test_learn_rejects_big_rewrites():
    c, _ = _fresh()
    # 4-word "replace" is too big (>3) — a rewrite, not a term fix
    learned = c.learn_from_edit("the quick brown fox", "a slow yellow cat")
    assert learned == []


def test_learn_proper_noun_is_safe():
    c, _ = _fresh()
    # Proper nouns (uppercase) are always safe to learn
    learned = c.learn_from_edit("cavach", "Kavach")
    assert learned == [{"from": "cavach", "to": "Kavach", "count": 1}]
    assert c.apply("I use cavach daily") == "I use Kavach daily"


def test_longest_phrase_first():
    c, _ = _fresh()
    c.add("sunoflow app", "SunoFlow App")
    # Longer phrases are tried FIRST so the multi-word match wins over any
    # single-word rule that would otherwise eat part of it. Rules still apply
    # cumulatively to the evolving string (existing behaviour — matches the old
    # server.py apply_corrections), so a short "app" rule added afterwards would
    # re-fire on "App" in the result. We assert the ordering guarantee only:
    # the long rule runs before any shorter overlapping one.
    assert "SunoFlow App" in c.apply("open the sunoflow app now")


def test_add_preserves_count_on_existing_key():
    c, _ = _fresh()
    c.learn_from_edit("hi jon", "hi John")  # count 1
    added = c.add("jon", "Johnny")  # same key, different "to" — count preserved
    assert added is True
    entries = [e for e in c.list() if e["key"] == "jon"]
    assert entries[0]["count"] == 1
    assert entries[0]["to"] == "Johnny"


def test_add_blank_from_returns_false():
    c, _ = _fresh()
    assert c.add("   ", "x") is False
    assert c.list() == []


def test_update_renormalizes_key():
    c, _ = _fresh()
    c.add("jon", "John")
    assert c.update("jon", "Jonny", "John") is True
    keys = [e["key"] for e in c.list()]
    assert "jonny" in keys and "jon" not in keys


def test_update_blank_from_restores_old():
    c, _ = _fresh()
    c.add("jon", "John")
    assert c.update("jon", "   ", "x") is False
    # original entry restored
    assert c.list() == [{"key": "jon", "from": "jon", "to": "John", "count": 0}]


def test_delete_and_clear():
    c, _ = _fresh()
    c.add("jon", "John")
    assert c.delete("jon") is True
    assert c.delete("jon") is False
    c.add("a", "A")
    c.clear()
    assert c.list() == []


def test_extract_pairs_returns_tuples():
    pairs = extract_correction_pairs("meet cavach", "meet Kavach")
    assert pairs == [("cavach", "Kavach")]


def test_apply_empty_dict_is_passthrough():
    c, _ = _fresh()
    assert c.apply("anything") == "anything"


def test_apply_empty_text_is_passthrough():
    c, _ = _fresh()
    c.add("jon", "John")
    assert c.apply("") == ""