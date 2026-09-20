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
            ("critter-sad", .sad, .idle, 0, 0), ("critter-shy", .shy, .idle, 0, 0), ("critter-bye", .bye, .idle, 0, 0), ("critter-deep", .curious, .idle, 1, 0),
            ("critter-dizzy", .dizzy, .idle, 0, 0), ("critter-thinking", .normal, .thinking, 0, 0), ("critter-wow", .wow, .idle, 0, 0), ("critter-annoyed", .annoyed, .idle, 0, 0)]
        // Set pieces at the moment that shows the prop, plus the one-tick effects pinned just after they fired.
        let sceneShots: [(String, Critter.Scene, Double, Bool, Bool, Bool, String?)] = [
            ("critter-inflate", .inflate, 2.4, false, false, false, "!!"), ("critter-burst", .inflate, 2.62, true, false, false, nil), ("critter-baby", .inflate, 4.0, false, false, false, "อุแว้~"),
            ("critter-lightning", .lightning, 0.61, false, false, false, "!!"), ("critter-charred", .lightning, 1.6, false, false, false, "@_@"),
            ("critter-rain-umbrella", .rainUmbrella, 3.0, false, false, false, "~♪"), ("critter-rain", .rain, 3.0, false, false, false, "TT"),
            ("critter-balloon", .balloon, 4.0, false, false, false, "ลอย~"), ("critter-balloon-pop", .balloon, 5.42, false, true, false, "!!"),
            ("critter-manhole-in", .manhole, 1.0, false, false, false, "โดด!"), ("critter-manhole-closed", .manhole, 3.0, false, false, false, nil),
            ("critter-sneeze", .sneeze, 1.3, false, false, true, "ฮัดเช้ย!"), ("critter-hiccup", .hiccup, 0.95, false, true, false, "ฮึก")]
        var shots: [(String, CritterEngine)] = critterStates.map { st in let e = CritterEngine(); e.settle(mood: st.1, external: st.2, z: st.3, level: st.4); return (st.0, e) }
        shots += sceneShots.map { sh in let e = CritterEngine(); e.settle(scene: sh.1, t: sh.2, burst: sh.3, pop: sh.4, droplets: sh.5, bubbleText: sh.6); return (sh.0, e) }
        let gagShots: [(String, Critter.Scene, Double, Bool, String?)] = [
            ("critter-eyepop", .eyePop, 1.0, false, "!!!"), ("critter-tornado", .tornado, 1.5, false, "หวืดดด!"),
            ("critter-spinjump", .spinJump, 0.9, false, "เย้!"), ("critter-levitate", .levitate, 3.0, false, "อืมมม~"), ("critter-ghost", .ghost, 1.5, false, "!!!"), ("critter-star", .shootingStar, 1.3, false, "ดาวตก!"),
            ("critter-flood-pour", .flood, 2.0, false, "!!"), ("critter-flood-swim", .flood, 6.8, false, "ว่าย ว่าย"), ("critter-flood-pant", .flood, 10.5, false, "ฮึบ… ฮึบ…"),
            ("critter-plane-climb", .plane, 4.5, false, "เมฆ!"), ("critter-plane-jump", .plane, 6.3, false, "ว้ากกก!"), ("critter-dance", .dance, 1.2, false, "♪♪"),
            ("critter-ninja-bomb", .ninja, 0.7, false, nil), ("critter-ninja-cloud", .ninja, 1.2, false, "หายตัว!"), ("critter-ninja-door", .ninja, 4.6, false, nil), ("critter-ninja-out", .ninja, 5.2, false, "ทาดา~"),
            ("critter-box", .box, 2.0, false, "..."), ("critter-melt", .melt, 3.0, false, "ร้อน… ละลาย…"), ("critter-freeze", .freeze, 2.0, false, "แข็ง…"), ("critter-freeze-crack", .freeze, 4.3, false, nil), ("critter-trip", .trip, 1.2, false, "อุ๊ย!"),
            ("critter-anvil", .pancake, 0.5, false, "…?"), ("critter-pancake", .pancake, 2.0, true, "แบน…"), ("critter-rubber", .rubber, 1.0, false, "ฮ่าฮ่าฮ่า!"),
            ("critter-dash", .dash, 0.65, false, "บี๊บ บี๊บ!"), ("critter-eat", .eat, 2.0, false, "หง่ำ ๆ"), ("critter-read", .read, 5.0, false, "อ่าน ๆ"), ("critter-hearts", .heartEyes, 1.0, false, "♥♥")]
        shots += gagShots.map { sh in let e = CritterEngine(); e.settle(scene: sh.1, t: sh.2, pop: sh.3, bubbleText: sh.4); return (sh.0, e) }
        let weatherShots: [(String, Critter.Weather, Bool, Bool, Critter.Mood, String?)] = [
            ("critter-sunny", .sunny, false, false, .happy, "^^"), ("critter-heat", .heat, false, false, .hot, "ร้อนน~"), ("critter-wind", .wind, false, false, .worried, "…?"),
            ("critter-snow", .snow, false, false, .cold, "brr"), ("critter-weather-rain", .rain, true, false, .normal, nil), ("critter-night", .clear, false, true, .sleepy, "zZ"),
            ("critter-hungry", .clear, false, false, .hungry, "กร๊อกกก"), ("critter-sulky", .clear, false, false, .sulky, "หึ")]
        // The same faces at playground size, where the LED dots can be judged one by one.
        for st in critterStates.prefix(2) + critterStates.suffix(4) { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(mood: st.1, external: st.2, z: st.3, level: st.4); shots.append((st.0 + "-big", e)) }
        for (name, m) in [("critter-happy-big", Critter.Mood.happy), ("critter-sad-big", .sad), ("critter-shy-big", .shy)] { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(mood: m); shots.append((name, e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .heartEyes, t: 1.0, bubbleText: "♥♥"); shots.append(("critter-hearts-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .eyePop, t: 1.0, bubbleText: "!!!"); shots.append(("critter-eyepop-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(asleepWithBird: true); shots.append(("critter-sleep-bird-big", e)) }
        do { let e = CritterEngine(); e.settle(asleepWithBird: true); shots.append(("critter-sleep-bird", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .plane, t: 4.5, bubbleText: "เมฆ!"); shots.append(("critter-plane-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .flood, t: 2.0, bubbleText: "!!"); shots.append(("critter-flood-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .dance, t: 1.2, bubbleText: "♪♪"); shots.append(("critter-dance-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .ninja, t: 4.6); shots.append(("critter-ninja-door-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .balloon, t: 4.0, bubbleText: "ลอย~"); shots.append(("critter-balloon-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .rainUmbrella, t: 3.0, bubbleText: "~♪"); shots.append(("critter-umbrella-big", e)) }
        shots += weatherShots.map { sh in let e = CritterEngine(); e.settle(weather: sh.1, umbrella: sh.2, night: sh.3, age: 100, mood: sh.4, bubbleText: sh.5); return (sh.0, e) }
        for (name, engine) in shots {
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
