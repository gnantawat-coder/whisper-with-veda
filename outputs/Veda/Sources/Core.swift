import Foundation
import CoreGraphics
import Darwin

enum Mode: String, CaseIterable { case th = "TH", en = "EN" }
enum Phase { case idle, starting, recording, processing }
struct FocusStamp: Equatable {
    let pid: Int32
    let element: Int
    let location: Int
    let length: Int
    let value: String
}
struct SessionGuard {
    private(set) var original: FocusStamp?
    private(set) var invalidated = false
    mutating func begin(_ stamp: FocusStamp?) { original = stamp; invalidated = stamp == nil }
    mutating func observe(_ stamp: FocusStamp?) { if stamp != original { invalidated = true } }
    func permits(_ stamp: FocusStamp?) -> Bool { !invalidated && original != nil && stamp == original }
}
struct BackendRequest {
    static func body(wav: Data, mode: Mode, vocabulary: String, boundary: String, sourceLanguage: String = "th") -> Data {
        var data = Data()
        func add(_ s: String) { data.append(Data(s.utf8)) }
        for (name, value) in [("language", sourceLanguage), ("translate", mode == .en ? "true" : "false"), ("response_format", "json"), ("temperature", "0"), ("prompt", String(vocabulary.prefix(2000)))] {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        data.append(wav)
        add("\r\n--\(boundary)--\r\n")
        return data
    }
    static func cleaned(_ text: String, polish: Bool) -> String {
        // whisper emits one line per segment; that break is a decoder artifact, not
        // something the user said, and would land as Return in the target field.
        let joined = ThaiText.normalized(text).replacingOccurrences(of: "[\\r\\n]+ *", with: " ", options: .regularExpression)
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        // Deliberately conservative: no semantic rewriting or filler deletion.
        return polish ? trimmed.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression) : trimmed
    }
}

enum PermissionGate: Equatable {
    case microphone, accessibility, ready
    static func evaluate(microphone: Bool, accessibility: Bool) -> PermissionGate {
        if !microphone { return .microphone }
        if !accessibility { return .accessibility }
        return .ready
    }
}

// A released/cancelled hold can never start a queued recording session.
final class HoldLatch {
    private let lock = NSLock()
    private var held: UUID?
    func begin() -> UUID { lock.lock(); defer { lock.unlock() }; let id = UUID(); held = id; return id }
    func end() { lock.lock(); held = nil; lock.unlock() }
    func isHeld(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return held == id }
    func whileHeld(_ id: UUID, _ action: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }; return held == id && action()
    }
}

// Kernel lock prevents duplicate panels/backends even when two copies start together.
final class SingleInstanceLock {
    private var descriptor: Int32 = -1
    func acquire(path: String) -> Bool {
        guard descriptor == -1 else { return true }
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd; return true
    }
    func release() { if descriptor >= 0 { close(descriptor); descriptor = -1 } }
    deinit { release() }
}


// Center on the display itself even when a side Dock reduces its visible area.
// Recompute from the screen every time; never inherit a dragged or resized origin.
struct OverlayPlacement {
    static func frame(screen: CGRect, visible: CGRect, active: Bool) -> CGRect {
        let size = CGSize(width: active ? 146 : 74, height: active ? 38 : 32)
        return CGRect(x: screen.midX - size.width / 2, y: visible.minY + 18, width: size.width, height: size.height)
    }
}

// Shared physical holds; Space is consumed through its matching release even if
// Fn/F18 is released first. Repeats never toggle twice or restart a recording.
/// A user-chosen push-to-talk key for keyboards without Fn: one key, held to speak, like Fn.
struct TalkKey: Equatable {
    var keyCode: Int64
    static let modifierCodes: Set<Int64> = [54, 55, 56, 58, 59, 60, 61, 62]   // ⌘ ⇧ ⌥ ⌃ (left/right); caps lock and Fn are not offered
    static let names: [Int64: String] = [54: "⌘ ขวา", 55: "⌘ ซ้าย", 56: "⇧ ซ้าย", 60: "⇧ ขวา", 58: "⌥ ซ้าย", 61: "⌥ ขวา", 59: "⌃ ซ้าย", 62: "⌃ ขวา",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20", 50: "`", 48: "Tab", 49: "Space", 36: "Return", 51: "Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn", 114: "Help", 117: "⌦"]
    var isModifier: Bool { TalkKey.modifierCodes.contains(keyCode) }
    var label: String { TalkKey.names[keyCode] ?? "ปุ่ม \(keyCode)" }
    var stored: String { String(keyCode) }
    init(keyCode: Int64) { self.keyCode = keyCode }
    init?(stored: String) { guard let k = Int64(stored), k >= 0 else { return nil }; keyCode = k }
    /// Keys that cannot serve: Fn itself, caps lock (toggles), Space (TH/EN chord), Esc (cancel).
    static func allowed(_ keyCode: Int64) -> Bool { ![63, 57, 49, 53].contains(keyCode) }
    /// For modifier keys the tap sees flagsChanged; this is the flag that tells "down".
    var modifierMask: UInt64? {
        switch keyCode { case 54, 55: return 1 << 20; case 56, 60: return 1 << 17; case 58, 61: return 1 << 19; case 59, 62: return 1 << 18; default: return nil }
    }
}

struct DictationShortcut {
    enum Trigger: Hashable { case fn, f18, custom }
    enum Action: Equatable { case begin, end, toggle, playfulness }
    private var held: Set<Trigger> = []
    private var switched = false
    private var spaceHeld = false
    mutating func trigger(_ key: Trigger, down: Bool) -> Action? {
        if down {
            guard held.insert(key).inserted else { return nil }
            return held.count == 1 ? .begin : nil
        }
        guard held.remove(key) != nil, held.isEmpty else { return nil }
        defer { switched = false }
        return switched ? nil : .end
    }
    /// Option pressed while Fn/F18 is held. Modifiers are never consumed, so only the action is returned.
    mutating func option(down: Bool) -> Action? {
        guard down, !held.isEmpty else { return nil }
        switched = true
        return .playfulness
    }
    mutating func space(down: Bool, repeatKey: Bool) -> (consume: Bool, action: Action?) {
        if !down {
            let consume = spaceHeld; spaceHeld = false
            return (consume, nil)
        }
        guard !held.isEmpty || spaceHeld else { return (false, nil) }
        guard !repeatKey, !spaceHeld else { return (true, nil) }
        spaceHeld = true; switched = true
        return (true, .toggle)
    }
}

// Held transcripts live in RAM only. This is the single exception: a one-time
// handoff across an update, owner-readable only, deleted the moment it is restored.
enum PendingArchive {
    static func path(uid: UInt32) -> String { "/private/tmp/veda-upgrade-pending-\(uid).json" }
    static func encode(_ pending: [String]) -> Data? {
        let kept = pending.filter { !$0.isEmpty }
        guard !kept.isEmpty else { return nil }
        return try? JSONEncoder().encode(kept)
    }
    // Writing nothing must leave an existing archive untouched: it may still hold text
    // from an earlier session that was never restored. Created 0600 from the start,
    // because /private/tmp is world readable.
    @discardableResult
    static func save(_ pending: [String], to path: String) -> Bool {
        guard let data = encode(pending) else { return false }
        try? FileManager.default.removeItem(atPath: path)
        return FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
    // Accepts both the plain list written here and the older answer/question shape.
    static func decode(_ data: Data) -> [String]? {
        struct UpgradeState: Decodable { let pending: [String] }
        if let texts = try? JSONDecoder().decode([String].self, from: data) { return texts }
        if let saved = try? JSONDecoder().decode(UpgradeState.self, from: data) { return saved.pending }
        return nil
    }
}

// Personal profile is local text only: a name, vocabulary hints and examples the
// user confirmed. No audio is kept and no acoustic model is trained.
enum PersonalProfile {
    static let exampleLimit = 20
    static func adding(expected: String, heard: String, audioPath: String? = nil, model: String? = nil, to examples: [[String: String]]) -> [[String: String]]? {
        let spoken = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let recognised = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !recognised.isEmpty else { return nil }
        var next = examples
        var example = ["expected": spoken, "heard": recognised]
        // The path lets the same clip be re-scored after a model change; the file itself is never copied.
        if let audioPath, !audioPath.isEmpty { example["audio"] = audioPath }
        if let model, !model.isEmpty { example["model"] = model }
        next.append(example)
        if next.count > exampleLimit { next.removeFirst(next.count - exampleLimit) }
        return next
    }
    // Session vocabulary first, then profile words; blanks and repeats dropped.
    static func hint(vocabulary: String, profileWords: String) -> String {
        var seen = Set<String>()
        let terms = (vocabulary + "," + profileWords)
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return terms.joined(separator: ", ")
    }
}

// Ordinary phone recordings are converted locally, so only length is a hard limit.
// Two minutes covers one read-through of the whole calibration list in a single take.
enum AudioImport {
    static let maxSeconds = 120.0
    static let sampleRate = 16000.0
    enum Verdict: Equatable { case accept, empty, tooLong(seconds: Int) }
    static func verdict(frames: Int64, sampleRate rate: Double) -> Verdict {
        guard frames > 0, rate > 0 else { return .empty }
        let seconds = Double(frames) / rate
        guard seconds <= maxSeconds else { return .tooLong(seconds: Int(seconds.rounded())) }
        return .accept
    }
}

// Orthographic repair only, never semantic: models sometimes emit Thai in
// decomposed or misordered form that looks right but is a different string,
// so later searches, spell checks and pastes misbehave. Every rule here maps
// one encoding of a syllable to its canonical encoding of the same syllable.
enum ThaiText {
    static func normalized(_ text: String) -> String {
        var s = text
        // Invisible characters that only break cursor movement and matching.
        for ghost in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"] { s = s.replacingOccurrences(of: ghost, with: "") }
        // NIKHAHIT + SARA AA is a decomposed SARA AM; a tone mark may sit on either side.
        s = s.replacingOccurrences(of: "\u{0E4D}([\u{0E48}-\u{0E4B}]?)\u{0E32}", with: "$1\u{0E33}", options: .regularExpression)
        s = s.replacingOccurrences(of: "([\u{0E48}-\u{0E4B}])\u{0E4D}\u{0E32}", with: "$1\u{0E33}", options: .regularExpression)
        // Canonical order is vowel then tone; a tone written first is the same syllable.
        s = s.replacingOccurrences(of: "([\u{0E48}-\u{0E4B}])([\u{0E31}\u{0E34}-\u{0E3A}\u{0E47}])", with: "$2$1", options: .regularExpression)
        // A doubled combining mark renders as one; keep one.
        s = s.replacingOccurrences(of: "([\u{0E31}\u{0E34}-\u{0E3A}\u{0E47}-\u{0E4E}])\\1+", with: "$1", options: .regularExpression)
        return s
    }
}

// Character error rate between what the user says they said and what the model
// heard. Whitespace is ignored so phrase spacing never counts; Thai digits and
// words are compared as written, because "12345" for "หนึ่งสองสามสี่ห้า" is a
// real difference a reader sees.
enum Accuracy {
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }; if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for (i, cx) in x.enumerated() {
            var current = [i + 1]
            for (j, cy) in y.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (cx == cy ? 0 : 1)))
            }
            previous = current
        }
        return previous[y.count]
    }
    static func compact(_ s: String) -> String { ThaiText.normalized(s).filter { !$0.isWhitespace } }
    /// 0 = identical, 1 = nothing right. Nil when there is no reference to compare against.
    static func characterErrorRate(expected: String, heard: String) -> Double? {
        let reference = compact(expected)
        guard !reference.isEmpty else { return nil }
        return Double(editDistance(reference, compact(heard))) / Double(reference.count)
    }
}

// Whether a field now holds the dictated text. Web editors (Claude desktop's
// composer is one) re-flow what was typed — trailing newlines, paragraph breaks,
// collapsed spaces — so an exact match against the predicted string reports a
// successful insertion as a failure and the text is held a second time.
// "Inserted" means: the field changed, and the dictated text is in it.
enum Insertion {
    static func compact(_ s: String) -> String { ThaiText.normalized(s).filter { !$0.isWhitespace } }
    static func succeeded(original: String, final: String?, expected: String, inserted text: String) -> Bool {
        guard let final else { return false }
        if final == expected { return true }
        let typed = compact(text)
        guard !typed.isEmpty, final != original else { return false }
        return compact(final).contains(typed) && !compact(original).contains(typed)
            || compact(final).components(separatedBy: typed).count > compact(original).components(separatedBy: typed).count
    }
}

// Corrections the user approved one by one: a spelling the model actually produced
// mapped to the term they meant. Applied only to that exact variant, never as a
// global search-and-replace of phonetically similar words.
enum TermCorrections {
    static func apply(_ text: String, pairs: [[String: String]]) -> String {
        var out = text
        let usable = pairs.compactMap { pair -> (String, String)? in
            guard let heard = pair["heard"]?.trimmingCharacters(in: .whitespacesAndNewlines), !heard.isEmpty,
                  let correct = pair["correct"]?.trimmingCharacters(in: .whitespacesAndNewlines), !correct.isEmpty, heard != correct else { return nil }
            return (heard, correct)
        }.sorted { $0.0.count > $1.0.count }   // longer variants first so "Voice2Tech" beats "Tech"
        for (heard, correct) in usable {
            let latin = heard.unicodeScalars.allSatisfy { $0.isASCII }
            if latin {
                // Whole word only, case-insensitive: "codec" and "Codec" are the same mistake.
                let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: heard) + "(?![A-Za-z0-9])"
                out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: correct), options: [.regularExpression, .caseInsensitive])
            } else {
                out = out.replacingOccurrences(of: heard, with: correct)
            }
        }
        return out
    }
}

// Snap Translate: which way to translate is decided by what the text mostly is,
// and OCR lines are joined into one passage the translator can read as a whole.
enum SnapText {
    enum Direction: Equatable { case thaiToEnglish, englishToThai }
    static func direction(of text: String) -> Direction {
        var thai = 0, latin = 0
        for scalar in text.unicodeScalars {
            if (0x0E00...0x0E7F).contains(scalar.value) { thai += 1 }
            else if (scalar.value < 0x80 && CharacterSet.letters.contains(scalar)) { latin += 1 }
        }
        return thai >= latin && thai > 0 ? .thaiToEnglish : .englishToThai
    }
    static func passage(from lines: [String]) -> String {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return ThaiText.normalized(cleaned.joined(separator: " ")).replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
    }
}

// Snap Translate shortcut: any key plus modifiers, chosen by the user. Default is
// ⌘⇧3 at the user's request; Veda consumes it before the system screenshot does.
struct SnapShortcut: Equatable {
    var keyCode: Int64
    var command: Bool, shift: Bool, control: Bool, option: Bool
    static let `default` = SnapShortcut(keyCode: 20, command: true, shift: true, control: false, option: false)  // kVK_ANSI_3
    var hasModifier: Bool { command || shift || control || option }
    func matches(keyCode: Int64, command: Bool, shift: Bool, control: Bool, option: Bool) -> Bool {
        keyCode == self.keyCode && command == self.command && shift == self.shift && control == self.control && option == self.option
    }
    var label: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + SnapShortcut.keyName(keyCode)
    }
    // Stored as "cmd+shift+20" so a hand-edited default still parses.
    var stored: String {
        ([command ? "cmd" : nil, control ? "ctrl" : nil, option ? "opt" : nil, shift ? "shift" : nil].compactMap { $0 } + [String(keyCode)]).joined(separator: "+")
    }
    init(keyCode: Int64, command: Bool, shift: Bool, control: Bool, option: Bool) {
        self.keyCode = keyCode; self.command = command; self.shift = shift; self.control = control; self.option = option
    }
    init?(stored: String) {
        let parts = stored.split(separator: "+").map(String.init)
        guard let last = parts.last, let code = Int64(last), code >= 0, code < 128 else { return nil }
        let mods = Set(parts.dropLast())
        self.init(keyCode: code, command: mods.contains("cmd"), shift: mods.contains("shift"), control: mods.contains("ctrl"), option: mods.contains("opt"))
        guard hasModifier else { return nil }   // a bare key would hijack typing
    }
    static func keyName(_ code: Int64) -> String {
        let names: [Int64: String] = [0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 49: "Space", 50: "`", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑", 79: "F18", 80: "F19", 64: "F17", 106: "F16"]
        return names[code] ?? "key\(code)"
    }
}

