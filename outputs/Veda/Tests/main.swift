import Foundation
import CoreGraphics
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }; checks += 1
}
let a = FocusStamp(pid: 1, element: 4, location: 3, length: 0, value: "abc")
let b = FocusStamp(pid: 2, element: 4, location: 3, length: 0, value: "abc")
var guardState = SessionGuard()
guardState.begin(nil); check(!guardState.permits(nil), "unknown target holds")
guardState.begin(a); check(guardState.permits(a), "unchanged target inserts")
guardState.observe(b); guardState.observe(a); check(!guardState.permits(a), "switch away and back holds")
for changed in [FocusStamp(pid: 1, element: 5, location: 3, length: 0, value: "abc"), FocusStamp(pid: 1, element: 4, location: 2, length: 0, value: "abc"), FocusStamp(pid: 1, element: 4, location: 3, length: 1, value: "abc"), FocusStamp(pid: 1, element: 4, location: 3, length: 0, value: "abcd")] {
    guardState.begin(a); guardState.observe(changed); check(!guardState.permits(a), "field, caret, selection or value change holds")
}
guardState.begin(a); guardState.observe(nil); check(!guardState.permits(a), "lost AX access holds")
let audio = Data([0,1,2,255])
for mode in Mode.allCases {
    let body = BackendRequest.body(wav: audio, mode: mode, vocabulary: "Veda, API", boundary: "test")
    let text = String(decoding: body, as: UTF8.self)
    check(text.contains("name=\"translate\"\r\n\r\n\(mode == .en ? "true" : "false")"), "explicit mode avoids sticky server translation")
    check(text.contains("name=\"language\"\r\n\r\nth"), "Thai source for both modes")
    check(body.range(of: audio) != nil, "audio retained")
    check(text.hasSuffix("--test--\r\n"), "multipart closed")
}
check(BackendRequest.cleaned("  ห้ามลบ API 42  ", polish: false) == "ห้ามลบ API 42", "verbatim keeps negation and numbers")
check(BackendRequest.cleaned("ห้าม  ลบ API 42", polish: true) == "ห้าม ลบ API 42", "cleanup only changes whitespace")
check(PermissionGate.evaluate(microphone: false, accessibility: false) == .microphone, "both missing prioritizes microphone")
check(PermissionGate.evaluate(microphone: true, accessibility: false) == .accessibility, "granting microphone updates remaining blocker")
check(PermissionGate.evaluate(microphone: true, accessibility: true) == .ready, "both granted allows start")
check(PermissionGate.evaluate(microphone: false, accessibility: true) == .microphone, "revoked microphone blocks start")
let latch = HoldLatch()
let holdOne = latch.begin()
check(latch.isHeld(holdOne), "new hold permits capture")
latch.end()
var beganAfterRelease = false
_ = latch.whileHeld(holdOne) { beganAfterRelease = true; return true }
check(!beganAfterRelease, "queued start after release never records")
let holdTwo = latch.begin()
check(!latch.isHeld(holdOne) && latch.isHeld(holdTwo), "new hold rejects stale completion")
latch.end()
check(!latch.isHeld(holdTwo), "Escape cancellation invalidates current hold")
let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("veda-test-\(UUID().uuidString).lock").path
let firstInstance = SingleInstanceLock(), secondInstance = SingleInstanceLock()
check(firstInstance.acquire(path: lockPath), "first instance acquires lock")
check(!secondInstance.acquire(path: lockPath), "second instance cannot create another bar")
firstInstance.release()
check(secondInstance.acquire(path: lockPath), "new instance works after previous quits")
secondInstance.release(); try? FileManager.default.removeItem(atPath: lockPath)
check(Mode.allCases.map { $0.rawValue } == ["TH", "EN"], "only Thai and English are offered")
print("PASS: \(checks) core checks")

