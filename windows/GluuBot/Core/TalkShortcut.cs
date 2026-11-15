namespace GluuBot.Core;

public enum TalkAction { Begin, End, Toggle }

/// Hold the talk key to speak, release to type; talk key + Space flips TH/EN and cancels that take.
/// The same state machine as the Mac app's DictationShortcut, with one trigger.
public struct TalkShortcut
{
    private bool held, switched, spaceHeld;

    public TalkAction? Key(bool down)
    {
        if (down)
        {
            if (held) return null;          // auto-repeat while the key stays down
            held = true;
            return TalkAction.Begin;
        }
        if (!held) return null;
        held = false;
        bool wasSwitched = switched; switched = false;
        return wasSwitched ? null : TalkAction.End;
    }

    public (bool Consume, TalkAction? Action) Space(bool down, bool repeat)
    {
        if (!down) { bool consume = spaceHeld; spaceHeld = false; return (consume, null); }
        if (!held && !spaceHeld) return (false, null);
        if (repeat || spaceHeld) return (true, null);
        spaceHeld = true; switched = true;
        return (true, TalkAction.Toggle);
    }

    public bool Held => held;
}

/// Windows virtual-key codes the user may pick as the talk key. The Fn key is not on this list because
/// Windows never sees it: laptop firmware handles Fn before the OS does.
public static class TalkKeys
{
    public const int Default = 0xA3;   // Right Ctrl
    private static readonly Dictionary<int, string> Names = new()
    {
        [0xA3] = "Ctrl ขวา", [0xA2] = "Ctrl ซ้าย", [0xA5] = "Alt ขวา", [0xA4] = "Alt ซ้าย", [0xA1] = "Shift ขวา", [0xA0] = "Shift ซ้าย",
        [0x5B] = "Win ซ้าย", [0x5C] = "Win ขวา", [0x5D] = "Menu", [0x91] = "Scroll Lock", [0x13] = "Pause", [0x2D] = "Insert", [0x2E] = "Delete",
        [0x24] = "Home", [0x23] = "End", [0x21] = "Page Up", [0x22] = "Page Down", [0xC0] = "`", [0x09] = "Tab", [0x90] = "Num Lock",
    };
    public static bool IsModifier(int vk) => vk is >= 0xA0 and <= 0xA5 or 0x5B or 0x5C;
    /// Space is the TH/EN chord, Esc cancels, Caps Lock toggles state, Enter/Backspace are needed for typing.
    public static bool Allowed(int vk) => vk is not (0x20 or 0x1B or 0x14 or 0x0D or 0x08) && vk > 0x07 && vk < 0xFF;
    public static string Name(int vk)
    {
        if (Names.TryGetValue(vk, out var n)) return n;
        if (vk is >= 0x70 and <= 0x87) return "F" + (vk - 0x6F);
        if (vk is >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A) return ((char)vk).ToString();
        if (vk is >= 0x60 and <= 0x69) return "Numpad " + (vk - 0x60);
        return "ปุ่ม 0x" + vk.ToString("X2");
    }
}