// OCR lines in reading order: top to bottom, left to right within a row.
struct TextLine: Equatable {
    let text: String
    let box: CGRect
}
enum SnapLayout {
    static func readingOrder(_ lines: [TextLine]) -> [TextLine] {
        lines.sorted { a, b in
            let sameRow = abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) * 0.5
            return sameRow ? a.box.minX < b.box.minX : a.box.midY > b.box.midY
        }
    }
}

// Where the model's spelling differs from what the user said they said. Offered,
// never applied: each pair still needs the user's approval. Number formatting
// and case-only differences are not offered.
enum TermSuggestions {
    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || ",.;:!?()[]\"".contains($0) }).map(String.init)
    }
    static func suggest(expected: String, heard: String, approved: [[String: String]] = []) -> [[String: String]] {
        let a = tokens(ThaiText.normalized(heard)), b = tokens(ThaiText.normalized(expected))
        // LCS table over tokens; replaced runs of 1–3 tokens on both sides become candidates.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0, out: [[String: String]] = []
        var runA: [String] = [], runB: [String] = []
        func flush() {
            defer { runA = []; runB = [] }
            guard (1...3).contains(runA.count), (1...3).contains(runB.count) else { return }
            let h = runA.joined(separator: " "), c = runB.joined(separator: " ")
            guard h.lowercased() != c.lowercased(), !h.allSatisfy({ $0.isNumber || $0 == " " }), !c.allSatisfy({ $0.isNumber || $0 == " " }) else { return }
            guard !approved.contains(where: { $0["heard"] == h }), !out.contains(where: { $0["heard"] == h }) else { return }
            out.append(["heard": h, "correct": c])
        }
        while i < a.count && j < b.count {
            if a[i] == b[j] { flush(); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { runA.append(a[i]); i += 1 }
            else { runB.append(b[j]); j += 1 }
        }
        runA += a[i...]; runB += b[j...]; flush()
        return out
    }
}

// Slang and idioms. The on-device translator is literal ("เดือดสัส" → "boiling"),
// so known expressions are rewritten to plain language *before* translation and,
// in chat mode, the plain rendering is swapped back for the target language's
// own slang afterwards. Every match is reported so the user sees what happened.
struct SlangEntry: Equatable {
    enum Register: String { case casual, rude, vulgar }
    let th: String, thPlain: String
    let en: String, enPlain: String
    let register: Register
    let meaning: String   // short gloss shown in the note, in Thai
    var dictionary: [String: String] { ["th": th, "thPlain": thPlain, "en": en, "enPlain": enPlain, "register": register.rawValue, "meaning": meaning] }
    init(th: String, thPlain: String, en: String, enPlain: String, register: Register, meaning: String) {
        self.th = th; self.thPlain = thPlain; self.en = en; self.enPlain = enPlain; self.register = register; self.meaning = meaning
    }
    // Only the two slang words are required. A missing plain form means the word is
    // already plain enough to send to the translator as it is.
    init?(_ d: [String: String]) {
        func value(_ key: String) -> String { (d[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let th = value("th"), en = value("en")
        guard !th.isEmpty, !en.isEmpty else { return nil }
        let thPlain = value("thPlain"), enPlain = value("enPlain")
        self.init(th: th, thPlain: thPlain.isEmpty ? th : thPlain, en: en, enPlain: enPlain.isEmpty ? en : enPlain,
                  register: Register(rawValue: value("register")) ?? .casual, meaning: value("meaning"))
    }
}
struct SlangNote: Equatable {
    let source: String, target: String, plain: String, register: SlangEntry.Register, meaning: String
}
enum Slang {
    enum Mode: String, CaseIterable { case polite, chat }
    static let seed: [SlangEntry] = [
        .init(th: "เดือดสัส", thPlain: "ดุเดือดมาก", en: "intense as hell", enPlain: "very intense", register: .vulgar, meaning: "ดุเดือด/มันมาก"),
        .init(th: "โคตรเดือด", thPlain: "ดุเดือดมาก", en: "insanely intense", enPlain: "very intense", register: .rude, meaning: "ดุเดือดมาก"),
        .init(th: "เดือดมาก", thPlain: "ดุเดือดมาก", en: "heated", enPlain: "very intense", register: .casual, meaning: "ดุเดือด"),
        .init(th: "สัส", thPlain: "มาก", en: "as hell", enPlain: "very", register: .vulgar, meaning: "คำเสริมหยาบ"),
        .init(th: "แม่ง", thPlain: "มัน", en: "damn", enPlain: "it", register: .vulgar, meaning: "คำเสริม/สรรพนามหยาบ"),
        .init(th: "โคตร", thPlain: "มาก", en: "freaking", enPlain: "very", register: .rude, meaning: "มาก (หยาบเล็กน้อย)"),
        .init(th: "จึ้ง", thPlain: "ดีมาก", en: "slaps", enPlain: "excellent", register: .casual, meaning: "ดี/สวย/โดนใจมาก"),
        .init(th: "ปัง", thPlain: "ดีมาก", en: "a banger", enPlain: "great", register: .casual, meaning: "ดีมาก ประสบความสำเร็จ"),
        .init(th: "ตัวตึง", thPlain: "ตัวจริงที่เก่งที่สุด", en: "the GOAT", enPlain: "the best", register: .casual, meaning: "คนเก่งที่สุดในเรื่องนั้น"),
        .init(th: "ตัวแม่", thPlain: "ตัวจริง", en: "iconic", enPlain: "outstanding", register: .casual, meaning: "ตัวจริง โดดเด่น"),
        .init(th: "นอย", thPlain: "กังวล", en: "paranoid", enPlain: "worried", register: .casual, meaning: "กังวล/คิดมาก"),
        .init(th: "ลำไย", thPlain: "น่ารำคาญ", en: "annoying", enPlain: "annoying", register: .casual, meaning: "น่ารำคาญ"),
        .init(th: "เกรียน", thPlain: "กวนประสาท", en: "trolling", enPlain: "provocative", register: .casual, meaning: "กวน ยั่วให้โกรธ"),
        .init(th: "ฟิน", thPlain: "มีความสุขมาก", en: "blissed out", enPlain: "very happy", register: .casual, meaning: "มีความสุขสุด ๆ"),
        .init(th: "ชิล", thPlain: "สบาย ๆ", en: "chill", enPlain: "relaxed", register: .casual, meaning: "สบาย ๆ ไม่เครียด"),
        .init(th: "ห่วยแตก", thPlain: "แย่มาก", en: "trash", enPlain: "very bad", register: .rude, meaning: "แย่มาก"),
        .init(th: "กาก", thPlain: "ห่วย", en: "garbage", enPlain: "bad", register: .rude, meaning: "ห่วย ไม่เก่ง"),
        .init(th: "เฟล", thPlain: "ล้มเหลว", en: "a fail", enPlain: "a failure", register: .casual, meaning: "ล้มเหลว ผิดหวัง"),
        .init(th: "มโน", thPlain: "คิดไปเอง", en: "imagining things", enPlain: "imagining", register: .casual, meaning: "จินตนาการไปเอง"),
        .init(th: "ขิง", thPlain: "อวด", en: "flexing", enPlain: "showing off", register: .casual, meaning: "อวด"),
        .init(th: "คือดีย์", thPlain: "ดีมาก", en: "so good", enPlain: "very good", register: .casual, meaning: "ดีมาก"),
        .init(th: "อิหยังวะ", thPlain: "อะไรกัน", en: "what the heck", enPlain: "what is this", register: .casual, meaning: "อะไรกัน (งง)"),
        .init(th: "แกง", thPlain: "แกล้งหลอก", en: "pranking", enPlain: "teasing", register: .casual, meaning: "หลอก/แกล้ง"),
        .init(th: "ส่งซิก", thPlain: "ส่งสัญญาณ", en: "dropping hints", enPlain: "signaling", register: .casual, meaning: "ส่งสัญญาณ"),
        .init(th: "โดนเท", thPlain: "ถูกทิ้ง", en: "ghosted", enPlain: "abandoned", register: .casual, meaning: "ถูกทิ้ง/เบี้ยว"),
        .init(th: "โป๊ะ", thPlain: "ความจริงเปิดเผย", en: "busted", enPlain: "exposed", register: .casual, meaning: "ถูกจับได้"),
        .init(th: "เปย์", thPlain: "ทุ่มเงินให้", en: "splurging on", enPlain: "paying for", register: .casual, meaning: "จ่ายให้ ทุ่มให้"),
        .init(th: "แซ่บ", thPlain: "เร่าร้อน", en: "spicy", enPlain: "exciting", register: .casual, meaning: "เผ็ดร้อน/น่าตื่นเต้น"),
        .init(th: "ตึง", thPlain: "สุดโต่ง", en: "hardcore", enPlain: "extreme", register: .casual, meaning: "จัดเต็ม สุดโต่ง"),
        .init(th: "555", thPlain: "ขำ", en: "lol", enPlain: "laughing", register: .casual, meaning: "หัวเราะ"),
        .init(th: "จริง ๆ นะ", thPlain: "จริง ๆ", en: "no cap", enPlain: "honestly", register: .casual, meaning: "ไม่โกหก"),
        .init(th: "งั้น ๆ", thPlain: "ธรรมดา", en: "mid", enPlain: "mediocre", register: .casual, meaning: "ธรรมดา ไม่ดีไม่แย่"),
        .init(th: "ไม่โกหกนะ", thPlain: "พูดตรง ๆ", en: "ngl", enPlain: "not going to lie", register: .casual, meaning: "พูดตรง ๆ"),
        .init(th: "ตรง ๆ นะ", thPlain: "พูดตามตรง", en: "tbh", enPlain: "to be honest", register: .casual, meaning: "พูดตามตรง"),
        .init(th: "โอเคเลย", thPlain: "ดูดี", en: "LGTM", enPlain: "looks good to me", register: .casual, meaning: "ดูดี ผ่าน (โค้ด)"),
        .init(th: "ปล่อยเลย", thPlain: "ปล่อยใช้งาน", en: "ship it", enPlain: "release it", register: .casual, meaning: "ปล่อยใช้งาน (โค้ด)"),
        .init(th: "กำลังทำ", thPlain: "กำลังดำเนินการ", en: "WIP", enPlain: "work in progress", register: .casual, meaning: "งานยังไม่เสร็จ"),
        .init(th: "งอน", thPlain: "ไม่พอใจ", en: "salty", enPlain: "upset", register: .casual, meaning: "ไม่พอใจ ขุ่นเคือง"),
        .init(th: "ฟีล", thPlain: "ความรู้สึก", en: "vibe", enPlain: "feeling", register: .casual, meaning: "อารมณ์/บรรยากาศ"),
        .init(th: "อี๋", thPlain: "น่าอาย", en: "cringe", enPlain: "embarrassing", register: .casual, meaning: "น่าอาย ขนลุก"),
        .init(th: "เดี๋ยวมา", thPlain: "เดี๋ยวกลับมา", en: "brb", enPlain: "be right back", register: .casual, meaning: "เดี๋ยวกลับมา"),
        .init(th: "ไม่รู้", thPlain: "ไม่ทราบ", en: "idk", enPlain: "I don't know", register: .casual, meaning: "ไม่รู้"),
        .init(th: "ช่างมัน", thPlain: "ไม่เป็นไร", en: "nvm", enPlain: "never mind", register: .casual, meaning: "ไม่เป็นไร ลืมไปเถอะ"),
        .init(th: "ด่วนสุด", thPlain: "เร็วที่สุด", en: "asap", enPlain: "as soon as possible", register: .casual, meaning: "เร็วที่สุดเท่าที่ทำได้"),
        .init(th: "แจ้งให้ทราบ", thPlain: "เพื่อทราบ", en: "fyi", enPlain: "for your information", register: .casual, meaning: "แจ้งเพื่อทราบ"),
        .init(th: "อะไรวะ", thPlain: "อะไรกัน", en: "wtf", enPlain: "what on earth", register: .vulgar, meaning: "อะไรกัน (หยาบ)"),
    ]
    static func entries(custom: [[String: String]]) -> [SlangEntry] {
        let user = custom.compactMap(SlangEntry.init)
        // User entries win over the seed for the same expression.
        return user + seed.filter { s in !user.contains { $0.th == s.th || $0.en.lowercased() == s.en.lowercased() } }
    }
    /// Before translation: known expressions become plain language the translator handles.
    /// `sourceIsThai` selects which side to match. Longest expressions first.
    static func prepare(_ text: String, sourceIsThai: Bool, mode: Mode, entries: [SlangEntry]) -> (text: String, notes: [SlangNote]) {
        var out = text, notes: [SlangNote] = []
        let ordered = entries.sorted { (sourceIsThai ? $0.th.count : $0.en.count) > (sourceIsThai ? $1.th.count : $1.en.count) }
        for e in ordered {
            let source = sourceIsThai ? e.th : e.en
            let plain = sourceIsThai ? e.thPlain : e.enPlain
            let target = mode == .chat ? (sourceIsThai ? e.en : e.th) : (sourceIsThai ? e.enPlain : e.thPlain)
            let before = out
            if sourceIsThai {
                out = out.replacingOccurrences(of: source, with: plain)
            } else {
                let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: source) + "(?![A-Za-z0-9])"
                out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: plain), options: [.regularExpression, .caseInsensitive])
            }
            if out != before { notes.append(SlangNote(source: source, target: target, plain: sourceIsThai ? e.enPlain : e.thPlain, register: e.register, meaning: e.meaning)) }
        }
        return (out, notes)
    }
    /// After translation, chat mode swaps the plain rendering back for the target language's slang.
    /// Polite mode leaves the plain rendering. Best effort: if the translator phrased it differently, the note still tells the user.
    static func finish(_ translated: String, notes: [SlangNote], mode: Mode) -> String {
        guard mode == .chat else { return translated }
        var out = translated
        for n in notes where n.target != n.plain {
            let latin = n.plain.unicodeScalars.allSatisfy { $0.isASCII }
            if latin {
                let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: n.plain) + "(?![A-Za-z0-9])"
                out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: n.target), options: [.regularExpression, .caseInsensitive])
            } else {
                out = out.replacingOccurrences(of: n.plain, with: n.target)
            }
        }
        // Keep a sentence-initial capital after a Latin swap.
        if let first = out.first, first.isLowercase, translated.first?.isUppercase == true { out = first.uppercased() + out.dropFirst() }
        return out
    }
}

