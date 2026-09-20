import AppKit
import SwiftUI
import Combine
import AVFoundation
import ApplicationServices
import Carbon
import UniformTypeIdentifiers
import CryptoKit

final class Target {
    // Diagnostics only: roles and which guard failed, never field contents.
    static var lastRejection: String?
    static var lastRole = "-"
    static var lastInsertFailure: String?
    let element: AXUIElement
    let stamp: FocusStamp
    init(element: AXUIElement, stamp: FocusStamp) { self.element = element; self.stamp = stamp }
    static func capture() -> Target? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.12)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.12)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        if role as? String == "AXSecureTextField" { return nil }
        var primaryRole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &primaryRole)
        let fieldRole = primaryRole as? String ?? "?"
        // Web editors (Electron, browsers) expose editable areas under other roles.
        // Accept any focused element that exposes a caret and a value and lets the
        // selection be replaced; the read-back after insertion still guards it.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        let known = ["AXTextField", "AXTextArea", "AXComboBox"].contains(fieldRole)
        guard known || settable.boolValue else { lastRejection = "role=\(fieldRole) subrole=\(role as? String ?? "-") selectedTextSettable=false"; return nil }
        var rangeValue: CFTypeRef?
        var text: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { lastRejection = "role=\(fieldRole) no selected range"; return nil }
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &text) == .success,
              let string = text as? String else { lastRejection = "role=\(fieldRole) no string value"; return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { lastRejection = "role=\(fieldRole) bad range"; return nil }
        lastRejection = nil; lastRole = fieldRole
        return Target(element: element, stamp: FocusStamp(pid: app.processIdentifier, element: Int(bitPattern: CFHash(element)), location: range.location, length: range.length, value: string))
    }
    @MainActor func insert(_ text: String, verified now: Target?) async -> Bool {
        guard AXIsProcessTrusted(), let now, now.stamp == stamp, CFEqual(now.element, element) else { return false }
        let original = stamp.value as NSString
        guard stamp.location >= 0, stamp.length >= 0,
              stamp.location <= original.length, stamp.length <= original.length - stamp.location else { return false }
        let expected = original.replacingCharacters(in: NSRange(location: stamp.location, length: stamp.length), with: text)
        func value() -> String? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &result) == .success else { return nil }
            return result as? String
        }
        Target.lastInsertFailure = nil
        let setResult = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        try? await Task.sleep(nanoseconds: 100_000_000)
        if Insertion.succeeded(original: stamp.value, final: value(), expected: expected, inserted: text) { return true }
        // Web editors can ignore AXSelectedText. Fall back only when absolutely
        // nothing changed and the original field/caret still owns focus.
        let after = value()
        guard !Task.isCancelled, after == stamp.value else {
            Target.lastInsertFailure = "AXSelectedText rc=\(setResult.rawValue) changed value but not to the expected text (\(after == nil ? "unreadable" : "different"))"; return false
        }
        guard let current = Target.capture(), current.stamp == stamp, CFEqual(current.element, element) else {
            Target.lastInsertFailure = "AXSelectedText rc=\(setResult.rawValue) no-op and focus/caret moved before key fallback"; return false
        }
        // Unicode keyboard input avoids modifying the user's clipboard or sending Return.
        guard let source = CGEventSource(stateID: .privateState) else { Target.lastInsertFailure = "no event source"; return false }
        for character in text {
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == stamp.pid else { return false }
            let units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            units.withUnsafeBufferPointer {
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!)
            }
            down.postToPid(stamp.pid); up.postToPid(stamp.pid)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let final = value()
        if Insertion.succeeded(original: stamp.value, final: final, expected: expected, inserted: text) { return true }
        Target.lastInsertFailure = "key events sent; read-back \(final == nil ? "unreadable" : final == stamp.value ? "unchanged" : "changed but does not contain the text")"
        return false
    }
}

final class TargetWatch {
    var observer: AXObserver?
    var onChange: (() -> Void)?
    func start(_ target: Target?, onChange: @escaping () -> Void) {
        stop(); self.onChange = onChange
        guard let target else { return }
        var result: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            Unmanaged<TargetWatch>.fromOpaque(context).takeUnretainedValue().onChange?()
        }
        guard AXObserverCreate(target.stamp.pid, callback, &result) == .success, let result else { return }
        observer = result
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(result, AXUIElementCreateApplication(target.stamp.pid), kAXFocusedUIElementChangedNotification as CFString, context)
        AXObserverAddNotification(result, target.element, kAXSelectedTextChangedNotification as CFString, context)
        AXObserverAddNotification(result, target.element, kAXValueChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
    }
    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; onChange = nil
    }
    deinit { stop() }
}

final class LocalBackend {
    var process: Process?
    var modelName = "small"
    let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 150
        return URLSession(configuration: c)
    }()
    func start() throws {
        guard process == nil else { return }
        let runtime = Bundle.main.resourceURL!.appendingPathComponent("runtime")
        let executable = runtime.appendingPathComponent("whisper-server")
        // Largest installed model wins. large-v3 was the only one of the three that
        // both kept Thai tone marks and still translated to English; turbo cannot
        // translate. Delete a file from models/ to fall back to the next one.
        let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Veda/models")
        let installed = ["large-v3-q5_0", "large-v3", "medium"].map { ($0, models.appendingPathComponent("ggml-\($0).bin")) }
            .first { FileManager.default.fileExists(atPath: $0.1.path) }
        let (name, model) = installed ?? ("small", runtime.appendingPathComponent("ggml-small.bin"))
        modelName = name
        guard FileManager.default.fileExists(atPath: executable.path), FileManager.default.fileExists(atPath: model.path) else {
            throw NSError(domain: "Veda", code: 1, userInfo: [NSLocalizedDescriptionKey: "ยังไม่มี whisper-server หรือโมเดล — ดู README"])
        }
        let p = Process()
        p.executableURL = executable
        // No "-nt": without timestamp tokens whisper.cpp loses its place at the 30 s
        // window boundary and silently drops the speech just before it (a whole
        // sentence in the user's 37 s recording). Timestamps are ignored by the app.
        p.arguments = ["--host", "127.0.0.1", "--port", "18765", "-m", model.path, "-l", "th", "-t", "4"]
        p.currentDirectoryURL = runtime
        // Whisper logs can contain transcripts. Never persist or pipe them unread.
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); process = p
    }
    func ready() async -> Bool {
        guard process?.isRunning == true else { return false }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18765/health")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["status"] as? String == "ok"
    }
    func transcribe(_ wav: Data, mode: Mode, vocabulary: String, sourceLanguage: String = "th") async throws -> String {
        guard process?.isRunning == true else { throw URLError(.cannotConnectToHost) }
        let boundary = "Veda-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18765/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = BackendRequest.body(wav: wav, mode: mode, vocabulary: vocabulary, boundary: boundary, sourceLanguage: sourceLanguage)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = json["text"] as? String else { throw URLError(.cannotParseResponse) }
        return text
    }
    // After hours of sitting idle the first transcription took 5-6 s in the user's
    // own log while back-to-back ones take ~1.7 s: the weights get evicted. One
    // inference on a second of real speech pulls them back. Silence is useless
    // here — whisper loops on it for over ten seconds.
    func warmUp() async {
        guard process?.isRunning == true,
              let fixture = try? Data(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("runtime/test-jfk.wav")),
              let clip = WAVClip.prefix(fixture, seconds: 1.0) else { return }
        _ = try? await transcribe(clip, mode: .th, vocabulary: "", sourceLanguage: "en")
    }
    func stop() { process?.terminate(); process = nil }
}

