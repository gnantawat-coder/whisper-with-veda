import AppKit
import SwiftUI
import Combine

// The corner character. Rules live in Core (Critter); this file runs the clock,
// listens to the app, and draws. The panel is transparent, never takes focus,
// and only accepts a click when the pointer is on the body itself.

enum CritterCue: Equatable { case language(Mode), done, held, error, notice(String), copied }

final class CritterEngine: ObservableObject {
    enum External { case idle, listening, thinking, done }
    struct Snapshot {
        var center: CGPoint, drawRadius: Double, unit: Double, squash: Double, z: Double
        var face: Critter.Face, blink: Double, gaze: CGPoint, level: Double, t: Double, still: Bool, moodAge: Double, groundY: Double
    }
    @Published private(set) var snapshot: Snapshot
    @Published var bubble: String?
    @Published var langLabel: String?
    var onTap: (() -> Void)?

    let area: Critter.Area
    let inset = CGSize(width: 20, height: 64)     // room for the bubble above and a little slack each side
    var panelSize: CGSize { CGSize(width: area.width + inset.width * 2, height: area.height + inset.height + 12) }
    var body: Critter.Body
    var face = Critter.Face()
    var scheduler = Critter.Scheduler()
    var reduceMotion = false
    var external: External = .idle
    var level = 0.0
    var paused = false                  // offscreen previews only
    var settingsIsFront: () -> Bool = { false }   // asked every tick; a hidden settings window does not count
    private(set) var mood: Critter.Mood = .normal
    private var moodEndsAt = 0.0, moodSetAt = 0.0, nextMoveAt = 3.0, nextMoodAt = 5.0, blinkAt = 1.8, blinkUntil = -1.0, saccadeAt = 2.0
    private var bubbleUntil = -1.0, langUntil = -1.0, deepStartAt = -1.0, doneUntil = -1.0
    private var clock = 0.0, lastTick: CFTimeInterval = CACurrentMediaTime()
    private var look = CGPoint.zero, want = CGPoint.zero, pointerInside = false
    private var timer: Timer?
    var mouseInPanel: (() -> CGPoint?)?  // pointer in panel coordinates (y down), nil when outside