// Minimal 16 kHz mono PCM WAV handling, used to cut a short warm-up clip out of
// the bundled fixture. Whisper loops for many seconds on silence, so the warm-up
// has to be real speech.
enum WAVClip {
    static let header = 44
    /// First `seconds` of a 16-bit mono WAV, re-wrapped with a correct header.
    static func prefix(_ wav: Data, seconds: Double, sampleRate: Int = 16000) -> Data? {
        guard wav.count > header, wav.prefix(4) == Data("RIFF".utf8), seconds > 0 else { return nil }
        let wanted = Int(Double(sampleRate) * seconds) * 2
        let available = wav.count - header
        let take = min(wanted, available)
        guard take > 0 else { return nil }
        return mono16k(wav.subdata(in: header..<(header + take)), sampleRate: sampleRate)
    }
    static func mono16k(_ pcm: Data, sampleRate: Int = 16000) -> Data {
        var out = Data(capacity: header + pcm.count)
        func ascii(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { for i in 0..<4 { out.append(UInt8((v >> (8 * i)) & 0xFF)) } }
        func u16(_ v: Int) { for i in 0..<2 { out.append(UInt8((v >> (8 * i)) & 0xFF)) } }
        ascii("RIFF"); u32(36 + pcm.count); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        ascii("data"); u32(pcm.count)
        out.append(pcm)
        return out
    }
}

// The initial prompt is the one lever openai/whisper documents for names and
// mixed-language terms, and on the user's own audio a plain list of terms cut
// the error rate from 10.7% to 8.0%. Terms only help if they are in the list,
// so harvest them from what the user typed as "what I said" in saved examples.
enum VocabularyHarvest {
    /// Latin words, dotted names (main.swift), and letter+digit codes (F18) that
    /// appear in `expected` but not yet in the hint. Order of first appearance.
    static func candidates(expected: String, existingHint: String) -> [String] {
        let known = Set(existingHint.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var seen = Set<String>(), out: [String] = []
        for raw in expected.split(whereSeparator: { $0.isWhitespace }) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?()[]\"'"))
            guard token.count >= 2, token.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) else { continue }
            guard token.unicodeScalars.allSatisfy({ $0.isASCII }) else { continue }   // pure Latin/digit tokens only, Thai stays out
            let key = token.lowercased()
            guard !known.contains(key), seen.insert(key).inserted else { continue }
            out.append(token)
        }
        return out
    }
    static func candidates(examples: [[String: String]], existingHint: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for e in examples {
            for c in candidates(expected: e["expected"] ?? "", existingHint: existingHint) where seen.insert(c.lowercased()).inserted { out.append(c) }
        }
        return out
    }
}

// The accurate model is 1.08 GB and is not bundled; a fresh install downloads it
// once, verifies the checksum, and only then moves it into place. Anything that
// fails verification is deleted so the app can never load a corrupt file.
struct ModelDownload {
    let name: String
    let url: URL
    let bytes: Int64
    let sha256: String
    static let largeV3Q5 = ModelDownload(
        name: "large-v3-q5_0",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin")!,
        bytes: 1_081_140_203,
        sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1")
    var fileName: String { "ggml-\(name).bin" }
    static func progressLabel(received: Int64, total: Int64) -> String {
        guard total > 0 else { return String(format: "%.0f MB", Double(received) / 1e6) }
        return String(format: "%.0f / %.0f MB · %d%%", Double(received) / 1e6, Double(total) / 1e6, Int(Double(received) * 100 / Double(total)))
    }
}

// MARK: - Critter: the corner character. Pure state and rules; AppKit/SwiftUI draw it.
// Units are points on screen with y pointing down. Everything that tunes the feel is
// expressed relative to the body radius so the same numbers work at 44 px and 24 px.
enum Critter {
    enum Mood: String, CaseIterable {
        case normal, bored, thinking, sleepy, asleep, curious, happy, done, shy, sad, wow, startled, worried, dizzy, peek, cold, listening, annoyed, bye, back
        case hungry, sulky, loved, laugh, full, hot, zen, pant, groove
    }
    struct Eye: Equatable {
        var w: Double, h: Double, r: Double, dx: Double, dy: Double
        static func lerp(_ a: Eye, _ b: Eye, _ k: Double) -> Eye {
            Eye(w: a.w + (b.w - a.w) * k, h: a.h + (b.h - a.h) * k, r: a.r + (b.r - a.r) * k, dx: a.dx + (b.dx - a.dx) * k, dy: a.dy + (b.dy - a.dy) * k)
        }
    }
    /// One pose. `front` is how far the face turns toward the viewer (0 = the reference
    /// three-quarter pose from the Canva mark, 1 = symmetric, facing you).
    struct Expression {
        var front: Double
        var left: Eye, right: Eye
        var tilt = 0.0, sx = 1.0, sy = 1.0
        var arc = false, blush = false, rings = false, shake = false, wow = false, tear = false, spark = false
        var slowBreath = false, sticky = false
        var says: [String] = []
    }
    static let restLeft = Eye(w: 9, h: 22, r: 22, dx: 0, dy: 0)
    static let restRight = Eye(w: 9, h: 23, r: 22, dx: 0, dy: 0)
    // Emotions that read through symmetry face the viewer; ones that read through gaze direction stay turned.
    static let expressions: [Mood: Expression] = [
        .normal:   Expression(front: 0, left: restLeft, right: restRight),
        .bored:    Expression(front: 0, left: Eye(w: 9, h: 11, r: 22, dx: 0, dy: 3), right: Eye(w: 9, h: 11, r: 22, dx: 0, dy: 7), says: ["......", "-_-", "..."]),
        .thinking: Expression(front: 0.2, left: Eye(w: 9, h: 16, r: 28, dx: 10, dy: -8), right: Eye(w: 9, h: 17, r: 28, dx: 10, dy: -4), says: ["..."]),
        .sleepy:   Expression(front: 0.3, left: Eye(w: 9, h: 5, r: 16, dx: 0, dy: 6), right: Eye(w: 9, h: 5, r: 16, dx: 0, dy: 8), sy: 0.95, slowBreath: true, says: ["zZ", "zzZ"]),
        .asleep:   Expression(front: 0.3, left: Eye(w: 9, h: 3, r: 16, dx: 0, dy: 7), right: Eye(w: 9, h: 3, r: 16, dx: 0, dy: 9), sy: 0.93, slowBreath: true, sticky: true, says: ["z z z"]),
        .curious:  Expression(front: 0.6, left: Eye(w: 9, h: 25, r: -8, dx: 0, dy: -5), right: Eye(w: 9, h: 19, r: 10, dx: 0, dy: 4), tilt: -7, says: ["?", "??", "อืม?"]),
        .happy:    Expression(front: 1, left: restLeft, right: restRight, arc: true, spark: true, says: ["^^", "^_^", "~♪"]),
        .done:     Expression(front: 1, left: restLeft, right: restRight, arc: true, spark: true, says: ["^^", "เสร็จ!"]),
        .shy:      Expression(front: 1, left: Eye(w: 9, h: 14, r: -6, dx: -3, dy: 8), right: Eye(w: 9, h: 14, r: 6, dx: -3, dy: 8), tilt: 4, blush: true, says: ["///", "/////", ">///<"]),
        .sad:      Expression(front: 1, left: Eye(w: 9, h: 15, r: -14, dx: 0, dy: 5), right: Eye(w: 9, h: 15, r: 14, dx: 0, dy: 5), sy: 0.94, tear: true, says: ["TT", "T_T", ";_;"]),
        .wow:      Expression(front: 1, left: Eye(w: 12, h: 27, r: -4, dx: 0, dy: -1), right: Eye(w: 12, h: 28, r: 4, dx: 0, dy: -1), sx: 0.94, sy: 1.08, wow: true, says: ["!", "ว้าว"]),
        .startled: Expression(front: 1, left: Eye(w: 13, h: 28, r: -3, dx: 0, dy: -1), right: Eye(w: 13, h: 29, r: 3, dx: 0, dy: -1), shake: true, says: ["!!"]),
        .worried:  Expression(front: 1, left: Eye(w: 9, h: 19, r: -12, dx: 0, dy: 2), right: Eye(w: 9, h: 19, r: 12, dx: 0, dy: 2), says: ["…?"]),
        .dizzy:    Expression(front: 1, left: Eye(w: 9, h: 14, r: 40, dx: 0, dy: 2), right: Eye(w: 9, h: 14, r: -40, dx: 0, dy: 2), says: ["@_@"]),
        .peek:     Expression(front: 1, left: Eye(w: 9, h: 26, r: -3, dx: 0, dy: -6), right: Eye(w: 9, h: 27, r: 3, dx: 0, dy: -6), sx: 0.9, sy: 1.28, says: ["?"]),
        .cold:     Expression(front: 0.8, left: Eye(w: 9, h: 16, r: -3, dx: 0, dy: 2), right: Eye(w: 9, h: 16, r: 3, dx: 0, dy: 2), shake: true, says: ["brr"]),
        .listening: Expression(front: 1, left: Eye(w: 11, h: 26, r: -4, dx: 0, dy: -2), right: Eye(w: 11, h: 27, r: 4, dx: 0, dy: -2), sx: 0.97, sy: 1.03, rings: true),
        .annoyed:  Expression(front: 1, left: Eye(w: 9, h: 16, r: 34, dx: 0, dy: 1), right: Eye(w: 9, h: 16, r: -34, dx: 0, dy: 1), says: [">_<"]),
        // No hands: the goodbye is a soft smile, a head tilt, and the words.
        .bye:      Expression(front: 1, left: restLeft, right: restRight, tilt: 9, arc: true, says: ["บ๊ายบาย~", "ไปแป๊บ", "เดี๋ยวมา"]),
        .back:     Expression(front: 1, left: restLeft, right: restRight, arc: true, spark: true, says: ["กลับมาแล้ว", "ทาดา~"]),
        // Care: needs read through posture (droop, turn away) and the words.
        .hungry:   Expression(front: 1, left: Eye(w: 9, h: 14, r: -10, dx: 0, dy: 6), right: Eye(w: 9, h: 14, r: 10, dx: 0, dy: 6), sy: 0.95, says: ["กร๊อกกก", "หิว…", "ขอกินหน่อย"]),
        .sulky:    Expression(front: 0, left: Eye(w: 9, h: 12, r: 30, dx: -4, dy: 4), right: Eye(w: 9, h: 12, r: 30, dx: -4, dy: 8), tilt: -5, says: ["หึ", "ไม่คุยด้วย", "..."]),
        .loved:    Expression(front: 1, left: restLeft, right: restRight, arc: true, blush: true, spark: true, says: ["♥", "♥♥", "ชอบ~"]),
        .laugh:    Expression(front: 1, left: restLeft, right: restRight, sx: 1.06, sy: 0.96, arc: true, spark: true, says: ["ฮ่าฮ่าฮ่า!", "555", "ฮ่า~"]),
        .full:     Expression(front: 0.5, left: Eye(w: 9, h: 8, r: 16, dx: 0, dy: 6), right: Eye(w: 9, h: 8, r: 16, dx: 0, dy: 8), sx: 1.1, sy: 1.04, slowBreath: true, says: ["อิ่ม~", "อิ่มจัง"]),
        .hot:      Expression(front: 0.8, left: Eye(w: 9, h: 12, r: -4, dx: 0, dy: 4), right: Eye(w: 9, h: 12, r: 4, dx: 0, dy: 4), sy: 0.97, tear: true, says: ["ร้อนน~", "ฮ่อก ฮ่อก"]),
        .zen:      Expression(front: 1, left: Eye(w: 12, h: 3, r: 90, dx: 0, dy: 2), right: Eye(w: 12, h: 3, r: 90, dx: 0, dy: 2), slowBreath: true, says: ["อืมมม~", "สงบ…"]),
        // Out of breath: half-shut eyes, a sweat drop, and the body heaving (the engine speeds the breath up).
        .pant:     Expression(front: 0.9, left: Eye(w: 10, h: 9, r: -8, dx: 0, dy: 5), right: Eye(w: 10, h: 9, r: 8, dx: 0, dy: 5), sy: 0.94, tear: true, says: ["ฮึบ… ฮึบ…", "หอบ…"]),
        .groove:   Expression(front: 1, left: restLeft, right: restRight, spark: true, says: ["♪", "♪♪", "เต้น~"]),
    ]
    /// Eye anchors in the 120-unit face, sliding from the turned pose to the symmetric one.
    static func anchors(front f: Double) -> (left: (x: Double, y: Double), right: (x: Double, y: Double)) {
        ((39 + (47 - 39) * f, 42 + (52 - 42) * f), (59 + (73 - 59) * f, 48 + (52 - 48) * f))
    }
    /// The body narrows a little half-way through a turn, which is what sells rotation on a flat circle.
    static func turnSqueeze(front f: Double) -> Double { 1 - 0.07 * sin(f * .pi) }