final class Model: ObservableObject {
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "TH") ?? .th { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") } }
    @Published var notice: String?
    @Published var overlayVisible = false
    var showOverlayImmediately: (() -> Void)?
    var hideSettingsForDictation: (() -> Void)?
    var processingDeadline: DispatchWorkItem?
    var hideNoticeWork: DispatchWorkItem?
    @Published var phase: Phase = .idle
    @Published var status = "กำลังเตรียมโมเดล…"
    @Published var level: CGFloat = 0
    @Published var ready = false
    @Published var microphoneStatus = "กำลังตรวจ"
    @Published var accessibilityStatus = "กำลังตรวจ"
    @Published var lastEvent = "ยังไม่ได้รับ Fn"
    @Published var lastStage = "เริ่มแอป"
    @Published var needsAttention = false
    @Published var backendCheck = "ยังไม่ได้ตรวจด้วยไฟล์ตัวอย่าง"
    @Published var testingBackend = false
    var permissionTimer: Timer?
    var waitingForPermissions = false
    var accessChanged: (() -> Void)?
    var previousAX: Bool?
    var microphoneAllowed = false
    var accessibilityAllowed = false
    var exclusiveFnReady = false
    @Published var externalF18 = UserDefaults.standard.bool(forKey: "externalF18") {
        didSet { UserDefaults.standard.set(externalF18, forKey: "externalF18") }
    }
    @Published var pending: [String] = []
    var holdReason = "-"
    var snapLast = "-"
    // Corner character vs the classic bar; the character is the default the user asked for.
    @Published var overlayStyle = UserDefaults.standard.string(forKey: "overlayStyle") ?? "character" { didSet { UserDefaults.standard.set(overlayStyle, forKey: "overlayStyle") } }
    @Published var critterPlayfulness = UserDefaults.standard.object(forKey: "critterPlayfulness") as? Int ?? 1 { didSet { UserDefaults.standard.set(critterPlayfulness, forKey: "critterPlayfulness") } }
    @Published var critterReduceMotion = UserDefaults.standard.bool(forKey: "critterReduceMotion") { didSet { UserDefaults.standard.set(critterReduceMotion, forKey: "critterReduceMotion") } }
    let critterCues = PassthroughSubject<CritterCue, Never>()
    var tapLevel = "-"
    @Published var slangMode: Slang.Mode = Slang.Mode(rawValue: UserDefaults.standard.string(forKey: "slangMode") ?? "") ?? .polite { didSet { UserDefaults.standard.set(slangMode.rawValue, forKey: "slangMode") } }
    @Published var slangNotes = UserDefaults.standard.object(forKey: "slangNotes") as? Bool ?? true { didSet { UserDefaults.standard.set(slangNotes, forKey: "slangNotes") } }
    @Published var slangCustom: [[String: String]] = UserDefaults.standard.array(forKey: "slangCustom") as? [[String: String]] ?? [] { didSet { UserDefaults.standard.set(slangCustom, forKey: "slangCustom") } }
    @Published var newSlang: [String: String] = ["register": "casual"]
    func addSlang() {
        guard let entry = SlangEntry(newSlang) else { return }
        slangCustom.removeAll { $0["th"] == entry.th }
        slangCustom.append(entry.dictionary)
        newSlang = ["register": "casual"]
    }
    @Published var snapSpeak = UserDefaults.standard.bool(forKey: "snapSpeak") { didSet { UserDefaults.standard.set(snapSpeak, forKey: "snapSpeak") } }
    @Published var snapShortcut: SnapShortcut = SnapShortcut(stored: UserDefaults.standard.string(forKey: "snapShortcut") ?? "") ?? .default {
        didSet { UserDefaults.standard.set(snapShortcut.stored, forKey: "snapShortcut") }
    }
    @Published var recordingShortcut = false
    private var shortcutMonitor: Any?
    // Next chord pressed while the settings window is key becomes the shortcut.
    func beginRecordingShortcut() {
        guard shortcutMonitor == nil else { return }
        recordingShortcut = true
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 { self.endRecordingShortcut(); return nil }
            let f = e.modifierFlags
            let chord = SnapShortcut(keyCode: Int64(e.keyCode), command: f.contains(.command), shift: f.contains(.shift), control: f.contains(.control), option: f.contains(.option))
            guard chord.hasModifier else { return nil }
            self.snapShortcut = chord; self.endRecordingShortcut(); return nil
        }
    }
    func endRecordingShortcut() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil; recordingShortcut = false
    }
    @Published var profileName = UserDefaults.standard.string(forKey: "profileName") ?? "โปรไฟล์ของฉัน" { didSet { UserDefaults.standard.set(profileName, forKey: "profileName") } }
    @Published var profileWords = UserDefaults.standard.string(forKey: "profileWords") ?? "" { didSet { UserDefaults.standard.set(profileWords, forKey: "profileWords") } }
    @Published var calibrationExpected = ""
    @Published var calibrationHeard = ""
    @Published var calibrationStatus = "กรอกข้อความที่พูดจริง แล้วเลือกไฟล์เสียงสั้น ๆ (เสียงจากมือถือใช้ได้)"
    @Published var examples: [[String: String]] = UserDefaults.standard.array(forKey: "profileExamples") as? [[String: String]] ?? [] {
        didSet { UserDefaults.standard.set(examples, forKey: "profileExamples") }
    }
    // Each pair was approved by the user for one exact recognised spelling.
    @Published var terms: [[String: String]] = UserDefaults.standard.array(forKey: "profileTerms") as? [[String: String]] ?? [] {
        didSet { UserDefaults.standard.set(terms, forKey: "profileTerms") }
    }
    @Published var newTermHeard = ""
    @Published var newTermCorrect = ""
    func approveTerm() {
        let heard = newTermHeard.trimmingCharacters(in: .whitespacesAndNewlines), correct = newTermCorrect.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !correct.isEmpty, heard != correct, terms.count < 50 else { return }
        terms.removeAll { $0["heard"] == heard }
        terms.append(["heard": heard, "correct": correct])
        newTermHeard = ""; newTermCorrect = ""
    }
    var profileHintWords: String { ([profileWords] + terms.compactMap { $0["correct"] }).joined(separator: ", ") }
    func importCalibration() {
        guard phase == .idle, ready, !testingBackend else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]
        picker.allowsMultipleSelection = false
        picker.message = "เลือกไฟล์เสียงพูดไม่เกิน 2 นาที · m4a จากมือถือ, mp3, wav หรือ caf"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        importCalibration(url: url)
    }
    var calibrationAudioPath: String?
    @Published var reevaluating = false
    @Published var reevaluationStatus = ""
    /// Mean character error rate over examples that have a reference and a result.
    var profileCER: Double? {
        let rates = examples.compactMap { Accuracy.characterErrorRate(expected: $0["expected"] ?? "", heard: $0["heard"] ?? "") }
        return rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
    }
    // Runs every saved example whose clip is still where it was through the current
    // model, so a model or setting change is scored instead of assumed.
    func reevaluateExamples() {
        guard phase == .idle, ready, !testingBackend, !reevaluating else { return }
        let indexed = examples.enumerated().filter { FileManager.default.fileExists(atPath: $0.element["audio"] ?? "") }
        guard !indexed.isEmpty else { reevaluationStatus = "ไม่มีตัวอย่างที่ยังหาไฟล์เสียงเจอ"; return }
        reevaluating = true
        let hint = PersonalProfile.hint(vocabulary: vocabulary, profileWords: profileWords)
        Task { @MainActor in
            defer { reevaluating = false; writeDiagnostics() }
            var done = 0, missing = 0
            for (index, example) in indexed {
                reevaluationStatus = "กำลังวัด \(done + 1)/\(indexed.count)…"
                do {
                    let audio = try CalibrationAudio.wav16kMono(from: URL(fileURLWithPath: example["audio"]!))
                    let heard = try await backend.transcribe(audio.wav, mode: .th, vocabulary: hint)
                    guard index < examples.count, examples[index]["expected"] == example["expected"] else { continue }
                    examples[index]["heard"] = BackendRequest.cleaned(heard, polish: false)
                    examples[index]["model"] = backend.modelName
                    done += 1
                } catch { missing += 1 }
            }
            let skipped = examples.count - indexed.count
            reevaluationStatus = "วัดแล้ว \(done) ตัวอย่างด้วย \(backend.modelName)" + (skipped > 0 ? " · ข้าม \(skipped) ที่ไม่มีไฟล์เสียง" : "") + (missing > 0 ? " · อ่านไม่ได้ \(missing)" : "")
        }
    }
    func importCalibration(url: URL) {
        guard phase == .idle, ready, !testingBackend else { return }
        calibrationAudioPath = url.path
        testingBackend = true; calibrationHeard = ""; calibrationStatus = "กำลังแปลงเสียงบนเครื่อง…"
        let hint = PersonalProfile.hint(vocabulary: vocabulary, profileWords: profileWords)
        Task { @MainActor in
            defer { testingBackend = false }
            do {
                let audio = try CalibrationAudio.wav16kMono(from: url)
                calibrationStatus = "กำลังถอดเสียงบนเครื่อง… (\(String(format: "%.1f", audio.seconds)) วินาที)"
                calibrationHeard = try await backend.transcribe(audio.wav, mode: .th, vocabulary: hint)
                calibrationStatus = calibrationHeard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "ถอดเสียงแล้วแต่ไม่ได้ข้อความ ลองไฟล์ที่พูดชัดกว่านี้"
                    : "ตรวจคำที่ผิด แล้วเพิ่มเฉพาะชื่อหรือศัพท์ที่คุณใช้ในช่องคำศัพท์ส่วนตัว"
            } catch {
                calibrationStatus = error.localizedDescription
            }
        }
    }
    func saveCalibration() {
        guard !testingBackend,
              let next = PersonalProfile.adding(expected: calibrationExpected, heard: calibrationHeard, audioPath: calibrationAudioPath, model: backend.modelName, to: examples) else { return }
        examples = next
        calibrationExpected = ""; calibrationHeard = ""; calibrationAudioPath = nil; writeDiagnostics()
        calibrationStatus = "บันทึกตัวอย่างข้อความแล้ว · ไม่ได้เก็บไฟล์เสียงหรือฝึกโมเดลใหม่"
    }
    @Published var vocabulary = UserDefaults.standard.string(forKey: "vocabulary") ?? "" { didSet { UserDefaults.standard.set(vocabulary, forKey: "vocabulary") } }
    let backend = LocalBackend()
    let audio = AudioCapture()
    let holdLatch = HoldLatch()
    let focusQueue = DispatchQueue(label: "local.veda.focus", qos: .userInitiated)
    let diagnosticQueue = DispatchQueue(label: "local.veda.diagnostics", qos: .utility)
    var focusQueryPending = false
    var targetWasChanged = false
    var originPID: pid_t?
    var fnPressedAt: TimeInterval = 0
    var overlayReadyMS: Int?
    var captureReadyMS: Int?
    var target: Target?
    var guardState = SessionGuard()
    let watch = TargetWatch()
    var peakDB: Float = -160
    var timer: Timer?
    var requestTask: Task<Void, Never>?
    var token = UUID()
    var fnDown = false
    var started = Date()
    var heldMode: Mode = .th
    var heldVocabulary = ""
    var settingsAction: (() -> Void)?
    var relaunchAction: (() -> Void)?
    var playgroundAction: (() -> Void)?
    @Published var lastLatency = "ยังไม่มีการทดสอบเสียงจริง"
    func refreshPermissions() {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneAllowed = auth == .authorized
        switch auth {
        case .authorized: microphoneStatus = "อนุญาตแล้ว"
        case .notDetermined: microphoneStatus = "ยังไม่เคยขอ — กดอนุญาตไมโครโฟน"
        case .denied: microphoneStatus = "ถูกปฏิเสธ — เปิด Microphone ใน System Settings"
        case .restricted: microphoneStatus = "ถูกจำกัดโดยระบบ"
        @unknown default: microphoneStatus = "ไม่ทราบสถานะ"
        }
        let ax = AXIsProcessTrusted()
        accessibilityAllowed = ax
        accessibilityStatus = ax ? "อนุญาตแล้ว" : "ยังไม่ได้รับอนุญาตสำหรับแอปที่เปิดอยู่นี้"
        if previousAX != ax { previousAX = ax; accessChanged?() }
        if phase == .idle && waitingForPermissions {
            switch PermissionGate.evaluate(microphone: microphoneAllowed, accessibility: ax) {
            case .microphone:
                status = "ยังไม่เริ่มอัด: Microphone — " + microphoneStatus
            case .accessibility:
                status = "ถอดเสียงได้ · ข้อความจะพักไว้จนอนุญาต Accessibility"
            case .ready:
                waitingForPermissions = false; needsAttention = false
                status = ready ? "พร้อมแล้ว — กลับไปช่องข้อความแล้วกด Fn ค้าง" : "กำลังเตรียมโมเดล…"
            }
            lastStage = waitingForPermissions ? "รอสิทธิ์จาก macOS" : "สิทธิ์ครบแล้ว"
        }
        writeDiagnostics()
    }
    func writeDiagnostics() {
        let d: [String: Any] = ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", "model": backend.modelName, "updatedAt": ISO8601DateFormatter().string(from: Date()), "pid": ProcessInfo.processInfo.processIdentifier, "bundlePath": Bundle.main.bundlePath,
            "exclusiveFnReady": exclusiveFnReady, "microphone": microphoneStatus, "accessibility": accessibilityStatus,
            "overlayDispatchMS": overlayReadyMS ?? -1, "captureReadyMS": captureReadyMS ?? -1, "sessionMode": heldMode.rawValue, "backendCheck": backendCheck, "backendReady": ready, "backendRunning": backend.process?.isRunning == true,
            "phase": String(describing: phase), "lastEvent": lastEvent, "lastStage": lastStage, "status": status, "pendingCount": pending.count, "holdReason": holdReason, "accurateModel": hasAccurateModel, "warmUpMS": warmUpMS, "idleBeforeSec": idleBeforeSec, "snapLast": snapLast, "screenRecording": CGPreflightScreenCaptureAccess(), "tapLevel": tapLevel,
            "profileExamples": examples.count, "profileCER": profileCER.map { Int(($0 * 1000).rounded()) } ?? -1, "profileModel": examples.last?["model"] ?? "-"]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            diagnosticQueue.async { try? data.write(to: URL(fileURLWithPath: Bundle.main.bundleIdentifier == "local.veda.preview" ? "/private/tmp/veda-preview-diagnostics.json" : "/private/tmp/veda-diagnostics.json"), options: .atomic) }
        }
    }
    func block(_ message: String) {
        status = message; needsAttention = true; lastStage = "เริ่มไม่ได้: " + message
        showNotice(message); critterCues.send(.error); writeDiagnostics()
    }
    func showNotice(_ message: String) {
        hideNoticeWork?.cancel(); notice = message; overlayVisible = true
        if overlayStyle == "character" && !message.hasPrefix("เลือก TH") && !message.hasPrefix("เปลี่ยนภาษา") { critterCues.send(.notice(message)) }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.notice = nil
            if self.phase == .idle && !self.fnDown { self.overlayVisible = false }
        }
        hideNoticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
    func copyLatest() {
        guard let text = pending.last else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        showNotice("คัดลอกแล้ว"); critterCues.send(.copied)
    }
    func restoreUpgradeText() {
        let url = URL(fileURLWithPath: PendingArchive.path(uid: getuid()))
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let data = try? Data(contentsOf: url), let texts = PendingArchive.decode(data) else { return }
        pending.append(contentsOf: texts)
        try? FileManager.default.removeItem(at: url)
        if !texts.isEmpty { writeDiagnostics() }
    }
    // Held text is RAM-only, so quitting or updating would otherwise discard it.
    // Written owner-only, read back once on the next launch, then deleted.
    func preservePendingForUpgrade() {
        PendingArchive.save(pending, to: PendingArchive.path(uid: getuid()))
    }
    func selectMode(_ selected: Mode) {
        guard phase != .processing else { return }
        mode = selected
        if phase == .starting || phase == .recording { heldMode = selected }
        writeDiagnostics()
    }
    func invalidateTarget() {
        guard phase != .idle else { return }
        targetWasChanged = true; guardState.observe(nil)
    }
    func pollTarget() {
        guard !focusQueryPending, target != nil else { return }
        focusQueryPending = true; let id = token
        focusQueue.async { [weak self] in
            let current = Target.capture()
            DispatchQueue.main.async {
                guard let self else { return }; self.focusQueryPending = false
                guard self.token == id, self.phase != .idle else { return }
                self.guardState.observe(current?.stamp)
            }
        }
    }
    func prepare() {
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        do { try backend.start() } catch { status = error.localizedDescription; return }
        Task { @MainActor in
            for _ in 0..<120 {
                if await backend.ready() { ready = true; waitingForPermissions = !microphoneAllowed || !accessibilityAllowed; needsAttention = waitingForPermissions; status = "กด Fn ค้างเพื่อพูด"; refreshPermissions(); return }
                if backend.process?.isRunning != true { block("ตัวประมวลผลหยุดทำงาน หรือมี gluu bot อีกสำเนาเปิดอยู่ ให้ปิด gluu bot ทุกสำเนาแล้วเปิดใหม่"); return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            status = "โมเดลยังไม่พร้อม — เปิดแอปใหม่หรือตรวจ runtime"
        }
    }
    func testBackend() {
        guard phase == .idle, !testingBackend else { return }
        testingBackend = true; backendCheck = "กำลังตรวจไฟล์ตัวอย่าง ไม่ใช้ไมโครโฟน…"
        Task { @MainActor in
            defer { testingBackend = false }
            do {
                let url = Bundle.main.resourceURL!.appendingPathComponent("runtime/test-jfk.wav")
                let data = try Data(contentsOf: url)
                let start = ProcessInfo.processInfo.systemUptime
                let result = try await backend.transcribe(data, mode: .th, vocabulary: "", sourceLanguage: "en")
                let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
                backendCheck = result.lowercased().contains("fellow americans") ? "ผ่าน: ไฟล์ตัวอย่าง → WAV/HTTP → โมเดล → ข้อความ (\(ms) ms; ไม่ใช่ latency Fn)" : "API ตอบแล้ว แต่ผลไม่ตรง fixture ให้ตรวจโมเดล"
            } catch { backendCheck = "ตรวจโมเดลไม่ผ่าน: " + error.localizedDescription }
            writeDiagnostics()
        }
    }
    func microphonePermission() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissions() }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
    func accessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refreshPermissions()
    }
    func press() {
        guard !fnDown else { return }; fnDown = true
        guard phase == .idle, !testingBackend else { return }
        // UI is committed synchronously before permissions, AX calls or audio setup.
        hideSettingsForDictation?()
        fnPressedAt = ProcessInfo.processInfo.systemUptime
        overlayVisible = true; notice = nil; hideNoticeWork?.cancel()
        phase = .starting; showOverlayImmediately?()
        overlayReadyMS = Int((ProcessInfo.processInfo.systemUptime - fnPressedAt) * 1000)
        lastEvent = "ได้รับ Fn ลง"; captureReadyMS = nil
        token = holdLatch.begin(); let id = token
        target = nil; targetWasChanged = false; guardState.begin(nil)
        originPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        heldMode = mode; heldVocabulary = PersonalProfile.hint(vocabulary: vocabulary, profileWords: profileHintWords)
        // Yield to the next main-loop cycle before touching the audio system.
        DispatchQueue.main.async { [weak self] in self?.startCapture(id: id); self?.warmUpIfCold() }
    }
    func startCapture(id: UUID) {
        guard token == id, phase == .starting, holdLatch.isHeld(id) else { return }
        refreshPermissions()
        guard ready, backend.process?.isRunning == true else {
            phase = .idle; holdLatch.end(); block("โมเดลยังไม่พร้อม — คลิกไอคอนคลื่นเสียงเพื่อตรวจ"); return
        }
        guard microphoneAllowed else {
            phase = .idle; holdLatch.end(); waitingForPermissions = true
            block("ต้องอนุญาตไมโครโฟน · คลิกไอคอนคลื่นเสียงเพื่อตั้งค่า"); return
        }
        waitingForPermissions = false; needsAttention = false
        lastStage = "กำลังเปิดไมโครโฟน"
        if accessibilityAllowed {
            focusQueue.async { [weak self] in
                let captured = Target.capture()
                DispatchQueue.main.async {
                    guard let self, self.token == id, self.phase != .idle else { return }
                    if !self.targetWasChanged, captured?.stamp.pid == self.originPID {
                        self.target = captured; self.guardState.begin(captured?.stamp)
                        self.watch.start(captured) { [weak self] in self?.invalidateTarget() }
                    }
                }
            }
        }
        audio.start(id: id, latch: holdLatch) { [weak self] result in
            guard let self, self.token == id else { return }
            switch result {
            case .success(true):
                guard self.phase == .starting, self.fnDown else { return }
                self.captureReadyMS = Int((ProcessInfo.processInfo.systemUptime - self.fnPressedAt) * 1000)
                self.phase = .recording; self.started = Date()
                self.lastStage = "บันทึกเสียงแล้ว"
                self.status = self.accessibilityAllowed ? "กำลังฟัง · ปล่อย Fn เพื่อแปลง" : "กำลังฟัง · จะพักข้อความ (Accessibility ยังไม่พร้อม)"
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
                self.writeDiagnostics()
            case .success(false):
                if self.phase == .starting { self.finish() }
            case .failure(let error):
                self.finish(); self.block("เปิดไมโครโฟนไม่สำเร็จ: " + error.localizedDescription)
            }
        }
    }
    func tick() {
        pollTarget()
        if phase == .recording {
            let id = token
            audio.meter { [weak self] average, peak in
                guard let self, self.token == id, self.phase == .recording else { return }
                self.peakDB = peak; self.level = CGFloat(max(0, min(1, (average + 60) / 60)))
            }
            if Date().timeIntervalSince(started) > 120 { release() }
        }
    }
    func release() {
        lastEvent = "ได้รับ Fn ปล่อย"; fnDown = false; holdLatch.end()
        guard phase == .starting || phase == .recording else {
            if phase == .idle && notice == nil { overlayVisible = false }; writeDiagnostics(); return
        }
        let released = ProcessInfo.processInfo.systemUptime, id = token
        phase = .processing; level = 0
        processingDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.token == id, self.phase == .processing else { return }
            self.cancel(); self.block("ใช้เวลานานเกินไป · กด Fn เพื่อลองใหม่")
        }
        processingDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: deadline)
        status = "กำลังแปลง \(heldMode.rawValue)…"
        audio.finish { [weak self] captured in
            guard let self, self.token == id, self.phase == .processing else { return }
            guard let captured, captured.wav.count > 44 else {
                self.finish(); self.showNotice("ยังไม่ทันรับเสียง · รอแถบรับเสียงก่อนพูด"); return
            }
            guard captured.duration >= 0.35 else { self.finish(); self.showNotice("เสียงสั้นเกินไป · กด Fn ค้างระหว่างพูด"); return }
            guard captured.peakDB > -50 else { self.finish(); self.block("ระดับเสียงต่ำมาก · ตรวจ Sound → Input"); return }
            self.transcribe(captured.wav, id: id, released: released)
        }
    }
    // The accurate model is fetched on first run; a fresh copy of the app only bundles "small".
    @Published var modelDownloadStatus = ""
    @Published var modelDownloading = false
    @Published var modelDownloadFraction = 0.0
    private var modelDownloadTask: URLSessionDownloadTask?
    private var modelDownloadDelegate: ModelDownloadDelegate?
    static var modelsDirectory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Veda/models") }
    var hasAccurateModel: Bool { FileManager.default.fileExists(atPath: Model.modelsDirectory.appendingPathComponent(ModelDownload.largeV3Q5.fileName).path) }
    func downloadAccurateModel() {
        guard !modelDownloading else { return }
        let spec = ModelDownload.largeV3Q5
        modelDownloading = true; modelDownloadFraction = 0; modelDownloadStatus = "กำลังดาวน์โหลด…"
        let delegate = ModelDownloadDelegate(
            progress: { [weak self] received, total in
                DispatchQueue.main.async { self?.modelDownloadFraction = total > 0 ? Double(received) / Double(total) : 0; self?.modelDownloadStatus = "กำลังดาวน์โหลด " + ModelDownload.progressLabel(received: received, total: total) }
            },
            finished: { [weak self] result in
                // Called on the session queue with the temp file, which vanishes when this returns: verify and move now.
                let outcome: String
                switch result {
                case .failure(let error): outcome = "ดาวน์โหลดไม่สำเร็จ: " + error.localizedDescription
                case .success(let temp):
                    let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? -1
                    if size != spec.bytes { outcome = "ไฟล์ไม่ครบ (\(size) ไบต์) ลองใหม่อีกครั้ง" }
                    else if Model.sha256(of: temp) != spec.sha256 { outcome = "ไฟล์ไม่ตรง checksum ลบทิ้งแล้ว ลองใหม่อีกครั้ง" }
                    else {
                        let dir = Model.modelsDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let dest = dir.appendingPathComponent(spec.fileName)
                        try? FileManager.default.removeItem(at: dest)
                        outcome = (try? FileManager.default.moveItem(at: temp, to: dest)) != nil ? "ติดตั้งโมเดลแล้ว · เปิด gluu bot ใหม่เพื่อเริ่มใช้" : "ย้ายไฟล์เข้าโฟลเดอร์โมเดลไม่ได้"
                    }
                    try? FileManager.default.removeItem(at: temp)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.modelDownloading = false; self?.modelDownloadStatus = outcome; self?.modelDownloadTask = nil; self?.modelDownloadDelegate = nil
                    self?.writeDiagnostics()
                }
            })
        modelDownloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: spec.url); request.timeoutInterval = 60
        modelDownloadTask = session.downloadTask(with: request)
        modelDownloadTask?.resume()
    }
    func cancelModelDownload() { modelDownloadTask?.cancel(); modelDownloadTask = nil; modelDownloading = false; modelDownloadStatus = "ยกเลิกแล้ว" }
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let progress: (Int64, Int64) -> Void
        let finished: (Result<URL, Error>) -> Void
        init(progress: @escaping (Int64, Int64) -> Void, finished: @escaping (Result<URL, Error>) -> Void) { self.progress = progress; self.finished = finished }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten, totalBytesExpectedToWrite) }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard (downloadTask.response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { finished(.failure(URLError(.badServerResponse))); return }
            finished(.success(location))
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { finished(.failure(error)) } }
    }
    var releasedAt: TimeInterval = 0
    var lastInferenceAt: Date?
    var warmUpTask: Task<Void, Never>?
    var warmUpMS = -1
    var idleBeforeSec = -1
    /// Warming costs ~1 s of GPU, so it only runs when the backend has been idle
    /// long enough to have gone cold, and always while the user is still talking.
    static let warmAfterIdle: TimeInterval = 90
    func warmUpIfCold() {
        guard ready, backend.process?.isRunning == true, warmUpTask == nil, requestTask == nil else { return }
        let idle = lastInferenceAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        idleBeforeSec = idle == .greatestFiniteMagnitude ? -1 : Int(idle)
        guard idle >= Model.warmAfterIdle else { warmUpMS = 0; return }
        let started = Date()
        warmUpTask = Task { @MainActor [weak self] in
            await self?.backend.warmUp()
            guard let self else { return }
            self.warmUpMS = Int(Date().timeIntervalSince(started) * 1000)
            self.lastInferenceAt = Date()
            self.warmUpTask = nil
        }
    }
    func transcribe(_ wav: Data, id: UUID, released: TimeInterval) {
        releasedAt = released
        lastStage = "ส่งเสียงไปโมเดลบนเครื่อง"; writeDiagnostics()
        let mode = heldMode, vocabulary = heldVocabulary
        requestTask = Task { @MainActor in
            do {
                if let warmUpTask { await warmUpTask.value }
                let raw = try await backend.transcribe(wav, mode: mode, vocabulary: vocabulary)
                guard token == id, !Task.isCancelled else { return }
                let text = TermCorrections.apply(BackendRequest.cleaned(raw, polish: true), pairs: terms)
                let current = Target.capture()
                guardState.observe(current?.stamp)
                var inserted = false
                if !text.isEmpty && !targetWasChanged && guardState.permits(current?.stamp) {
                    inserted = await target?.insert(text, verified: current) == true
                    if !inserted { holdReason = "insert: " + (Target.lastInsertFailure ?? "unknown") + " (role \(Target.lastRole))" }
                } else if !text.isEmpty {
                    holdReason = target == nil ? "no target at Fn down: " + (Target.lastRejection ?? "no focused element")
                        : targetWasChanged ? "focus or field changed while recording (role \(Target.lastRole))"
                        : current == nil ? "field unreadable at result time: " + (Target.lastRejection ?? "-")
                        : "field differs at result time: " + (current!.stamp.pid != target!.stamp.pid ? "other app" : current!.stamp.element != target!.stamp.element ? "other element" : current!.stamp.value != target!.stamp.value ? "value changed" : "caret moved") + " (role \(Target.lastRole))"
                }
                if inserted { holdReason = "-" }
                guard token == id, !Task.isCancelled else { return }
                if !text.isEmpty && !inserted { pending.append(text) }
                lastInferenceAt = Date()
                let elapsed = (ProcessInfo.processInfo.systemUptime - released) * 1000
                logLatency(mode: mode, ms: elapsed, outcome: text.isEmpty ? "empty" : inserted ? "inserted" : "held")
                finish()
                lastStage = text.isEmpty ? "โมเดลไม่พบข้อความ" : inserted ? "แทรกสำเร็จ" : "พักข้อความ: เป้าหมายเปลี่ยนหรือช่องไม่รองรับ Accessibility"
                status = text.isEmpty ? "ไม่พบข้อความ" : inserted ? "แทรกแล้ว · \(Int(elapsed)) ms" : "ยังไม่ได้พิมพ์ · คลิกไอคอนคลื่นเสียงเพื่อคัดลอก"
                if !inserted { showNotice(status) }
                critterCues.send(inserted ? .done : text.isEmpty ? .notice("ไม่พบข้อความ") : .held)
            } catch {
                guard token == id else { return }
                logLatency(mode: mode, ms: (ProcessInfo.processInfo.systemUptime - released) * 1000, outcome: "error")
                finish(); block("แปลงไม่สำเร็จ: \(error.localizedDescription)")
            }
        }
    }
    func finish() {
        processingDeadline?.cancel(); processingDeadline = nil
        watch.stop(); timer?.invalidate(); timer = nil
        phase = .idle; target = nil; level = 0; overlayVisible = fnDown
        status = "พร้อม · กด Fn ค้างเพื่อพูด"
    }
    func cancel() {
        holdLatch.end(); token = UUID(); requestTask?.cancel(); requestTask = nil
        audio.cancel(); finish(); status = "ยกเลิกแล้ว"; notice = nil
    }
    func logLatency(mode: Mode, ms: Double, outcome: String) {
        lastLatency = "\(mode.rawValue): \(Int(ms)) ms · \(outcome)"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Veda")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("latency.csv")
        if !FileManager.default.fileExists(atPath: url.path) { try? Data("timestamp,mode,release_to_result_ms,outcome,model,idle_before_s,warm_up_ms\n".utf8).write(to: url) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())),\(mode.rawValue),\(Int(ms)),\(outcome),whisper-\(backend.modelName),\(idleBeforeSec),\(warmUpMS)\n".utf8))
    }
}

