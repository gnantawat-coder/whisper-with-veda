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
var chord = DictationShortcut()
check(chord.option(down: true) == nil, "Option alone does nothing")
_ = chord.trigger(.fn, down: true)
check(chord.option(down: true) == .playfulness, "Option while Fn is held cycles playfulness")
check(chord.option(down: false) == nil, "Option release is ignored")
check(chord.trigger(.fn, down: false) == nil, "the hold that carried the chord is cancelled, not transcribed")
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

// Critter: the rules that make the corner character move and emote, checked without a screen.
do {
    let area = Critter.Area.standard
    var b = Critter.Body(x: 200, y: 100, radius: 44)
    var landed = false
    for _ in 0..<240 { if Critter.step(&b, in: area, dt: 1.0 / 60, rng: { 0.5 }).contains(where: { if case .landed = $0 { return true } else { return false } }) { landed = true } }
    check(landed && b.onGround && abs(b.y - Critter.ground(b, in: area)) < 0.01, "a dropped body lands and comes to rest on the floor")
    check(b.squash > 0.97 && b.squash < 1.03, "the landing squash springs back to round")

    var w = Critter.Body(x: 200, y: Critter.ground(Critter.Body(x: 0, y: 0, radius: 44), in: area), radius: 44)
    w.vx = 600; var hitWall = false
    for _ in 0..<60 { if Critter.step(&w, in: area, dt: 1.0 / 60, rng: { 0.5 }).contains(where: { if case .wall = $0 { return true } else { return false } }) { hitWall = true } }
    check(hitWall && w.vx < 0 && w.x <= Critter.maxX(w, in: area), "a fast roll bounces back off the wall")
    check(w.x >= Critter.minX(w) && w.x <= Critter.maxX(w, in: area), "the body never leaves the area")

    var zz = Critter.Body(x: 60, y: 100, radius: 44); Critter.zigzag(&zz, in: area, rng: { 0.5 })
    var walls = 0, startled = false
    for _ in 0..<300 { for e in Critter.step(&zz, in: area, dt: 1.0 / 60, rng: { 0.5 }) { if case .wall = e { walls += 1 }; if e == .startled { startled = true } } }
    check(walls >= 4 && startled, "zigzag hits the walls four times and ends startled")

    var d = Critter.Body(x: 60, y: 100, radius: 44); Critter.dribble(&d)
    var bounces = 0
    for _ in 0..<600 { for e in Critter.step(&d, in: area, dt: 1.0 / 60, rng: { 0.5 }) { if case .landed = e { bounces += 1 } } }
    check(bounces >= 5, "a dribble bounces at least five times before resting")

    var deep = Critter.Body(x: 200, y: 100, radius: 44); Critter.goDeep(&deep)
    var maxZ = 0.0, arrived = false, returned = false
    for _ in 0..<(60 * 8) { for e in Critter.step(&deep, in: area, dt: 1.0 / 60, rng: { 0.5 }) { if e == .deepArrived { arrived = true }; if e == .deepReturned { returned = true } }; maxZ = max(maxZ, deep.z) }
    check(arrived && returned && maxZ > 0.9 && deep.z < 0.05, "the depth trip goes all the way in and comes back")
    check(abs(deep.drawRadius - deep.radius) < 2, "back at the front the drawn radius is the real radius")

    var small = Critter.Body(x: 100, y: 50, radius: 24)
    for _ in 0..<240 { _ = Critter.step(&small, in: Critter.Area(width: 260, height: 170), dt: 1.0 / 60, rng: { 0.5 }) }
    check(small.onGround, "the same rules settle at the on-screen radius too")
}
do {
    var face = Critter.Face()
    let target = Critter.expressions[.sad]!
    for _ in 0..<40 { face.approach(target, breath: 0, extraTilt: 0, k: 0.16) }
    check(abs(face.left.r - target.left.r) < 0.5 && abs(face.right.r - target.right.r) < 0.5 && face.front > 0.95 && face.tear > 0.9, "a face converges on the target expression, turning to the front")
    let a0 = Critter.anchors(front: 0), a1 = Critter.anchors(front: 1)
    check(a0.left.x == 39 && a1.left.x == 47 && a1.right.x == 73 && a1.left.y == a1.right.y, "front anchors are symmetric; the rest pose is the reference offset")
    check(abs(Critter.turnSqueeze(front: 0) - 1) < 1e-9 && Critter.turnSqueeze(front: 0.5) < 0.95 && abs(Critter.turnSqueeze(front: 1) - 1) < 1e-9, "the body narrows only mid-turn")
    check(Critter.Mood.allCases.allSatisfy { Critter.expressions[$0] != nil }, "every mood has an expression")
    let fronts = Critter.Mood.allCases.filter { Critter.expressions[$0]!.front >= 1 }
    check(fronts.contains(.happy) && fronts.contains(.sad) && fronts.contains(.shy) && !fronts.contains(.bored) && !fronts.contains(.normal), "symmetry-read emotions face front; gaze-read ones stay turned")
}
do {
    let s = Critter.Scheduler(playfulness: 0), p = Critter.Scheduler(playfulness: 2)
    check(s.nextMoveDelay(0) == 7 && s.nextMoveDelay(1) == 14 && p.nextMoveDelay(0) == 1.8, "quiet waits longer than playful")
    check(s.pickMove(0) == .roll && s.pickMove(0.999) == .deep, "weighted picks cover the whole table")
    var gated = Critter.Scheduler(playfulness: 1); gated.lastDeepAt = 100
    check(gated.pickMove(0.999, now: 400) == .roll && gated.pickMove(0.999, now: 100 + 601) == .deep, "the depth trip waits at least ten minutes between trips")
    check(Critter.Scheduler.moveWeights.first { $0.0 == .deep }!.1 <= 3, "the depth trip is the rarest move")
    check(Critter.expressions[.bye]!.arc && Critter.expressions[.bye]!.tilt > 0 && Critter.expressions[.back]!.spark, "goodbye is a tilted smile, coming back sparkles")
    check(abs(Critter.home(in: Critter.Area.standard) - 176.8) < 0.01, "the rest position sits right of centre, well inside the area")
    var counts: [Critter.Mood: Int] = [:]
    for i in 0..<1000 { counts[s.pickMood(Double(i) / 1000), default: 0] += 1 }
    check((counts[.normal] ?? 0) > 350 && (counts[.wow] ?? 0) < 90, "normal dominates and wow is rare")
    check(Critter.Scheduler(playfulness: 9).nextMoveDelay(0) == 1.8, "out-of-range playfulness clamps")
}
print("Critter checks passed; total \(checks)")