    /// The blended face on screen; approaches the target expression a little every frame.
    struct Face {
        var left = restLeft, right = restRight
        var front = 0.0, tilt = 0.0, sx = 1.0, sy = 1.0
        var blush = 0.0, arc = 0.0, rings = 0.0, shake = 0.0, wow = 0.0, tear = 0.0, spark = 0.0
        mutating func approach(_ e: Expression, breath: Double, extraTilt: Double, k: Double) {
            left = Eye.lerp(left, e.left, k); right = Eye.lerp(right, e.right, k)
            front += (e.front - front) * min(1, k * 0.75)
            tilt += (e.tilt + extraTilt - tilt) * k
            sx += (e.sx - sx) * k; sy += (e.sy + breath - sy) * k
            func on(_ v: Bool) -> Double { v ? 1 : 0 }
            blush += (on(e.blush) * 0.9 - blush) * k
            arc += (on(e.arc) - arc) * min(1, k * 2); rings += (on(e.rings) - rings) * min(1, k * 1.3)
            shake += (on(e.shake) - shake) * min(1, k * 2); wow += (on(e.wow) - wow) * min(1, k * 1.5)
            tear += (on(e.tear) - tear) * min(1, k * 1.3); spark += (on(e.spark) - spark) * min(1, k * 1.5)
        }
    }

    // MARK: physics
    enum Event: Equatable { case landed(Double), wall(Double), ceiling(Double), dizzy, startled, deepArrived, deepReturned }
    struct Body {
        var x: Double, y: Double
        var vx = 0.0, vy = 0.0
        var z = 0.0, zTarget = 0.0
        var squash = 1.0, squashV = 0.0
        var onGround = true
        var zig = 0, pin = 0, dribble = 0, climb = 0
        var anticipation = -1.0, hopHeight = 0.0, hopVx = 0.0
        var deepClock = -1.0
        let radius: Double
        init(x: Double, y: Double, radius: Double) { self.x = x; self.y = y; self.radius = radius }
        /// Everything below was tuned at radius 44; scale keeps the feel at other sizes.
        var unit: Double { radius / 44 }
        var scale: Double { 1 - 0.6 * z }
        var drawRadius: Double { radius * scale }
    }
    struct Area {
        var width: Double, height: Double
        static let standard = Area(width: 260, height: 170)
    }
    /// Floor rises with depth so a far ball sits higher on screen, like a real floor plane.
    static func ground(_ b: Body, in a: Area) -> Double { a.height - b.drawRadius - b.z * 100 * b.unit }
    static func minX(_ b: Body) -> Double { b.drawRadius }
    static func maxX(_ b: Body, in a: Area) -> Double { a.width - b.drawRadius }
    static func ceiling(_ b: Body) -> Double { b.drawRadius }

    static func roll(_ b: inout Body, in a: Area, rng: () -> Double = { Double.random(in: 0..<1) }) {
        let dir: Double = b.x > a.width / 2 ? -1 : 1
        b.vx += dir * (110 + rng() * 120) * b.unit
    }
    static func hop(_ b: inout Body, height: Double, vx: Double = 0) { b.anticipation = 0.11; b.hopHeight = height * b.unit; b.hopVx = vx * b.unit }
    static func dribble(_ b: inout Body) { b.dribble = 5; hop(&b, height: 150) }
    static func throwUp(_ b: inout Body) { hop(&b, height: 700) }
    static func pinball(_ b: inout Body, in a: Area, rng: () -> Double = { Double.random(in: 0..<1) }) {
        b.pin = 7; b.vx = (b.x < a.width / 2 ? 1 : -1) * (420 + rng() * 120) * b.unit; b.vy = -620 * b.unit; b.onGround = false
    }
    static func zigzag(_ b: inout Body, in a: Area, rng: () -> Double = { Double.random(in: 0..<1) }) {
        b.zig = 4; b.vx = (b.x < a.width / 2 ? 1 : -1) * (560 + rng() * 120) * b.unit; b.vy = -220 * b.unit; b.onGround = false
    }
    static func wallClimb(_ b: inout Body, in a: Area) {
        b.climb = 3; let d: Double = b.x < a.width / 2 ? -1 : 1
        b.vx = -d * 260 * b.unit; hop(&b, height: 380, vx: d * 260)
    }
    static func goDeep(_ b: inout Body) { if b.deepClock < 0 { b.deepClock = 0 } }
    static let deepDuration = 6.6
    /// Where the body rests when nothing is happening.
    static func home(in a: Area) -> Double { a.width * 0.68 }

    /// One simulation step. `rng` is injectable so tests are deterministic.
    static func step(_ b: inout Body, in a: Area, dt: Double, rng: () -> Double = { Double.random(in: 0..<1) }) -> [Event] {
        var events: [Event] = []
        let u = b.unit
        // Depth trip: roll away toward the inner corner, wait, roll back.
        if b.deepClock >= 0 {
            b.deepClock += dt
            let far = 70 * u, home = a.width / 2
            if b.deepClock < 2.6 { b.zTarget = 1; b.vx += ((far - b.x) * 1.2 - b.vx) * 0.08 }
            else if b.deepClock < 3.8 { b.zTarget = 1; if b.deepClock - dt < 2.6 { events.append(.deepArrived) } }
            else if b.deepClock < deepDuration { b.zTarget = 0; b.vx += ((home - b.x) * 1.2 - b.vx) * 0.08 }
            else { b.deepClock = -1; b.vx *= 0.5; events.append(.deepReturned) }
        }
        b.z += (b.zTarget - b.z) * min(1, dt * 1.6)
        // Anticipation: the body crouches for 110 ms, then the hop is released.
        if b.anticipation >= 0 {
            b.anticipation -= dt
            let ph = 1 - max(0, b.anticipation) / 0.11
            b.squash = 1 - 0.22 * sin(min(1, ph) * .pi)
            if b.anticipation < 0 { b.vy = -b.hopHeight; b.vx += b.hopVx; b.onGround = false; b.squash = 1.14 }
        }
        b.vy += 1500 * u * dt
        b.x += b.vx * dt; b.y += b.vy * dt
        let g = ground(b, in: a), c = ceiling(b), lo = minX(b), hi = maxX(b, in: a)
        if b.y < c && b.vy < 0 {
            b.y = c
            if b.pin > 0 { b.pin -= 1; b.vy = -b.vy * 0.92; b.squash = 0.82 }
            else { b.vy = -b.vy * 0.7; b.squash = 0.8; if abs(b.vy) > 300 * u { events.append(.startled) } }
            events.append(.ceiling(abs(b.vy)))
        }
        for atWall in [b.x < lo, b.x > hi] where atWall {
            b.x = b.x < lo ? lo : hi
            let speed = abs(b.vx)
            if b.pin > 0 { b.pin -= 1; b.vx = -b.vx * 0.92; b.squash = 0.78; if b.pin == 0 { events.append(.dizzy) } }
            else if b.climb > 0 { b.climb -= 1; b.vx = -b.vx * 0.5; b.vy = -(300 + rng() * 80) * u; b.squash = 0.8 }
            else if b.zig > 0 { b.zig -= 1; b.vx = -b.vx * 0.94; b.vy = -(200 + rng() * 60) * u; b.squash = 0.76; if b.zig == 0 { events.append(.startled) } }
            else { b.vx = -b.vx * 0.6; b.squash = 0.82; if speed > 250 * u { events.append(.startled) } }
            events.append(.wall(speed))
        }
        if b.y >= g {
            b.y = g; b.zig = 0; b.climb = 0
            if !b.onGround && b.vy > 60 * u {
                let v = b.vy
                if b.pin > 0 { b.pin -= 1; b.vy = -v * 0.92; b.squash = 1 - min(0.3, v / (1600 * u)) }
                else {
                    b.squash = 1 - min(0.3, v / (1600 * u)); b.squashV = 0
                    b.vy = -v * 0.55; if abs(b.vy) < 70 * u { b.vy = 0 }
                    if b.dribble > 0 { b.dribble -= 1; b.vy = -(120 + Double(b.dribble) * 45) * u }
                }
                events.append(.landed(v))
            } else { b.vy = 0 }
            b.onGround = b.vy == 0
        } else { b.onGround = false }
        b.vx *= b.onGround ? 0.965 : 0.996
        if abs(b.vx) < 4 * u { b.vx = 0 }
        // Squash returns through a light spring so a landing wobbles instead of snapping.
        b.squashV += (1 - b.squash) * 0.35; b.squashV *= 0.72; b.squash += b.squashV
        return events
    }

