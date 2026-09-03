import Cocoa
import SwiftUI

/// The writing voice a dictation is cleaned into.
///
/// The `rawValue` is the ID sent to the sidecar and on to the cleanup gateway,
/// which owns the closed set and the instruction behind each entry. Nothing
/// here describes *how* a voice writes — that lives server-side, so a wording
/// change ships as a gateway deploy rather than an app release, and the three
/// clients cannot drift from each other.
///
/// `faithful` is the default and deliberately sends nothing: an empty ID means
/// the gateway builds the prompt it built before tones existed, and the user's
/// own wording survives untouched. Anyone who never presses the key is on
/// exactly the behaviour they have always had.
enum Tone: String, CaseIterable, Identifiable {
    case faithful = ""
    case professional
    case formal
    case casual
    case friendly
    case concise
    case confident

    var id: String { rawValue }

    /// What the user sees — in the overlay, the menu, and Settings.
    var label: String {
        switch self {
        case .faithful:     return "As spoken"
        case .professional: return "Professional"
        case .formal:       return "Formal"
        case .casual:       return "Casual"
        case .friendly:     return "Friendly"
        case .concise:      return "Concise"
        case .confident:    return "Confident"
        }
    }

    /// One line of explanation, for the Settings list.
    var blurb: String {
        switch self {
        case .faithful:     return "Your words, tidied. Filler and grammar only — nothing is rephrased."
        case .professional: return "Clear and polite, the way a colleague writes at work."
        case .formal:       return "Serious and measured. No contractions, no slang."
        case .casual:       return "Relaxed and conversational, like writing to someone you know."
        case .friendly:     return "Warm and personable, without added enthusiasm."
        case .concise:      return "As short as it can be without losing anything you said."
        case .confident:    return "Direct and decisive, with the hedging dropped."
        }
    }

    /// The next voice in the cycle. Declaration order is the cycle order, and
    /// `faithful` leads it so one press away from the default is always one
    /// press back to it.
    var next: Tone {
        let all = Tone.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    /// Read a stored or received ID, falling back to the default. A value the
    /// app does not know — a preference written by a newer build, or edited by
    /// hand — leaves the user's words alone rather than guessing at a voice.
    static func from(_ raw: String?) -> Tone {
        Tone(rawValue: raw ?? "") ?? .faithful
    }
}

// MARK: - Colour

/// One tint per voice, in the same muted family as the rest of the palette so
/// the pill still reads as this product rather than as seven different ones.
///
/// `faithful` is the app's own accent, unchanged: the default dictation looks
/// exactly as it always has, and colour only becomes information once the user
/// has chosen something.
///
/// Colour is reinforcement, never the whole signal — seven hues are not
/// learnable on their own, which is why a non-default voice also names itself
/// in a chip below the pill for as long as it is up. See `BubbleView.setTone`.
extension Tone {
    var tint: Color {
        switch self {
        case .faithful:     return Theme.accent
        case .professional: return Color(red: 0.165, green: 0.435, blue: 0.690)  // #2A6FB0
        case .formal:       return Color(red: 0.208, green: 0.337, blue: 0.420)  // #35566B
        case .casual:       return Color(red: 0.753, green: 0.486, blue: 0.173)  // #C07C2C
        case .friendly:     return Color(red: 0.722, green: 0.322, blue: 0.498)  // #B8527F
        case .concise:      return Color(red: 0.118, green: 0.478, blue: 0.333)  // #1E7A55
        case .confident:    return Color(red: 0.698, green: 0.290, blue: 0.200)  // #B24A33
        }
    }

    var nsTint: NSColor { NSColor(tint) }
}