    init(radius: Double = 24, area: Critter.Area = .standard) {
        self.area = area
        body = Critter.Body(x: Critter.home(in: area), y: 0, radius: radius)
        body.y = Critter.ground(body, in: area)
        snapshot = Snapshot(center: .zero, drawRadius: radius, unit: radius / 44, squash: 1, z: 0, face: face, blink: 0, gaze: .zero, level: 0, t: 0, still: false, moodAge: 0, groundY: 0)
        publish()
    }
    func start() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }

    // MARK: what the app tells us
    func cue(_ c: CritterCue) {
        switch c {
        case .language(let m):
            bubble = nil; bubbleUntil = -1          // only the TH/EN pill, never two boxes stacked
            langLabel = m.rawValue; langUntil = clock + 1.3
            Critter.hop(&body, height: 180); blinkUntil = clock + 0.12
        case .done: external = .done; doneUntil = clock + 1.1; Critter.hop(&body, height: 400); say(Critter.expressions[.done]!.says, for: 1.2)
        case .held: setMood(.sad, hold: 3.0)
        case .error: setMood(.annoyed, hold: 2.5)
        case .copied: setMood(.happy, hold: 1.6)
        case .notice(let text): say([text], for: 3.2)
        }
    }
    func setExternal(_ e: External) {
        if e == .listening && external != .listening { bubble = nil; bubbleUntil = -1 }
        if e == .thinking && external != .thinking { say(Critter.expressions[.thinking]!.says, for: 1.4) }
        external = e
    }
    func setMood(_ m: Critter.Mood, hold: Double = 2.6) {
        mood = m; moodSetAt = clock; moodEndsAt = clock + hold
        guard let e = Critter.expressions[m] else { return }
        if m == .normal { bubble = nil; bubbleUntil = -1 } else if !e.says.isEmpty {
            // Wait for the turn to finish before speaking, or it looks like talking without looking.
            let delay = e.front >= 1 ? 0.26 : 0.06
            let words = e.says
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in guard let self, self.mood == m else { return }; self.say(words, for: e.sticky ? 1e9 : 1.8) }
        }
    }
    private func say(_ words: [String], for seconds: Double) {
        guard let w = words.randomElement() else { return }
        bubble = w; bubbleUntil = clock + seconds
    }
    func perform(_ move: Critter.Move) {
        switch move {
        case .roll: Critter.roll(&body, in: area)
        case .hop: Critter.hop(&body, height: 180 + Double.random(in: 0..<160))
        case .dribble: Critter.dribble(&body)
        case .throwUp: Critter.throwUp(&body)
        case .pinball: Critter.pinball(&body, in: area)
        case .wallClimb: Critter.wallClimb(&body, in: area)
        case .zigzag: Critter.zigzag(&body, in: area)
        case .peek: setMood(.peek, hold: 1.5)
        case .shiver: setMood(.cold, hold: 1.4)
        case .sway: swayUntil = clock + 2.4
        case .deep:
            // Say goodbye first, then leave; the scheduler keeps this one rare.
            scheduler.lastDeepAt = clock
            setMood(.bye, hold: 1.4); deepStartAt = clock + 0.9
        }
    }
    private var swayUntil = -1.0

    // MARK: the clock
    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.033, now - lastTick); lastTick = now; clock += dt
        let still = reduceMotion
        if let p = mouseInPanel?() {
            pointerInside = true
            let c = center()
            let dx = p.x - c.x, dy = p.y - c.y, d = max(1, hypot(dx, dy)), m = min(1, d / (220 * body.unit))
            want = CGPoint(x: dx / d * m, y: dy / d * m)
        } else { pointerInside = false }

        if external == .done && clock > doneUntil { external = .idle; setMood(.normal) }
        if external == .idle && !still && !paused && !settingsIsFront() {
            if clock > nextMoodAt && !(Critter.expressions[mood]?.sticky ?? false) && deepStartAt < 0 && body.deepClock < 0 {
                let m = scheduler.pickMood(Double.random(in: 0..<1))
                setMood(m, hold: m == .normal ? 0 : 2.4 + Double.random(in: 0..<2.2))
                nextMoodAt = clock + scheduler.nextMoodDelay(Double.random(in: 0..<1))
            }
            if mood != .normal, moodEndsAt > 0, clock > moodEndsAt, !(Critter.expressions[mood]?.sticky ?? false) { setMood(.normal) }
            if mood == .sleepy && clock > moodEndsAt + 6 { setMood(.asleep) }
            if mood != .sleepy && mood != .asleep && clock > nextMoveAt && body.onGround && body.deepClock < 0 && deepStartAt < 0 {
                perform(scheduler.pickMove(Double.random(in: 0..<1), now: clock))
                nextMoveAt = clock + scheduler.nextMoveDelay(Double.random(in: 0..<1))
            }
            if pointerInside && (Critter.expressions[mood]?.sticky ?? false) { setMood(.normal) }
        }
        if deepStartAt >= 0 && clock >= deepStartAt { deepStartAt = -1; Critter.goDeep(&body) }
        if external == .listening, body.onGround, level > 0.75, Double.random(in: 0..<1) < 0.07, !still { Critter.hop(&body, height: 90 + level * 90) }

        if still {
            body.x = Critter.home(in: area); body.y = Critter.ground(body, in: area); body.vx = 0; body.vy = 0; body.squash = 1; body.squashV = 0; body.z = 0; body.zTarget = 0; body.deepClock = -1; body.anticipation = -1
        } else {
            for e in Critter.step(&body, in: area, dt: dt) {
                switch e {
                case .startled: setMood(.startled, hold: 0.9)
                case .dizzy: setMood(.dizzy, hold: 1.8)
                case .deepArrived: setMood(.curious, hold: 1.1)
                case .deepReturned: setMood(.back, hold: 1.6)
                default: break
                }
            }
        }
        // Gaze: follow the pointer, otherwise glance around now and then.
        if !pointerInside && !still && clock > saccadeAt { want = CGPoint(x: Double.random(in: -0.3...0.3), y: Double.random(in: -0.2...0.2)); saccadeAt = clock + 1.8 + Double.random(in: 0..<2.6) }
        let k = still ? 1 : 0.1
        look.x += (want.x - look.x) * k; look.y += (want.y - look.y) * k
        let target = currentExpression()
        if clock > blinkAt && !still && !target.arc { let slow = Double.random(in: 0..<1) < 0.2; blinkUntil = clock + (slow ? 0.32 : 0.11); blinkAt = clock + 2 + Double.random(in: 0..<3) }
        let breath = still ? 0 : sin(clock * (target.slowBreath ? 1.2 : 2)) * 0.015
        var extraTilt = max(-12, min(12, body.vx * 0.03 / body.unit))
        // Never fully still: a slow weight shift between the bigger moves, like someone standing in place.
        if !still && external == .idle && body.onGround && mood != .asleep { extraTilt += sin(clock * 0.9) * 2.2 + sin(clock * 2.3) * 0.6 }
        if swayUntil > clock { extraTilt += sin(clock * 4) * 9 }
        if body.pin > 0 { extraTilt += sin(clock * 20) * 4 }
        face.approach(target, breath: breath, extraTilt: extraTilt, k: still ? 1 : 0.16)
        if external == .listening { face.left.h = 26 + level * 4; face.right.h = 27 + level * 4 }
        if bubble != nil && clock > bubbleUntil { bubble = nil }
        if langLabel != nil && clock > langUntil { langLabel = nil }
        publish()
    }
    private func currentExpression() -> Critter.Expression {
        switch external {
        case .listening: return Critter.expressions[.listening]!
        case .thinking: return Critter.expressions[.thinking]!
        case .done: return Critter.expressions[.done]!
        case .idle: return Critter.expressions[mood] ?? Critter.expressions[.normal]!
        }
    }
    func center() -> CGPoint { CGPoint(x: inset.width + body.x, y: inset.height + body.y) }
    private func publish() {
        let gs = (1 - face.front * 0.55) * (1 - body.z * 0.5)
        var gaze = CGPoint(x: look.x * 9 * gs, y: look.y * 7 * gs)
        if mood == .bored && external == .idle { gaze.x += sin(clock * 0.8) * 6 }
        if !body.onGround && face.arc < 0.5 && external == .idle { gaze.y -= max(-5, min(5, -body.vy * 0.01 / body.unit)) }
        snapshot = Snapshot(center: center(), drawRadius: body.drawRadius, unit: body.unit, squash: body.squash, z: body.z, face: face,
                            blink: clock < blinkUntil ? 1 : 0, gaze: gaze, level: level, t: clock, still: reduceMotion, moodAge: clock - moodSetAt,
                            groundY: inset.height + Critter.ground(body, in: area) + body.drawRadius)
    }
    /// Offscreen review: put the character in a state and let the face settle without a screen.
    func settle(mood m: Critter.Mood, external e: External = .idle, z: Double = 0, level lv: Double = 0, bubbleText: String? = nil, steps: Int = 90) {
        external = e; level = lv; scheduler.playfulness = 0; paused = true
        body.z = z; body.zTarget = z; body.y = Critter.ground(body, in: area)
        setMood(m, hold: 1e9)
        for _ in 0..<steps { tick() }
        bubble = bubbleText ?? Critter.expressions[m]?.says.first
    }
    /// True when the pointer (panel coordinates) is on the body: the only place a click is ours.
    func hit(_ p: CGPoint) -> Bool { let c = center(); return hypot(p.x - c.x, p.y - c.y) <= body.drawRadius * 1.15 }
}