    // MARK: scheduling
    enum Move: String, CaseIterable { case roll, hop, dribble, throwUp, pinball, wallClimb, zigzag, peek, shiver, sway, deep }
    struct Scheduler {
        /// 0 quiet, 1 normal, 2 playful — seconds between actions.
        var playfulness = 1
        static let moveGap: [(Double, Double)] = [(7, 14), (3.5, 7.5), (1.8, 4)]
        static let moodGap: [(Double, Double)] = [(9, 18), (4.5, 9.5), (2.5, 5.5)]
        static let moveWeights: [(Move, Double)] = [(.roll, 22), (.hop, 16), (.dribble, 10), (.throwUp, 8), (.pinball, 5), (.wallClimb, 6), (.zigzag, 7), (.peek, 8), (.shiver, 4), (.sway, 8), (.deep, 2)]
        static let deepMinimumGap: Double = 600
        var lastDeepAt: Double = -.greatestFiniteMagnitude
        /// The depth trip is the rarest move: low weight, and never twice within ten minutes.
        func pickMove(_ roll: Double, now: Double) -> Move {
            let m = pickMove(roll)
            return m == .deep && now - lastDeepAt < Scheduler.deepMinimumGap ? .roll : m
        }
        static let moodWeights: [(Mood, Double)] = [(.normal, 40), (.shy, 10), (.curious, 12), (.happy, 10), (.bored, 14), (.sleepy, 8), (.wow, 6)]
        var cartoon = false     // gag reel on: cartoon set pieces join the table
        static func weighted<T>(_ table: [(T, Double)], _ roll: Double) -> T {
            let total = table.reduce(0) { $0 + $1.1 }
            var acc = 0.0
            for (item, w) in table { acc += w; if roll * total < acc { return item } }
            return table[table.count - 1].0
        }
        func nextMoveDelay(_ roll: Double) -> Double { let g = Scheduler.moveGap[max(0, min(2, playfulness))]; return g.0 + (g.1 - g.0) * roll }
        func nextMoodDelay(_ roll: Double) -> Double { let g = Scheduler.moodGap[max(0, min(2, playfulness))]; return g.0 + (g.1 - g.0) * roll }
        func pickMove(_ roll: Double) -> Move { Scheduler.weighted(Scheduler.moveWeights, roll) }
        func pickMood(_ roll: Double) -> Mood { Scheduler.weighted(Scheduler.moodWeights, roll) }
    }
}

// MARK: - Critter scenes: rare set pieces with a fixed timeline. Pure: time in → frame out.
extension Critter {
    enum Scene: String, CaseIterable {
        case inflate, lightning, rainUmbrella, rain, balloon, manhole, sneeze, hiccup
        case eat, read, heartEyes                                    // care
        case eyePop, tornado, pancake, rubber, dash                 // cartoon gags (eyes and body only — no mouth, ever)
        case spinJump, levitate, ghost, shootingStar, box, melt, freeze   // more set pieces, eyes and posture only
        case flood, plane, dance, ninja
        case roadkill, clone, beach, crush
        case snack, pat, chin, skateboard, kite
        case toilet, pingpong, meadow
        case bulb, catWalk, catPlay, football
        var isCartoon: Bool { [.eyePop, .tornado, .pancake, .rubber, .dash].contains(self) }
    }
    struct Offset: Equatable { var x: Double, y: Double }
    struct SceneFrame: Equatable {
        var scale = 1.0          // drawn body size multiplier
        var hidden = false
        var charred = 0.0        // 0 normal … 1 burnt
        var pacifier = 0.0       // baby version after rebirth
        var umbrella = false, rain = false
        var balloon = 0.0        // 0 none … 1 fully inflated on its string
        var bolt = 0.0           // flash intensity this instant
        var smoke = 0.0          // puffs per second
        var lift: Double? = nil  // when set, the body hangs this many radii above the floor (physics off)
        var mood: Mood? = nil
        var burst = false, pop = false, droplets = false
        var snot = 0.0           // runny nose after a sneeze
        var manhole = 0.0        // 0 no cover drawn … 1 cover fully open
        var manholeShown = false
        var sink = 0.0           // fraction of the body that has dropped into the hole
        var prop = false         // draw the engine's prop (food) at the mouth
        var chew = 0.0           // chewing rhythm amplitude
        var book = false, hearts = 0.0
        var eyeScale = 1.0, eyeOut = 0.0, spin = 0.0, flat = 0.0, stretch = 0.0, anvil: Double? = nil, dust = false
        var spinDeg = 0.0        // whole-body rotation (spin jump, trip)
        var hopNow: Double? = nil  // engine hops this high on this tick
        var aura = false, ghost = 0.0, star = 0.0, box = 0.0, ice = 0.0, melt = 0.0, speedLines = 0.0
        var glass = 0.0, pour = false, water = 0.0, bubbles = false      // flood: water level in radii above the floor
        var plane: Offset? = nil, clouds = false                          // plane position relative to the body, in radii
        var disco = false, notes = false
        var bomb = 0.0, smokeCloud = 0.0, door = 0.0, doorOpen = 0.0   // ninja vanish: bomb falls, cloud bursts, a sliding door lets it back in
        var pump = 0.0, pumpStroke = 0.0                                // air pump after the anvil: presence, handle position
        var zebra = false, road = false, carX: Double? = nil, soul = 0.0 // crossings; the car's x in radii; the soul's climb 0…1
        var clones = 0.0, cloneVanish = 0.0, chosen = -1                 // split into four; which one is real (0…3)
        var beach = false, towel = false, bench = false, lookUp = false
        var room = 0.0, roomLift = 0.0, forklift: Double? = nil, toilet = false, newspaper = false
        var table = false, paddleL = 0.0, paddleR = 0.0
        var grass = false
        var xFrac: Double? = nil      // when set, the engine places the body at this fraction of the area width (batted about)
        var depth: Double? = nil      // when set, the body eases into the screen (0 here … 1 far away, small), like the deep roll
        var pin = false               // the engine records where the body stands the first tick this is true (props that stay put)
        var glow = 0.0, lamp = 0.0, lampOn = false, lampFinger = 0.0   // light-bulb scene
        var catFrac: Double? = nil, catRel: Double? = nil, catDir = -1.0, catPaw = 0.0, catMeow = false, catSit = false
        var wall = false          // garden wall with grass and trees along the back; the cat walks along its top
        var goal = false, boot = 0.0, bootSwing = 0.0, netHit = 0.0, confetti = 0.0, missCloud = 0.0, scoreText: String? = nil, inNet = false
        var girl = 0.0            // a girl gluu bot (bob wig, red cheeks) standing at the right of the area
        var bag = 0.0             // snack bag on the floor to the right (shrinks as it is eaten)
        var hand = 0, handPhase = 0.0   // 1 = patting the head from above, 2 = scratching under the chin
        var board = false, kite = 0.0
        var dashX = 0.0          // horizontal offset in radii; the painter draws afterimages behind it
        var driveVx: Double? = nil   // when set, the engine pushes the body sideways this many radii per second
        var say: String? = nil
        var done = false
    }
    static func sceneDuration(_ s: Scene) -> Double {
        switch s {
        case .roadkill: return 9.5; case .clone: return 8.0; case .beach: return 10.5; case .crush: return 7.5
        case .snack: return 10.0; case .pat: return 3.6; case .chin: return 3.6; case .skateboard: return 6.0; case .kite: return 8.5
        case .toilet: return 9.0; case .pingpong: return 7.4; case .meadow: return 9.5
        case .bulb: return 6.5; case .catWalk: return 7.0; case .catPlay: return 10.0; case .football: return 7.8
        case .inflate: return 7.2; case .lightning: return 5.6; case .rainUmbrella, .rain: return 6.5; case .balloon: return 7.5; case .manhole: return 7.6; case .sneeze: return 2.6; case .hiccup: return 2.4
        case .eat: return 5.0; case .read: return 12.0; case .heartEyes: return 2.6
        case .eyePop: return 2.6; case .tornado: return 4.2; case .pancake: return 6.8; case .rubber: return 5.0; case .dash: return 3.6
        case .spinJump: return 2.4; case .levitate: return 6.0; case .ghost: return 4.5; case .shootingStar: return 5.0; case .box: return 6.5; case .melt: return 6.0; case .freeze: return 6.0
        case .flood: return 12.0; case .plane: return 10.5; case .dance: return 8.0; case .ninja: return 7.2 }
    }
    /// The frame for a scene at time `t` (seconds since it started). `say` is set only on the tick that should speak.
    /// `from` is where the body stood (fraction of the area width) when the scene began, for flights that start from there.
    static func sceneFrame(_ s: Scene, t: Double, dt: Double = 1.0 / 60, seed: Int = 0, from: Double = 0.5) -> SceneFrame {
        var f = SceneFrame()
        func at(_ moment: Double) -> Bool { t >= moment && t - dt < moment }
        switch s {
        case .inflate:
            if t < 2.6 { f.scale = 1 + (t / 2.6) * (t / 2.6) * 1.3; f.mood = t < 1.4 ? .wow : .worried; if at(0.05) { f.say = "…?" }; if at(2.0) { f.say = "!!" } }
            else if t < 3.6 { f.hidden = true; if at(2.6) { f.burst = true } }
            else { let g = min(1, (t - 3.6) / 3.0); f.scale = 0.45 + 0.55 * g * g; f.pacifier = max(0, 1 - max(0, g - 0.7) / 0.3); f.mood = g < 0.85 ? .curious : .happy; if at(3.6) { f.say = "อุแว้~" }; if at(6.0) { f.say = "^^" } }
        case .lightning:
            // Strike, char, the soul drifts up and thinks better of it, then the soot wears off.
            if at(0.6) { f.bolt = 1; f.say = "!!" } else if t > 0.6 && t < 0.75 { f.bolt = 1 - (t - 0.6) / 0.15 }
            f.charred = t < 0.6 ? 0 : t < 4.6 ? 1 : max(0, 1 - (t - 4.6) / 0.9)
            f.mood = t < 0.6 ? .normal : t < 4.0 ? .dizzy : .worried
            f.smoke = t > 0.7 && t < 3.0 ? 4 : 0
            f.soul = t < 1.2 ? 0 : t < 4.2 ? (t - 1.2) / 3.0 : 0
            if at(1.4) { f.say = "ลาก่อน…" }; if at(3.3) { f.say = "เอ๊ะ ยังไม่ตาย" }; if at(4.6) { f.say = "@_@" }
        case .rainUmbrella:
            f.rain = t > 0.3 && t < 6.0; f.umbrella = t > 0.8 && t < 6.3
            f.mood = t < 0.8 ? .worried : .normal
            if at(0.3) { f.say = "ฝนมา" }; if at(1.0) { f.say = "~♪" }
        case .rain:
            f.rain = t > 0.3 && t < 6.0
            f.mood = t < 0.6 ? .worried : .cold
            if t > 0.6 && t < 6.0 { f.driveVx = sin((t - 0.6) * 1.6) * 3.2 }   // rolls left and right looking for shelter
            if at(0.3) { f.say = "ฝนมา" }; if at(1.2) { f.say = "TT" }; if at(4.0) { f.say = "brr" }
        case .balloon:
            f.balloon = min(1, t / 0.9)
            if t < 0.9 { f.mood = .curious }
            else if t < 5.4 { let r = (t - 0.9) / 4.5; f.lift = 0.4 + 3.2 * (1 - (1 - r) * (1 - r)); f.mood = .happy; if at(0.9) { f.say = "ลอย~" } }
            else { f.balloon = 0; f.mood = .startled; if at(5.4) { f.pop = true; f.say = "!!" } }
        case .manhole:
            f.manholeShown = true
            let open: Double
            if t < 0.7 { open = t / 0.7 } else if t < 1.3 { open = 1 } else if t < 1.8 { open = 1 - (t - 1.3) / 0.5 }
            else if t < 5.5 { open = 0 } else if t < 6.0 { open = (t - 5.5) / 0.5 } else if t < 6.9 { open = 1 } else { open = max(0, 1 - (t - 6.9) / 0.5) }
            f.manhole = open
            if t < 0.7 { f.mood = .curious; if at(0.05) { f.say = "…?" } }
            else if t < 1.3 { f.sink = (t - 0.7) / 0.6; f.mood = .happy; if at(0.7) { f.say = "โดด!" } }
            else if t < 6.0 { f.hidden = true }
            else if t < 6.9 { f.sink = 1 - (t - 6.0) / 0.6; f.mood = .back; if at(6.0) { f.say = "ทาดา~" } }
            else { f.mood = .happy }
            if f.sink > 0 && f.sink < 1 { f.hidden = false }
        case .sneeze:
            if t < 0.8 { f.scale = 1 + t * 0.12; f.mood = .cold }
            else { f.mood = t < 1.4 ? .startled : .sad; f.snot = min(1, (t - 0.8) / 0.5); if at(0.8) { f.droplets = true; f.say = "ฮัดเช้ย!" }; if at(1.6) { f.say = "ขอทิชชู่…" } }
        case .hiccup:
            f.mood = .normal
            for k in [0.2, 0.9, 1.6] where at(k) { f.pop = true; f.say = "ฮึก" }
        case .eat:
            f.prop = t < 3.8; f.mood = t < 0.5 ? .wow : t < 3.8 ? .happy : .full
            if t >= 0.5 && t < 3.8 { f.chew = 1 }
            if at(0.05) { f.say = "ว้าว อาหาร!" }; if at(1.2) { f.say = "หง่ำ ๆ" }; if at(3.8) { f.say = "อิ่ม~" }
        case .read:
            f.book = t > 0.4 && t < 11.2; f.mood = t < 0.4 ? .curious : t < 11.2 ? .thinking : .happy
            if at(0.4) { f.say = "อ่าน ๆ" }; if at(5.0) { f.say = "อืมม" }; if at(11.2) { f.say = "ฉลาดขึ้น!" }
        case .heartEyes:
            f.hearts = t < 2.2 ? 1 : max(0, 1 - (t - 2.2) / 0.4); f.mood = .loved
            if at(0.05) { f.say = "♥♥" }
        case .eyePop:
            // Gear 5: the eyeballs fly out of the head on their stalks, the body rocks back, speed lines everywhere.
            if t < 0.3 { f.scale = 1 - t * 0.25; f.mood = .curious }
            else if t < 1.9 { let q = min(1, (t - 0.3) / 0.12); f.eyeOut = q; f.speedLines = 1; f.mood = .startled; if at(0.3) { f.say = "!!!"; f.hopNow = 120 } }
            else { let q = max(0, 1 - (t - 1.9) / 0.3); f.eyeOut = q; f.speedLines = q; f.mood = .dizzy; if at(1.9) { f.pop = true } }
        case .tornado:
            if t < 0.4 { f.mood = .startled; f.scale = 1 + t * 0.2 }
            else if t < 3.2 { f.spin = 1; f.dust = true; f.driveVx = sin((t - 0.4) * 2.2) * 4; f.mood = .dizzy; if at(0.4) { f.say = "หวืดดด!" } }
            else { f.mood = .dizzy; if at(3.2) { f.say = "@_@" } }
        case .pancake:
            // Anvil, flat, then an air pump rolls in and pumps it round again in four strokes.
            if t < 0.9 { f.anvil = t / 0.9; f.mood = .worried; if at(0.05) { f.say = "…?" } }
            else if t < 2.6 { f.flat = 1; f.anvil = 1; f.mood = .dizzy; if at(0.9) { f.pop = true; f.say = "แบน…" } }
            else if t < 3.2 { f.flat = 1; f.anvil = 1 - (t - 2.6) / 0.6; f.mood = .dizzy }
            else if t < 3.8 { f.flat = 1; f.pump = (t - 3.2) / 0.6; f.mood = .worried }
            else if t < 6.0 {
                let strokes = [3.8, 4.35, 4.9, 5.45]
                let done = strokes.filter { t >= $0 + 0.3 }.count
                var handle = 0.0
                for k in strokes where t >= k && t < k + 0.55 { let q = (t - k) / 0.55; handle = q < 0.55 ? q / 0.55 : 1 - (q - 0.55) / 0.45 }
                f.pump = 1; f.pumpStroke = handle
                f.flat = max(0, 1 - 0.25 * Double(done)) * (1 - 0.06 * sin(t * 30) * (handle > 0.9 ? 1 : 0))
                f.mood = done < 2 ? .worried : done < 4 ? .curious : .happy
                for k in strokes where at(k + 0.3) { f.pop = true }
                if at(3.8) { f.say = "สูบ ๆ" }; if at(5.75) { f.say = "กลมแล้ว!" }
            }
            else { f.pump = max(0, 1 - (t - 6.0) / 0.5); f.mood = .happy }
        case .rubber:
            // Rubber body: stretches tall and springs; the laugh is in the eyes and the bounce.
            if t < 0.5 { f.mood = .laugh; if at(0.05) { f.say = "ฮ่าฮ่าฮ่า!" } }
            else if t < 3.6 { let q = (t - 0.5) / 3.1; f.stretch = (0.5 + 0.5 * sin((t - 0.5) * 5)) * (1 - q * 0.5); f.mood = .laugh; if at(1.6) { f.say = "ยืดดด~" }; if at(2.8) { f.say = "555" } }
            else { f.mood = .happy }
        case .spinJump:
            if t < 0.3 { f.scale = 1 - t * 0.3; f.mood = .happy }
            else if t < 1.5 { f.spinDeg = 360 * (t - 0.3) / 1.2; f.mood = .happy; if at(0.3) { f.hopNow = 420; f.say = "เย้!" } }
            else { f.mood = .happy }
        case .levitate:
            // Floats up with eyes closed, an aura breathing around it, then settles back down.
            if t < 0.5 { f.mood = .zen }
            else if t < 4.6 { let q = min(1, (t - 0.5) / 1.6); f.lift = 0.2 + 1.3 * q * q * (3 - 2 * q); f.aura = true; f.mood = .zen; if at(0.5) { f.say = "อืมมม~" } }
            else if t < 5.3 { let q = (t - 4.6) / 0.7; f.lift = 1.5 * (1 - q * q); f.mood = .zen }
            else { f.mood = .happy; if at(5.3) { f.say = "สดชื่น" } }
        case .ghost:
            f.ghost = t < 0.8 ? t / 0.8 : t < 2.6 ? 1 : t < 3.4 ? 1 - (t - 2.6) / 0.8 : 0
            if t < 0.8 { f.mood = .normal }
            else if t < 2.6 { f.mood = .startled; if at(0.8) { f.say = "!!!"; f.hopNow = 200 }; if at(1.8) { f.hopNow = 120 } }
            else if t < 3.4 { f.mood = .worried }
            else { f.mood = .curious; if at(3.4) { f.say = "…?" } }
        case .shootingStar:
            f.star = t > 0.6 && t < 2.0 ? (t - 0.6) / 1.4 : 0
            f.mood = t < 0.6 ? .curious : t < 3.6 ? .wow : .happy
            if at(1.0) { f.say = "ดาวตก!" }; if at(3.6) { f.say = "ขอพร~" }
        case .box:
            // A cardboard box drops over it; only the eyes glow through the hole, then it pops out.
            if t < 0.7 { f.box = t / 0.7; f.mood = .startled; if at(0.05) { f.say = "?" } }
            else if t < 4.5 { f.box = 1; f.mood = .peek; if at(1.0) { f.say = "..." } }
            else if t < 5.2 { f.box = 1 - (t - 4.5) / 0.7; f.mood = .happy; if at(4.5) { f.hopNow = 300; f.say = "ทาดา~" } }
            else { f.mood = .happy }
        case .melt:
            if t < 2.5 { f.melt = (t / 2.5) * (t / 2.5); f.mood = .hot; if at(0.1) { f.say = "ร้อน… ละลาย…" } }
            else if t < 4.0 { f.melt = 1; f.mood = .hot }
            else if t < 5.5 { let q = (t - 4.0) / 1.5; f.melt = (1 - q) * (1 - q); f.mood = .dizzy; if at(4.0) { f.pop = true } }
            else { f.mood = .happy; if at(5.5) { f.say = "ฟื้น!" } }
        case .freeze:
            if t < 0.6 { f.ice = t / 0.6; f.mood = .cold; if at(0.05) { f.say = "หนาว…" } }
            else if t < 4.0 { f.ice = 1; f.mood = .startled; if at(0.6) { f.say = "แข็ง…" } }
            else if t < 4.6 { f.ice = 1 - (t - 4.0) / 0.6; f.mood = .cold; if at(4.0) { f.burst = true } }
            else { f.mood = .cold; if at(4.6) { f.say = "brr" } }
        case .flood:
            // A glass tips in from above, the water rises over its head, it sinks, swims up, and pants on dry ground.
            f.glass = t < 0.6 ? t / 0.6 : t < 8.0 ? 1 : max(0, 1 - (t - 8.0) / 0.6)
            f.pour = t >= 0.6 && t < 3.0
            f.water = t < 0.6 ? 0 : t < 3.0 ? (t - 0.6) / 2.4 * 2.4 : t < 7.5 ? 2.4 : t < 9.5 ? 2.4 * (1 - (t - 7.5) / 2.0) : 0
            f.bubbles = t >= 2.4 && t < 7.5
            if t < 0.6 { f.mood = .curious; if at(0.05) { f.say = "…?" } }
            else if t < 1.5 { f.mood = .startled; if at(0.6) { f.say = "!!" } }
            else if t < 5.0 { f.mood = .worried; if at(3.0) { f.say = "จม…" } }
            else if t < 7.5 { let q = (t - 5.0) / 2.5; f.lift = 1.6 * q * q * (3 - 2 * q); f.spinDeg = sin(t * 6) * 10; f.mood = q < 0.6 ? .worried : .happy; if at(5.2) { f.say = "ว่าย ว่าย" } }
            else if t < 9.5 { f.lift = max(0, f.water - 0.8); f.mood = .happy }
            else { f.mood = .pant; if at(9.5) { f.say = "ฮึบ… ฮึบ…" }; if at(11.2) { f.say = "รอด…" } }
        case .plane:
            // Hops onto a passing plane, climbs through the clouds, then jumps and drops all the way down.
            if t < 1.0 { f.plane = Offset(x: -6 + 6 * t, y: 0.6); f.mood = .curious; if at(0.1) { f.say = "เครื่องบิน!" } }
            else if t < 1.4 { f.plane = Offset(x: 0, y: 0.6); f.mood = .happy; if at(1.0) { f.hopNow = 300; f.say = "โดด!" } }
            else if t < 6.0 {
                let q = min(1, (t - 1.4) / 2.6), climb = 3.2 * q * q * (3 - 2 * q)
                f.lift = 0.9 + climb; f.plane = Offset(x: 0, y: 0.9); f.driveVx = 0.5; f.clouds = t > 2.5
                f.mood = t < 3.0 ? .happy : .wow; if at(3.0) { f.say = "เมฆ!" }
            }
            else if t < 8.0 { f.plane = Offset(x: (t - 6.0) * 5, y: 4.1); f.mood = .startled; if at(6.0) { f.hopNow = 140; f.say = "ว้ากกก!" } }
            else if t < 9.5 { f.mood = .dizzy; if at(8.0) { f.say = "@_@" } }
            else { f.mood = .happy; if at(9.5) { f.say = "สนุก!" } }
        case .dance:
            f.disco = true; f.notes = true; f.mood = .groove
            f.driveVx = sin(t * 3.1) * 1.5
            for k in stride(from: 0.5, to: 7.6, by: 0.5) where at(k) { f.hopNow = 90 }
            if t >= 4.0 && t < 4.6 { f.spinDeg = 360 * (t - 4.0) / 0.6 }
            if at(0.2) { f.say = "♪♪" }; if at(3.0) { f.say = "เต้น~" }; if at(6.0) { f.say = "♪" }
        case .ninja:
            // Throws a smoke bomb at its feet, vanishes in the cloud, and later steps back in through a door.
            if t < 0.5 { f.scale = 1 - t * 0.16; f.mood = .curious; if at(0.05) { f.say = "…" } }
            else if t < 0.8 { f.bomb = (t - 0.5) / 0.3; f.mood = .happy }
            else if t < 2.8 { let q = (t - 0.8) / 2.0; f.smokeCloud = q < 0.25 ? q / 0.25 : max(0, 1 - (q - 0.25) / 0.75); f.hidden = t >= 0.9; if at(0.8) { f.say = "หายตัว!"; f.pop = true } }
            else if t < 3.6 { f.hidden = true }
            else if t < 4.2 { f.hidden = true; f.door = (t - 3.6) / 0.6 }
            else if t < 4.8 { f.hidden = true; f.door = 1; f.doorOpen = (t - 4.2) / 0.6 }
            else if t < 5.6 { f.door = 1; f.doorOpen = 1; f.driveVx = 2.4; f.mood = .back; if at(4.8) { f.say = "ทาดา~" } }
            else if t < 6.4 { f.door = 1; f.doorOpen = 1 - (t - 5.6) / 0.8; f.mood = .happy }
            else { f.door = max(0, 1 - (t - 6.4) / 0.6); f.mood = .happy }
        case .roadkill:
            // Rolls onto the road, a car flattens it, the soul floats up… and comes back. Nothing dies here.
            f.road = true
            if t < 1.2 { f.mood = .curious }
            else if t < 3.0 { f.driveVx = 2.2; f.mood = .happy; if at(1.2) { f.say = "ข้าม~" } }
            else if t < 3.5 { f.carX = 9 - (t - 3.0) / 0.5 * 9; f.mood = .startled; if at(3.0) { f.say = "!!!" } }
            else if t < 4.2 { f.carX = -(t - 3.5) / 0.7 * 9; f.flat = 1; f.mood = .dizzy; if at(3.5) { f.pop = true } }
            else if t < 7.8 { f.flat = 1; f.soul = (t - 4.2) / 3.6; f.mood = .dizzy; if at(4.4) { f.say = "ลาก่อน…" }; if at(6.8) { f.say = "ยังไม่ถึงเวลา!" } }
            else if t < 8.6 { let q = (t - 7.8) / 0.8; f.flat = (1 - q) * (1 - q); f.mood = .startled; if at(7.8) { f.pop = true } }
            else { f.mood = .happy; if at(8.6) { f.say = "ฟื้น!" } }
        case .clone:
            // "Split!" — four of it, all sizes; one is chosen at random, the rest vanish ninja-style.
            f.chosen = ((seed % 4) + 4) % 4
            if t < 0.6 { f.scale = 1 - t * 0.2; f.mood = .curious; if at(0.05) { f.say = "แยกร่าง!" } }
            else if t < 1.2 { f.clones = (t - 0.6) / 0.6; f.hidden = true; if at(0.6) { f.pop = true } }
            else if t < 4.5 { f.clones = 1; f.hidden = true; if at(2.0) { f.say = "ตัวไหนตัวจริง?" } }
            else if t < 5.2 { f.clones = 1; f.hidden = true; if at(4.5) { f.say = "ตัวนี้!" } }
            else if t < 6.0 { f.clones = 1; f.cloneVanish = (t - 5.2) / 0.8; f.hidden = true }
            else if t < 6.8 { f.clones = 1 - (t - 6.0) / 0.8; f.cloneVanish = 1; f.hidden = true }
            else { f.mood = .happy; if at(6.8) { f.hopNow = 160; f.say = "ตัวจริง~" } }
        case .crush:
            // Rolls right, meets a girl gluu bot, freezes, blushes, and rolls off the other way.
            f.girl = t < 0.5 ? t / 0.5 : t < 7.0 ? 1 : max(0, 1 - (t - 7.0) / 0.5)
            if t < 1.6 { f.driveVx = 2.2; f.mood = .happy }
            else if t < 2.2 { f.mood = .wow; if at(1.6) { f.say = "!" } }
            else if t < 4.6 { f.mood = .shy; if at(2.2) { f.say = "///" }; if at(3.6) { f.say = ">///<" } }
            else if t < 6.6 { f.driveVx = -3.4; f.mood = .shy; if at(4.6) { f.say = "แง้~" } }
            else { f.mood = .happy; if at(6.6) { f.say = "…เขิน" } }
        case .snack:
            // A snack bag lands nearby; it eats the lot, balloons up, and rolls the weight off again.
            f.bag = t < 0.5 ? t / 0.5 : t < 1.5 ? 1 : t < 3.5 ? max(0, 1 - (t - 1.5) / 2.0) : 0
            if t < 0.5 { f.mood = .curious; if at(0.05) { f.say = "?" } }
            else if t < 1.5 { f.driveVx = 1.6; f.mood = .wow; if at(0.5) { f.say = "ขนม!" } }
            else if t < 3.5 { f.chew = 1; f.mood = .happy; if at(1.6) { f.say = "หง่ำ ๆ" } }
            else if t < 4.5 { let q = (t - 3.5); f.scale = 1 + 0.45 * q; f.mood = .full; if at(3.5) { f.say = "อิ่ม~ ตัวใหญ่เลย" } }
            else if t < 8.5 { let q = (t - 4.5) / 4.0; f.scale = 1.45 - 0.45 * q; f.driveVx = sin((t - 4.5) * 1.6) * 2.4; f.mood = q < 0.5 ? .full : .happy; if at(4.6) { f.say = "ออกกำลัง~" } }
            else { f.mood = .happy; if at(8.5) { f.say = "ผอมแล้ว!" } }
        case .pat:
            f.hand = 1; f.handPhase = t < 3.0 ? abs(sin(t * 5.2)) : 0
            f.mood = t < 0.5 ? .curious : .loved
            if at(0.6) { f.say = "อือ~" }; if at(2.2) { f.say = "♥" }
        case .chin:
            f.hand = 2; f.handPhase = t < 3.0 ? sin(t * 14) : 0
            f.mood = t < 0.4 ? .curious : .zen
            if at(0.5) { f.say = "อื้อ…" }; if at(2.0) { f.say = "ตรงนั้นแหละ~" }
        case .skateboard:
            f.board = true
            if t < 0.6 { f.mood = .happy; if at(0.05) { f.say = "โย่ว~" } }
            else if t < 5.2 { f.driveVx = 2.6; f.mood = .happy; if t >= 2.4 && t < 3.0 { f.spinDeg = 360 * (t - 2.4) / 0.6 }; if at(2.4) { f.hopNow = 260; f.say = "คิกฟลิป!" } }
            else { f.mood = .happy }
        case .kite:
            f.kite = t < 1.0 ? 0 : t < 3.0 ? (t - 1.0) / 2.0 : t < 7.0 ? 1 : max(0, 1 - (t - 7.0) / 1.2)
            f.mood = t < 1.0 ? .curious : t < 3.0 ? .happy : t < 7.0 ? .wow : .happy
            if at(1.0) { f.say = "ว่าว~" }; if at(4.0) { f.say = "สูงจัง!" }; if at(7.0) { f.say = "เก็บว่าว" }
        case .dash:
            if t < 0.5 { f.mood = .curious; f.stretch = -0.2 * (t / 0.5); if at(0.05) { f.say = "บี๊บ บี๊บ!" } }
            else if t < 0.8 { f.dashX = (t - 0.5) / 0.3 * 8; f.dust = true; f.mood = .happy }
            else if t < 2.4 { f.hidden = true }
            else if t < 2.9 { f.dashX = -8 + (t - 2.4) / 0.5 * 8; f.dust = true; f.mood = .happy }
            else { f.mood = .happy; if at(2.9) { f.say = "ทัน!" } }
        case .toilet:
            // Rolls into a portable toilet; a forklift carries the cabin off, revealing it mid-newspaper. Mortified, it bolts.
            f.room = t < 0.4 ? t / 0.4 : t < 7.0 ? 1 : max(0, 1 - (t - 7.0) / 0.5)
            f.pin = t >= 1.3
            if t < 1.3 { f.driveVx = 2.0; f.mood = .curious; if at(0.4) { f.say = "ห้องน้ำ!" } }
            else if t < 3.0 { f.hidden = true }
            else if t < 4.8 { f.hidden = t < 3.6; f.forklift = 7 - (t - 3.0) / 1.8 * 7; f.roomLift = t < 3.6 ? 0 : (t - 3.6) / 1.2; f.toilet = true; f.newspaper = true; f.lift = 0.85; f.mood = .zen; if at(3.6) { f.say = "อ่าน ๆ" } }
            else if t < 5.6 { f.forklift = 0; f.roomLift = 1; f.toilet = true; f.newspaper = t < 5.0; f.mood = .startled; if at(4.8) { f.say = "!!!"; f.hopNow = 220 } }
            else if t < 7.4 { f.forklift = (t - 5.6) / 1.8 * 6; f.roomLift = 1; f.toilet = true; f.driveVx = -3.4; f.mood = .shy; if at(5.6) { f.say = "อ๊ายยย" } }
            else { f.toilet = true; f.mood = .shy; if at(7.4) { f.say = ">///<" } }
        case .pingpong:
            // On the table out of nowhere; two paddles bat it left and right until it has had enough.
            f.table = t < 7.0
            if t < 0.6 { f.lift = 0.9; f.mood = .curious; if at(0.05) { f.say = "?" } }
            else if t < 4.8 {
                // Six slow strokes (0.7 s each) carry it from one end of the table to the other in an arc.
                let k = Int((t - 0.6) / 0.7), phase = (t - 0.6) - Double(k) * 0.7, q = phase / 0.7
                f.lift = 0.9 + 0.7 * sin(q * .pi)
                f.xFrac = k % 2 == 0 ? 0.1 + 0.8 * q : 0.9 - 0.8 * q
                f.paddleL = k % 2 == 0 && phase < 0.2 ? 1 - phase / 0.2 : 0
                f.paddleR = k % 2 == 1 && phase < 0.2 ? 1 - phase / 0.2 : 0
                f.mood = k < 3 ? .startled : .dizzy
                if phase < 1.0 / 60 && k > 0 { f.pop = true }
                if at(0.6) { f.say = "เอ๊ะ!" }; if at(2.0) { f.say = "โอ๊ย" }; if at(3.4) { f.say = "พอ…" }
            }
            else if t < 6.4 { f.lift = 0.9; f.xFrac = 0.5; f.mood = .annoyed; if at(4.8) { f.say = "หยุดได้แล้ว!!" } }
            else { f.mood = .dizzy; if at(6.4) { f.say = "@_@" } }
        case .meadow:
            f.grass = true
            if t < 3.2 { f.driveVx = 0.9; f.mood = .happy; if at(0.2) { f.say = "กลิ้งช้า ๆ~" } }
            else if t < 3.8 { f.mood = .curious }
            else if t < 7.2 { f.driveVx = t < 5.5 ? 4.6 : -4.6; f.mood = .laugh; if at(3.8) { f.say = "กลิ้งเร็ว!!" } }
            else { f.mood = t < 8.4 ? .dizzy : .happy; if at(7.2) { f.say = "@_@" }; if at(8.4) { f.say = "สนุก!" } }
        case .bulb:
            // A finger flicks a wall switch: the body lights up like a bulb, far too bright for its own liking.
            f.lamp = t < 0.5 ? t / 0.5 : t < 6.0 ? 1 : max(0, 1 - (t - 6.0) / 0.5)
            f.lampFinger = t < 0.4 ? 0 : t < 1.0 ? (t - 0.4) / 0.6 : t < 1.6 ? 1 : t < 2.2 ? 1 - (t - 1.6) / 0.6 : t < 4.4 ? 0 : t < 4.8 ? (t - 4.4) / 0.4 : t < 5.2 ? 1 : max(0, 1 - (t - 5.2) / 0.4)
            f.lampOn = t >= 1.0 && t < 4.8
            f.glow = t < 1.0 ? 0 : t < 1.3 ? (t - 1.0) / 0.3 : t < 4.8 ? 1 : max(0, 1 - (t - 4.8) / 0.5)
            f.mood = t < 1.0 ? .curious : t < 1.4 ? .startled : t < 4.8 ? .annoyed : .happy
            if at(0.4) { f.say = "?" }; if at(1.4) { f.say = "มันจ้าาาา ซะเหลือเกิน" }; if at(3.2) { f.say = "ปิดที…" }; if at(4.8) { f.say = "ค่อยยังชั่ว" }
        case .catWalk:
            // An orange tabby strolls past from right to left and says hello.
            f.wall = true
            f.catFrac = 1.15 - t / 7.0 * 1.3; f.catDir = -1
            f.catMeow = t >= 2.6 && t < 4.2
            f.mood = t < 2.4 ? .curious : t < 4.4 ? .happy : .normal
            if at(1.2) { f.say = "แมว!" }; if at(4.4) { f.say = "บ๊ายบาย~" }
        case .catPlay:
            // The cat bats it like a ball, chases it across, bats it back, then sits down pleased with itself.
            if t < 1.2 { f.catRel = 6 - t / 1.2 * 3.6; f.catDir = -1; f.mood = .curious; if at(0.3) { f.say = "?" } }
            else if t < 1.6 { f.catRel = 2.4; f.catDir = -1; f.catPaw = (t - 1.2) / 0.4; f.mood = .startled; if at(1.2) { f.say = "ว้าย!" } }
            else if t < 4.0 { f.driveVx = -4.5; f.catRel = 2.6; f.catDir = -1; f.mood = .dizzy; if at(1.6) { f.pop = true } }
            else if t < 4.4 { f.catRel = -2.4; f.catDir = 1; f.catPaw = (t - 4.0) / 0.4; f.mood = .startled; if at(4.0) { f.say = "อีกแล้ว!" } }
            else if t < 7.0 { f.driveVx = 4.5; f.catRel = -2.6; f.catDir = 1; f.mood = .dizzy; if at(4.4) { f.pop = true } }
            else if t < 8.6 { f.catRel = -2.8; f.catDir = 1; f.catSit = true; f.catMeow = t >= 7.4 && t < 8.4; f.mood = .dizzy; if at(7.0) { f.say = "@_@" } }
            else { f.catRel = -2.8; f.catDir = 1; f.catSit = true; f.mood = .happy; if at(8.6) { f.say = "สนุกดี~" } }
        case .football:
            // A boot kicks it away from us, deep into the screen, toward a far-off goal. Half the time it goes in.
            let scores = ((seed / 4) % 2) == 0
            f.goal = true; f.pin = true   // the leg stays where the kick happened while the body flies
            if t < 1.0 { f.boot = t; f.depth = 0; f.mood = .curious; if at(0.3) { f.say = "…?" } }
            else if t < 1.25 { f.boot = 1; f.bootSwing = (t - 1.0) / 0.25; f.depth = 0; f.mood = .worried }
            else if t < 2.8 {
                let q = (t - 1.25) / 1.55
                f.boot = max(0, 1 - q * 2); f.bootSwing = 1
                f.xFrac = from + (0.76 - from) * q; f.depth = q; f.lift = 1.6 * sin(q * .pi) + 0.05
                f.spinDeg = 720 * q; f.mood = .startled
                if at(1.25) { f.pop = true; f.say = "โอ้ย!!" }
            }
            else if scores {
                f.depth = t < 6.2 ? 1 : max(0, 1 - (t - 6.2) / 1.4); f.inNet = t < 6.2
                if t < 3.6 { f.xFrac = 0.78; f.lift = 0.05; f.netHit = 1 - (t - 2.8) / 0.8; f.mood = .dizzy; if at(2.8) { f.pop = true } }
                else if t < 6.2 { f.xFrac = 0.78; f.mood = .happy; if at(3.6) { f.say = "เข้าาา!" }; if at(5.0) { f.hopNow = 200 } }
                else { f.driveVx = -1.2; f.mood = .happy; if at(6.2) { f.say = "กลับมาแล้ว~" } }
                f.confetti = t < 6.2 ? 1 : max(0, 1 - (t - 6.2) / 0.8)
                f.scoreText = t >= 2.8 && t < 6.2 ? "GOAL!!" : nil
            } else {
                f.depth = t < 3.6 ? 1 - (t - 2.8) / 0.8 * 0.25 : t < 6.2 ? 0.75 : max(0, 0.75 - (t - 6.2) / 1.4 * 0.75)
                if t < 3.6 { f.driveVx = -1.5; f.mood = .dizzy; if at(2.8) { f.pop = true; f.say = "ตึง!" } }
                else if t < 6.2 { f.mood = .sad; if at(3.6) { f.say = "แป้ก…" }; if at(5.2) { f.say = "TT" } }
                else { f.driveVx = -1.2; f.mood = .normal; if at(6.2) { f.say = "…" } }
                f.missCloud = t >= 2.8 && t < 6.2 ? 1 : 0
                f.scoreText = t >= 3.1 && t < 6.2 ? "ไม่เข้า…" : nil
            }
        case .beach:
            f.beach = true
            if t < 2.0 { f.driveVx = t < 0.9 ? 1.6 : 0; f.mood = .happy }
            else if t < 2.8 { f.mood = .wow; if at(2.0) { f.say = "ทะเล!" } }
            else if t < 8.6 { f.bench = true; f.lift = 0.55; f.lookUp = true; f.mood = .normal; if at(2.8) { f.hopNow = 160 }; if at(3.4) { f.say = "อาบแดด~" }; if at(6.5) { f.say = "ฟ้าสวย…" } }
            else if t < 9.4 { f.bench = true; f.mood = .happy; if at(8.6) { f.hopNow = 140 } }
            else { f.mood = .happy; if at(9.4) { f.say = "สดชื่น!" } }
        }
        f.done = t >= sceneDuration(s)
        return f
    }
    /// Which bubbles are allowed. Quiet mode keeps only what marks a real change of state.
    enum BubbleKind { case mood, notice, playfulness, language, listening, thinking, done, scene, care }
    static func allowsBubble(_ kind: BubbleKind, quiet: Bool) -> Bool {
        guard quiet else { return true }
        switch kind { case .playfulness, .language, .listening, .thinking, .done: return true; case .mood, .notice, .scene, .care: return false }
    }
}
extension Critter.Scheduler {
    static let sceneGap: [(Double, Double)] = [(480, 900), (90, 180), (40, 90)]   // quiet / normal / playful — the user found 5–10 min "almost never"
    static let sceneWeights: [(Critter.Scene, Double)] = [(.inflate, 3), (.lightning, 3), (.rainUmbrella, 4), (.rain, 3), (.balloon, 4), (.manhole, 4), (.sneeze, 8), (.hiccup, 8),
                                                            (.spinJump, 6), (.levitate, 3), (.ghost, 3), (.shootingStar, 3), (.box, 3), (.melt, 2), (.freeze, 2), (.flood, 2), (.plane, 2), (.dance, 4), (.ninja, 3), (.roadkill, 2), (.clone, 3), (.beach, 2), (.crush, 3), (.skateboard, 4), (.kite, 3), (.toilet, 2), (.pingpong, 3), (.meadow, 4), (.bulb, 3), (.catWalk, 4), (.catPlay, 3), (.football, 4)]
    static let cartoonWeights: [(Critter.Scene, Double)] = [(.eyePop, 8), (.tornado, 5), (.pancake, 5), (.rubber, 6), (.dash, 6)]
    func nextSceneDelay(_ roll: Double) -> Double { let g = Critter.Scheduler.sceneGap[max(0, min(2, playfulness))]; return (g.0 + (g.1 - g.0) * roll) * (cartoon ? 0.6 : 1) }
    func pickScene(_ roll: Double) -> Critter.Scene { Critter.Scheduler.weighted(cartoon ? Critter.Scheduler.sceneWeights + Critter.Scheduler.cartoonWeights : Critter.Scheduler.sceneWeights, roll) }
    // Weather: a background state that lasts minutes; clear is the common case.
    static let weatherWeights: [(Critter.Weather, Double)] = [(.clear, 40), (.sunny, 14), (.rain, 12), (.wind, 10), (.snow, 8), (.heat, 8)]
    static let weatherLength: (Double, Double) = (180, 480)
    static let weatherGap: (Double, Double) = (600, 1500)
    func pickWeather(_ roll: Double) -> Critter.Weather { Critter.Scheduler.weighted(Critter.Scheduler.weatherWeights, roll) }
    static let sunLength: (Double, Double) = (45, 90)   // the sun is a corner ornament; the user found 3–8 min of it too long
    func weatherLength(_ roll: Double, kind: Critter.Weather = .rain) -> Double {
        let g = kind == .sunny || kind == .heat ? Critter.Scheduler.sunLength : Critter.Scheduler.weatherLength
        return g.0 + (g.1 - g.0) * roll
    }
    func nextWeatherDelay(_ roll: Double) -> Double { Critter.Scheduler.weatherGap.0 + (Critter.Scheduler.weatherGap.1 - Critter.Scheduler.weatherGap.0) * roll }
}


// MARK: - Weather and care (Tamagotchi-style bond). Pure rules; the engine keeps time.
extension Critter {
    enum Weather: String, CaseIterable, Codable { case clear, sunny, rain, wind, snow, heat }
    struct Sky: Equatable {
        var kind: Weather = .clear
        var umbrella = false     // rain only: did it bring one this time
        var night = false        // by the clock, independent of the weather roll
        var age = 0.0            // seconds since this weather began (snow piles up with it)
    }
    static func isNight(hour: Int) -> Bool { hour >= 20 || hour < 6 }
    /// How the body feels about the weather; nil when there is nothing to react to.
    static func weatherMood(_ sky: Sky) -> Mood? {
        switch sky.kind {
        case .clear: return nil
        case .sunny: return .happy
        case .rain: return sky.umbrella ? nil : .cold
        case .wind: return .worried
        case .snow: return .cold
        case .heat: return .hot
        }
    }
    static let weatherNames: [Weather: String] = [.clear: "ฟ้าโปร่ง", .sunny: "แดดออก", .rain: "ฝนตก", .wind: "ลมพัด", .snow: "หิมะตก", .heat: "หน้าร้อน"]