// Scenes are fixed timelines; the moments that matter must land where the design says.
do {
    let inflate = { (t: Double) in Critter.sceneFrame(.inflate, t: t) }
    check(inflate(0.0).scale == 1 && inflate(2.5).scale > 2.1, "the body inflates past double size before it bursts")
    check(inflate(2.6).burst && inflate(3.0).hidden && !inflate(2.7).burst, "it bursts once, then is gone for a second")
    check(inflate(3.7).scale < 0.5 && inflate(3.7).pacifier > 0.99 && inflate(7.1).scale > 0.99 && inflate(7.1).pacifier == 0, "it is reborn small with a pacifier and grows back to full size")
    check(inflate(7.2).done && !inflate(7.1).done, "the scene ends exactly at its duration")
    let strike = Critter.sceneFrame(.lightning, t: 0.6 + 1.0 / 120)
    check(strike.bolt == 1 && strike.charred == 1 && Critter.sceneFrame(.lightning, t: 2.0).smoke > 0 && Critter.sceneFrame(.lightning, t: 5.5).charred < 0.2, "lightning flashes, chars the body, smokes, then heals")
    check(Critter.sceneFrame(.rainUmbrella, t: 3).umbrella && Critter.sceneFrame(.rainUmbrella, t: 3).rain && !Critter.sceneFrame(.rain, t: 3).umbrella && Critter.sceneFrame(.rain, t: 3).mood == .cold, "rain with an umbrella stays dry; without it the body is cold")
    check(Critter.sceneFrame(.rainUmbrella, t: 3).driveVx == nil && Critter.sceneFrame(.rain, t: 1.6).driveVx != nil && Critter.sceneFrame(.rain, t: 1.6).driveVx! > 0 && Critter.sceneFrame(.rain, t: 3.6).driveVx! < 0, "without an umbrella it rolls right, then left")
    let up = Critter.sceneFrame(.balloon, t: 5.0), fall = Critter.sceneFrame(.balloon, t: 5.4 + 1.0 / 120)
    check((up.lift ?? 0) > 3 && up.balloon == 1 && fall.pop && fall.lift == nil && fall.balloon == 0, "the balloon lifts the body up, then pops and lets it fall")
    check(Critter.sceneFrame(.sneeze, t: 0.8 + 1.0 / 120).droplets && Critter.sceneFrame(.sneeze, t: 0.4).scale > 1.03 && Critter.sceneFrame(.sneeze, t: 1.5).snot == 1 && Critter.sceneFrame(.sneeze, t: 0.5).snot == 0, "a sneeze builds up, bursts, then the nose runs")
    let m = { (t: Double) in Critter.sceneFrame(.manhole, t: t) }
    check(m(0.7).manhole == 1 && m(1.0).sink > 0 && m(1.0).sink < 1 && !m(1.0).hidden, "the cover opens and the body drops in")
    check(m(3.0).hidden && m(3.0).manhole == 0 && m(3.0).manholeShown, "the cover is closed and the body gone while underground")
    check(m(6.3).sink < 1 && !m(6.3).hidden && m(7.5).manhole < 0.2 && m(7.5).sink == 0, "it pops back up and the cover closes again")
    check([0.2, 0.9, 1.6].allSatisfy { Critter.sceneFrame(.hiccup, t: $0 + 1.0 / 120).pop }, "hiccups come in three")
    check(Critter.Scene.allCases.allSatisfy { Critter.sceneDuration($0) > 1 }, "every scene has a duration")
    check(Critter.allowsBubble(.language, quiet: true) && Critter.allowsBubble(.thinking, quiet: true) && !Critter.allowsBubble(.mood, quiet: true) && !Critter.allowsBubble(.scene, quiet: true) && Critter.allowsBubble(.mood, quiet: false), "quiet mode keeps only state-change bubbles")
    let sch = Critter.Scheduler(playfulness: 1)
    check(sch.nextSceneDelay(0) == 90 && Critter.Scheduler(playfulness: 0).nextSceneDelay(1) == 900 && Critter.Scheduler(playfulness: 2).nextSceneDelay(0) == 40, "scenes are 1.5–3 min apart normally, rarer when quiet, under 1.5 min when playful")
    check(sch.pickScene(0) == .inflate && sch.pickScene(0.999) == .football, "scene picks span the table")
    let fbG = { (t: Double) in Critter.sceneFrame(.football, t: t, seed: 0, from: 0.3) }, fbM = { (t: Double) in Critter.sceneFrame(.football, t: t, seed: 4, from: 0.3) }
    check(fbG(1.1).bootSwing > 0.3 && fbG(1.25 + 1.0 / 120).pop && fbG(1.25 + 1.0 / 120).say == "โอ้ย!!" && fbG(2.0).xFrac! > 0.5 && (fbG(2.0).lift ?? 0) > 1.5 && (fbG(2.0).depth ?? 0) > 0.4 && (fbG(2.0).depth ?? 0) < 0.6, "the boot swings, it yells, and flies deep toward the far goal")
    check(fbG(3.2).scoreText == "GOAL!!" && fbG(3.2).confetti == 1 && fbG(4.0).mood == .happy && fbG(3.2).netHit > 0 && fbG(4.0).depth == 1 && fbG(4.0).inNet && !fbG(7.0).inNet && fbG(7.7).depth! < 0.1, "seed 0 scores far away: confetti, net wobble, joy, then rolls back to us")
    check(fbM(3.2).scoreText == "ไม่เข้า…" && fbM(3.2).missCloud == 1 && fbM(3.0).driveVx! < 0 && fbM(4.0).mood == .sad && fbM(4.0).depth! < 0.8 && fbM(7.7).depth! < 0.1, "seed 4 misses: bounces off the far post, sad, then comes back")
    check(fbG(1.3).xFrac! > 0.29 && fbG(1.3).xFrac! < 0.35, "the flight starts from where it stood")
    let bl = { (t: Double) in Critter.sceneFrame(.bulb, t: t) }
    check(bl(0.8).lampFinger > 0.5 && !bl(0.8).lampOn && bl(2.0).lampOn && bl(2.0).glow == 1 && bl(2.0).mood == .annoyed && bl(5.5).glow < 0.1 && !bl(5.5).lampOn, "the finger flips the switch, it glows, then the switch goes off")
    check(Critter.sceneFrame(.catWalk, t: 3).wall && Critter.sceneFrame(.toilet, t: 4.2).lift == 0.85, "the cat walks a wall; on the toilet it sits up on the seat")
    check(Critter.sceneFrame(.catWalk, t: 0).catFrac! > 1 && Critter.sceneFrame(.catWalk, t: 6.9).catFrac! < 0 && Critter.sceneFrame(.catWalk, t: 3).catMeow, "the cat crosses right to left and meows in the middle")
    let cp = { (t: Double) in Critter.sceneFrame(.catPlay, t: t) }
    check(cp(1.4).catPaw > 0 && cp(2.5).driveVx! < 0 && cp(4.2).catDir == 1 && cp(5.5).driveVx! > 0 && cp(9).catSit && cp(9).mood == .happy, "batted left, chased, batted back, the cat sits")
    let pp2 = { (t: Double) in Critter.sceneFrame(.pingpong, t: t) }, tl2 = { (t: Double) in Critter.sceneFrame(.toilet, t: t) }
    check(pp2(2.0).xFrac != nil && pp2(0.6 + 0.35).xFrac! > 0.4 && pp2(0.6 + 0.35).xFrac! < 0.6 && pp2(0.6 + 0.69).xFrac! > 0.85 && pp2(0.6 + 1.39).xFrac! < 0.15, "ping-pong carries it end to end of the table each stroke")
    check(tl2(5.0).pin && !tl2(1.0).pin && tl2(8.0).toilet, "the toilet stays where it was, even after it bolts")
    let tl = { (t: Double) in Critter.sceneFrame(.toilet, t: t) }
    check(tl(2.0).hidden && tl(2.0).room == 1 && tl(4.2).forklift != nil && tl(4.2).roomLift > 0.4 && tl(4.2).toilet && tl(4.2).newspaper && tl(4.2).mood == .zen, "inside the cabin, then the forklift lifts it off mid-newspaper")
    check(tl(5.0).mood == .startled && tl(6.0).driveVx! < 0 && tl(6.0).mood == .shy && tl(8.0).room == 0, "startled, bolts left, the cabin is gone")
    let pp = { (t: Double) in Critter.sceneFrame(.pingpong, t: t) }
    check(pp(0.8).table && (pp(0.8).lift ?? 0) > 0.9 && pp(1.15).xFrac! > 0.6 && pp(1.85).xFrac! < 0.4 && pp(1.3 + 1.0 / 120).pop && pp(5.5).mood == .annoyed && !pp(7.0).table && Critter.sceneDuration(.pingpong) < 8, "batted left and right on the table, slower and shorter, until it protests")
    let md = { (t: Double) in Critter.sceneFrame(.meadow, t: t) }
    check(md(1).grass && md(1).driveVx == 0.9 && md(4.5).driveVx == 4.6 && md(6).driveVx == -4.6 && md(9).mood == .happy, "slow roll, then fast both ways")
    check(Critter.sceneFrame(.lightning, t: 2.7).soul > 0.4 && Critter.sceneFrame(.lightning, t: 2.7).soul < 0.6 && Critter.sceneFrame(.lightning, t: 4.3).soul == 0 && Critter.sceneFrame(.lightning, t: 5.5).charred < 0.05, "lightning: the soul flies its loop and is back before the soot wears off")
    let sn = { (t: Double) in Critter.sceneFrame(.snack, t: t) }
    check(sn(1.0).bag == 1 && sn(1.0).driveVx! > 0 && sn(2.5).chew == 1 && sn(2.5).bag < 0.6 && sn(4.4).scale > 1.35 && sn(6.5).scale < 1.3 && sn(6.5).scale > 1.1 && sn(9).scale == 1, "eats the snack, grows, rolls it off")
    check(Critter.sceneFrame(.pat, t: 1).hand == 1 && Critter.sceneFrame(.pat, t: 1).mood == .loved && Critter.sceneFrame(.chin, t: 1).hand == 2 && Critter.sceneFrame(.chin, t: 1).mood == .zen, "pat and chin scratch show the hand and the right face")
    check(Critter.sceneFrame(.skateboard, t: 2.7).spinDeg > 100 && Critter.sceneFrame(.skateboard, t: 2.4 + 1.0 / 120).hopNow != nil && Critter.sceneFrame(.skateboard, t: 4).board, "kickflip mid-ride")
    check(Critter.sceneFrame(.kite, t: 5).kite == 1 && Critter.sceneFrame(.kite, t: 8.4).kite == 0, "the kite goes up and is reeled in")
    check(Critter.Care.rps(user: 0, bot: 2) == 1 && Critter.Care.rps(user: 1, bot: 1) == 0 && Critter.Care.rps(user: 2, bot: 0) == -1 && Critter.Care.rps(user: 1, bot: 0) == 1, "rock beats scissors, paper beats rock, scissors beat paper")
    let cr = { (t: Double) in Critter.sceneFrame(.crush, t: t) }
    check(cr(1).girl == 1 && cr(1).driveVx! > 0 && cr(3).mood == .shy && cr(5).driveVx! < 0 && cr(5).mood == .shy && cr(7.4).girl < 0.3, "meets the girl, blushes, rolls away the other way")
    let pk = { (t: Double) in Critter.sceneFrame(.pancake, t: t) }
    check(pk(3.5).pump > 0.4 && pk(3.5).flat == 1 && pk(4.0).pumpStroke > 0.5 && pk(4.3).flat < 0.8 && pk(4.3).flat > 0.6 && pk(5.9).flat == 0 && pk(6.7).pump < 0.1, "the pump arrives, each stroke rounds it a quarter, then leaves")
    check(Critter.sceneFrame(.ninja, t: 5.0).driveVx != nil && Critter.sceneFrame(.ninja, t: 5.0).hopNow == nil, "it rolls out of the sliding door instead of hopping")
    let rk = { (t: Double) in Critter.sceneFrame(.roadkill, t: t) }
    check(rk(3.2).carX != nil && rk(3.2).carX! > 0 && rk(3.5 + 1.0 / 120).pop && rk(3.8).flat == 1 && rk(3.8).carX! < 0, "the car comes from the right and flattens it")
    check(rk(6.0).soul > 0.45 && rk(6.0).soul < 0.55 && rk(7.7).soul > 0.95 && rk(8.0).soul == 0 && rk(9.0).flat == 0 && rk(9.0).mood == .happy, "the soul flies a full loop, comes back, and it pops back — nothing dies")
    check(Critter.sceneFrame(.clone, t: 3, seed: 6).chosen == 2 && Critter.sceneFrame(.clone, t: 3, seed: -1).chosen == 3 && Critter.sceneFrame(.clone, t: 3).hidden && Critter.sceneFrame(.clone, t: 3).clones == 1 && Critter.sceneFrame(.clone, t: 5.6).cloneVanish > 0 && !Critter.sceneFrame(.clone, t: 7).hidden, "four clones, the chosen one comes from the seed, the rest vanish")
    let bc = { (t: Double) in Critter.sceneFrame(.beach, t: t) }
    check(bc(0.5).beach && bc(0.5).driveVx == 1.6 && bc(1.5).driveVx == 0 && bc(5).bench && bc(5).lookUp && (bc(5).lift ?? 0) > 0.5 && bc(10).lift == nil, "rolls to the beach and lies on the bench looking at the sky")
    check(sch.weatherLength(1, kind: .sunny) == 90 && sch.weatherLength(1, kind: .heat) == 90 && sch.weatherLength(1, kind: .rain) == 480, "sun and heat are short; rain keeps the long range")
    let nj = { (t: Double) in Critter.sceneFrame(.ninja, t: t) }
    check(nj(0.65).bomb > 0.4 && nj(0.65).bomb < 0.6 && !nj(0.65).hidden, "the bomb is mid-fall before the cloud")
    check(nj(1.3).smokeCloud == 1 && nj(1.3).hidden && nj(3.0).hidden && nj(3.0).smokeCloud == 0, "the cloud bursts and it is gone after the smoke clears")
    check(nj(4.5).door == 1 && abs(nj(4.5).doorOpen - 0.5) < 0.01 && nj(4.5).hidden && !nj(5.0).hidden && nj(5.0).driveVx != nil && nj(7.1).door < 0.1, "the door appears, slides open, it rolls out, and the door goes away")
}
print("Scene checks passed; total \(checks)")