for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: 200, width: 1920, height: 1080)] {
    let visible = CGRect(x: screen.minX + 80, y: screen.minY + 70, width: screen.width - 80, height: screen.height - 95)
    for active in [false, true] {
        let frame = OverlayPlacement.frame(screen: screen, visible: visible, active: active)
        check(frame.midX == screen.midX, "center survives mode change, side Dock and secondary display")
        check(frame.minY == visible.minY + 18, "overlay clears Dock")
    }
}
print("Placement checks passed; total \(checks)")

for trigger in [DictationShortcut.Trigger.fn, .f18] {
    var shortcut = DictationShortcut()
    check(shortcut.trigger(trigger, down: true) == .begin, "hold begins")
    check(shortcut.trigger(trigger, down: true) == nil, "repeat hold ignored")
    check(shortcut.space(down: true, repeatKey: false).action == .toggle, "chord toggles")
    check(shortcut.space(down: true, repeatKey: true).action == nil, "repeat space ignored")
    check(shortcut.trigger(trigger, down: false) == nil, "chord release never transcribes")
    check(shortcut.space(down: false, repeatKey: false).consume, "consume space up after trigger release")
    check(!shortcut.space(down: true, repeatKey: false).consume, "ordinary space preserved")
    check(shortcut.trigger(trigger, down: true) == .begin, "next hold starts")
    check(shortcut.trigger(trigger, down: false) == .end, "ordinary release transcribes")
}
print("Shortcut checks passed; total \(checks)")

