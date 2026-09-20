import AppKit
import SwiftUI

enum WaveformIcon {
    static func menuImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for (index, height) in [6.0, 16.0, 11.0, 5.0].enumerated() {
                NSBezierPath(roundedRect: NSRect(x: 1 + Double(index)*4.3, y: (18-height)/2, width: 2.2, height: height), xRadius:1.1,yRadius:1.1).fill()
            }
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = "gluu bot"
        return image
    }
}

// Offscreen visual QA. No delegate, event monitors, timers, microphone, or backend.
enum OverlaySnapshots {
    static func render(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let scenarios: [(String, Phase, String?)] = [("idle", .idle, nil), ("listening", .recording, nil), ("processing", .processing, nil), ("held", .idle, "ข้อความพักไว้"), ("permission", .idle, "อนุญาตไมโครโฟนก่อนพูด")]
        let settingsModel = Model()
        settingsModel.microphoneAllowed = true; settingsModel.accessibilityAllowed = true
        settingsModel.microphoneStatus = "อนุญาตแล้ว"; settingsModel.accessibilityStatus = "อนุญาตแล้ว"
        settingsModel.status = "พร้อมแล้ว · กด Fn ค้างเพื่อพูด"
        // Stated outright: these views read saved defaults, so the empty state has to
        // be set here or a previous run's profile leaks into the "new user" snapshot.
        settingsModel.profileName = "โปรไฟล์ของฉัน"; settingsModel.profileWords = ""
        settingsModel.vocabulary = ""; settingsModel.examples = []

        // The profile page is reviewed both empty and carrying saved content, because
        // long Thai vocabulary and example cards are what actually stretch the layout.
        let filledProfile = Model()
        filledProfile.microphoneAllowed = true; filledProfile.accessibilityAllowed = true
        filledProfile.microphoneStatus = "อนุญาตแล้ว"; filledProfile.accessibilityStatus = "อนุญาตแล้ว"
        filledProfile.profileName = "สมชาย"
        filledProfile.profileWords = "gluu bot, Keychron K2 Max, whisper, ถอดเสียง, สมชาย"
        filledProfile.calibrationExpected = "เปลี่ยนคำพูดให้เป็นข้อความ"
        filledProfile.calibrationHeard = "เปลี่ยนคําพูดให้เป็นข้อความ"
        filledProfile.calibrationStatus = "ตรวจคำที่ผิด แล้วเพิ่มเฉพาะชื่อหรือศัพท์ที่คุณใช้ในช่องคำศัพท์ส่วนตัว"
        filledProfile.examples = [["expected": "เปลี่ยนคำพูดให้เป็นข้อความ", "heard": "เปลี่ยนคําพูดให้เป็นข้อความ"]]
        filledProfile.terms = [["heard": "คลอส", "correct": "Claude"], ["heard": "Codec", "correct": "Codex"]]
        settingsModel.terms = []

        // 650 is the real window height; the tall render exists only so the whole
        // scrolling page can be reviewed in one image.
        for (name, model, section, height) in [("settings", settingsModel, 0, 650.0), ("settings-profile", settingsModel, 3, 650.0), ("settings-profile-filled", filledProfile, 3, 650.0), ("settings-profile-full-page", filledProfile, 3, 1200.0)] {
            let settingsFrame = NSRect(x: 0, y: 0, width: 780, height: height)
            let settingsWindow = NSWindow(contentRect: settingsFrame, styleMask: .borderless, backing: .buffered, defer: false)
            settingsWindow.isReleasedWhenClosed = false
            let settingsHost = NSHostingView(rootView: Settings(model: model, section: section))
            settingsHost.frame = settingsFrame; settingsWindow.contentView = settingsHost
            settingsHost.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            if let bitmap = settingsHost.bitmapImageRepForCachingDisplay(in: settingsHost.bounds) {
                settingsHost.cacheDisplay(in: settingsHost.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: directory + "/" + name + ".png")) }
            }
            settingsWindow.close()
        }
        // Snap Translate result panel with representative Thai→English content.
        let snap = SnapTranslator()
        snap.source = "โปรแกรมนี้ต้องแปลงเสียงภาษาไทยเป็นข้อความภาษาอังกฤษ แก้ไขโปรแกรมได้ แต่ห้ามลบข้อมูลผู้ใช้"
        snap.translated = "This program must convert Thai speech into English text. You may edit the program, but do not delete user data."
        snap.mode = .chat
        snap.notes = [SlangNote(source: "เดือดสัส", target: "intense as hell", plain: "very intense", register: .vulgar, meaning: "ดุเดือด/มันมาก")]
        let snapFrame = NSRect(x: 0, y: 0, width: 640, height: 340)
        let snapWindow = NSWindow(contentRect: snapFrame, styleMask: .borderless, backing: .buffered, defer: false)
        snapWindow.isReleasedWhenClosed = false
        let snapHost = NSHostingView(rootView: SnapView(snap: snap)); snapHost.frame = snapFrame; snapWindow.contentView = snapHost
        snapHost.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        if let bitmap = snapHost.bitmapImageRepForCachingDisplay(in: snapHost.bounds) {
            snapHost.cacheDisplay(in: snapHost.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: directory + "/snap.png")) }
        }
        snapWindow.close()
        // The corner character in the states that carry the most meaning, at real size on a
        // mid-grey ground so both the black body and the white bubble can be judged.
        let critterStates: [(String, Critter.Mood, CritterEngine.External, Double, Double)] = [
            ("critter-normal", .normal, .idle, 0, 0), ("critter-listening", .normal, .listening, 0, 0.8), ("critter-happy", .happy, .idle, 0, 0),
            ("critter-sad", .sad, .idle, 0, 0), ("critter-shy", .shy, .idle, 0, 0), ("critter-bye", .bye, .idle, 0, 0), ("critter-deep", .curious, .idle, 1, 0)]
        for (name, mood, ext, z, lv) in critterStates {
            let engine = CritterEngine()
            engine.settle(mood: mood, external: ext, z: z, level: lv)
            let frame = NSRect(origin: .zero, size: engine.panelSize)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.backgroundColor = NSColor(white: 0.55, alpha: 1)
            let host = NSHostingView(rootView: CritterView(engine: engine).background(Color(white: 0.55))); host.frame = frame; window.contentView = host
            host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: directory + "/" + name + ".png")) }
            }
            window.close()
        }
        for (name, phase, notice) in scenarios {
            let model = Model(); model.phase = phase; model.level = 0.65
            model.notice = notice; model.overlayVisible = name != "idle"
            if name == "held" { model.pending = ["ข้อความทดสอบ"] }
            // Review the marker at the size it actually gets on screen, not one size for all.
            let size = OverlayPlacement.frame(screen: .zero, visible: .zero, active: name != "idle").size
            let frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect:frame, styleMask:.borderless, backing:.buffered, defer:false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView:Bar(model:model)); host.frame = frame; window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { continue }
            host.cacheDisplay(in:host.bounds,to:bitmap)
            if let data = bitmap.representation(using:.png,properties:[:]) { try data.write(to:URL(fileURLWithPath:directory + "/" + name + ".png")) }
            window.close()
        }
    }
}

// The same four bars as the app icon, so the sidebar, the menu bar and the Dock
// all show one mark. Proportions are the icon's (220 : 500 : 350 : 160 of 1024).
struct WaveformMark: View {
    var size: CGFloat = 22
    var body: some View {
        let heights: [CGFloat] = [0.44, 1.0, 0.70, 0.32]
        HStack(alignment: .center, spacing: size * 0.14) {
            ForEach(0..<4, id: \.self) { index in
                Capsule(style: .continuous).frame(width: size * 0.105, height: size * heights[index])
            }
        }.frame(width: size, height: size)
    }
}