// MARK: - drawing
struct CritterView: View {
    @ObservedObject var engine: CritterEngine
    var body: some View {
        let s = engine.snapshot
        ZStack(alignment: .topLeading) {
            Canvas(rendersAsynchronously: false) { ctx, _ in CritterPainter.draw(s, in: &ctx) }
            if let text = engine.bubble {
                Text(text).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Color(white: 0.1))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .fixedSize().position(x: s.center.x, y: s.center.y - s.drawRadius * s.face.sy * s.squash - 20)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if let lang = engine.langLabel {
                Text(lang).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Color(white: 0.07), in: Capsule())
                    .fixedSize().position(x: s.center.x, y: s.center.y - s.drawRadius - 22 - (engine.bubble == nil ? 0 : 30))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            Color.clear.frame(width: s.drawRadius * 2.3, height: s.drawRadius * 2.3).contentShape(Circle())
                .position(s.center).onTapGesture { engine.onTap?() }
        }
        .frame(width: engine.panelSize.width, height: engine.panelSize.height)
        .animation(engine.reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: engine.bubble)
        .animation(engine.reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: engine.langLabel)
    }
}

enum CritterPainter {
    static let ink = Color(white: 0.07)
    static func draw(_ s: CritterEngine.Snapshot, in ctx: inout GraphicsContext) {
        let f = s.face, t = s.t
        // Ground shadow: the one cue that turns "smaller" into "farther".
        let lift = max(0, s.groundY - s.drawRadius - s.center.y)
        let shadowScale = (1 - min(0.5, lift / (260 * s.unit)))
        ctx.opacity = 0.14 * (1 - min(0.7, lift / (260 * s.unit)))
        ctx.fill(Path(ellipseIn: CGRect(x: s.center.x - 30 * s.unit * (s.drawRadius / (s.unit * 44)) * shadowScale, y: s.groundY - 6 * s.unit, width: 60 * s.unit * (s.drawRadius / (s.unit * 44)) * shadowScale, height: 10 * s.unit)), with: .color(ink))
        ctx.opacity = 1

        var c = ctx
        c.translateBy(x: s.center.x, y: s.center.y)
        let k = s.drawRadius / 46
        c.scaleBy(x: k, y: k)
        // Listening rings and effects sit outside the squash so they stay round.
        if f.rings > 0.01 {
            for i in 0..<3 {
                let q = s.still ? 0.5 : ((t * 0.9 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
                c.stroke(Path(ellipseIn: CGRect(x: -(48 + q * 22), y: -(48 + q * 22), width: 2 * (48 + q * 22), height: 2 * (48 + q * 22))), with: .color(ink.opacity(f.rings * (1 - q) * 0.55)), lineWidth: 2)
            }
        }
        if f.spark > 0.01 {
            for (i, pos) in [(-38.0, -38.0), (38.0, -42.0), (32.0, 12.0)].enumerated() {
                let ph = s.still ? 0.5 : ((s.moodAge * 0.9 + Double(i) * 0.25).truncatingRemainder(dividingBy: 1))
                let pop = sin(ph * .pi), size = (0.3 + pop) * [6.0, 5.0, 4.0][i]
                var star = Path()
                for j in 0..<8 { let a = Double(j) * .pi / 4 + ph * .pi / 2, r = j % 2 == 0 ? size : size * 0.27; let p = CGPoint(x: pos.0 + cos(a) * r, y: pos.1 - ph * 10 + sin(a) * r); j == 0 ? star.move(to: p) : star.addLine(to: p) }
                star.closeSubpath()
                c.fill(star, with: .color(Color(red: 0.94, green: 0.62, blue: 0.15).opacity(f.spark * pop)))
            }
        }
        if f.wow > 0.01 {
            let age = s.moodAge, grow = 1 + min(0.3, age * 0.8)
            var w = c; w.scaleBy(x: grow, y: grow)
            for (a, b) in [((0.0, -56.0), (0.0, -49.0)), ((-38.0, -42.0), (-33.0, -37.0)), ((38.0, -42.0), (33.0, -37.0)), ((-52.0, -8.0), (-45.0, -8.0)), ((52.0, -8.0), (45.0, -8.0))] {
                var p = Path(); p.move(to: CGPoint(x: a.0, y: a.1)); p.addLine(to: CGPoint(x: b.0, y: b.1))
                w.stroke(p, with: .color(ink.opacity(f.wow * max(0, 1 - age * 0.8))), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
        if f.shake > 0.01 {
            let o = f.shake * (0.5 + 0.5 * sin(t * 40))
            for (a, b) in [((-52.0, -26.0), (-47.0, -30.0)), ((-54.0, -14.0), (-48.0, -14.0)), ((52.0, -26.0), (47.0, -30.0)), ((54.0, -14.0), (48.0, -14.0))] {
                var p = Path(); p.move(to: CGPoint(x: a.0, y: a.1)); p.addLine(to: CGPoint(x: b.0, y: b.1))
                c.stroke(p, with: .color(ink.opacity(o)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
        // Squash about the bottom of the body, then the head tilt.
        c.translateBy(x: 0, y: 46)
        c.scaleBy(x: f.sx * (2 - s.squash) * Critter.turnSqueeze(front: f.front), y: f.sy * s.squash)
        c.translateBy(x: 0, y: -46)
        c.rotate(by: .degrees(f.tilt))
        let bodyPath = Path(ellipseIn: CGRect(x: -46, y: -46, width: 92, height: 92))
        c.fill(bodyPath, with: .color(ink))
        c.stroke(bodyPath, with: .color(.white.opacity(0.16)), lineWidth: 1.2)   // keeps it visible over a black window
        let an = Critter.anchors(front: f.front)
        let aL = CGPoint(x: an.left.x - 60, y: an.left.y - 60), aR = CGPoint(x: an.right.x - 60, y: an.right.y - 60)
        if f.blush > 0.01 {
            let fr = f.front
            for (x, y) in [(38 + 2 * fr - 60, 70 - 2 * fr - 60), (76 + 4 * fr - 60, 74 - 6 * fr - 60)] {
                c.fill(Path(ellipseIn: CGRect(x: x - 8 + s.gaze.x * 0.4, y: y - 4.5 + s.gaze.y * 0.4, width: 16, height: 9)), with: .color(Color(red: 0.83, green: 0.33, blue: 0.49).opacity(f.blush)))
            }
        }
        if f.arc < 0.99 {
            c.opacity = 1 - f.arc
            c.fill(pill(f.left, at: aL, gaze: s.gaze, blink: s.blink), with: .color(.white))
            c.fill(pill(f.right, at: aR, gaze: s.gaze, blink: s.blink), with: .color(.white))
            c.opacity = 1
        }
        if f.arc > 0.01 {
            for a in [aL, aR] {
                var p = Path(); p.move(to: CGPoint(x: a.x - 8 + s.gaze.x, y: a.y + 4 + s.gaze.y))
                p.addQuadCurve(to: CGPoint(x: a.x + 8 + s.gaze.x, y: a.y + 4 + s.gaze.y), control: CGPoint(x: a.x + s.gaze.x, y: a.y - 6 + s.gaze.y))
                c.stroke(p, with: .color(.white.opacity(f.arc)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
        }
        if f.tear > 0.01 {
            let ph = s.still ? 0.4 : (s.moodAge * 0.7).truncatingRemainder(dividingBy: 1)
            var d = Path(); let o = CGPoint(x: aL.x + s.gaze.x, y: aL.y + 12 + s.gaze.y + ph * 16)
            d.move(to: o); d.addCurve(to: CGPoint(x: o.x, y: o.y + 9), control1: CGPoint(x: o.x - 3, y: o.y + 4), control2: CGPoint(x: o.x - 3, y: o.y + 8))
            d.addCurve(to: o, control1: CGPoint(x: o.x + 3, y: o.y + 8), control2: CGPoint(x: o.x + 3, y: o.y + 4)); d.closeSubpath()
            c.fill(d, with: .color(Color(red: 0.52, green: 0.72, blue: 0.92).opacity(f.tear * (1 - ph) * 0.95)))
        }
    }
    static func pill(_ e: Critter.Eye, at a: CGPoint, gaze: CGPoint, blink: Double) -> Path {
        let x = a.x + e.dx + gaze.x, y = a.y + e.dy + gaze.y, h = blink > 0.5 ? 2.5 : e.h
        let rect = CGRect(x: x - e.w / 2, y: y - h / 2, width: e.w, height: h)
        return Path(roundedRect: rect, cornerRadius: e.w / 2, style: .continuous)
            .applying(CGAffineTransform(translationX: x, y: y).rotated(by: e.r * .pi / 180).translatedBy(x: -x, y: -y))
    }
}

// MARK: - playground: the same engine, larger, with every move and mood on a button
struct CritterPlayground: View {
    @ObservedObject var engine: CritterEngine
    @ObservedObject var model: Model
    @State private var holding = false
    @State private var levelTimer: Timer?
    @State private var lang: Mode = .th
    private let moves: [(Critter.Move, String)] = [(.roll, "กลิ้ง"), (.hop, "เด้ง"), (.dribble, "ดริบเบิล"), (.throwUp, "โยนชนเพดาน"), (.pinball, "พินบอล"), (.wallClimb, "ปีนกำแพง"), (.zigzag, "ซิกแซก"), (.peek, "ยืดมอง"), (.shiver, "ตัวสั่น"), (.sway, "โยกตัว"), (.deep, "กลิ้งลึกเข้าไป")]
    private let moodNames: [Critter.Mood: String] = [.normal: "ปกติ", .bored: "เบื่อ", .thinking: "คิด", .sleepy: "ง่วง", .asleep: "หลับ", .curious: "สงสัย", .happy: "ดีใจ", .done: "เสร็จ", .shy: "เขิน", .sad: "เศร้า", .wow: "ว้าว", .startled: "ตกใจ", .worried: "กังวล", .dizzy: "เวียนหัว", .peek: "ยืดมอง", .cold: "สั่น", .listening: "ฟัง", .annoyed: "หงุดหงิด", .bye: "บอกลา", .back: "กลับมา"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor))
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: engine.area.width, height: engine.area.height).offset(y: (engine.inset.height - 12) / 2)
                CritterView(engine: engine)
            }.frame(width: engine.panelSize.width, height: engine.panelSize.height)
            HStack(spacing: 8) {
                Button(holding ? "กำลังฟัง… ปล่อยเพื่อพิมพ์" : "กด Fn ค้าง (กดเมาส์ค้างที่ปุ่มนี้)") {}
                    .buttonStyle(.borderedProminent)
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in if !holding { startHold() } }.onEnded { _ in endHold() })
                Button("Fn + Space สลับ TH/EN") { lang = lang == .th ? .en : .th; engine.cue(.language(lang)) }
                Button("Fn + Option ความขี้เล่น") { model.critterPlayfulness = (model.critterPlayfulness + 1) % 3 }
                Text(["เงียบ", "ปกติ", "ขี้เล่น"][max(0, min(2, model.critterPlayfulness))]).font(.caption).foregroundStyle(.secondary)
            }
            Text("ท่า").font(.caption).foregroundStyle(.secondary)
            FlowButtons(items: moves.map { (mv: (Critter.Move, String)) -> (String, () -> Void) in (mv.1, { engine.perform(mv.0) }) })
            Text("อารมณ์ (ตัวเลขคือระดับหันหน้า: 0 เอียงตามภาพต้นแบบ · 1 หันตรง)").font(.caption).foregroundStyle(.secondary)
            FlowButtons(items: Critter.Mood.allCases.map { (m: Critter.Mood) -> (String, () -> Void) in ((moodNames[m] ?? m.rawValue) + " " + String(format: "%.0f", Critter.expressions[m]!.front), { engine.setMood(m, hold: 4) }) })
        }.padding(20)
    }
    private func startHold() {
        holding = true; engine.setExternal(.listening)
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            let t = Date().timeIntervalSinceReferenceDate
            engine.level += ((0.35 + 0.65 * abs(sin(t * 7) * sin(t * 2.3))) - engine.level) * 0.25
        }
    }
    private func endHold() {
        guard holding else { return }
        holding = false; levelTimer?.invalidate(); levelTimer = nil; engine.level = 0
        engine.setExternal(.thinking)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { engine.cue(.done) }
    }
}
struct FlowButtons: View {
    let items: [(String, () -> Void)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in Button(item.0, action: item.1).controlSize(.small) }
        }
    }
}

// MARK: - the window
final class CritterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    let engine: CritterEngine
    init(engine: CritterEngine) {
        self.engine = engine
        super.init(contentRect: NSRect(origin: .zero, size: engine.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false; hidesOnDeactivate = false; ignoresMouseEvents = true
        let host = NSHostingView(rootView: CritterView(engine: engine))
        host.frame = NSRect(origin: .zero, size: engine.panelSize)
        contentView = host
        engine.mouseInPanel = { [weak self] in
            guard let self, self.isVisible else { return nil }
            let m = NSEvent.mouseLocation
            guard self.frame.contains(m) else { return nil }
            let local = CGPoint(x: m.x - self.frame.minX, y: self.frame.maxY - m.y)
            // Let clicks through everywhere except on the body.
            let onBody = self.engine.hit(local)
            if self.ignoresMouseEvents == onBody { self.ignoresMouseEvents = !onBody }
            return local
        }
    }
    /// Bottom-right of the visible area of the screen the pointer is on, above the Dock.
    func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        setFrameOrigin(NSPoint(x: v.maxX - 16 - engine.panelSize.width + engine.inset.width, y: v.minY + 16 - 12))
    }
}
