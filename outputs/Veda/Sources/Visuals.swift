import AppKit
import SwiftUI
import ImageIO

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
    /// Review actual painter + deterministic live-engine steps. No app delegate or recording.
    static func renderActing(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func capture(_ samples: [(String, CritterEngine.Snapshot)], columns: Int, compact: Bool = false) -> CGImage? {
            let cell = CGSize(width: 180, height: compact ? 130 : 155)
            let size = CGSize(width: cell.width * Double(columns), height: cell.height * Double((samples.count + columns - 1) / columns))
            let canvas = Canvas { context, _ in
                for (index, sample) in samples.enumerated() {
                    let x = Double(index % columns) * cell.width, y = Double(index / columns) * cell.height
                    context.fill(Path(CGRect(x: x, y: y, width: cell.width, height: cell.height)), with: .color(Color(white: index % 2 == 0 ? 0.88 : 0.17)))
                    var s = sample.1
                    let ground = y + cell.height - 28
                    s.center = CGPoint(x: x + cell.width / 2, y: ground - s.drawRadius)
                    s.groundY = ground; s.area = CGRect(x: x, y: y, width: cell.width, height: cell.height)
                    CritterPainter.draw(s, in: &context)
                    context.draw(Text(sample.0).font(.system(size: 12, weight: .medium)).foregroundColor(index % 2 == 0 ? .black : .white), at: CGPoint(x: x + cell.width / 2, y: ground + 15))
                }
            }.frame(width: size.width, height: size.height)
            let frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: canvas); host.frame = frame; window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.015))
            defer { window.close() }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.cgImage
        }
        func writePNG(_ image: CGImage, name: String) throws {
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
            }
        }
        for radius in [24.0, 44.0] {
            let samples = Critter.Mood.allCases.map { mood -> (String, CritterEngine.Snapshot) in
                let engine = CritterEngine(radius: radius)
                engine.quiet = true; engine.weatherEnabled = false; engine.settle(mood: mood)
                return (mood.rawValue, engine.snapshot)
            }
            if let image = capture(samples, columns: 5, compact: radius == 24) { try writePNG(image, name: "expressions-\(Int(radius))") }
        }
        let moods: [Critter.Mood] = [.normal, .curious, .happy, .startled, .sad, .annoyed, .thinking, .laugh]
        let engines = moods.map { _ -> CritterEngine in
            let engine = CritterEngine(radius: 36)
            engine.quiet = true; engine.weatherEnabled = false; engine.eyeTracking = false
            engine.settle(mood: .normal)
            return engine
        }
        let url = URL(fileURLWithPath: directory + "/acting.gif")
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 90, nil) else { return }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var bounds = [String: [Double]]()
        for frame in 0..<90 {
            for (index, engine) in engines.enumerated() {
                if frame == 9 { engine.setMood(moods[index], hold: 10, speak: false) }
                if frame == 51 && index == 0 { engine.reviewBlink() }
                engine.reviewStep()
                let face = engine.snapshot.face
                let values = [face.left.w, face.left.h, face.right.w, face.right.h, face.tilt, face.sx, face.sy, engine.snapshot.blink]
                precondition(values.allSatisfy { $0.isFinite } && face.sx > 0 && face.sy > 0, "Invalid acting frame")
                bounds["\(moods[index].rawValue)-\(frame)"] = values
            }
            if let image = capture(zip(moods, engines).map { ($0.0.rawValue, $0.1.snapshot) }, columns: 4) {
                CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
                if [9, 12, 18, 30, 53, 57].contains(frame) { try writePNG(image, name: "acting-frame-\(frame)") }
            }
        }
        guard CGImageDestinationFinalize(gif) else { throw NSError(domain: "VedaActingReview", code: 1) }
        let metrics = try JSONSerialization.data(withJSONObject: bounds, options: [.sortedKeys])
        try metrics.write(to: URL(fileURLWithPath: directory + "/acting-frames.json"))
        print("Rendered 29 expressions at radius 24 and 44, plus 90 frames of eight live-engine reactions.")
    }
    /// Cosplay review: the bee helmet over the expressions (front and turned), during the drop, in two scenes,
    /// at the real corner size (24) and the preview size (44), plus the voice lines it picks.
    static func renderCostume(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func sheet(_ samples: [(String, CritterEngine.Snapshot, String?)], columns: Int, cell: CGSize) -> CGImage? {
            let size = CGSize(width: cell.width * Double(columns), height: cell.height * Double((samples.count + columns - 1) / columns))
            let canvas = Canvas { context, _ in
                for (index, sample) in samples.enumerated() {
                    let x = Double(index % columns) * cell.width, y = Double(index / columns) * cell.height
                    let light = (index / columns + index % columns) % 2 == 0
                    context.fill(Path(CGRect(x: x, y: y, width: cell.width, height: cell.height)), with: .color(Color(white: light ? 0.9 : 0.2)))
                    var s = sample.1
                    let ground = y + cell.height - 26
                    s.center = CGPoint(x: x + cell.width / 2, y: ground - s.drawRadius)
                    s.groundY = ground; s.area = CGRect(x: x, y: y, width: cell.width, height: cell.height)
                    CritterPainter.draw(s, in: &context)
                    if let b = sample.2 {
                        context.draw(Text(b).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(light ? .black : .white), at: CGPoint(x: x + cell.width / 2, y: y + 14))
                    }
                    context.draw(Text(sample.0).font(.system(size: 11)).foregroundColor(light ? .black : .white), at: CGPoint(x: x + cell.width / 2, y: ground + 14))
                }
            }.frame(width: size.width, height: size.height)
            let frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: canvas); host.frame = frame; window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.015))
            defer { window.close() }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.cgImage
        }
        func write(_ image: CGImage?, _ name: String) throws {
            guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try data.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        }
        let moods: [Critter.Mood] = [.normal, .happy, .curious, .wow, .sad, .annoyed, .shy, .asleep, .loved, .dizzy, .hungry, .laugh]
        for costume in [Critter.Costume.bee, .prime] { for (radius, eyes) in [(24.0, "pixel"), (44.0, "pixel"), (44.0, "classic")] {
            var samples = moods.map { m -> (String, CritterEngine.Snapshot, String?) in
                let engine = CritterEngine(radius: radius)
                engine.weatherEnabled = false; engine.eyeTracking = false; engine.pixelEyes = eyes == "pixel"
                engine.setCostume(costume, announce: false); engine.settle(mood: m)
                return (m.rawValue, engine.snapshot, radius > 30 ? engine.bubble : nil)
            }
            for (label, ext) in [("listening", CritterEngine.External.listening), ("thinking", .thinking)] {
                let engine = CritterEngine(radius: radius)
                engine.weatherEnabled = false; engine.eyeTracking = false; engine.pixelEyes = eyes == "pixel"
                engine.setCostume(costume, announce: false); engine.settle(mood: .normal, external: ext, level: 0.6)
                samples.append((label, engine.snapshot, nil))
            }
            for amount in [0.25, 0.6] {   // the helmet dropping onto the head
                let engine = CritterEngine(radius: radius)
                engine.weatherEnabled = false; engine.eyeTracking = false; engine.pixelEyes = eyes == "pixel"
                engine.settle(mood: .happy)
                var s = engine.snapshot; s.costume = costume; s.costumeT = amount
                samples.append(("drop \(Int(amount * 100))%", s, nil))
            }
            for (scene, t) in [(Critter.Scene.rainUmbrella, 3.0), (.pancake, 2.6)] {
                let engine = CritterEngine(radius: radius)
                engine.weatherEnabled = false; engine.eyeTracking = false; engine.pixelEyes = eyes == "pixel"
                engine.setCostume(costume, announce: false); engine.settle(scene: scene, t: t)
                samples.append((scene.rawValue, engine.snapshot, nil))
            }
            try write(sheet(samples, columns: 6, cell: radius > 30 ? CGSize(width: 190, height: 190) : CGSize(width: 120, height: 110)), "costume-\(costume.rawValue)-\(Int(radius))-\(eyes)")
        } }
        // Voice sample: the same moments with and without the costume (text only, printed for review).
        for c in [Critter.Costume.bee, .prime] { for m in [Critter.Mood.happy, .sad, .hungry, .bye] { print(c.rawValue, m.rawValue, "→", c.says(m)?.joined(separator: " | ") ?? "-") } }
        for line in ["ฟ้าสวย…", "อร่อย!", "เป่า… ยิ้ง… ฉุบ!"] { for c in [Critter.Costume.bee, .prime] { print(c.rawValue, line, "→", [0.1, 0.4, 0.6, 0.9].map { c.restyle(line, kind: .scene, roll: $0) }.joined(separator: " | ")) } }
        // The click menu's real width against the old fixed hit-test widths (the "can't change costume" bug).
        for (menu, oldWidth) in [(CritterEngine.Menu.root, 268.0), (.costume, 196.0), (.play, 300.0), (.rps, 150.0)] {
            let engine = CritterEngine(); engine.choose(menu)
            let host = NSHostingView(rootView: CritterMenuBar(engine: engine))
            let fit = host.fittingSize
            engine.menuMeasured[menu] = fit
            let rect = engine.menuRect()
            print("menu \(menu): content \(Int(fit.width))×\(Int(fit.height)) · old hit width \(Int(oldWidth)) · new hit rect \(Int(rect.width))×\(Int(rect.height)) inside panel \(Int(engine.panelSize.width)) → \(rect.minX >= 0 && rect.maxX <= engine.panelSize.width && rect.width >= fit.width ? "ok" : "CLIPPED")")
        }
        print("Rendered both costumes at radius 24 and 44 (pixel and classic eyes).")
    }
    static func renderSceneMotion(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for scene in Critter.Scene.allCases {
            let engine = CritterEngine(radius: 24)
            engine.paused = true; engine.quiet = true; engine.weatherEnabled = false; engine.eyeTracking = false
            engine.perform(scene: scene)
            for _ in 0..<Int((Critter.sceneDuration(scene) + 0.2) * 60) {
                engine.reviewStep(dt: 1.0 / 60)
                let s = engine.snapshot
                precondition(s.center.x.isFinite && s.center.y.isFinite && s.squash.isFinite, "Non-finite scene state: \(scene)")
            }
            precondition(engine.scene == nil, "Scene did not complete: \(scene)")
        }
        print("All \(Critter.Scene.allCases.count) scene timelines completed with finite live-engine states.")
        let scenes: [Critter.Scene] = [.pingpong, .plane, .skateboard, .manhole, .balloon, .rainUmbrella]
        let engines = scenes.map { scene -> CritterEngine in
            let e = CritterEngine(radius: 24)
            e.paused = true; e.quiet = true; e.weatherEnabled = false; e.eyeTracking = false
            e.perform(scene: scene); return e
        }
        let cell = engines[0].panelSize
        let size = CGSize(width: cell.width * 3, height: cell.height * 2)
        let url = URL(fileURLWithPath: directory + "/scenes.gif")
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 165, nil) else { return }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var positions = [[Double]]()
        for frame in 0..<165 {
            // Four 60 Hz live-engine steps per displayed frame. Keep the real positions.
            for engine in engines { for _ in 0..<4 { engine.reviewStep(dt: 1.0 / 60) } }
            let samples = engines.map { $0.snapshot }
            positions.append(samples.flatMap { [$0.center.x, $0.center.y] })
            let canvas = Canvas { ctx, _ in
                for i in samples.indices {
                    var c = ctx; c.translateBy(x: Double(i % 3) * cell.width, y: Double(i / 3) * cell.height)
                    c.fill(Path(CGRect(origin: .zero, size: cell)), with: .color(Color(white: 0.16)))
                    CritterPainter.draw(samples[i], in: &c)
                    c.draw(Text(scenes[i].rawValue).font(.system(size: 12)).foregroundColor(.white), at: CGPoint(x: cell.width / 2, y: 16))
                }
            }.frame(width: size.width, height: size.height)
            let rect = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: canvas); host.frame = rect; window.contentView = host
            host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let image = bitmap.cgImage {
                    CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 15]] as CFDictionary)
                    if [8, 39, 44, 71, 89, 92, 97].contains(frame), let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: URL(fileURLWithPath: directory + "/scene-\(frame).png"))
                    }
                }
            }
            window.close()
        }
        guard CGImageDestinationFinalize(gif) else { throw NSError(domain: "SceneReview", code: 1) }
        try JSONSerialization.data(withJSONObject: positions).write(to: URL(fileURLWithPath: directory + "/positions.json"))
        print("Rendered 11 seconds of six live scene timelines, 660 simulation steps each.")
    }
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
            ("critter-pump", .pancake, 4.6, false, "สูบ ๆ"), ("critter-shoji", .ninja, 5.0, false, "ทาดา~"),
            ("critter-car", .roadkill, 3.3, false, "!!!"), ("critter-soul", .roadkill, 5.5, false, "ลาก่อน…"), ("critter-soul-loop", .roadkill, 6.6, false, nil), ("critter-clones", .clone, 3.0, false, "ตัวไหนตัวจริง?"), ("critter-clones-vanish", .clone, 5.6, false, nil), ("critter-beach", .beach, 5.0, false, "อาบแดด~"), ("critter-crush", .crush, 3.0, false, "///"), ("critter-toilet-in", .toilet, 2.0, false, nil), ("critter-toilet-lift", .toilet, 4.4, false, "อ่าน ๆ"), ("critter-toilet-run", .toilet, 6.2, false, "อ๊ายยย"), ("critter-pingpong", .pingpong, 1.05, true, "โอ๊ย"), ("critter-meadow", .meadow, 4.5, false, "กลิ้งเร็ว!!"), ("critter-bulb", .bulb, 2.0, false, "มันจ้าาาา ซะเหลือเกิน"), ("critter-kick", .football, 1.2, false, nil), ("critter-goal", .football, 3.6, false, "เข้าาา!"), ("critter-cat", .catWalk, 3.0, false, "แมว!"), ("critter-catplay", .catPlay, 1.4, false, "ว้าย!"), ("critter-catsit", .catPlay, 9.0, false, "สนุกดี~"), ("critter-snack-eat", .snack, 2.5, false, "หง่ำ ๆ"), ("critter-snack-fat", .snack, 5.0, false, "ออกกำลัง~"), ("critter-pat", .pat, 1.2, false, "อือ~"), ("critter-chin", .chin, 1.2, false, "อื้อ…"), ("critter-skate", .skateboard, 1.5, false, "โย่ว~"), ("critter-kite", .kite, 5.0, false, "สูงจัง!"), ("critter-lightning-soul", .lightning, 2.6, false, "ลาก่อน…"),
            ("critter-box", .box, 2.0, false, "..."), ("critter-melt", .melt, 3.0, false, "ร้อน… ละลาย…"), ("critter-freeze", .freeze, 2.0, false, "แข็ง…"), ("critter-freeze-crack", .freeze, 4.3, false, nil),
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
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .pancake, t: 4.6, bubbleText: "สูบ ๆ"); shots.append(("critter-pump-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .beach, t: 5.0, bubbleText: "อาบแดด~"); shots.append(("critter-beach-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .clone, t: 3.0, bubbleText: "ตัวไหนตัวจริง?"); shots.append(("critter-clones-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .roadkill, t: 6.0, bubbleText: "ลาก่อน…"); shots.append(("critter-soul-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .rainUmbrella, t: 3.0, bubbleText: "~♪"); shots.append(("critter-umbrella2-big", e)) }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .crush, t: 3.0, bubbleText: "///"); shots.append(("critter-crush-big", e)) }
        for (name, t, seed, txt) in [("critter-kick-big", 1.15, 0, "…?"), ("critter-fly-big", 2.0, 0, "โอ้ย!!"), ("critter-goal-big", 4.0, 0, "เข้าาา!"), ("critter-miss-big", 4.0, 4, "แป้ก…")] {
            let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: .football, t: t, bubbleText: txt, seed: seed); shots.append((name, e))
        }
        for (name, sc, t, txt) in [("critter-bulb-big", Critter.Scene.bulb, 2.0, "มันจ้าาาา ซะเหลือเกิน"), ("critter-bulb-finger-big", .bulb, 0.9, "?"), ("critter-cat-big", .catWalk, 3.0, "แมว!"), ("critter-catplay-big", .catPlay, 1.4, "ว้าย!"), ("critter-catsit-big", .catPlay, 9.0, "สนุกดี~"), ("critter-pingpong2-big", .pingpong, 0.79, "เอ๊ะ!"), ("critter-toilet-run-big", .toilet, 6.4, "อ๊ายยย"), ("critter-toilet-big", Critter.Scene.toilet, 4.4, "อ่าน ๆ"), ("critter-pingpong-big", .pingpong, 1.05, "โอ๊ย"), ("critter-meadow-big", .meadow, 1.5, "กลิ้งช้า ๆ~"), ("critter-soul2-big", .roadkill, 5.2, "ลาก่อน…"), ("critter-snack-big", Critter.Scene.snack, 2.5, "หง่ำ ๆ"), ("critter-pat-big", .pat, 1.2, "อือ~"), ("critter-chin-big", .chin, 1.2, "อื้อ…"), ("critter-skate-big", .skateboard, 1.5, "โย่ว~"), ("critter-kite-big", .kite, 5.0, "สูงจัง!")] {
            let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(scene: sc, t: t, bubbleText: txt); shots.append((name, e))
        }
        do { let e = CritterEngine(radius: 44, area: Critter.Area(width: 416, height: 272)); e.settle(mood: .normal); e.menu = .root; shots.append(("critter-menu-big", e)) }
        do { let e = CritterEngine(); e.settle(mood: .normal); e.menu = .play; shots.append(("critter-menu-play", e)) }
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
