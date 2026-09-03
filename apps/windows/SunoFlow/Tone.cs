using System;
using System.Collections.Generic;
using System.Drawing;

namespace SunoFlow;

/// <summary>
/// The writing voice a dictation is cleaned into — the Windows counterpart of
/// <c>Tone.swift</c>, and a deliberate 1:1 mirror of it.
///
/// The <see cref="Id"/> is what travels to the sidecar and on to the cleanup
/// gateway, which owns the closed set and the instruction behind each entry.
/// Nothing here describes <b>how</b> a voice writes — that lives server-side, so
/// a wording change ships as a gateway deploy rather than three app releases,
/// and the clients cannot drift from each other.
///
/// <see cref="Faithful"/> is the default and deliberately sends an empty id: the
/// gateway then builds the prompt it built before tones existed, and the user's
/// own wording survives untouched. Anyone who never presses the key is on
/// exactly the behaviour they have always had.
/// </summary>
internal sealed class Tone
{
    public string Id { get; }

    /// <summary>What the user sees — in the overlay, the tray menu, and Settings.</summary>
    public string Label { get; }

    /// <summary>One line of explanation, for the Settings row.</summary>
    public string Blurb { get; }

    /// <summary>
    /// One tint per voice, in the same muted family as the rest of the palette so
    /// the pill still reads as this product rather than as seven different ones.
    /// The values are the same hexes as the macOS build.
    ///
    /// Faithful is the app's own accent, unchanged: the default dictation looks
    /// exactly as it always has, and colour only becomes information once the
    /// user has chosen something. Colour is reinforcement, never the whole
    /// signal — seven hues are not learnable on their own, which is why a
    /// non-default voice also names itself next to the pill.
    /// </summary>
    public Color Tint { get; }

    private Tone(string id, string label, string blurb, Color tint)
    {
        Id = id;
        Label = label;
        Blurb = blurb;
        Tint = tint;
    }

    public static readonly Tone Faithful = new(
        "", "As spoken",
        "Your words, tidied. Filler and grammar only — nothing is rephrased.",
        Theme.Accent);

    public static readonly Tone Professional = new(
        "professional", "Professional",
        "Clear and polite, the way a colleague writes at work.",
        Color.FromArgb(42, 111, 176));   // #2A6FB0

    public static readonly Tone Formal = new(
        "formal", "Formal",
        "Serious and measured. No contractions, no slang.",
        Color.FromArgb(53, 86, 107));    // #35566B

    public static readonly Tone Casual = new(
        "casual", "Casual",
        "Relaxed and conversational, like writing to someone you know.",
        Color.FromArgb(192, 124, 44));   // #C07C2C

    public static readonly Tone Friendly = new(
        "friendly", "Friendly",
        "Warm and personable, without added enthusiasm.",
        Color.FromArgb(184, 82, 127));   // #B8527F

    public static readonly Tone Concise = new(
        "concise", "Concise",
        "As short as it can be without losing anything you said.",
        Color.FromArgb(30, 122, 85));    // #1E7A55

    public static readonly Tone Confident = new(
        "confident", "Confident",
        "Direct and decisive, with the hedging dropped.",
        Color.FromArgb(178, 74, 51));    // #B24A33

    /// <summary>
    /// Declaration order is the cycle order, and <see cref="Faithful"/> leads it
    /// so one press away from the default is always one press back to it.
    /// </summary>
    public static readonly IReadOnlyList<Tone> All = new[]
    {
        Faithful, Professional, Formal, Casual, Friendly, Concise, Confident,
    };

    /// <summary>The next voice in the cycle.</summary>
    public Tone Next()
    {
        int i = 0;
        for (int n = 0; n < All.Count; n++)
            if (ReferenceEquals(All[n], this)) { i = n; break; }
        return All[(i + 1) % All.Count];
    }

    /// <summary>
    /// Read a stored id, falling back to the default. A value this build does not
    /// know — a settings file written by a newer version, or edited by hand —
    /// leaves the user's words alone rather than guessing at a voice.
    /// </summary>
    public static Tone From(string? id)
    {
        if (!string.IsNullOrEmpty(id))
            foreach (var t in All)
                if (string.Equals(t.Id, id, StringComparison.OrdinalIgnoreCase))
                    return t;
        return Faithful;
    }

    public override string ToString() => Label;
}