    enum Care {
        enum Food: String, CaseIterable, Codable {
            case rice, ramen, cookie, icecream, fish, apple
            var emoji: String { switch self { case .rice: return "🍙"; case .ramen: return "🍜"; case .cookie: return "🍪"; case .icecream: return "🍦"; case .fish: return "🐟"; case .apple: return "🍎" } }
            var name: String { switch self { case .rice: return "ข้าวปั้น"; case .ramen: return "ราเมง"; case .cookie: return "คุกกี้"; case .icecream: return "ไอศกรีม"; case .fish: return "ปลา"; case .apple: return "แอปเปิล" } }
            var fill: Double { switch self { case .ramen: return 38; case .rice: return 30; case .fish: return 28; case .apple: return 18; case .cookie: return 14; case .icecream: return 12 } }
            var fun: Double { switch self { case .icecream, .cookie: return 8; default: return 2 } }
        }
        enum Action: Equatable { case stroke, tease, feed(Food), read, play, dictation, visit, snack, pat, chin, game(Int) }   // game: 1 user won, 0 draw, -1 gluu bot won
        struct State: Codable, Equatable {
            var bond = 0.0, fullness = 70.0, fun = 60.0, energy = 80.0, knowledge = 0.0
            var streakDays = 0, lastVisitDay = -1
            var lastFedAt = -1e9, lastStrokedAt = -1e9, lastReadAt = -1e9, lastPlayedAt = -1e9, lastTickAt = -1.0
            var recentTeases: [Double] = []
            var strokeHeat = 0.0
            var totalFeeds = 0, totalReads = 0, totalStrokes = 0, totalPlays = 0, totalDictations = 0
            var dictationBondToday = 0.0, dictationDay = -1
        }
        struct Outcome: Equatable {
            var accepted = true
            var mood: Mood? = nil
            var scene: Scene? = nil
            var move: Move? = nil
            var say: String? = nil
            var bondGained = 0.0
        }
        static let levelFloors: [Double] = [0, 15, 35, 60, 85]
        static let titles = ["คนแปลกหน้า", "คุ้นเคย", "เพื่อน", "เพื่อนซี้", "ครอบครัว"]
        static func level(_ bond: Double) -> Int { levelFloors.lastIndex { bond >= $0 } ?? 0 }
        static func title(_ bond: Double) -> String { titles[level(bond)] }
        static func day(_ now: Double) -> Int { Int(floor((now + 7 * 3600) / 86400)) }   // Bangkok day boundary
        static func clamp(_ v: Double) -> Double { max(0, min(100, v)) }
        /// Bond grows slower the closer you already are; never past 100.
        static func gain(_ s: inout State, _ amount: Double) -> Double { let g = amount * (1 - s.bond / 130); s.bond = clamp(s.bond + g); return g }

