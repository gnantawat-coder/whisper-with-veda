import AppKit
import SwiftUI
import Vision
import Translation
import AVFoundation

// Snap Translate: ⌘⇧2 → the system region picker → on-device OCR → on-device
// translation → a floating panel with the result. The screenshot exists only as
// a temporary file for the length of the OCR call and is deleted before anything
// else happens; no image or text is stored or sent anywhere.
// State is only touched on the main thread: the hotkey dispatches there, the
// capture task hops back with MainActor.run, and translationTask runs there.
final class SnapTranslator: ObservableObject {
    @Published var source = ""
    @Published var translated = ""
    @Published var status = ""
    @Published var busy = false
    @Published var direction: SnapText.Direction = .thaiToEnglish
    @Published var mode: Slang.Mode = .polite
    @Published var notes: [SlangNote] = []
    var showNotes = true
    var entries: [SlangEntry] = Slang.seed
    private var sendText = ""
    @Published var configuration: TranslationSession.Configuration?
    /// Diagnostics: stage names and timings only, never text.
    @Published var lastRun = "-"
    var onFinished: (() -> Void)?
    /// Called at each stage so diagnostics show where a run stopped.
    var onStage: (() -> Void)?
    @Published var stalled = false
    private var attempt = 0
    // If the translator never answers, say so and offer a retry instead of spinning forever.
    private func armWatchdog(for id: Int) {
        stalled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.attempt == id, self.translated.isEmpty, self.status.hasPrefix("กำลัง") else { return }
            self.stalled = true
            self.status = "ตัวแปลไม่ตอบภายใน 20 วินาที"
            self.lastRun += " · translator did not respond"
            self.resize(); self.onStage?()
        }
    }
    func retry() { guard !source.isEmpty else { return }; begin(source, direction: direction) }
    func setMode(_ new: Slang.Mode) {
        guard new != mode else { return }
        mode = new; stopSpeaking()
        if !source.isEmpty { begin(source, direction: direction) }
    }
    var speakEnabled = false
    @Published var speaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var speechDelegate: SpeechDelegate?
    private var panel: NSPanel?
    // Reads the translation aloud in the target language's voice, on device.
    func speak() {
        guard !translated.isEmpty else { return }
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: translated)
        utterance.voice = Self.bestVoice(for: direction == .thaiToEnglish ? "en" : "th")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if speechDelegate == nil { speechDelegate = SpeechDelegate { [weak self] in self?.speaking = false }; synthesizer.delegate = speechDelegate }
        speaking = true; synthesizer.speak(utterance)
    }
    // An enhanced/premium voice if one is installed; otherwise the system's own
    // default for the language, never a novelty voice picked by accident.
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let locale = language == "th" ? "th-TH" : "en-US"
        let upgraded = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == locale && $0.quality != .default }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        return upgraded ?? AVSpeechSynthesisVoice(language: locale)
    }
    func stopSpeaking() { if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }; speaking = false }
    final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
        let finished: () -> Void
        init(finished: @escaping () -> Void) { self.finished = finished }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { DispatchQueue.main.async { self.finished() } }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { DispatchQueue.main.async { self.finished() } }
    }

    func requestCapture() {
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            lastRun = "screen recording not granted"
            status = "อนุญาต Screen Recording ให้ gluu bot ใน System Settings แล้วกด \"เปิด gluu bot ใหม่\""
            source = ""; translated = ""; show(); return
        }
        busy = true; lastRun = "capturing"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("veda-snap-\(UUID().uuidString).png")
        let started = Date()
        Task.detached { [weak self] in
            // The system's own region picker (-i -s): familiar, precise, Escape cancels.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-s", "-x", "-t", "png", file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit() } catch {}
            let lines: [TextLine]? = {
                guard let image = NSImage(contentsOf: file), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return Self.recognise(cg)
            }()
            try? FileManager.default.removeItem(at: file)   // the screenshot never outlives the OCR call
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy = false
                guard let lines else { self.lastRun = "cancelled"; return }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let passage = SnapText.passage(from: SnapLayout.readingOrder(lines).map(\.text))
                guard !passage.isEmpty else {
                    self.lastRun = "ocr found no text (\(ms) ms)"
                    self.source = ""; self.translated = ""; self.status = "ไม่พบข้อความในส่วนที่เลือก ลองเลือกให้ครอบตัวหนังสือชัด ๆ"
                    self.show(); return
                }
                self.lastRun = "ocr \(lines.count) lines in \(ms) ms"
                self.onStage?()
                self.begin(passage, direction: SnapText.direction(of: passage))
            }
        }
    }

    // Vision reads Thai and English together; lines come back top to bottom.
    private static func recognise(_ cg: CGImage) -> [TextLine]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["th-TH", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return (request.results ?? []).compactMap { o in o.topCandidates(1).first.map { TextLine(text: $0.string, box: o.boundingBox) } }
    }

    func begin(_ text: String, direction: SnapText.Direction) {
        source = text; translated = ""; self.direction = direction
        // Known slang goes to the translator as plain language; the notes remember what it was.
        let prepared = Slang.prepare(text, sourceIsThai: direction == .thaiToEnglish, mode: mode, entries: entries)
        sendText = prepared.text; notes = prepared.notes
        status = "กำลังแปลบนเครื่อง…"
        let th = Locale.Language(identifier: "th"), en = Locale.Language(identifier: "en")
        // translationTask re-runs only when the configuration value changes. A fresh
        // Configuration invalidated once equals the previous one (same languages,
        // same version), so the second capture never translated. Keep one
        // configuration per direction and invalidate *that* so its version climbs.
        let sameLanguages = configuration?.source == (direction == .thaiToEnglish ? th : en)
        if sameLanguages, configuration != nil {
            configuration!.invalidate()
        } else {
            configuration = direction == .thaiToEnglish
                ? TranslationSession.Configuration(source: th, target: en)
                : TranslationSession.Configuration(source: en, target: th)
        }
        attempt += 1
        armWatchdog(for: attempt)
        onStage?()
        show()
    }
    func swapDirection() {
        guard !source.isEmpty else { return }
        stopSpeaking()
        begin(source, direction: direction == .thaiToEnglish ? .englishToThai : .thaiToEnglish)
    }
    // Runs inside the view's translationTask, which is the only place a session exists.
    @MainActor func translate(with session: TranslationSession) async {
        let started = Date()
        do {
            try await session.prepareTranslation()   // first use prompts macOS to download the language pack
            let response = try await session.translate(sendText)
            translated = Slang.finish(response.targetText, notes: notes, mode: mode); status = ""; stalled = false
            resize()
            if speakEnabled { speak() }
            lastRun += " · translated in \(Int(Date().timeIntervalSince(started) * 1000)) ms"
        } catch {
            status = "แปลไม่สำเร็จ: " + error.localizedDescription
            resize()
            lastRun += " · translation failed"
        }
        onFinished?()
    }
    func copyTranslation() {
        guard !translated.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(translated, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.copied = false }
    }
    @Published var copied = false
    @Published var contentHeight: CGFloat = 0
    static let cardWidth: CGFloat = 640
    private var host: NSHostingView<SnapView>?
    var isVisible: Bool { panel?.isVisible == true }
    func frameContains(_ point: NSPoint) -> Bool { panel?.frame.contains(point) == true }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.isReleasedWhenClosed = false; p.level = .floating; p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let h = NSHostingView(rootView: SnapView(snap: self)); h.frame = p.contentView!.bounds
            p.contentView = h; host = h; panel = p
        }
        resize()
        // Land just below-right of the pointer, where the selection was finished.
        if let p = panel, !p.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            var origin = NSPoint(x: mouse.x + 14, y: mouse.y - 14 - p.frame.height)
            origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - p.frame.width - 8)
            origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - p.frame.height - 8)
            p.setFrameOrigin(origin)
        }
        panel?.orderFrontRegardless()
    }
    // Height follows the content, capped so long passages scroll inside.
    func resize() {
        guard let p = panel, host != nil else { return }
        // header 46 + measured body + footer 62 when a translation is shown.
        let body = min(max(contentHeight, 60), 380)
        let height = 46 + body + 28 + (translated.isEmpty ? 0 : 62)
        let top = p.frame.maxY
        p.setContentSize(NSSize(width: Self.cardWidth, height: height))
        if p.isVisible { p.setFrameTopLeftPoint(NSPoint(x: p.frame.minX, y: top)) }
    }
    func close() { stopSpeaking(); panel?.orderOut(nil); copied = false }
}

