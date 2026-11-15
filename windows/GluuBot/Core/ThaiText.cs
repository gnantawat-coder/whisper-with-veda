using System.Text.RegularExpressions;

namespace GluuBot.Core;

/// Same rules as the Mac app (Core.swift › ThaiText, BackendRequest.cleaned): fix what whisper writes
/// in a decomposed or mis-ordered way, never rewrite what the speaker said.
public static class ThaiText
{
    public static string Normalized(string text)
    {
        var s = text;
        // Invisible characters that only break cursor movement and matching.
        foreach (var ghost in new[] { "​", "‌", "‍", "﻿" }) s = s.Replace(ghost, "");
        // NIKHAHIT + SARA AA is a decomposed SARA AM; a tone mark may sit on either side.
        s = Regex.Replace(s, "ํ([่-๋]?)า", "$1ำ");
        s = Regex.Replace(s, "([่-๋])ํา", "$1ำ");
        // Canonical order is vowel then tone; a tone written first is the same syllable.
        s = Regex.Replace(s, "([่-๋])([ัิ-ฺ็])", "$2$1");
        // A doubled combining mark renders as one; keep one.
        s = Regex.Replace(s, "([ัิ-ฺ็-๎])\\1+", "$1");
        return s;
    }

    /// whisper emits one line per segment; that break is a decoder artifact and would land as Enter in the target field.
    public static string Cleaned(string text)
    {
        var joined = Regex.Replace(Normalized(text), "[\\r\\n]+ *", " ").Trim();
        joined = Regex.Replace(joined, "[ \\t]+", " ");
        return IsNonSpeech(joined) ? "" : joined;
    }

    /// "[BLANK_AUDIO]", "(music)" and the like are the model describing silence, not words to type.
    public static bool IsNonSpeech(string text)
    {
        var t = text.Trim();
        return t.Length == 0 || Regex.IsMatch(t, "^[\\[(][^\\])]*[\\])]$");
    }
}