        static func apply(_ a: Action, to s: inout State, now: Double) -> Outcome {
            var o = Outcome()
            switch a {
            case .stroke:
                s.totalStrokes += 1; s.fun = clamp(s.fun + 2)
                if now - s.lastStrokedAt > 15 { o.bondGained = gain(&s, 0.6); s.lastStrokedAt = now }
                s.strokeHeat = min(1.2, s.strokeHeat + 0.18)
                if s.strokeHeat >= 1 { s.strokeHeat = 0; o.scene = .heartEyes } else { o.mood = s.strokeHeat > 0.5 ? .loved : .shy }
            case .tease:
                s.recentTeases = s.recentTeases.filter { now - $0 < 20 } + [now]
                s.fun = clamp(s.fun + 3)
                if s.recentTeases.count > 4 { o.mood = .annoyed; o.say = "พอได้แล้ว!"; s.bond = clamp(s.bond - 0.3); o.accepted = false }
                else { o.bondGained = gain(&s, 0.4); o.mood = .laugh; o.say = ["ฮ่าฮ่า!", "จั๊กจี้!", "เอาอีก!"][s.recentTeases.count % 3] }
            case .feed(let food):
                if s.fullness > 92 { o.accepted = false; o.mood = .full; o.say = "อิ่มแล้ว…"; return o }
                s.totalFeeds += 1; s.fullness = clamp(s.fullness + food.fill); s.fun = clamp(s.fun + food.fun)
                if now - s.lastFedAt > 300 { o.bondGained = gain(&s, 1.5) }
                s.lastFedAt = now; o.scene = .eat
            case .read:
                s.totalReads += 1; s.knowledge = clamp(s.knowledge + 5); s.energy = clamp(s.energy - 5)
                if now - s.lastReadAt > 600 { o.bondGained = gain(&s, 1.2) }
                s.lastReadAt = now; o.scene = .read
            case .play:
                if s.energy < 12 { o.accepted = false; o.mood = .sleepy; o.say = "ง่วง… ขอพักก่อน"; return o }
                s.totalPlays += 1; s.fun = clamp(s.fun + 10); s.energy = clamp(s.energy - 8)
                if now - s.lastPlayedAt > 120 { o.bondGained = gain(&s, 1.0) }
                s.lastPlayedAt = now; o.move = [.pinball, .zigzag, .dribble, .wallClimb][s.totalPlays % 4]; o.mood = .happy; o.say = "เย้!"
            case .snack:
                if s.fullness > 92 { o.accepted = false; o.mood = .full; o.say = "อิ่มแล้ว…"; return o }
                s.totalFeeds += 1; s.fullness = clamp(s.fullness + 22); s.fun = clamp(s.fun + 6)
                if now - s.lastFedAt > 300 { o.bondGained = gain(&s, 1.2) }
                s.lastFedAt = now; o.scene = .snack
            case .pat:
                s.totalStrokes += 1; s.fun = clamp(s.fun + 4)
                if now - s.lastStrokedAt > 15 { o.bondGained = gain(&s, 0.8); s.lastStrokedAt = now }
                o.scene = .pat
            case .chin:
                s.totalStrokes += 1; s.fun = clamp(s.fun + 4)
                if now - s.lastStrokedAt > 15 { o.bondGained = gain(&s, 0.8); s.lastStrokedAt = now }
                o.scene = .chin
            case .game(let result):
                s.totalPlays += 1; s.fun = clamp(s.fun + 6)
                if now - s.lastPlayedAt > 60 { o.bondGained = gain(&s, 0.6) }
                s.lastPlayedAt = now
                o.mood = result > 0 ? .sad : result < 0 ? .laugh : .curious
                o.say = result > 0 ? "แพ้…" : result < 0 ? "ชนะ! 555" : "เสมอ~"
            case .dictation:
                s.totalDictations += 1; s.fun = clamp(s.fun + 1)
                let d = day(now); if d != s.dictationDay { s.dictationDay = d; s.dictationBondToday = 0 }
                if s.dictationBondToday < 6 { o.bondGained = gain(&s, 0.3); s.dictationBondToday += 0.3 }
            case .visit:
                let d = day(now)
                if d != s.lastVisitDay {
                    let gap = s.lastVisitDay < 0 ? 0 : d - s.lastVisitDay
                    s.streakDays = gap == 1 ? s.streakDays + 1 : 1
                    if gap >= 3 && s.bond > 15 { o.mood = .sulky; o.say = "หายไปไหนมา…" } else if s.lastVisitDay >= 0 { o.mood = .happy; o.say = "มาแล้ว!" }
                    o.bondGained = gain(&s, 0.5); s.lastVisitDay = d
                }
            }
            return o
        }
        /// Time passing while the app runs or is closed. Hours in, hunger out. Nothing dies.
        static func decay(_ s: inout State, hours: Double) {
            let h = max(0, min(48, hours))
            s.fullness = clamp(s.fullness - 5 * h); s.fun = clamp(s.fun - 4 * h); s.energy = clamp(s.energy - 2 * h)
            if s.fullness < 20 || s.fun < 15 { s.bond = clamp(s.bond - 0.15 * h) }
            s.strokeHeat = max(0, s.strokeHeat - 0.5 * h)
        }
        static func rest(_ s: inout State, hours: Double) { s.energy = clamp(s.energy + 12 * max(0, hours)) }
        /// What it would ask for right now: a face and the words. Hunger first, then sleep, then play, then a cuddle.
        static func want(_ s: State, now: Double) -> (Mood, String)? {
            if s.fullness < 25 { return (.hungry, ["อยากกินข้าว~", "หิวแล้ว…", "ขออาหารหน่อย"].randomElement()!) }
            if s.energy < 18 { return (.sleepy, "ง่วง… ขอนอนหน่อย") }
            if s.fun < 20 && s.bond > 15 { return (.sulky, ["อยากเล่นด้วย~", "เบื่อ… เล่นกันไหม"].randomElement()!) }
            if s.bond > 10 && now - s.lastStrokedAt > 3 * 3600 { return (.shy, ["อยากให้ลูบ~", "ขอเกาคางหน่อย"].randomElement()!) }
            return nil
        }
        /// The one need that shows on the face right now, if any.
        static func need(_ s: State) -> Mood? {
            if s.fullness < 25 { return .hungry }
            if s.energy < 18 { return .sleepy }
            if s.fun < 20 && s.bond > 15 { return .sulky }
            return nil
        }
    }
}

extension Critter.Care {
    /// Rock-paper-scissors: 0 rock, 1 paper, 2 scissors. Returns 1 when the user wins, -1 when gluu bot wins, 0 for a draw.
    static func rps(user: Int, bot: Int) -> Int { user == bot ? 0 : (user - bot + 3) % 3 == 1 ? 1 : -1 }
    static let rpsEmoji = ["✊", "✋", "✌️"]
}