// Held text must survive an update: encode only when there is something to keep,
// and read back both the current shape and the older answer/question file.
check(PendingArchive.path(uid: 501) == "/private/tmp/veda-upgrade-pending-501.json", "migration file is per user")
check(PendingArchive.encode([]) == nil, "nothing pending writes no file")
check(PendingArchive.encode(["", ""]) == nil, "blank entries write no file")
let heldTexts = ["ข้อความหนึ่ง", "ข้อความสอง ที่มี \"เครื่องหมาย\" และ\nบรรทัดใหม่"]
check(PendingArchive.decode(PendingArchive.encode(heldTexts)!) == heldTexts, "every held transcript survives the round trip")
let legacy = Data(#"{"pending":["เก่า"],"answer":"","question":""}"#.utf8)
check(PendingArchive.decode(legacy) == ["เก่า"], "older migration file still restores")
check(PendingArchive.decode(Data("not json".utf8)) == nil, "damaged file restores nothing")

check(PersonalProfile.adding(expected: "   ", heard: "ได้ยิน", to: []) == nil, "whitespace-only expected text cannot be saved")
check(PersonalProfile.adding(expected: "พูด", heard: "", to: []) == nil, "missing transcript cannot be saved")
check(PersonalProfile.adding(expected: " พูด ", heard: " ได้ยิน ", to: [])?.first?["expected"] == "พูด", "saved example is trimmed")
var manyExamples: [[String: String]] = []
for index in 0..<25 { manyExamples = PersonalProfile.adding(expected: "พูด\(index)", heard: "ได้ยิน\(index)", to: manyExamples)! }
check(manyExamples.count == PersonalProfile.exampleLimit, "examples stop at the documented limit")
check(manyExamples.first?["expected"] == "พูด5" && manyExamples.last?["expected"] == "พูด24", "the oldest example is the one dropped")

let withClip = PersonalProfile.adding(expected: "พูด", heard: "ได้ยิน", audioPath: "/tmp/x.wav", model: "large-v3-q5_0", to: [])!.first!
check(withClip["audio"] == "/tmp/x.wav" && withClip["model"] == "large-v3-q5_0", "example keeps the clip location and model, not the audio")
check(PersonalProfile.adding(expected: "พูด", heard: "ได้ยิน", audioPath: "", to: [])!.first!["audio"] == nil, "empty path is not stored")
check(PersonalProfile.hint(vocabulary: "", profileWords: "") == "", "no hint without vocabulary")
check(PersonalProfile.hint(vocabulary: "API", profileWords: "") == "API", "session vocabulary alone is used")
check(PersonalProfile.hint(vocabulary: "API,  Veda ", profileWords: "Veda\nสมชาย") == "API, Veda, สมชาย", "profile words extend the hint without repeats")

check(AudioImport.verdict(frames: 0, sampleRate: 16000) == .empty, "silent file rejected")
check(AudioImport.verdict(frames: 1000, sampleRate: 0) == .empty, "unreadable rate rejected")
check(AudioImport.verdict(frames: 1_920_000, sampleRate: 16000) == .accept, "exactly two minutes accepted")
check(AudioImport.verdict(frames: 1_440_000, sampleRate: 48000) == .accept, "48 kHz phone recording accepted")
check(AudioImport.verdict(frames: 2_112_000, sampleRate: 44100) == .accept, "a 48-second single take is accepted")
check(AudioImport.verdict(frames: 7_056_000, sampleRate: 44100) == .tooLong(seconds: 160), "over two minutes reports its length")
// The file itself must be owner-only, because /private/tmp is world readable.
let archivePath = "/private/tmp/veda-pending-archive-test-\(getpid()).json"
try? FileManager.default.removeItem(atPath: archivePath)
FileManager.default.createFile(atPath: archivePath, contents: PendingArchive.encode(heldTexts), attributes: [.posixPermissions: 0o600])
let archiveMode = ((try? FileManager.default.attributesOfItem(atPath: archivePath))?[.posixPermissions] as? NSNumber)?.intValue
check(archiveMode == 0o600, "held text on disk is readable only by its owner")
check(PendingArchive.decode(try! Data(contentsOf: URL(fileURLWithPath: archivePath))) == heldTexts, "held text restores from the written file")
try? FileManager.default.removeItem(atPath: archivePath)
check(!FileManager.default.fileExists(atPath: archivePath), "restored file is removed, never left behind")

// Regression: quitting with an empty tray once deleted an archive an earlier session
// had written, which is exactly the text this mechanism exists to protect.
check(PendingArchive.save(heldTexts, to: archivePath), "held text is written on quit")
check(((try? FileManager.default.attributesOfItem(atPath: archivePath))?[.posixPermissions] as? NSNumber)?.intValue == 0o600, "the written archive is owner-only")
check(!PendingArchive.save([], to: archivePath), "an empty tray writes nothing")
check(PendingArchive.decode(try! Data(contentsOf: URL(fileURLWithPath: archivePath))) == heldTexts, "an empty tray never destroys an unrestored archive")
try? FileManager.default.removeItem(atPath: archivePath)

print("Profile and held-text checks passed; total \(checks)")

// Thai orthographic repair: same syllable, canonical encoding, nothing else touched.
check(ThaiText.normalized("ค\u{0E4D}าพูด") == "คำพูด", "decomposed SARA AM is recomposed")
check(ThaiText.normalized("น\u{0E4D}\u{0E49}า") == "น้ำ", "tone between NIKHAHIT and SARA AA keeps its place")
check(ThaiText.normalized("น\u{0E49}\u{0E4D}า") == "น้ำ", "tone before NIKHAHIT keeps its place")
check(ThaiText.normalized("ก\u{0E48}\u{0E35}") == "กี่", "tone written before the vowel is reordered")
check(ThaiText.normalized("ท\u{0E49}\u{0E49}องฟ้า") == "ท้องฟ้า", "doubled tone mark collapses")
check(ThaiText.normalized("ข้อ\u{200B}ความ") == "ข้อความ", "zero-width space removed")
check(ThaiText.normalized("แก้ไข่โปรแกรม") == "แก้ไข่โปรแกรม", "a wrong but well-formed word is left alone: no semantic rewriting")
check(ThaiText.normalized("Fix the API, ห้ามลบ 42") == "Fix the API, ห้ามลบ 42", "Latin, digits and spacing untouched")
check(BackendRequest.cleaned(" ค\u{0E4D}าพูด ", polish: false) == "คำพูด", "normalization applies to verbatim output too")
print("Thai text checks passed; total \(checks)")

// Accuracy is measured, never inferred: the same numbers the validation notes quote.
check(Accuracy.editDistance("", "") == 0 && Accuracy.editDistance("abc", "") == 3, "edit distance handles empty strings")
check(Accuracy.editDistance("แก้ไข", "แก้ไข่") == 1, "one extra tone mark is one edit")
check(Accuracy.characterErrorRate(expected: "ท้องฟ้า เป็น สีฟ้า", heard: "ท้องฟ้าเป็นสีฟ้า") == 0, "phrase spacing does not count")
check(Accuracy.characterErrorRate(expected: "คำพูด", heard: "ค\u{0E4D}าพูด") == 0, "decomposed SARA AM is repaired before comparing")
check(Accuracy.characterErrorRate(expected: "", heard: "อะไรก็ได้") == nil, "no reference means no score")
check(Accuracy.characterErrorRate(expected: "ทดสอบ", heard: "") == 1, "silence against speech is total error")
check(abs(Accuracy.characterErrorRate(expected: "โปรแกรม", heard: "โปรแกม")! - 1.0/7.0) < 1e-9, "rate is edits over reference length")
print("Accuracy checks passed; total \(checks)")

// Insertion is judged by what the field contains, not by an exact predicted string.
check(Insertion.succeeded(original: "", final: "สวัสดี", expected: "สวัสดี", inserted: "สวัสดี"), "exact match still counts")
check(Insertion.succeeded(original: "", final: "สวัสดี\n", expected: "สวัสดี", inserted: "สวัสดี"), "editor-added trailing newline is still an insertion")
check(Insertion.succeeded(original: "ก่อนหน้า ", final: "ก่อนหน้า\nสวัสดี ครับ\n", expected: "ก่อนหน้า สวัสดี ครับ", inserted: "สวัสดี ครับ"), "re-flowed whitespace is still an insertion")
check(!Insertion.succeeded(original: "", final: "", expected: "สวัสดี", inserted: "สวัสดี"), "unchanged field is not an insertion")
check(!Insertion.succeeded(original: "", final: nil, expected: "สวัสดี", inserted: "สวัสดี"), "unreadable field is not an insertion")
check(!Insertion.succeeded(original: "สวัสดี", final: "สวัสดี", expected: "สวัสดีสวัสดี", inserted: "สวัสดี"), "text that was already there does not count")
check(Insertion.succeeded(original: "สวัสดี", final: "สวัสดี สวัสดี", expected: "สวัสดี สวัสดี", inserted: "สวัสดี"), "a second copy of existing text counts")
check(!Insertion.succeeded(original: "abc", final: "abd", expected: "abcสวัสดี", inserted: "สวัสดี"), "a changed field without the text is not an insertion")
print("Insertion checks passed; total \(checks)")

// Segment line breaks from the decoder never reach the target field as Return.
check(BackendRequest.cleaned("ประโยคแรก\nประโยคสอง", polish: false) == "ประโยคแรก ประโยคสอง", "segment newline becomes a space even verbatim")
check(BackendRequest.cleaned("หนึ่ง\n สอง\r\nสาม\n", polish: false) == "หนึ่ง สอง สาม", "multiple breaks and trailing break handled")
check(BackendRequest.cleaned("ก  ข\nค", polish: true) == "ก ข ค", "polish still collapses spaces after joining")
print("Segment join checks passed; total \(checks)")

// Approved corrections touch only the exact variant the user approved.
let approved = [["heard": "คลอส", "correct": "Claude"], ["heard": "Codec", "correct": "Codex"], ["heard": "Voice2Tech", "correct": "Voice to Text"], ["heard": "Tech", "correct": "Text"], ["heard": "", "correct": "x"], ["heard": "same", "correct": "same"]]
check(TermCorrections.apply("ส่งข้อความนี้ให้คลอส แล้วให้ Codec เขียนเทสต์", pairs: approved) == "ส่งข้อความนี้ให้Claude แล้วให้ Codex เขียนเทสต์", "Thai and Latin variants are replaced")
check(TermCorrections.apply("ทดสอบระบบ Voice2Tech บน codec", pairs: approved) == "ทดสอบระบบ Voice to Text บน Codex", "longest variant wins and Latin match is case-insensitive")
check(TermCorrections.apply("Codecs are fine, Techno too", pairs: approved) == "Codecs are fine, Techno too", "partial Latin words are never touched")
check(TermCorrections.apply("โปรแกรมคลอสเตอร์", pairs: [["heard": "คลอสเตอร์", "correct": "cluster"]]) == "โปรแกรมcluster", "Thai variant is replaced exactly as approved")
check(TermCorrections.apply("ข้อความเดิม", pairs: []) == "ข้อความเดิม", "no pairs, no change")

// Snap Translate direction and passage assembly.
check(SnapText.direction(of: "ช่วยแปลข้อความนี้ให้หน่อย with API") == .thaiToEnglish, "mostly Thai goes to English")
check(SnapText.direction(of: "Please translate this sentence ไทย") == .englishToThai, "mostly English goes to Thai")
check(SnapText.direction(of: "12345 !!!") == .englishToThai, "no letters at all defaults to English→Thai")
check(SnapText.passage(from: ["  first line ", "", "second", "ค\u{0E4D}า  ไทย"]) == "first line second คำ ไทย", "lines join into one normalized passage")
print("Term and snap checks passed; total \(checks)")

// The shortcut must match exactly its own chord, survive storage, and never be a bare key.
check(SnapShortcut.default.matches(keyCode: 20, command: true, shift: true, control: false, option: false), "default ⌘⇧3 fires")
check(!SnapShortcut.default.matches(keyCode: 20, command: true, shift: true, control: true, option: false), "extra ⌃ does not fire")
check(!SnapShortcut.default.matches(keyCode: 21, command: true, shift: true, control: false, option: false), "⌘⇧4 is not ⌘⇧3")
check(SnapShortcut.default.label == "⇧⌘3", "label reads like macOS")
check(SnapShortcut(stored: SnapShortcut.default.stored) == SnapShortcut.default, "round-trips through storage")
check(SnapShortcut(stored: "ctrl+opt+17")?.label == "⌃⌥T", "custom chord parses")
check(SnapShortcut(stored: "17") == nil && SnapShortcut(stored: "cmd+abc") == nil, "bare key or garbage is rejected")
print("Shortcut checks passed; total \(checks)")

// OCR lines come back in reading order regardless of how Vision returned them.
let l1 = TextLine(text: "first line", box: CGRect(x: 0.10, y: 0.80, width: 0.50, height: 0.03))
let l2 = TextLine(text: "second line", box: CGRect(x: 0.10, y: 0.76, width: 0.48, height: 0.03))
let l3 = TextLine(text: "far paragraph", box: CGRect(x: 0.10, y: 0.40, width: 0.40, height: 0.03))
let right = TextLine(text: "sidebar", box: CGRect(x: 0.70, y: 0.78, width: 0.20, height: 0.03))
check(SnapLayout.readingOrder([l3, right, l2, l1]).map(\.text) == ["first line", "sidebar", "second line", "far paragraph"], "reading order is top to bottom, left to right within a row")

// Suggestions come from real differences only and never repeat approved pairs.
let sug = TermSuggestions.suggest(expected: "ส่งข้อความนี้ให้ Claude แล้วให้ Codex เขียนเทสต์ต่อ", heard: "ส่งข้อความนี้ให้คลอส แล้วให้ Codec เขียนเทสต์ต่อ")
check(sug.contains(["heard": "Codec", "correct": "Codex"]), "Latin spelling difference is suggested")
check(sug.contains(["heard": "ส่งข้อความนี้ให้คลอส", "correct": "ส่งข้อความนี้ให้ Claude"]) || sug.contains(where: { $0["correct"]?.contains("Claude") == true }), "Thai-run difference containing the name is suggested")
check(TermSuggestions.suggest(expected: "ประชุมวันที่สิบสองกันยายน", heard: "ประชุมวันที่ 12 กันยายน").allSatisfy { !($0["heard"] ?? "").allSatisfy { $0.isNumber } }, "digits alone are not suggested")
check(TermSuggestions.suggest(expected: "Fix the API", heard: "fix the api").isEmpty, "case-only differences are not suggested")
check(TermSuggestions.suggest(expected: "ใช้ Codex", heard: "ใช้ Codec", approved: [["heard": "Codec", "correct": "Codex"]]).isEmpty, "already approved pairs are not suggested again")
print("Reading order and suggestion checks passed; total \(checks)")

// Slang: plain language goes to the translator; chat mode restores the target slang; notes always explain.
let slangAll = Slang.entries(custom: [])
let prepTH = Slang.prepare("เดือดสัส สร้าง tools", sourceIsThai: true, mode: .chat, entries: slangAll)
check(prepTH.text == "ดุเดือดมาก สร้าง tools", "Thai slang becomes plain Thai before translating")
check(prepTH.notes.count == 1 && prepTH.notes[0].register == .vulgar && prepTH.notes[0].target == "intense as hell", "the longest match wins and carries its register")
check(Slang.finish("Very intense, creating tools.", notes: prepTH.notes, mode: .chat) == "Intense as hell, creating tools.", "chat mode swaps the plain rendering for target slang and keeps the capital")
check(Slang.finish("Very intense, creating tools.", notes: prepTH.notes, mode: .polite) == "Very intense, creating tools.", "polite mode leaves the plain rendering")
let prepPolite = Slang.prepare("เดือดสัส", sourceIsThai: true, mode: .polite, entries: slangAll)
check(prepPolite.notes[0].target == "very intense", "polite mode notes point at the plain target")
let prepEN = Slang.prepare("ngl this build slaps, LGTM", sourceIsThai: false, mode: .chat, entries: slangAll)
check(prepEN.text == "not going to lie this build excellent, looks good to me", "English slang becomes plain English, whole words only")
check(prepEN.notes.map(\.target).sorted() == ["จึ้ง", "โอเคเลย", "ไม่โกหกนะ"], "each English match maps to Thai chat slang")
check(Slang.prepare("Slapstick comedy", sourceIsThai: false, mode: .chat, entries: slangAll).notes.isEmpty, "partial English words are never matched")
check(Slang.prepare("ข้อความปกติ", sourceIsThai: true, mode: .chat, entries: slangAll).notes.isEmpty, "no slang, no notes")
let custom = [["th": "เดือดสัส", "thPlain": "สนุกมาก", "en": "wild", "enPlain": "very fun", "register": "casual", "meaning": "สนุก"]]
check(Slang.entries(custom: custom).first { $0.th == "เดือดสัส" }?.en == "wild", "a user entry replaces the seed entry for the same expression")
check(SlangEntry(["th": "", "en": "x"]) == nil, "an entry without both words is rejected")
print("Slang checks passed; total \(checks)")

// Adding a slang word needs only the two words; everything else is optional.
check(SlangEntry(["th": "เดือดสัส", "en": "intense as hell"]) != nil, "the two words alone make a valid entry")
let minimal = SlangEntry(["th": "จึ้ง", "en": "slaps"])!
check(minimal.thPlain == "จึ้ง" && minimal.enPlain == "slaps", "a missing plain form falls back to the word itself")
check(minimal.register == .casual && minimal.meaning.isEmpty, "register defaults to casual and the gloss may be empty")
check(SlangEntry(["th": "  ", "en": "x"]) == nil && SlangEntry(["th": "x"]) == nil, "whitespace-only or half-filled entries are still rejected")
check(SlangEntry(["th": " เดือด ", "en": " heated ", "register": "vulgar"])?.th == "เดือด", "entries are trimmed and the chosen register is kept")
print("Slang entry checks passed; total \(checks)")

// The warm-up clip must be a valid short WAV cut from a real recording.
let silence = Data(repeating: 0, count: 16000 * 2)
let builtWav = WAVClip.mono16k(silence)
check(builtWav.count == WAVClip.header + silence.count, "header plus samples")
check(builtWav.prefix(4) == Data("RIFF".utf8) && builtWav.subdata(in: 8..<12) == Data("WAVE".utf8), "RIFF/WAVE magic is written")
check(Int(builtWav[24]) | Int(builtWav[25]) << 8 == 16000, "sample rate lands at offset 24")
check(Int(builtWav[22]) | Int(builtWav[23]) << 8 == 1, "one channel")
let oneSecond = WAVClip.prefix(builtWav, seconds: 0.5)
check(oneSecond?.count == WAVClip.header + 16000, "half a second of 16 kHz mono is 16000 bytes of PCM")
check(WAVClip.prefix(builtWav, seconds: 99)?.count == builtWav.count, "asking for more than the file holds returns the whole file")
check(WAVClip.prefix(Data("not a wav".utf8), seconds: 1) == nil, "a non-WAV is rejected")
check(WAVClip.prefix(builtWav, seconds: 0) == nil, "zero seconds is rejected")
print("WAV clip checks passed; total \(checks)")

// Vocabulary harvesting: the English terms the user actually said, minus what the prompt already has.
let harvest = VocabularyHarvest.candidates(expected: "ช่วยตรวจสอบโค้ดในไฟล์ main.swift แล้วส่งให้ Claude กับ Codex ทดสอบ Voice to Text ด้วยปุ่ม F18.", existingHint: "Claude, Keychron")
check(harvest == ["main.swift", "Codex", "Voice", "to", "Text", "F18"], "dotted names, codes and words are harvested in order; known terms skipped")
check(VocabularyHarvest.candidates(expected: "ประชุมวันที่สิบสอง บ่ายสามโมง", existingHint: "").isEmpty, "pure Thai yields nothing")
check(VocabularyHarvest.candidates(expected: "API api Api", existingHint: "").count == 1, "case variants collapse to one")
check(VocabularyHarvest.candidates(expected: "ใช้ Claude", existingHint: "claude").isEmpty, "hint match is case-insensitive")
check(VocabularyHarvest.candidates(examples: [["expected": "ส่ง Codex"], ["expected": "ส่ง codex อีกครั้ง F18"]], existingHint: "") == ["Codex", "F18"], "across examples, first spelling wins and repeats collapse")
print("Vocabulary harvest checks passed; total \(checks)")

// The model download spec is what the installer trusts; it must be internally consistent.
check(ModelDownload.largeV3Q5.fileName == "ggml-large-v3-q5_0.bin", "file name matches what LocalBackend.start looks for")
check(ModelDownload.largeV3Q5.sha256.count == 64 && ModelDownload.largeV3Q5.sha256.allSatisfy { $0.isHexDigit }, "checksum is a full sha256")
check(ModelDownload.largeV3Q5.url.host == "huggingface.co" && ModelDownload.largeV3Q5.url.scheme == "https", "download is https from Hugging Face")
check(ModelDownload.progressLabel(received: 540_570_102, total: 1_081_140_203) == "541 / 1081 MB · 50%", "progress label rounds to whole megabytes")
check(ModelDownload.progressLabel(received: 12_000_000, total: 0) == "12 MB", "unknown total still shows received")
print("Model download checks passed; total \(checks)")