struct Bar: View {
    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var showsHeldText: Bool {
        guard let notice = model.notice, !model.pending.isEmpty else { return false }
        return notice.hasPrefix("พักข้อความ") || notice == "ข้อความพักไว้" || notice == "คัดลอกแล้ว"
    }
    var inlineMessage: String {
        let notice = model.notice ?? ""
        if showsHeldText { return notice == "คัดลอกแล้ว" ? notice : "ยังไม่ได้พิมพ์ · เก็บไว้ให้" }
        if notice.contains("อนุญาตไมโครโฟน") { return "ต้องอนุญาตไมโครโฟน" }
        if notice.contains("โมเดลยังไม่พร้อม") { return "โมเดลยังไม่พร้อม" }
        return notice
    }
    var body: some View {
        Group {
            if model.overlayVisible {
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(Mode.allCases, id: \.self) { mode in
                            Button { model.selectMode(mode) } label: {
                                Text(mode.rawValue).font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(model.mode == mode ? Color.white : Color.white.opacity(0.45))
                                    .frame(width: 26, height: 21)
                                    .background(Capsule().fill(model.mode == mode ? Color.white.opacity(0.12) : Color.clear))
                            }.disabled(model.phase == .processing)
                                .accessibilityValue(model.mode == mode ? "เลือกอยู่" : "")
                        }
                    }
                    HStack(spacing: 2) {
                        ForEach(0..<5) { i in
                            Capsule().fill(Color.white.opacity(model.phase == .recording ? 0.9 : 0.35))
                                .frame(width: 2, height: 3 + (model.phase == .recording ? model.level : 0.15) * CGFloat([5,10,14,8,4][i]))
                        }
                    }.frame(width: 24, height: 18).accessibilityLabel(model.phase == .recording ? "ระดับเสียงไมโครโฟน" : "ไมโครโฟนพักอยู่")
                    if model.phase == .processing {
                        // Seconds since Fn was released: proof the app is working, not stuck.
                        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                            Text(String(format: "%.1fs", max(0, ProcessInfo.processInfo.systemUptime - model.releasedAt)))
                                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.8)).frame(width: 30, height: 16)
                        }.accessibilityLabel("กำลังถอดเสียง")
                    } else if model.phase == .starting {
                        ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 24, height: 16)
                            .accessibilityLabel("กำลังเปิดไมโครโฟน")
                    } else if model.notice != nil {
                        Button {
                            if showsHeldText { model.copyLatest() } else { model.settingsAction?() }
                        } label: {
                            Image(systemName: showsHeldText ? "doc.on.doc" : "exclamationmark.circle")
                                .font(.system(size: 12)).frame(width: 24, height: 18)
                        }.accessibilityLabel(inlineMessage + (showsHeldText ? " · คัดลอก" : " · ดูรายละเอียด"))
                    }
                }.buttonStyle(.plain).foregroundStyle(.white).padding(.horizontal, 11).frame(width: 140, height: 32)
                    .background(Capsule().fill(Color(white: 0.065)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .overlay {
                        if model.phase != .idle {
                            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                                let angle = reduceMotion ? 45.0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2 * 360
                                let energy = model.phase == .recording ? Double(model.level) : 0.45
                                let gradient = AngularGradient(colors: [.cyan.opacity(0.15), .cyan, .indigo, .purple.opacity(0.8), .white.opacity(0.85), .cyan.opacity(0.15)], center: .center, angle: .degrees(angle))
                                ZStack {
                                    Capsule().strokeBorder(gradient, lineWidth: 3).blur(radius: 2)
                                        .opacity(0.45 + energy * 0.3)
                                    Capsule().strokeBorder(gradient, lineWidth: 1.3)
                                }
                            }.allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            } else {
                Button { model.showNotice("เลือก TH หรือ EN แล้วกด Fn ค้าง") } label: {
                    Capsule(style: .continuous).fill(Color.black.opacity(0.32)).frame(width: 44, height: 9)
                        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("gluu bot · เปิดแถบ TH/EN")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 3)
    }
}
// NSTextView accepts file drags itself and inserts the path as text, which is what
// happened when the user dropped a recording onto the transcript box. This view
// keeps normal typing and text drops, but routes a dropped file to the importer.
struct FileDropTextView: NSViewRepresentable {
    @Binding var text: String
    var onFileDrop: (URL) -> Void
    final class DropTextView: NSTextView {
        var onFileDrop: ((URL) -> Void)?
        private func droppedFile(_ info: NSDraggingInfo) -> URL? {
            (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { droppedFile(sender) != nil ? .copy : super.draggingEntered(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { droppedFile(sender) != nil ? .copy : super.draggingUpdated(sender) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let url = droppedFile(sender) { onFileDrop?(url); return true }
            return super.performDragOperation(sender)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let view = DropTextView(frame: .zero)
        view.isRichText = false; view.drawsBackground = false; view.font = .systemFont(ofSize: 13)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.allowsUndo = true; view.textContainerInset = NSSize(width: 0, height: 0)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator; view.onFileDrop = onFileDrop
        view.string = text; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? DropTextView else { return }
        view.onFileDrop = onFileDrop
        if view.string != text { view.string = text }
    }
}
struct Settings: View {
    @ObservedObject var model: Model
    @State private var section: Int
    @State private var dropTargeted = false
    private var canImport: Bool { !model.testingBackend && model.ready && model.phase == .idle }
    init(model: Model, section: Int = 0) {
        self.model = model
        _section = State(initialValue: section)
    }
    private let sections = [("การพิมพ์ด้วยเสียง", "waveform"), ("ยังไม่ได้พิมพ์", "tray"), ("ตรวจระบบ", "slider.horizontal.3"), ("โปรไฟล์ของฉัน", "person.crop.circle")]
    // Every free-text box uses the dictation vocabulary field's look, plus a
    // placeholder so an empty box still says what belongs in it.
    @ViewBuilder func editor(_ text: Binding<String>, placeholder: String, height: CGFloat, onFileDrop: ((URL) -> Void)? = nil) -> some View {
        Group {
            if let onFileDrop { FileDropTextView(text: text, onFileDrop: onFileDrop).padding(.horizontal, 5) }
            else { TextEditor(text: text).font(.system(size: 13)).scrollContentBackground(.hidden) }
        }
            .padding(8).frame(height: height)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                }
            }
    }
    private func slangField(_ key: String) -> Binding<String> {
        Binding(get: { model.newSlang[key] ?? "" }, set: { model.newSlang[key] = $0 })
    }
    @ViewBuilder func setupStep<Actions: View>(_ number: Int, done: Bool, title: String, why: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle").font(.system(size: 18)).foregroundStyle(done ? Color.green : Color.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(why).font(.caption).foregroundStyle(.secondary)
                if !done { HStack { actions() }.controlSize(.small).padding(.top, 2) }
            }
            Spacer()
        }
    }
    @ViewBuilder func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    WaveformMark(size: 22).foregroundStyle(.cyan)
                    Text("gluu bot").font(.system(size: 23, weight: .semibold, design: .rounded))
                }.padding(.top, 8)
                VStack(spacing: 5) {
                    ForEach(0..<sections.count, id: \.self) { index in
                        Button { section = index } label: {
                            HStack(spacing: 10) {
                                Image(systemName: sections[index].1).frame(width: 18)
                                Text(sections[index].0)
                                Spacer(minLength: 0)
                                if index == 1 && !model.pending.isEmpty { Text("\(model.pending.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            }.font(.system(size: 12, weight: section == index ? .semibold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 11)
                                .background(section == index ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                Label("ประมวลผลบน Mac", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("ออกจาก gluu bot") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.caption)
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development").font(.caption2).foregroundStyle(.tertiary)
            }.padding(20).frame(width: 185).frame(maxHeight: .infinity).background(.ultraThinMaterial)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sections[section].0).font(.system(size: 25, weight: .semibold))
                        Text(section == 0 ? "พูดอย่างเป็นธรรมชาติ ให้ gluu bot ช่วยพิมพ์" : section == 1 ? "ข้อความที่ยังไม่ได้พิมพ์ลงช่อง เก็บไว้ให้คัดลอก" : section == 3 ? "คำศัพท์และตัวอย่างเสียงสำหรับการใช้งานของคุณ" : "ตรวจความพร้อมของไมโครโฟนและการพิมพ์")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.bottom, 6)
                    if section == 0 {
                        if !(model.microphoneAllowed && model.accessibilityAllowed && CGPreflightScreenCaptureAccess() && model.hasAccurateModel) {
                            card("ตั้งค่าครั้งแรก · 4 ขั้น") {
                                Text("gluu bot ทำงานบนเครื่องล้วน แต่ macOS ต้องให้คุณอนุญาตเอง 3 อย่าง (ทุกครั้งที่อัปเดต เพราะแอปยังไม่ได้เซ็นด้วย Developer ID)").font(.caption).foregroundStyle(.secondary)
                                setupStep(1, done: model.microphoneAllowed, title: "ไมโครโฟน", why: "ฟังเสียงตอนคุณกด Fn ค้าง") {
                                    Button("อนุญาต") { model.microphonePermission() }
                                }
                                setupStep(2, done: model.accessibilityAllowed, title: "Accessibility", why: "พิมพ์ข้อความลงช่องที่คุณกำลังใช้ และรับปุ่ม Fn") {
                                    Button("เปิดหน้าตั้งค่า") { model.accessibilityPermission() }
                                }
                                setupStep(3, done: CGPreflightScreenCaptureAccess(), title: "Screen Recording", why: "แคปหน้าจอสำหรับ Snap Translate · เปิดสวิตช์แล้วต้องเปิด gluu bot ใหม่") {
                                    Button("ขอสิทธิ์") { CGRequestScreenCaptureAccess() }
                                    Button("เปิด gluu bot ใหม่") { model.relaunchAction?() }
                                }
                                setupStep(4, done: model.hasAccurateModel, title: "โมเดลภาษาไทยความแม่นสูง (1.08 GB)", why: "ดาวน์โหลดครั้งเดียวจาก Hugging Face ตรวจ checksum ก่อนใช้ · ไม่มีโมเดลนี้จะใช้รุ่นเล็กที่แม่นน้อยกว่ามาก") {
                                if model.modelDownloading {
                                    ProgressView(value: model.modelDownloadFraction).frame(width: 160)
                                    Button("ยกเลิก") { model.cancelModelDownload() }
                                } else {
                                    Button("ดาวน์โหลด") { model.downloadAccurateModel() }
                                    if model.modelDownloadStatus.hasPrefix("ติดตั้งโมเดลแล้ว") { Button("เปิด gluu bot ใหม่") { model.relaunchAction?() } }
                                }
                            }
                            if !model.modelDownloadStatus.isEmpty { Text(model.modelDownloadStatus).font(.caption).foregroundStyle(.secondary) }
                                Button("ตรวจใหม่") { model.refreshPermissions() }.controlSize(.small)
                            }
                        }
                        card("การแสดงผล") {
                            Picker("การแสดงผล", selection: $model.overlayStyle) {
                                Text("ตัวละครมุมจอ · กลิ้ง เด้ง มีอารมณ์").tag("character")
                                Text("แถบดำกลางจอแบบเดิม").tag("classic")
                            }.pickerStyle(.radioGroup).labelsHidden()
                            if model.overlayStyle == "character" {
                                Picker("ความขี้เล่น", selection: $model.critterPlayfulness) {
                                    Text("เงียบ").tag(0); Text("ปกติ").tag(1); Text("ขี้เล่น").tag(2)
                                }.pickerStyle(.segmented).frame(maxWidth: 260)
                                Toggle("ลดการเคลื่อนไหว (หยุดกลิ้ง/เด้ง เหลือแค่ตามอง)", isOn: $model.critterReduceMotion).toggleStyle(.switch).controlSize(.small)
                                Button("เปิดหน้าต่างดูท่าทางและอารมณ์") { model.playgroundAction?() }.controlSize(.small)
                Text("คลิกที่ตัวละครเพื่อเปิดหน้านี้ · Fn + Option วนโหมดความขี้เล่น · ตั้งค่า \"ลดการเคลื่อนไหว\" ของ macOS มีผลด้วยเสมอ").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        card("ภาษาผลลัพธ์") {
                            Picker("ภาษาผลลัพธ์", selection: $model.mode) {
                                Text("TH · ข้อความไทย").tag(Mode.th)
                                Text("EN · แปลเป็นอังกฤษ").tag(Mode.en)
                            }.labelsHidden().pickerStyle(.segmented).disabled(model.phase != .idle)
                            Text(model.mode == .en ? "พูดภาษาไทย → รับข้อความภาษาอังกฤษ" : "ถอดเสียงไทย พร้อมคำศัพท์ภาษาอังกฤษที่คุณพูด")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        card("พร้อมเมื่อคุณกด Fn") {
                            HStack(spacing: 12) {
                                Text("fn").font(.system(size: 20, weight: .medium, design: .rounded)).frame(width: 44, height: 40)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("กดค้างเพื่อพูด · ปล่อยเพื่อพิมพ์").font(.system(size: 13, weight: .medium))
                                    Text("Fn + Space สลับ TH/EN · Fn + Option ความขี้เล่น · Escape ยกเลิก").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        card("Snap Translate") {
                            HStack(spacing: 12) {
                                Text(model.snapShortcut.label).font(.system(size: 15, weight: .medium, design: .rounded)).padding(.horizontal, 10).frame(height: 40)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("ลากเลือกส่วนของหน้าจอ → อ่านข้อความ → แปลทันที").font(.system(size: 13, weight: .medium))
                                    Text("ไทย ↔ อังกฤษ เลือกทิศทางอัตโนมัติ · OCR และแปลบนเครื่อง · ภาพถูกลบทันทีหลังอ่าน").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Label(CGPreflightScreenCaptureAccess() ? "Screen Recording · อนุญาตแล้ว" : "Screen Recording · ยังไม่มีผลในโปรเซสนี้", systemImage: CGPreflightScreenCaptureAccess() ? "checkmark.circle.fill" : "exclamationmark.circle").font(.caption)
                                if !CGPreflightScreenCaptureAccess() {
                                    Button("ขอสิทธิ์") { CGRequestScreenCaptureAccess() }.controlSize(.small)
                                    Button("เปิด gluu bot ใหม่") { model.relaunchAction?() }.controlSize(.small)
                                }
                            }
                            if !CGPreflightScreenCaptureAccess() { Text("ถ้าเปิดสวิตช์ใน System Settings แล้ว ต้องเปิด gluu bot ใหม่สิทธิ์จึงมีผล · ข้อความพักถูกเก็บและคืนให้อัตโนมัติ").font(.caption2).foregroundStyle(.secondary) }
                            Toggle("อ่านออกเสียงคำแปลหลังแปลเสร็จ", isOn: $model.snapSpeak).toggleStyle(.switch).controlSize(.small)
                            HStack(spacing: 8) {
                                Button(model.recordingShortcut ? "กดปุ่มลัดที่ต้องการ… (Esc ยกเลิก)" : "เปลี่ยนปุ่มลัด") { model.recordingShortcut ? model.endRecordingShortcut() : model.beginRecordingShortcut() }.controlSize(.small)
                                if model.snapShortcut != .default { Button("กลับเป็น ⇧⌘3") { model.snapShortcut = .default }.controlSize(.small) }
                            }
                            Text("ต้องมี ⌘ ⌥ ⌃ หรือ ⇧ อย่างน้อยหนึ่งตัว · ⇧⌘3 ซ้ำกับแคปทั้งจอของ macOS: gluu bot กลืนไว้ก่อน ถ้ายังแคปซ้อน ปิดใน System Settings › Keyboard › Shortcuts › Screenshots · ผลลัพธ์โผล่ข้างเคอร์เซอร์ คลิกที่อื่นหรือ Esc เพื่อปิด").font(.caption2).foregroundStyle(.secondary)
                        }
                        card("สแลงและสำนวน") {
                            Text("ตัวแปลบนเครื่องแปลตามตัวอักษร (\"เดือดสัส\" → \"boiling\") gluu bot จึงแปลงสำนวนที่รู้จักให้ก่อน แล้วบอกคุณทุกครั้งที่ทำ").font(.caption).foregroundStyle(.secondary)
                            Picker("โหมดเริ่มต้น", selection: $model.slangMode) {
                                Text("สุภาพ · สแลงเป็นภาษามาตรฐาน").tag(Slang.Mode.polite)
                                Text("แชทจริง · รักษาระดับภาษา คำหยาบยังหยาบ").tag(Slang.Mode.chat)
                            }.pickerStyle(.radioGroup)
                            Toggle("แสดงหมายเหตุสแลงใต้คำแปล", isOn: $model.slangNotes).toggleStyle(.switch).controlSize(.small)
                            Text("อภิธานตั้งต้น \(Slang.seed.count) คำ (ไทย/อังกฤษ) · เพิ่มของคุณเองได้ คำที่ซ้ำกับตั้งต้นจะใช้ของคุณแทน").font(.caption2).foregroundStyle(.secondary)
                            Text("กรอกแค่ช่องที่มี * ก็เพิ่มได้: คำไทยที่คุณใช้จริง กับคำอังกฤษที่อยากได้เวลาแปล · ช่อง \"สุภาพ\" คือคำที่จะใช้แทนในโหมดสุภาพ ถ้าไม่ใส่จะใช้คำเดิม").font(.caption2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    TextField("ไทย เช่น เดือดสัส *", text: slangField("th")).textFieldStyle(.roundedBorder)
                                    TextField("ไทยแบบสุภาพ (ไม่ใส่ก็ได้)", text: slangField("thPlain")).textFieldStyle(.roundedBorder)
                                    TextField("อังกฤษแชท เช่น intense as hell *", text: slangField("en")).textFieldStyle(.roundedBorder)
                                    TextField("อังกฤษสุภาพ (ไม่ใส่ก็ได้)", text: slangField("enPlain")).textFieldStyle(.roundedBorder)
                                }
                                HStack(spacing: 6) {
                                    TextField("ความหมายสั้น ๆ (ไม่ใส่ก็ได้)", text: slangField("meaning")).textFieldStyle(.roundedBorder)
                                    Picker("", selection: slangField("register")) {
                                        Text("ปกติ").tag("casual"); Text("ไม่สุภาพ").tag("rude"); Text("หยาบ").tag("vulgar")
                                    }.labelsHidden().frame(width: 110)
                                    Button("เพิ่ม") { model.addSlang() }.disabled(SlangEntry(model.newSlang) == nil)
                                }
                            }.controlSize(.small)
                            ForEach(Array(model.slangCustom.enumerated()), id: \.offset) { index, e in
                                HStack(spacing: 8) {
                                    Text(e["th"] ?? "").fontWeight(.medium)
                                    Image(systemName: "arrow.left.arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                    Text(e["en"] ?? "")
                                    Text(e["meaning"] ?? "").foregroundStyle(.secondary)
                                    Spacer()
                                    Button("ลบ", systemImage: "trash") { model.slangCustom.remove(at: index) }.controlSize(.small).labelStyle(.iconOnly)
                                }.font(.system(size: 12))
                            }
                        }
                        card("คีย์บอร์ดภายนอก") {
                            Toggle("กด F18 ค้างเพื่อพูด", isOn: $model.externalF18).toggleStyle(.switch).controlSize(.small).disabled(model.phase != .idle)
                            Text("Keychron K2 Max: ตั้งปุ่มที่ต้องการใน Launcher ให้ส่ง F18 · Fn บน Mac ยังใช้ได้ตามเดิม").font(.caption).foregroundStyle(.secondary)
                        }
                        card("คำศัพท์ของคุณ") {
                            Text("ชื่อคน ชื่อโปรเจกต์ และศัพท์เทคนิค คั่นด้วยจุลภาค").font(.caption).foregroundStyle(.secondary)
                            editor($model.vocabulary, placeholder: "เช่น gluu bot, Keychron, ถอดเสียง", height: 65)
                            Text("คำศัพท์เป็นคำใบ้สำหรับโมเดล อาจยังสะกดชื่อเฉพาะคลาดเคลื่อน").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if section == 1 {
                        Text("เก็บจนกว่าจะปิดแอป · คัดลอกข้อความสำคัญก่อนออก").font(.caption).foregroundStyle(.secondary)
                        if model.pending.isEmpty {
                            card("ไม่มีข้อความค้าง") { Label("ข้อความที่พิมพ์ลงช่องไม่ได้จะเก็บไว้ที่นี่", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                        }
                        ForEach(Array(model.pending.enumerated()).reversed(), id: \.offset) { index, text in
                            card("ข้อความ \(index + 1)") {
                                Text(text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button("คัดลอก", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                                    Spacer()
                                    Button("ลบ", systemImage: "trash") { model.pending.remove(at: index) }.foregroundStyle(.secondary)
                                }.controlSize(.small)
                            }
                        }
                    } else if section == 3 {
                        card("ข้อมูลส่วนตัวบน Mac เครื่องนี้") {
                            TextField("ชื่อโปรไฟล์", text: $model.profileName).textFieldStyle(.roundedBorder)
                            Text("โปรไฟล์นี้จำชื่อ คำศัพท์ และตัวอย่างที่คุณบันทึก ไม่ได้ระบุตัวผู้พูดหรือฝึก Whisper ให้จำเสียงอัตโนมัติ").font(.caption).foregroundStyle(.secondary)
                        }
                        card("คำศัพท์เฉพาะของคุณ") {
                            editor($model.profileWords, placeholder: "เช่น ชื่อเพื่อนร่วมงาน, ชื่อโปรเจกต์, ศัพท์เทคนิค", height: 65)
                            Text("ชื่อคน โปรเจกต์ และศัพท์เทคนิค คั่นด้วยจุลภาค · ส่งให้โมเดลเป็นคำใบ้ทุกครั้งที่คุณพูด — บนเสียงของคุณ รายการนี้ลดอักขระผิดจาก 10.7% เหลือ 8.0%").font(.caption).foregroundStyle(.secondary)
                            // Terms the user typed as "what I said" but never added here never reach the model.
                            let harvested = VocabularyHarvest.candidates(examples: model.examples, existingHint: model.profileHintWords + "," + model.vocabulary)
                            if !harvested.isEmpty {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("จากตัวอย่างที่คุณบันทึก ยังไม่อยู่ในรายการ:").font(.caption).foregroundStyle(.secondary)
                                    Text(harvested.joined(separator: " · ")).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                                    Spacer()
                                    Button("เพิ่มทั้งหมด") {
                                        let current = model.profileWords.trimmingCharacters(in: .whitespacesAndNewlines)
                                        model.profileWords = (current.isEmpty ? "" : current + ", ") + harvested.joined(separator: ", ")
                                    }.controlSize(.small)
                                }
                            }
                        }
                        card("ทดสอบเสียงของฉัน") {
                            Text("1. กรอกข้อความที่พูดจริง  2. เลือกเสียง  3. ตรวจและบันทึก").font(.caption)
                            editor($model.calibrationExpected, placeholder: "พิมพ์ประโยคที่คุณพูดในไฟล์เสียงนี้", height: 60,
                                   onFileDrop: { url in if canImport { model.importCalibration(url: url) } })
                            HStack(spacing: 12) {
                                Button("เลือกไฟล์เสียง") { model.importCalibration() }.disabled(!canImport)
                                Label("หรือลากไฟล์เสียงมาวางที่นี่", systemImage: "arrow.down.doc").font(.caption)
                                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(12).frame(maxWidth: .infinity)
                            .background(dropTargeted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(dropTargeted ? Color.accentColor : Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                            // Finder hands over file URLs; anything the converter rejects still gets a clear status line.
                            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                                guard canImport, let provider = providers.first else { return false }
                                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                                    DispatchQueue.main.async { model.importCalibration(url: url) }
                                }
                                return true
                            }
                            Text(model.calibrationStatus).font(.caption).foregroundStyle(.secondary)
                            if !model.calibrationHeard.isEmpty {
                                Text("ผลถอดเสียง").font(.caption.bold())
                                Text(model.calibrationHeard).textSelection(.enabled)
                                Button("ยืนยันและบันทึกตัวอย่าง") { model.saveCalibration() }.disabled(model.testingBackend || model.calibrationExpected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            Text("รับ m4a จากมือถือ, mp3, wav หรือ caf · แปลงเป็น 16 kHz บนเครื่องนี้ · เก็บข้อความตัวอย่างสูงสุด 20 ชุดพร้อมตำแหน่งไฟล์ ไม่คัดลอกไฟล์เสียง").font(.caption2).foregroundStyle(.secondary)
                        }
                        // Anywhere on the card counts, not just the dashed strip.
                        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                            guard canImport, let provider = providers.first else { return false }
                            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                                DispatchQueue.main.async { model.importCalibration(url: url) }
                            }
                            return true
                        }
                        card("คำที่คุณอนุมัติให้แก้") {
                            Text("เฉพาะตัวสะกดที่โมเดลได้จริง → คำที่คุณตั้งใจ ใช้กับคำนั้นเป๊ะ ๆ ตอนพิมพ์ด้วยเสียง ไม่เดาคำที่คล้ายกัน").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                TextField("โมเดลได้ เช่น คลอส", text: $model.newTermHeard).textFieldStyle(.roundedBorder)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                TextField("ที่ถูก เช่น Claude", text: $model.newTermCorrect).textFieldStyle(.roundedBorder)
                                Button("อนุมัติ") { model.approveTerm() }.disabled(model.newTermHeard.trimmingCharacters(in: .whitespaces).isEmpty || model.newTermCorrect.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            ForEach(Array(model.terms.enumerated()), id: \.offset) { index, term in
                                HStack {
                                    Text(term["heard"] ?? "").foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                    Text(term["correct"] ?? "").fontWeight(.medium)
                                    Spacer()
                                    Button("ลบ", systemImage: "trash") { model.terms.remove(at: index) }.controlSize(.small).labelStyle(.iconOnly)
                                }.font(.system(size: 13))
                            }
                            let suggestions = Array(model.examples.flatMap { TermSuggestions.suggest(expected: $0["expected"] ?? "", heard: $0["heard"] ?? "", approved: model.terms) }
                                .reduce(into: [[String: String]]()) { acc, pair in if !acc.contains(where: { $0["heard"] == pair["heard"] }) { acc.append(pair) } }.prefix(8))
                            if !suggestions.isEmpty {
                                Text("จากตัวอย่างที่คุณบันทึก — อนุมัติเฉพาะคู่ที่ตั้งใจ").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, pair in
                                    HStack {
                                        Text(pair["heard"] ?? "").foregroundStyle(.secondary)
                                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                        Text(pair["correct"] ?? "")
                                        Spacer()
                                        Button("อนุมัติ") { model.newTermHeard = pair["heard"] ?? ""; model.newTermCorrect = pair["correct"] ?? ""; model.approveTerm() }.controlSize(.small)
                                    }.font(.system(size: 13))
                                }
                            } else if model.terms.isEmpty { Text("ยังไม่มี · บันทึกตัวอย่างเสียงข้างล่าง แล้วคำที่โมเดลผิดจะถูกเสนอให้อนุมัติที่นี่").font(.caption2).foregroundStyle(.tertiary) }
                        }
                        if !model.examples.isEmpty {
                            card("ความแม่นจากตัวอย่างที่บันทึก") {
                                if let cer = model.profileCER {
                                    Text(String(format: "อักขระผิดเฉลี่ย %.1f%% จาก %d ตัวอย่าง", cer * 100, model.examples.count)).font(.system(size: 13, weight: .medium))
                                }
                                HStack {
                                    Button("วัดซ้ำด้วยโมเดลปัจจุบัน (\(model.backend.modelName))") { model.reevaluateExamples() }
                                        .disabled(model.reevaluating || model.testingBackend || !model.ready || model.phase != .idle)
                                    if model.reevaluating { ProgressView().controlSize(.small) }
                                }
                                Text(model.reevaluationStatus.isEmpty ? "ใช้ไฟล์เสียงจากตำแหน่งเดิมที่คุณเลือกไว้ ไม่ได้คัดลอกไฟล์ · ถ้าย้ายไฟล์ ตัวอย่างนั้นจะถูกข้าม" : model.reevaluationStatus).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Array(model.examples.enumerated()), id: \.offset) { index, example in
                            card("ตัวอย่าง \(index + 1)") {
                                Text("คุณพูด: " + (example["expected"] ?? "")).textSelection(.enabled)
                                Text("โมเดลได้: " + (example["heard"] ?? "")).foregroundStyle(.secondary).textSelection(.enabled)
                                HStack(spacing: 10) {
                                    if let cer = Accuracy.characterErrorRate(expected: example["expected"] ?? "", heard: example["heard"] ?? "") {
                                        Text(String(format: "ผิด %.1f%%", cer * 100)).font(.caption.monospacedDigit()).foregroundStyle(cer > 0.15 ? .red : cer > 0.05 ? .orange : .green)
                                    }
                                    Text(example["model"].map { "โมเดล " + $0 } ?? "โมเดลไม่ทราบ").font(.caption).foregroundStyle(.secondary)
                                    Text(FileManager.default.fileExists(atPath: example["audio"] ?? "") ? "มีไฟล์เสียงให้วัดซ้ำ" : "ไม่มีไฟล์เสียง").font(.caption).foregroundStyle(.tertiary)
                                    Spacer()
                                    Button("ลบตัวอย่าง") { model.examples.remove(at: index) }.controlSize(.small)
                                }
                            }
                        }
                    } else {
                        card("สิทธิ์การใช้งาน") {
                            Label("Microphone · " + model.microphoneStatus, systemImage: model.microphoneAllowed ? "checkmark.circle.fill" : "exclamationmark.circle").font(.caption)
                            Label("Accessibility · " + model.accessibilityStatus, systemImage: model.accessibilityAllowed ? "checkmark.circle.fill" : "exclamationmark.circle").font(.caption)
                            HStack {
                                if !model.microphoneAllowed { Button("อนุญาตไมโครโฟน") { model.microphonePermission() } }
                                if !model.accessibilityAllowed { Button("เปิด Accessibility") { model.accessibilityPermission() } }
                                Button("ตรวจใหม่") { model.refreshPermissions() }
                            }.controlSize(.small)
                        }
                        card("ระบบถอดเสียง") {
                            Text("โมเดลบนเครื่อง · Whisper " + model.backend.modelName).font(.caption)
                            if !model.hasAccurateModel {
                                HStack {
                                    Button(model.modelDownloading ? "กำลังดาวน์โหลด…" : "ดาวน์โหลดโมเดลความแม่นสูง (1.08 GB)") { model.downloadAccurateModel() }.disabled(model.modelDownloading).controlSize(.small)
                                    if !model.modelDownloadStatus.isEmpty { Text(model.modelDownloadStatus).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                            Text(model.lastLatency).font(.caption)
                            Button("ตรวจโมเดลด้วยไฟล์ตัวอย่าง") { model.testBackend() }.disabled(!model.ready || model.phase != .idle || model.testingBackend)
                            Text(model.backendCheck).font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("รายละเอียดสำหรับตรวจปัญหา") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(model.lastEvent + " · " + model.lastStage)
                                    Text(Bundle.main.bundlePath)
                                    Text("หาก Fn เปิดระบบอื่นร่วมด้วย ให้เปลี่ยนปุ่มลัดรับเสียงของแอปนั้น")
                                }.font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                            }
                        }
                    }
                }.padding(28)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        // The window itself is fixed at 780x650; a minimum rather than an exact size
        // lets the offscreen review render the whole scrolling page in one pass.
        }.frame(minWidth: 780, minHeight: 650, maxHeight: .infinity)
    }
}
final class Panel: NSPanel { override var canBecomeKey: Bool { false } }
final class Delegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let instanceLock = SingleInstanceLock()
    var panel: NSPanel!
    var settings: NSWindow?
    let snap = SnapTranslator()
    // Screen Recording only takes effect in a fresh process; relaunch instead of asking the user to.
    @objc func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
    func snapTranslate() {
        guard model.phase == .idle else { return }
        snap.speakEnabled = model.snapSpeak
        snap.mode = model.slangMode; snap.showNotes = model.slangNotes
        snap.entries = Slang.entries(custom: model.slangCustom)
        snap.onFinished = { [weak self] in self?.model.snapLast = self?.snap.lastRun ?? "-"; self?.model.writeDiagnostics() }
        snap.onStage = snap.onFinished
        snap.requestCapture()
        model.snapLast = snap.lastRun; model.writeDiagnostics()
    }
    var fnTap: CFMachPort?
    var fnSource: CFRunLoopSource?
    var shortcut = DictationShortcut()
    var global: Any?
    var local: Any?
    var activation: NSObjectProtocol?
    var panelObservation: AnyCancellable?
    var screenObservation: NSObjectProtocol?
    var critter: CritterPanel?
    var critterBag = Set<AnyCancellable>()
    func applyOverlayStyle() {
        if model.overlayStyle == "character" {
            if critter == nil {
                let engine = CritterEngine()
                let p = CritterPanel(engine: engine)
                engine.onTap = { [weak self] in self?.showSettings() }
                engine.settingsIsFront = { [weak self] in (self?.settings?.isVisible ?? false) && (self?.settings?.isKeyWindow ?? false) }
                model.$phase.receive(on: RunLoop.main).sink { [weak engine] phase in
                    switch phase { case .starting, .recording: engine?.setExternal(.listening); case .processing: engine?.setExternal(.thinking); case .idle: if engine?.external != .done { engine?.setExternal(.idle) } }
                }.store(in: &critterBag)
                model.$level.receive(on: RunLoop.main).sink { [weak engine] l in engine?.level = Double(l) }.store(in: &critterBag)
                model.critterCues.receive(on: RunLoop.main).sink { [weak engine] c in engine?.cue(c) }.store(in: &critterBag)
                model.$critterPlayfulness.receive(on: RunLoop.main).sink { [weak engine] v in engine?.scheduler.playfulness = v }.store(in: &critterBag)
                model.$critterReduceMotion.receive(on: RunLoop.main).sink { [weak engine] v in engine?.reduceMotion = v || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }.store(in: &critterBag)
                critter = p
            }
            critter?.place(); critter?.orderFrontRegardless(); critter?.engine.start()
            panel.orderOut(nil)
        } else {
            critter?.engine.stop(); critter?.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceLock.acquire(path: "/private/tmp/local.veda.\(getuid()).lock") else { NSApp.terminate(nil); return }
        model.restoreUpgradeText()
        NSApp.setActivationPolicy(.accessory)
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 46, height: 20), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: Bar(model: model))
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        panel.setFrameOrigin(NSPoint(x: screen.midX - 23, y: screen.minY + 18)); panel.orderFrontRegardless()
        model.showOverlayImmediately = { [weak self] in self?.resizePanel(active: true, hasNotice: false) }
        panelObservation = Publishers.CombineLatest(model.$overlayVisible, model.$notice).receive(on: RunLoop.main).sink { [weak self] visible, notice in
            guard let self else { return }
            self.resizePanel(active: visible, hasNotice: notice != nil)
        }
        screenObservation = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.resizePanel(active: self.model.overlayVisible, hasNotice: self.model.notice != nil)
        }
        model.hideSettingsForDictation = { [weak self] in self?.settings?.orderOut(nil) }
        model.settingsAction = { [weak self] in self?.showSettings() }
        applyOverlayStyle()
        model.$overlayStyle.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.applyOverlayStyle() }.store(in: &critterBag)
        model.relaunchAction = { [weak self] in self?.relaunch() }
        model.playgroundAction = { [weak self] in self?.showPlayground() }
        installGlobalMonitor()
        model.accessChanged = { [weak self] in self?.installGlobalMonitor() }
        local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown]) { [weak self] e in self?.event(e); return e }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.model.phase != .idle else { return }; self.model.invalidateTarget()
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = WaveformIcon.menuImage(); item.button?.image?.isTemplate = true; item.button?.toolTip = "gluu bot"; item.button?.target = self; item.button?.action = #selector(showMenu)
        model.prepare()
        model.showNotice("เลือก TH หรือ EN แล้วกด Fn ค้าง")
        // A fresh install (or a re-signed update) has no permissions: show the 3-step card right away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.model.refreshPermissions()
            if !(self.model.microphoneAllowed && self.model.accessibilityAllowed && CGPreflightScreenCaptureAccess() && self.model.hasAccurateModel) { self.showSettings() }
        }
    }
    func resizePanel(active: Bool, hasNotice: Bool) {
        critter?.place()
        guard model.overlayStyle != "character" else { panel.orderOut(nil); return }
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrame(OverlayPlacement.frame(screen: screen.frame, visible: screen.visibleFrame, active: active), display: true, animate: false)
    }
    // Own Fn while Veda runs so another dictation monitor cannot receive the same hold.
    // Requires normal macOS Accessibility permission; never bypass permission checks.
    func dispatchShortcut(_ action: DictationShortcut.Action) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case .begin: self.model.press()
            case .end: self.model.release()
            case .toggle:
                self.model.fnDown = false
                guard self.model.phase != .processing else { return }
                if self.model.phase != .idle { self.model.cancel() }
                self.model.selectMode(self.model.mode == .th ? .en : .th)
                self.model.showNotice("เปลี่ยนภาษาเป็น " + self.model.mode.rawValue)
                self.model.critterCues.send(.language(self.model.mode))
            case .playfulness:
                self.model.fnDown = false
                if self.model.phase != .idle && self.model.phase != .processing { self.model.cancel() }
                self.model.critterPlayfulness = (self.model.critterPlayfulness + 1) % 3
                self.model.showNotice("ความขี้เล่น: " + ["เงียบ", "ปกติ", "ขี้เล่น"][self.model.critterPlayfulness])
            }
        }
    }
    func installFnTap() {
        shortcut = DictationShortcut()
        if let fnSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), fnSource, .commonModes) }
        if let fnTap { CFMachPortInvalidate(fnTap) }
        fnTap = nil; fnSource = nil
        model.exclusiveFnReady = false
        defer { model.writeDiagnostics() }
        guard AXIsProcessTrusted() else { return }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<Delegate>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = owner.fnTap { CGEvent.tapEnable(tap: tap, enable: true) }
                DispatchQueue.main.async { owner.model.cancel() }
                return Unmanaged.passUnretained(event)
            }
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if (type == .keyDown || type == .keyUp), key == Int64(kVK_Space) {
                let outcome = owner.shortcut.space(down: type == .keyDown, repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
                if let action = outcome.action { owner.dispatchShortcut(action) }
                return outcome.consume ? nil : Unmanaged.passUnretained(event)
            }
            // Snap Translate chord (user-selectable). Consumed on both edges so the key never reaches the front app.
            if type == .keyDown || type == .keyUp,
               owner.model.snapShortcut.matches(keyCode: key, command: event.flags.contains(.maskCommand), shift: event.flags.contains(.maskShift),
                                              control: event.flags.contains(.maskControl), option: event.flags.contains(.maskAlternate)) {
                if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { DispatchQueue.main.async { owner.snapTranslate() } }
                return nil
            }
            if owner.model.externalF18, key == Int64(kVK_F18), type == .keyDown || type == .keyUp {
                if let action = owner.shortcut.trigger(.f18, down: type == .keyDown) { owner.dispatchShortcut(action) }
                return nil
            }
            // Fn + Option cycles the character's playfulness. Modifiers pass through untouched.
            if type == .flagsChanged, key == 58 || key == 61 {
                if let action = owner.shortcut.option(down: event.flags.contains(.maskAlternate)) { owner.dispatchShortcut(action) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .flagsChanged, key == 63 else { return Unmanaged.passUnretained(event) }
            if let action = owner.shortcut.trigger(.fn, down: event.flags.contains(.maskSecondaryFn)) { owner.dispatchShortcut(action) }
            return nil
        }
        let mask = CGEventMask((1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        // HID level runs before macOS handles its own ⇧⌘3; fall back to the session tap if it is refused.
        var level = "hid"
        var created = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if created == nil {
            level = "session"
            created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        }
        guard let tap = created else { model.tapLevel = "none"; return }
        model.tapLevel = level
        fnTap = tap
        fnSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), fnSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        model.exclusiveFnReady = CGEvent.tapIsEnabled(tap: tap)
    }
    func installGlobalMonitor() {
        installFnTap()
        if let global { NSEvent.removeMonitor(global) }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown]) { [weak self] e in self?.event(e) }
    }
    func event(_ e: NSEvent) {
        if e.type == .keyDown || e.type == .keyUp, model.externalF18, e.keyCode == UInt16(kVK_F18) {
            if fnTap == nil && !e.isARepeat {
                if e.type == .keyDown { model.press() } else { model.release() }
            }
            return
        }
        if e.type == .flagsChanged {
            // Only the physical Fn event: arrow/navigation keys can also carry .function.
            guard e.keyCode == 63, fnTap == nil else { return }
            if e.modifierFlags.contains(.function) { model.press() } else { model.release() }
        } else if e.type == .keyDown, e.keyCode == 53, snap.isVisible { snap.close() }
        else if e.type == .keyDown, e.keyCode == 53, model.phase != .idle { model.cancel() }
        else if e.type == .keyDown { model.invalidateTarget() }
        else if (e.type == .leftMouseDown || e.type == .rightMouseDown) {
            // The result card is transient: a click anywhere else dismisses it.
            if snap.isVisible, !snap.frameContains(NSEvent.mouseLocation) { snap.close() }
            if !panel.frame.contains(NSEvent.mouseLocation) && !(critter?.frame.contains(NSEvent.mouseLocation) ?? false) { model.invalidateTarget() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showNotice("เลือก TH หรือ EN แล้วกด Fn ค้าง")
        panel.orderFrontRegardless()
        return true
    }
    @objc func showMenu() {
        let menu = NSMenu()
        for (title, action) in [("เปิดแถบ TH/EN", #selector(revealBar)), ("ตั้งค่าและข้อความพัก", #selector(showSettings)), ("ออกจาก gluu bot", #selector(quitVeda))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        item.menu = menu; item.button?.performClick(nil); item.menu = nil
    }
    @objc func revealBar() { model.showNotice("เลือก TH หรือ EN แล้วกด Fn ค้าง"); if model.overlayStyle == "character" { critter?.orderFrontRegardless() } else { panel.orderFrontRegardless() } }
    @objc func quitVeda() { NSApp.terminate(nil) }
    @objc func showSettings() {
        model.refreshPermissions()
        if settings == nil {
            settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings?.title = "gluu bot"; settings?.isReleasedWhenClosed = false
            settings?.contentView = NSHostingView(rootView: Settings(model: model)); settings?.center()
        }
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    var playground: NSWindow?
    var playgroundEngine: CritterEngine?
    @objc func showPlayground() {
        if playground == nil {
            let engine = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272))
            engine.scheduler.playfulness = model.critterPlayfulness
            engine.reduceMotion = model.critterReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            model.$critterPlayfulness.receive(on: RunLoop.main).sink { [weak engine] v in engine?.scheduler.playfulness = v }.store(in: &critterBag)
            let view = CritterPlayground(engine: engine, model: model)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "ดูท่าทางและอารมณ์"; w.isReleasedWhenClosed = false; w.contentView = NSHostingView(rootView: view); w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak engine] _ in engine?.stop() }
            playground = w; playgroundEngine = engine
        }
        playgroundEngine?.start()
        playground?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.preservePendingForUpgrade()
        if let fnTap { CFMachPortInvalidate(fnTap) }
        model.cancel(); model.audio.shutdown(); model.backend.stop()
        if let global { NSEvent.removeMonitor(global) }; if let local { NSEvent.removeMonitor(local) }
    }
}
let app = NSApplication.shared
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--render-overlays" {
    try OverlaySnapshots.render(to: CommandLine.arguments[2])
} else if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--probe-focus" {
    // Give the user three seconds to click into the field under test, then describe it.
    Thread.sleep(forTimeInterval: 3)
    print("trusted:", AXIsProcessTrusted(), "| frontmost:", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")
    if let target = Target.capture() {
        print("accepted role=\(Target.lastRole) caret=\(target.stamp.location)+\(target.stamp.length) valueLength=\(target.stamp.value.count)")
    } else {
        print("rejected:", Target.lastRejection ?? "no focused element or not trusted")
    }
} else {
    let delegate = Delegate()
    app.delegate = delegate
    app.run()
}
