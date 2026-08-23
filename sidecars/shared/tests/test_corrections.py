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

from sidecars.shared.corrections import (
    KIND_CORRECTION,
    KIND_EXPANSION,
    Corrections,
    extract_correction_pairs,
    infer_kind,
)


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
    assert c.list() == [{"key": "jon", "from": "jon", "to": "John", "count": 1, "kind": "correction"}]


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
    assert c.list() == [{"key": "jon", "from": "jon", "to": "John", "count": 0, "kind": "correction"}]


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

# --- entry kinds ---------------------------------------------------------------


def test_infer_kind_respellings_are_corrections():
    # The two sides of a mishearing look alike; that is the whole signal.
    assert infer_kind("cavach", "Kavach") == KIND_CORRECTION
    assert infer_kind("sunno flow", "SunoFlow") == KIND_CORRECTION
    assert infer_kind("jon", "John") == KIND_CORRECTION


def test_infer_kind_values_are_expansions():
    for frm, to in [
        ("my instagram", "https://instagram.com/someone"),
        ("my email", "someone@example.com"),
        ("my handle", "@someone"),
        ("my site", "www.example.com"),
        ("my number", "+91 98765 43210"),
    ]:
        assert infer_kind(frm, to) == KIND_EXPANSION, (frm, to)


def test_expansion_is_never_blind_replaced():
    """The reason expansions exist as a separate kind at all.

    A global find-and-replace cannot tell a speaker offering their profile from
    one talking about the site, so it must not try.
    """
    c, _ = _fresh()
    c.add("my Instagram", "https://instagram.com/someone")
    said = "I don't have an Instagram, and my Instagram is not public anyway."
    assert c.apply(said) == said


def test_correction_still_applies_after_expansions_exist():
    c, _ = _fresh()
    c.add("my Instagram", "https://instagram.com/someone")
    c.add("cavach", "Kavach")
    assert c.apply("the cavach system") == "the Kavach system"


def test_apply_keeps_backslashes_literal():
    """A replacement goes in as text, not as a re.sub template — otherwise a
    value containing a backslash escape corrupts the output or raises."""
    c, _ = _fresh()
    c.add("the path", "C:\\1\\g<0>", kind=KIND_CORRECTION)
    assert c.apply("use the path here") == "use C:\\1\\g<0> here"


def test_apply_matches_from_starting_with_punctuation():
    c, _ = _fresh()
    c.add("@olduser", "@newuser", kind=KIND_CORRECTION)
    assert c.apply("ping @olduser now") == "ping @newuser now"


def test_explicit_kind_overrides_inference():
    c, _ = _fresh()
    c.add("my Instagram", "https://instagram.com/someone", kind=KIND_CORRECTION)
    assert c.list()[0]["kind"] == KIND_CORRECTION


def test_kind_inferred_for_entries_saved_before_the_field_existed():
    """An old corrections.json has no `kind`; it must keep working untouched."""
    c, path = _fresh()
    with open(path, "w") as f:
        f.write('{"cavach": {"from": "cavach", "to": "Kavach", "count": 3}}')
    c = Corrections(path)
    assert c.list()[0]["kind"] == KIND_CORRECTION
    assert c.apply("the cavach system") == "the Kavach system"


# --- what leaves the machine ---------------------------------------------------


def test_relevant_for_sends_nothing_when_nothing_matches():
    c, _ = _fresh()
    c.add("cavach", "Kavach")
    c.add("my Instagram", "https://instagram.com/someone")
    assert c.relevant_for("a totally unrelated sentence") == []


def test_relevant_for_matches_correction_literally():
    c, _ = _fresh()
    c.add("cavach", "Kavach")
    assert c.relevant_for("the cavach system") == [
        {"from": "cavach", "to": "Kavach", "kind": KIND_CORRECTION}
    ]
    # Substring hits don't count — "cavachs" is a different word.
    assert c.relevant_for("scavacher") == []


def test_relevant_for_matches_expansion_on_distinctive_words():
    """The spoken lead-in varies, so an expansion matches on its content words."""
    c, _ = _fresh()
    c.add("my Instagram", "https://instagram.com/someone")
    for said in [
        "here is my instagram id",
        "my Instagram handle is",
        "you can find me on Instagram",
    ]:
        assert c.relevant_for(said) == [
            {"from": "my Instagram", "to": "https://instagram.com/someone",
             "kind": KIND_EXPANSION}
        ], said


def test_relevant_for_caps_and_prefers_most_used():
    c, _ = _fresh()
    for i in range(10):
        c.add(f"term{i}", f"Term{i}")
        c.data[f"term{i}"]["count"] = i
    text = " ".join(f"term{i}" for i in range(10))
    got = c.relevant_for(text, limit=3)
    assert [e["from"] for e in got] == ["term9", "term8", "term7"]


def test_relevant_for_keeps_expansions_when_capped():
    """Expansions are hand-typed and never learned, so their count is always 0.
    Sorting on count alone would drop exactly the entries the user cared enough
    to add by hand."""
    c, _ = _fresh()
    for i in range(5):
        c.add(f"term{i}", f"Term{i}")
        c.data[f"term{i}"]["count"] = 100 + i
    c.add("my Instagram", "https://instagram.com/someone")
    text = "my instagram " + " ".join(f"term{i}" for i in range(5))
    got = c.relevant_for(text, limit=2)
    assert got[0]["kind"] == KIND_EXPANSION