// Result card: one direction pill, the source in a quiet voice, the translation
// as the single loud element, one filled action. Nothing else competes.
struct SnapView: View {
    @ObservedObject var snap: SnapTranslator
    private var directionLabel: String { snap.direction == .thaiToEnglish ? "TH → EN" : "EN → TH" }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(directionLabel).font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(0.4)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                Text("Snap Translate").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Picker("", selection: Binding(get: { snap.mode }, set: { snap.setMode($0) })) {
                    Text("สุภาพ").tag(Slang.Mode.polite)
                    Text("แชทจริง").tag(Slang.Mode.chat)
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150).help("สุภาพ: สแลงเป็นภาษามาตรฐาน · แชทจริง: รักษาระดับภาษาเดิม")
                Button { snap.speaking ? snap.stopSpeaking() : snap.speak() } label: { Image(systemName: snap.speaking ? "speaker.wave.2.fill" : "speaker.wave.2") }
                    .buttonStyle(.plain).foregroundStyle(snap.speaking ? Color.accentColor : .secondary).help(snap.speaking ? "หยุดอ่าน" : "อ่านออกเสียง").disabled(snap.translated.isEmpty)
                Menu {
                    Button("สลับทิศทาง", systemImage: "arrow.left.arrow.right") { snap.swapDirection() }.disabled(snap.source.isEmpty || snap.busy)
                    Button("คัดลอกต้นฉบับ", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(snap.source, forType: .string) }.disabled(snap.source.isEmpty)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
                Button { snap.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("ปิด (Esc)")
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if !snap.source.isEmpty {
                        Text(snap.source).font(.system(size: 15)).foregroundStyle(.secondary)
                            .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                    }
                    if !snap.translated.isEmpty {
                        Text(snap.translated).font(.system(size: 22, weight: .medium)).lineSpacing(5)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if snap.showNotes && !snap.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(snap.notes.enumerated()), id: \.offset) { _, note in
                                    HStack(spacing: 6) {
                                        Image(systemName: "text.bubble").font(.caption2).foregroundStyle(.tertiary)
                                        Text(note.source).foregroundStyle(.secondary)
                                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                        Text(note.target).fontWeight(.medium)
                                        if !note.meaning.isEmpty { Text(note.meaning).foregroundStyle(.tertiary) }
                                        if note.register != .casual {
                                            Text(note.register == .vulgar ? "หยาบ" : "ไม่สุภาพ").font(.system(size: 10, weight: .semibold))
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background((note.register == .vulgar ? Color.red : Color.orange).opacity(0.18), in: Capsule())
                                                .foregroundStyle(note.register == .vulgar ? Color.red : Color.orange)
                                        }
                                    }.font(.system(size: 12))
                                }
                            }.padding(.top, 2)
                        }
                    } else if !snap.status.isEmpty {
                        HStack(spacing: 8) {
                            if snap.status.hasPrefix("กำลัง") { ProgressView().controlSize(.small) }
                            Text(snap.status).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if snap.stalled { Button("ลองอีกครั้ง") { snap.retry() }.controlSize(.small) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 14)
                .background(GeometryReader { geo in Color.clear.preference(key: SnapBodyHeight.self, value: geo.size.height) })
            }.frame(maxHeight: 380)
            .onPreferenceChange(SnapBodyHeight.self) { height in
                if abs(snap.contentHeight - height) > 1 { snap.contentHeight = height; snap.resize() }
            }

            if !snap.translated.isEmpty {
                HStack {
                    Text("แปลบนเครื่อง · ไม่เก็บภาพ").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Button { snap.copyTranslation() } label: {
                        Label(snap.copied ? "คัดลอกแล้ว" : "คัดลอกคำแปล", systemImage: snap.copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold)).frame(minWidth: 132)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(snap.copied ? .green : .accentColor)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Color.primary.opacity(0.035))
            }
        }
        .frame(width: SnapTranslator.cardWidth)
        .background(.ultraThinMaterial)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .translationTask(snap.configuration) { session in await snap.translate(with: session) }
    }
}

struct SnapBodyHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