// Cartoon gags, weather, and the care rules.
do {
    let pop = Critter.sceneFrame(.eyePop, t: 1.0)
    check(pop.eyeOut == 1 && pop.speedLines == 1 && pop.mood == .startled && Critter.sceneFrame(.eyePop, t: 2.5).eyeOut < 0.1, "eyeballs fly out with speed lines and snap back")
    check(Critter.sceneFrame(.spinJump, t: 0.9).spinDeg > 170 && Critter.sceneFrame(.spinJump, t: 0.9).spinDeg < 190 && Critter.sceneFrame(.spinJump, t: 0.3 + 1.0 / 120).hopNow != nil, "the spin jump hops once and turns a full circle")
    check((Critter.sceneFrame(.levitate, t: 3.0).lift ?? 0) > 1.4 && Critter.sceneFrame(.levitate, t: 3.0).aura && Critter.sceneFrame(.levitate, t: 3.0).mood == .zen && Critter.sceneFrame(.levitate, t: 5.8).lift == nil, "levitation lifts with an aura and eyes closed, then lands")
    check(Critter.sceneFrame(.ghost, t: 1.5).ghost == 1 && Critter.sceneFrame(.ghost, t: 1.5).mood == .startled && Critter.sceneFrame(.ghost, t: 4.0).ghost == 0, "the ghost appears, scares, and fades")
    check(Critter.sceneFrame(.shootingStar, t: 1.3).star > 0.4 && Critter.sceneFrame(.shootingStar, t: 1.3).star < 0.6 && Critter.sceneFrame(.shootingStar, t: 3.0).mood == .wow, "the star crosses mid-way at 1.3 s")
    check(Critter.sceneFrame(.box, t: 2.0).box == 1 && Critter.sceneFrame(.box, t: 2.0).mood == .peek && Critter.sceneFrame(.box, t: 6.0).box == 0, "boxed with eyes peeking, then out")
    check(Critter.sceneFrame(.melt, t: 3.0).melt == 1 && Critter.sceneFrame(.melt, t: 5.9).melt == 0, "melts flat then reforms")
    check(Critter.sceneFrame(.freeze, t: 2.0).ice == 1 && Critter.sceneFrame(.freeze, t: 4.0 + 1.0 / 120).burst && Critter.sceneFrame(.freeze, t: 5.0).ice == 0, "frozen solid, then cracks out")
    check(Critter.Scene.allCases.allSatisfy { sc in stride(from: 0.0, through: Critter.sceneDuration(sc), by: 0.05).allSatisfy { !Critter.sceneFrame(sc, t: $0).hidden || sc == .inflate || sc == .manhole || sc == .dash || sc == .ninja || sc == .clone || sc == .toilet } }, "only inflate, manhole, dash, ninja, clone and toilet ever hide the body")
    let fl = { (t: Double) in Critter.sceneFrame(.flood, t: t) }
    check(fl(2.0).pour && fl(2.0).water > 1 && fl(2.0).water < 2 && fl(4.0).water == 2.4 && fl(4.0).lift == nil && fl(4.0).bubbles, "the glass pours, the water covers it, and it sinks first")
    check((fl(7.4).lift ?? 0) > 1.5 && fl(8.5).water < 2.4 && fl(10.5).mood == .pant && fl(10.5).water == 0 && fl(10.5).glass == 0, "it swims up, the water drains, and it pants on land")
    let ap = { (t: Double) in Critter.sceneFrame(.plane, t: t) }
    check(ap(0.5).plane != nil && ap(0.5).plane!.x < 0 && ap(1.0 + 1.0 / 120).hopNow != nil && (ap(5.0).lift ?? 0) > 3.5 && ap(5.0).clouds && ap(6.0 + 1.0 / 120).lift == nil && ap(7.0).plane!.x > 3 && ap(8.5).mood == .dizzy, "the plane arrives, it hops on, climbs through clouds, jumps, and lands dizzy")
    let dn = { (t: Double) in Critter.sceneFrame(.dance, t: t) }
    check(dn(1.0).disco && dn(1.0).notes && dn(1.0).mood == .groove && dn(0.5 + 1.0 / 120).hopNow != nil && dn(4.3).spinDeg > 100, "dancing: disco floor, note eyes, hops on the beat, one spin")
    let spin = Critter.sceneFrame(.tornado, t: 1.5)
    check(spin.spin == 1 && spin.dust && spin.driveVx != nil && Critter.sceneFrame(.tornado, t: 3.5).spin == 0, "the tornado spins, moves, then stops dizzy")
    check((Critter.sceneFrame(.pancake, t: 0.45).anvil ?? 0) > 0.4 && Critter.sceneFrame(.pancake, t: 2.0).flat == 1 && Critter.sceneFrame(.pancake, t: 6.5).flat < 0.05, "the anvil falls, flattens the body, and it re-inflates")
    check(Critter.sceneFrame(.rubber, t: 1.0).stretch > 0 && Critter.sceneFrame(.rubber, t: 1.0).mood == .laugh && Critter.sceneFrame(.rubber, t: 4.9).stretch == 0, "rubber body stretches while laughing, then relaxes")
    check(Critter.sceneFrame(.dash, t: 0.65).dashX > 3 && Critter.sceneFrame(.dash, t: 1.5).hidden && Critter.sceneFrame(.dash, t: 2.6).dashX < 0 && Critter.sceneFrame(.dash, t: 3.5).dashX == 0, "the dash leaves right, is gone, and returns from the left")
    check(Critter.sceneFrame(.eat, t: 2.0).prop && Critter.sceneFrame(.eat, t: 2.0).chew == 1 && Critter.sceneFrame(.eat, t: 4.5).mood == .full, "eating shows the food, chews, ends full")
    check(Critter.sceneFrame(.read, t: 5).book && Critter.sceneFrame(.read, t: 11.8).mood == .happy, "reading holds the book for most of the scene")
    check(Critter.sceneFrame(.heartEyes, t: 1).hearts == 1 && Critter.sceneFrame(.heartEyes, t: 2.55).hearts < 0.2, "heart eyes fade at the end")
    var sch = Critter.Scheduler(playfulness: 1)
    check(!Critter.Scene.allCases.filter { $0.isCartoon }.contains(sch.pickScene(0.999)), "without cartoon mode the gag reel never plays")
    sch.cartoon = true
    check(sch.pickScene(0.999).isCartoon && sch.nextSceneDelay(1) < 400, "cartoon mode adds the gags and shortens the wait")
    check(sch.pickWeather(0) == .clear && sch.pickWeather(0.999) == .heat && sch.weatherLength(0) == 180 && sch.nextWeatherDelay(1) == 1500, "weather rolls span the table with minute-scale lengths")
    check(Critter.isNight(hour: 22) && Critter.isNight(hour: 3) && !Critter.isNight(hour: 12), "night is 20:00–06:00")
    check(Critter.weatherMood(Critter.Sky(kind: .rain, umbrella: true)) == nil && Critter.weatherMood(Critter.Sky(kind: .rain)) == .cold && Critter.weatherMood(Critter.Sky(kind: .heat)) == .hot, "an umbrella keeps the rain from bothering it; heat is hot")

    typealias Care = Critter.Care
    var st = Care.State(); let t0 = 1_800_000_000.0
    let s1 = Care.apply(.stroke, to: &st, now: t0)
    check(s1.accepted && s1.bondGained > 0.5 && st.totalStrokes == 1 && s1.mood == .shy, "the first stroke bonds and makes it shy")
    let s2 = Care.apply(.stroke, to: &st, now: t0 + 1)
    check(s2.bondGained == 0, "strokes within 15 s do not add bond")
    var heart: Care.Outcome? = nil
    for i in 0..<8 { let o = Care.apply(.stroke, to: &st, now: t0 + Double(i) * 2); if o.scene == .heartEyes { heart = o; break } }
    check(heart != nil && st.strokeHeat == 0, "enough stroking in a row gives heart eyes and resets the heat")
    for i in 0..<4 { _ = Care.apply(.tease, to: &st, now: t0 + 100 + Double(i)) }
    let tooMuch = Care.apply(.tease, to: &st, now: t0 + 105)
    check(!tooMuch.accepted && tooMuch.mood == .annoyed, "a fifth tease inside 20 s is too much")
    var fed = Care.State(fullness: 50)
    let f1 = Care.apply(.feed(.ramen), to: &fed, now: t0)
    check(f1.scene == .eat && fed.fullness == 88 && f1.bondGained > 1, "ramen fills 38 and bonds")
    _ = Care.apply(.feed(.rice), to: &fed, now: t0 + 1)
    let f3 = Care.apply(.feed(.cookie), to: &fed, now: t0 + 2)
    check(!f3.accepted && f3.mood == .full && fed.totalFeeds == 2, "a full stomach refuses food")
    var r = Care.State(); let ro = Care.apply(.read, to: &r, now: t0)
    check(ro.scene == .read && r.knowledge == 5 && r.energy == 75, "reading adds knowledge and costs a little energy")
    var tired = Care.State(energy: 5); let po = Care.apply(.play, to: &tired, now: t0)
    check(!po.accepted && po.mood == .sleepy, "too tired to play")
    var pl = Care.State(); let p1 = Care.apply(.play, to: &pl, now: t0)
    check(p1.accepted && p1.move != nil && pl.fun == 70 && pl.energy == 72, "playing picks a move, adds fun, costs energy")
    var d = Care.State()
    for i in 0..<30 { _ = Care.apply(.dictation, to: &d, now: t0 + Double(i)) }
    check(d.totalDictations == 30 && d.bond > 5 && d.bond < 7, "dictation bond is capped per day (about 6)")
    var v = Care.State(); _ = Care.apply(.visit, to: &v, now: t0)
    let v2 = Care.apply(.visit, to: &v, now: t0 + 86400)
    check(v.streakDays == 2 && v2.mood == .happy, "coming back the next day extends the streak")
    var gone = v; gone.bond = 30; let v3 = Care.apply(.visit, to: &gone, now: t0 + 86400 * 5)
    check(gone.streakDays == 1 && v3.mood == .sulky, "three days away breaks the streak and earns a sulk")
    var dec = Care.State(bond: 50); Care.decay(&dec, hours: 10)
    check(dec.fullness == 20 && dec.fun == 20 && dec.energy == 60 && dec.bond == 50, "ten hours: hungry and bored, bond untouched until neglect")
    Care.decay(&dec, hours: 2)
    check(dec.bond < 50 && dec.bond > 49.5, "neglect wears bond down slowly")
    check(Care.want(Care.State(fullness: 10), now: t0)!.0 == .hungry && Care.want(Care.State(bond: 20, fun: 10), now: t0)!.0 == .sulky && Care.want(Care.State(bond: 20, lastStrokedAt: t0 - 4 * 3600), now: t0)!.0 == .shy && Care.want(Care.State(bond: 20, lastStrokedAt: t0 - 60), now: t0) == nil, "wants: food, then play, then a cuddle after three hours")
    check(Care.need(dec) == .hungry && Care.need(Care.State(bond: 20, fun: 10)) == .sulky && Care.need(Care.State(energy: 10)) == .sleepy && Care.need(Care.State()) == nil, "needs show in a fixed order: hunger, sleep, sulk")
    check(Care.level(0) == 0 && Care.level(15) == 1 && Care.level(84.9) == 3 && Care.level(100) == 4 && Care.title(60) == "เพื่อนซี้", "levels follow the bond floors")
    var big = Care.State(bond: 99); _ = Care.gain(&big, 5)
    check(big.bond <= 100 && big.bond > 99, "bond never passes 100")
    let data = try! JSONEncoder().encode(st); let back = try! JSONDecoder().decode(Care.State.self, from: data)
    check(back == st, "care state round-trips through JSON")
    var g = Care.State(); let go = Care.apply(.game(1), to: &g, now: t0)
    check(go.mood == .sad && g.fun == 66 && go.bondGained > 0 && Care.apply(.game(-1), to: &g, now: t0 + 1).mood == .laugh, "losing makes it sad, winning makes it laugh")
    var sk = Care.State(fullness: 50); let so = Care.apply(.snack, to: &sk, now: t0)
    check(so.scene == .snack && sk.fullness == 72 && Care.apply(.pat, to: &sk, now: t0).scene == .pat && Care.apply(.chin, to: &sk, now: t0).scene == .chin, "snack, pat and chin map to their scenes")
}
do {
    let k = TalkKey(keyCode: 61)
    check(k.isModifier && k.label == "⌥ ขวา" && k.modifierMask == 1 << 19 && TalkKey(stored: k.stored) == k, "a modifier talk key knows its flag and round-trips")
    check(!TalkKey(keyCode: 105).isModifier && TalkKey(keyCode: 105).label == "F13" && TalkKey(keyCode: 105).modifierMask == nil, "F13 is a plain key")
    check(!TalkKey.allowed(63) && !TalkKey.allowed(49) && !TalkKey.allowed(53) && !TalkKey.allowed(57) && TalkKey.allowed(61) && TalkKey.allowed(79), "Fn, Space, Esc and caps lock cannot be the talk key")
    check(TalkKey(stored: "x") == nil && TalkKey(stored: "-1") == nil, "bad stored values are rejected")
    var d = DictationShortcut()
    check(d.trigger(.custom, down: true) == .begin && d.trigger(.custom, down: true) == nil && d.trigger(.custom, down: false) == .end, "the custom key behaves like Fn: begin on press, ignore repeats, end on release")
}
print("Care/weather checks passed; total \(checks)")
