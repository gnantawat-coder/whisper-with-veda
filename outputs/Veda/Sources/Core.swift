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
struct DictationShortcut {
    enum Trigger: Hashable { case fn, f18 }
    enum Action: Equatable { case begin, end, toggle }
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
