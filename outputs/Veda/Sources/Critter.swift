import AppKit
import SwiftUI
import Combine

// The corner character. Rules live in Core (Critter); this file runs the clock,
// listens to the app, and draws. The panel is transparent, never takes focus,
// and only accepts a click when the pointer is on the body itself.

enum CritterCue: Equatable { case language(Mode), done, held, error, notice(String), copied, mode(String) }

final class CritterEngine: ObservableObject {
    enum External { case idle, listening, thinking, done }
    struct Snapshot {
        var center: CGPoint, drawRadius: Double, unit: Double, squash: Double, z: Double
        var face: Critter.Face, blink: Double, gaze: CGPoint, level: Double, t: Double, still: Bool, moodAge: Double, groundY: Double
        var scene: Critter.SceneFrame? = nil, sceneKind: Critter.Scene? = nil, area: CGRect = .zero
        var sky = Critter.Sky(), prop = ""
        var pixelEyes = false, mood: Critter.Mood = .normal, external: External = .idle
        var bird = 0.0, birdLeave = 0.0   // 0 none; bird 0→1 flying in then perched; birdLeave 0→1 flying off
        var burstAge = -1.0, popAge = -1.0, dropletAge = -1.0   // seconds since the one-tick effects fired; -1 = never
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
    var quiet = false                   // speech off: only state changes get a bubble (see Critter.allowsBubble)
    var eyeTracking = true              // eyes follow the pointer anywhere on screen; off = glance around on its own
    var pixelEyes = true                // Astro-style LED dots instead of solid white shapes; same geometry underneath
    var weatherEnabled = true
    private(set) var sky = Critter.Sky()
    private var weatherUntil = -1.0, nextWeatherAt = 0.0, weatherMoodAt = 0.0, hourCheckAt = 0.0
    var skyChanged: ((Critter.Sky) -> Void)?
    var care = Critter.Care.State()
    var careChanged: ((Critter.Care.State) -> Void)?
    var now: () -> Double = { Date().timeIntervalSince1970 }
    private var careTickAt = 0.0, needAt = 30.0, strokeDistance = 0.0, lastStrokeAt = -1.0
    private var sceneProp = ""
    var sleepAfter = 180.0              // seconds without any keyboard/mouse input before it dozes off
    private var idleSleeping = false, sleepAt = -1.0, birdArriveAt = -1.0, birdLeaveAt = -1.0
    static func systemIdleSeconds() -> Double { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) }
    private(set) var scene: Critter.Scene?
    private var sceneStartAt = 0.0, nextSceneAt = 0.0, burstAt = -1.0, popAt = -1.0, dropletAt = -1.0, liftBaseX = 0.0
    private var sceneFrame: Critter.SceneFrame?
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
    var mouseAnywhere: (() -> CGPoint?)? // pointer in panel coordinates even when far outside; nil when there is no panel

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
        case .done: external = .done; doneUntil = clock + 1.1; Critter.hop(&body, height: 400); say(Critter.expressions[.done]!.says, for: 1.2, kind: .done); act(.dictation)
        case .held: setMood(.sad, hold: 3.0)
        case .error: setMood(.annoyed, hold: 2.5)
        case .copied: setMood(.happy, hold: 1.6)
        case .notice(let text): say([text], for: 3.2, kind: .notice)
        case .mode(let text): say([text], for: 2.4, kind: .playfulness)
        }
    }
    func setExternal(_ e: External) {
        if e == .listening && external != .listening { bubble = nil; bubbleUntil = -1 }
        if e == .thinking && external != .thinking { say(Critter.expressions[.thinking]!.says, for: 1.4, kind: .thinking) }
        external = e
    }
    func setMood(_ m: Critter.Mood, hold: Double = 2.6, speak: Bool = true) {
        mood = m; moodSetAt = clock; moodEndsAt = clock + hold
        guard let e = Critter.expressions[m] else { return }
        if m == .normal { bubble = nil; bubbleUntil = -1 } else if !e.says.isEmpty && speak {
            // Wait for the turn to finish before speaking, or it looks like talking without looking.
            let delay = e.front >= 1 ? 0.26 : 0.06
            let words = e.says
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in guard let self, self.mood == m else { return }; self.say(words, for: e.sticky ? 1e9 : 1.8, kind: .mood) }
        }
    }
    private func say(_ words: [String], for seconds: Double, kind: Critter.BubbleKind) {
        guard Critter.allowsBubble(kind, quiet: quiet), let w = words.randomElement() else { return }
        bubble = w; bubbleUntil = clock + seconds
    }
    // MARK: care — the Tamagotchi side. Rules in Critter.Care; this just applies outcomes to the face and body.
    @discardableResult func act(_ a: Critter.Care.Action) -> Critter.Care.Outcome {
        let o = Critter.Care.apply(a, to: &care, now: now())
        careChanged?(care)
        if case .feed(let food) = a, o.accepted { sceneProp = food.emoji }
        if let sc = o.scene, scene == nil { perform(scene: sc) }
        else if let m = o.mood { setMood(m, hold: o.accepted ? 2.4 : 2.0, speak: o.say == nil) }
        if let w = o.say { say([w], for: 2.0, kind: .care) }
        if let mv = o.move { perform(mv) }
        return o
    }
    /// Pointer dragged across the body: every stroke length counts once, at most twice a second.
    func strokeMoved(by distance: Double) {
        strokeDistance += distance
        guard strokeDistance > 36 * body.unit, clock - lastStrokeAt > 0.5 else { return }
        strokeDistance = 0; lastStrokeAt = clock
        act(.stroke)
    }
    // MARK: weather
    func setWeather(_ w: Critter.Weather?, umbrella: Bool? = nil) {
        if let w, w != .clear {
            sky.kind = w; sky.age = 0; sky.umbrella = w == .rain ? (umbrella ?? (Double.random(in: 0..<1) < 0.6)) : false
            weatherUntil = clock + scheduler.weatherLength(Double.random(in: 0..<1), kind: w); weatherMoodAt = clock + 1.5
        } else {
            sky.kind = .clear; sky.umbrella = false; sky.age = 0
            nextWeatherAt = clock + scheduler.nextWeatherDelay(Double.random(in: 0..<1))
        }
        skyChanged?(sky)
    }
    private func runWeather(dt: Double) {
        sky.age += dt
        if paused { return }   // previews pin the sky they were given
        if clock > hourCheckAt {
            hourCheckAt = clock + 30
            let night = Critter.isNight(hour: Calendar.current.component(.hour, from: Date()))
            if night != sky.night { sky.night = night; skyChanged?(sky) }
        }
        guard weatherEnabled, !reduceMotion else { if sky.kind != .clear { setWeather(nil) }; return }
        if nextWeatherAt == 0 { nextWeatherAt = clock + scheduler.nextWeatherDelay(Double.random(in: 0..<1)) }
        if sky.kind != .clear && clock > weatherUntil { setWeather(nil) }
        else if sky.kind == .clear && clock > nextWeatherAt { let w = scheduler.pickWeather(Double.random(in: 0..<1)); if w == .clear { nextWeatherAt = clock + 120 } else { setWeather(w) } }
        guard sky.kind != .clear, scene == nil, external == .idle else { return }
        if clock > weatherMoodAt, let m = Critter.weatherMood(sky), mood == .normal { setMood(m, hold: 2.6); weatherMoodAt = clock + 35 }
        if sky.kind == .rain && !sky.umbrella && body.onGround { body.vx = sin(clock * 1.6) * 3.2 * body.radius }   // no umbrella: rolls about looking for shelter
        if sky.kind == .wind && body.onGround { body.vx += (sin(clock * 0.7) > 0.3 ? 1 : 0) * 40 * body.unit * dt * 60 * 0.02 }
    }
    /// Left alone for minutes it dozes off; a small blue bird lands on it; any input wakes it and the bird flies away.
    private func runIdleSleep() {
        guard !paused, !reduceMotion else { return }
        let idle = CritterEngine.systemIdleSeconds()
        if !idleSleeping && external == .idle && scene == nil && idle >= sleepAfter && mood != .asleep {
            idleSleeping = true; setMood(.sleepy, hold: 5); sleepAt = clock + 5
        }
        if idleSleeping && sleepAt > 0 && clock > sleepAt { sleepAt = -1; setMood(.asleep); birdArriveAt = clock + 3 }
        if idleSleeping && idle < 1.5 && (mood == .asleep || mood == .sleepy) {
            idleSleeping = false; sleepAt = -1
            if birdArriveAt >= 0 && clock > birdArriveAt { birdLeaveAt = clock }
            birdArriveAt = -1
            setMood(.startled, hold: 1.2)
        }
        if birdLeaveAt >= 0 && clock > birdLeaveAt + 1.2 { birdLeaveAt = -1 }
    }
    private func runCare() {
        let t = now()
        if care.lastTickAt < 0 { care.lastTickAt = t }
        if clock > careTickAt {
            careTickAt = clock + 60
            let hours = (t - care.lastTickAt) / 3600
            if hours > 0 { if mood == .asleep { Critter.Care.rest(&care, hours: hours) } else { Critter.Care.decay(&care, hours: hours) }; care.lastTickAt = t; careChanged?(care) }
        }
        if clock > needAt, external == .idle, scene == nil, mood == .normal, !paused {
            needAt = clock + 45
            if let need = Critter.Care.need(care) { setMood(need, hold: 3) }
        }
    }
    /// Start a set piece. Physics keeps running underneath; the frame tells the painter what to add.
    func perform(scene s: Critter.Scene) {
        scene = s; sceneStartAt = clock; liftBaseX = body.x
        sceneFrame = Critter.sceneFrame(s, t: 0)
        bubble = nil; bubbleUntil = -1
    }
    private func runScene(dt: Double) {
        guard let s = scene else { return }
        let fr = Critter.sceneFrame(s, t: clock - sceneStartAt, dt: dt)
        if fr.done { scene = nil; sceneFrame = nil; setMood(.normal); return }
        sceneFrame = fr
        if let m = fr.mood, m != mood { setMood(m, hold: 1e9, speak: false) }
        if let w = fr.say { say([w], for: 1.6, kind: .scene) }
        if fr.burst { burstAt = clock }
        if fr.pop { popAt = clock; if s == .hiccup { Critter.hop(&body, height: 70) } }
        if fr.droplets { dropletAt = clock; Critter.hop(&body, height: 50) }
        if let v = fr.driveVx { body.vx = v * body.radius }
        if let h = fr.hopNow { Critter.hop(&body, height: h) }
        if let lift = fr.lift {
            // Hanging from the balloon: the string sets the height, the wind sets the drift.
            body.y = Critter.ground(body, in: area) - lift * body.radius; body.vy = 0; body.vx = 0
            body.x = min(Critter.maxX(body, in: area), max(Critter.minX(body), liftBaseX + sin(clock * 1.2) * 12 * body.unit))
        }
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
        pointerInside = mouseInPanel?() != nil
        if let p = eyeTracking ? (mouseAnywhere?() ?? mouseInPanel?()) : mouseInPanel?() {
            let c = center()
            let dx = p.x - c.x, dy = p.y - c.y, d = max(1, hypot(dx, dy)), m = min(1, d / (220 * body.unit))
            want = CGPoint(x: dx / d * m, y: dy / d * m)
        }

        if external == .done && clock > doneUntil { external = .idle; setMood(.normal) }
        runIdleSleep()
        if external == .idle && !still && !paused && !settingsIsFront() && scene == nil {
            if nextSceneAt == 0 { nextSceneAt = clock + scheduler.nextSceneDelay(Double.random(in: 0..<1)) }
            if clock > nextSceneAt && body.onGround && body.deepClock < 0 && deepStartAt < 0 && mood != .asleep && mood != .sleepy {
                perform(scene: scheduler.pickScene(Double.random(in: 0..<1)))
                nextSceneAt = clock + scheduler.nextSceneDelay(Double.random(in: 0..<1))
            }
        }
        if external == .idle && !still && !paused && !settingsIsFront() && scene == nil {
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

        if scene != nil && !still { runScene(dt: dt) }
        runWeather(dt: dt); runCare()
        if still {
            scene = nil; sceneFrame = nil
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
            if let lift = sceneFrame?.lift { body.y = Critter.ground(body, in: area) - lift * body.radius; body.vy = 0 }
        }
        // Gaze: follow the pointer, otherwise glance around now and then.
        let tracking = eyeTracking ? (mouseAnywhere?() != nil || pointerInside) : pointerInside
        if !tracking && !still && clock > saccadeAt { want = CGPoint(x: Double.random(in: -0.3...0.3), y: Double.random(in: -0.2...0.2)); saccadeAt = clock + 1.8 + Double.random(in: 0..<2.6) }
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
                            groundY: inset.height + Critter.ground(body, in: area) + body.drawRadius,
                            scene: sceneFrame, sceneKind: scene, area: CGRect(x: inset.width, y: inset.height - body.radius, width: area.width, height: area.height + body.radius), sky: sky, prop: sceneProp, pixelEyes: pixelEyes, mood: mood, external: external,
                            bird: birdArriveAt >= 0 && clock >= birdArriveAt ? min(1, (clock - birdArriveAt) / 1.2) : 0, birdLeave: birdLeaveAt >= 0 ? min(1, (clock - birdLeaveAt) / 1.2) : 0,
                            burstAge: burstAt < 0 ? -1 : clock - burstAt, popAge: popAt < 0 ? -1 : clock - popAt, dropletAge: dropletAt < 0 ? -1 : clock - dropletAt)
    }
    /// Offscreen review: put the character in a state and let the face settle without a screen.
    func settle(mood m: Critter.Mood, external e: External = .idle, z: Double = 0, level lv: Double = 0, bubbleText: String? = nil, steps: Int = 90) {
        external = e; level = lv; scheduler.playfulness = 0; paused = true
        body.z = z; body.zTarget = z; body.y = Critter.ground(body, in: area)
        setMood(m, hold: 1e9)
        for _ in 0..<steps { tick() }
        moodSetAt = clock - 5; publish()
        bubble = bubbleText ?? Critter.expressions[m]?.says.first
    }
    /// Offscreen review of a set piece at a given moment; one-tick effects can be pinned to a recent age.
    func settle(scene s: Critter.Scene, t: Double, burst: Bool = false, pop: Bool = false, droplets: Bool = false, bubbleText: String? = nil) {
        paused = true; scheduler.playfulness = 0; clock = max(clock, 10); blinkAt = clock + 5
        if s == .eat { sceneProp = "🍜" }
        perform(scene: s); sceneStartAt = clock - t
        if burst { burstAt = clock - 0.12 }; if pop { popAt = clock - 0.1 }; if droplets { dropletAt = clock - 0.12 }
        for _ in 0..<60 { tick() }
        moodSetAt = clock - 5; publish()   // previews show the settled face, not the first frame of the dissolve
        bubble = bubbleText
    }
    /// Offscreen review of the idle sleep with the bird perched.
    func settle(asleepWithBird: Bool) {
        paused = true; scheduler.playfulness = 0; clock = max(clock, 10); blinkAt = clock + 5
        setMood(.asleep, hold: 1e9, speak: false)
        for _ in 0..<60 { tick() }
        if asleepWithBird { birdArriveAt = clock - 5 }
        moodSetAt = clock - 5; publish()
        bubble = "z z z"
    }
    /// Offscreen review of a weather state.
    func settle(weather w: Critter.Weather, umbrella: Bool = false, night: Bool = false, age: Double = 60, mood m: Critter.Mood = .normal, bubbleText: String? = nil) {
        paused = true; scheduler.playfulness = 0; clock = max(clock, 10); blinkAt = clock + 5
        sky = Critter.Sky(kind: w, umbrella: umbrella, night: night, age: age); weatherUntil = clock + 1e9
        setMood(m, hold: 1e9, speak: false)
        for _ in 0..<60 { tick() }
        moodSetAt = clock - 5; publish()   // previews show the settled face, not the first frame of the dissolve
        bubble = bubbleText
    }
    /// True when the pointer (panel coordinates) is on the body: the only place a click is ours.
    func hit(_ p: CGPoint) -> Bool { let c = center(); return hypot(p.x - c.x, p.y - c.y) <= body.drawRadius * 1.15 }
}

// MARK: - drawing
struct CritterView: View {
    @ObservedObject var engine: CritterEngine
    @State private var lastDrag = CGSize.zero
    var body: some View {
        let s = engine.snapshot
        ZStack(alignment: .topLeading) {
            Canvas(rendersAsynchronously: false) { ctx, _ in CritterPainter.draw(s, in: &ctx) }
            if let text = engine.bubble {
                Text(text).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Color(white: 0.1))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .fixedSize().position(x: s.center.x, y: s.center.y - s.drawRadius * (2 * (s.scene?.scale ?? 1) - 1) * s.face.sy * s.squash - 20 - ((s.scene?.balloon ?? 0) > 0 ? s.drawRadius * 3.7 : 0) - ((s.scene?.umbrella ?? false) || (s.sky.kind == .rain && s.sky.umbrella && s.sceneKind == nil) ? s.drawRadius * 1.9 : 0) - (s.scene?.eyeOut ?? 0) * s.drawRadius * 0.9 - (s.scene?.stretch ?? 0) * s.drawRadius * 1.3 - (s.bird > 0.5 && s.birdLeave == 0 ? s.drawRadius * 0.95 : 0))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if let lang = engine.langLabel {
                Text(lang).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Color(white: 0.07), in: Capsule())
                    .fixedSize().position(x: s.center.x, y: s.center.y - s.drawRadius - 22 - (engine.bubble == nil ? 0 : 30))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            Color.clear.frame(width: s.drawRadius * 2.3, height: s.drawRadius * 2.3).contentShape(Circle())
                .position(s.center)
                .gesture(DragGesture(minimumDistance: 4).onChanged { v in engine.strokeMoved(by: hypot(v.translation.width - lastDrag.width, v.translation.height - lastDrag.height)); lastDrag = v.translation }
                    .onEnded { _ in lastDrag = .zero })
                .onTapGesture(count: 2) { engine.act(.tease) }
                .onTapGesture { engine.onTap?() }
                .contextMenu {
                    Menu("ให้อาหาร") { ForEach(Critter.Care.Food.allCases, id: \.self) { f in Button(f.emoji + " " + f.name) { engine.act(.feed(f)) } } }
                    Button("อ่านหนังสือ") { engine.act(.read) }
                    Button("เล่นด้วยกัน") { engine.act(.play) }
                    Button("เล่นหัว") { engine.act(.tease) }
                    Divider()
                    Button("ตั้งค่า…") { engine.onTap?() }
                }
        }
        .frame(width: engine.panelSize.width, height: engine.panelSize.height)
        .animation(engine.reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: engine.bubble)
        .animation(engine.reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: engine.langLabel)
    }
}

enum CritterPainter {
    static let ink = Color(white: 0.07)
    static let sky = Color(red: 0.55, green: 0.70, blue: 0.88)
    static let balloonRed = Color(red: 0.90, green: 0.25, blue: 0.30)
    static let umbrellaRed = Color(red: 0.93, green: 0.36, blue: 0.30)
    static let pacifierYellow = Color(red: 0.98, green: 0.80, blue: 0.18)
    static func draw(_ s: CritterEngine.Snapshot, in ctx: inout GraphicsContext) {
        let f = s.face, t = s.t
        let sc = s.scene ?? Critter.SceneFrame()
        let sceneScale = sc.scale
        // World effects: rain across the whole area, the manhole in the floor, the lightning flash.
        drawSky(s, in: &ctx)
        if sc.rain || s.sky.kind == .rain { drawRain(s, in: &ctx) }
        if s.sky.kind == .snow { drawSnow(s, in: &ctx) }
        if s.sky.kind == .wind { drawWind(s, in: &ctx) }
        if sc.manholeShown { drawManhole(s, open: sc.manhole, in: &ctx) }
        if sc.bolt > 0.01 { drawBolt(s, intensity: sc.bolt, in: &ctx) }
        if sc.star > 0.001 { drawShootingStar(s, progress: sc.star, in: &ctx) }
        if sc.clouds { drawClouds(s, in: &ctx) }
        if sc.disco { drawDisco(s, in: &ctx) }
        defer { if sc.water > 0.01 { drawWater(s, level: sc.water, in: &ctx) } }
        if s.burstAge >= 0 && s.burstAge < 0.45 { drawBurst(at: s.center, radius: s.drawRadius * 2.3, age: s.burstAge, unit: s.unit, in: &ctx) }
        if sc.hidden && sc.smokeCloud < 0.01 && sc.door < 0.01 { return }
        // Ground shadow: the one cue that turns "smaller" into "farther".
        let lift = max(0, s.groundY - s.drawRadius - s.center.y)
        let shadowScale = (1 - min(0.5, lift / (260 * s.unit))) * sceneScale
        ctx.opacity = 0.14 * (1 - min(0.7, lift / (260 * s.unit))) * (1 - sc.sink)
        ctx.fill(Path(ellipseIn: CGRect(x: s.center.x - 30 * s.unit * (s.drawRadius / (s.unit * 44)) * shadowScale, y: s.groundY - 6 * s.unit, width: 60 * s.unit * (s.drawRadius / (s.unit * 44)) * shadowScale, height: 10 * s.unit)), with: .color(ink))
        ctx.opacity = 1

        var c = ctx
        if sc.sink > 0 {
            // Dropping into the hole: everything below the rim is gone.
            c.clip(to: Path(CGRect(x: s.area.minX - 40, y: s.area.minY - 200, width: s.area.width + 80, height: s.groundY - s.area.minY + 200 - 2 * s.unit)))
            c.translateBy(x: 0, y: sc.sink * s.drawRadius * 2.4)
        }
        c.translateBy(x: s.center.x + sc.dashX * s.drawRadius, y: s.center.y - s.drawRadius * (sceneScale - 1))
        let k = s.drawRadius / 46 * sceneScale
        c.scaleBy(x: k, y: k)
        if sc.dashX != 0 { drawAfterimages(direction: sc.dashX > 0 ? 1 : -1, in: &c) }
        if sc.dust { drawDust(t: t, still: s.still, in: &c) }
        if sc.speedLines > 0.01 { drawSpeedLines(amount: sc.speedLines, t: t, still: s.still, in: &c) }
        if sc.bomb > 0.01 || sc.smokeCloud > 0.01 || sc.door > 0.01 { drawNinja(bomb: sc.bomb, cloud: sc.smokeCloud, door: sc.door, doorOpen: sc.doorOpen, t: t, still: s.still, in: &c) }
        if sc.hidden { return }
        if let pl = sc.plane { drawPlane(at: CGPoint(x: pl.x * 46, y: pl.y * 46), t: t, still: s.still, in: &c) }
        if sc.glass > 0.01 { drawGlass(amount: sc.glass, pouring: sc.pour, streamTo: 46 - sc.water * 46, t: t, still: s.still, in: &c) }
        if sc.bubbles { drawBubbles(t: t, still: s.still, in: &c) }
        if sc.aura { drawAura(t: t, still: s.still, in: &c) }
        if sc.ghost > 0.01 { drawGhost(amount: sc.ghost, t: t, still: s.still, in: &c) }
        if sc.melt > 0.01 { c.fill(Path(ellipseIn: CGRect(x: -46 * (1 + 0.9 * sc.melt), y: 46 - 7 * sc.melt, width: 92 * (1 + 0.9 * sc.melt), height: 14 * sc.melt)), with: .color(ink)) }
        if let a = sc.anvil { drawAnvil(drop: a, flat: sc.flat, in: &c) }
        // Things held or attached above the body, drawn before the body so their handle disappears into it.
        if sc.balloon > 0.01 { drawBalloon(amount: sc.balloon, t: t, still: s.still, in: &c) }
        if s.popAge >= 0 && s.popAge < 0.35 && s.sceneKind == .balloon { drawBurst(at: CGPoint(x: 0, y: -46 - 80 - 41), radius: 52, age: s.popAge, unit: 1, in: &c) }
        if sc.umbrella || (s.sky.kind == .rain && s.sky.umbrella && s.sceneKind == nil) { drawUmbrella(t: t, still: s.still, in: &c) }
        if sc.smoke > 0 { drawSmoke(t: t, still: s.still, in: &c) }
        if s.dropletAge >= 0 && s.dropletAge < 0.55 { drawDroplets(age: s.dropletAge, in: &c) }
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
        if sc.spinDeg != 0 { c.rotate(by: .degrees(sc.spinDeg)) }
        c.translateBy(x: 0, y: 46)
        c.scaleBy(x: f.sx * (2 - s.squash) * Critter.turnSqueeze(front: f.front) * (1 + 0.6 * sc.flat) * (1 - 0.25 * sc.stretch) * (1 + 0.7 * sc.melt), y: f.sy * s.squash * (1 - 0.85 * sc.flat) * (1 + 1.3 * sc.stretch) * (1 - 0.7 * sc.melt))
        c.translateBy(x: 0, y: -46)
        c.rotate(by: .degrees(f.tilt))
        let bodyPath = Path(ellipseIn: CGRect(x: -46, y: -46, width: 92, height: 92))
        if sc.spin > 0.01 {
            // Tasmanian-devil blur: three narrow ghosts of the body, turning.
            for i in 0..<3 {
                var g = c; g.rotate(by: .radians((s.still ? 0.4 : t * 28) + Double(i) * .pi / 3))
                g.fill(Path(ellipseIn: CGRect(x: -34, y: -50, width: 68, height: 100)), with: .color(ink.opacity(0.55)))
            }
        } else {
            c.fill(bodyPath, with: .color(ink))
            c.stroke(bodyPath, with: .color(.white.opacity(0.16)), lineWidth: 1.2)   // keeps it visible over a black window
        }
        if s.sky.kind == .snow && s.sceneKind == nil { drawSnowCap(amount: min(1, s.sky.age / 90), in: &c) }
        if sc.charred > 0.01 { drawCharred(amount: sc.charred, t: t, still: s.still, in: &c) }
        let an = Critter.anchors(front: f.front)
        let aL = CGPoint(x: an.left.x - 60, y: an.left.y - 60), aR = CGPoint(x: an.right.x - 60, y: an.right.y - 60)
        if f.blush > 0.01 {
            let fr = f.front
            for (x, y) in [(38 + 2 * fr - 60, 70 - 2 * fr - 60), (76 + 4 * fr - 60, 74 - 6 * fr - 60)] {
                c.fill(Path(ellipseIn: CGRect(x: x - 8 + s.gaze.x * 0.4, y: y - 4.5 + s.gaze.y * 0.4, width: 16, height: 9)), with: .color(Color(red: 0.83, green: 0.33, blue: 0.49).opacity(f.blush)))
            }
        }
        // Everything the face "lights up" goes through one painter: solid white (classic) or LED dots (pixel).
        // The geometry — anchors, turn, tilt, gaze, blink, squash — is the same in both styles.
        let px = s.pixelEyes
        let pixelMode: PixelMode = !px ? .none : s.external == .listening ? .equalizer(s.level) : (s.external == .thinking || s.mood == .thinking) ? .bands : .plain
        func lit(_ path: Path, alpha: Double, in g: inout GraphicsContext) {
            if px { drawDots(path, alpha: alpha, mode: pixelMode, t: t, age: s.moodAge, still: s.still, in: &g) }
            else { g.fill(path, with: .color(.white.opacity(alpha))) }
        }
        let eyeGrow = px ? 1.3 : 1.0   // LED eyes read bigger, like Astro's
        if f.arc < 0.99 && sc.hearts < 0.99 {
            let alpha = (1 - f.arc) * (1 - sc.hearts)
            if sc.eyeOut > 0.01 { drawFlyingEyes(left: aL, right: aR, out: sc.eyeOut, t: t, still: s.still, pixel: px, in: &c) }
            for (e0, a) in [(f.left, aL), (f.right, aR)] where sc.eyeOut < 0.01 {
                var e = e0; e.w *= eyeGrow; e.h *= eyeGrow
                var eye = c
                if sc.eyeScale != 1 { eye.translateBy(x: a.x, y: a.y); eye.scaleBy(x: sc.eyeScale, y: sc.eyeScale); eye.translateBy(x: -a.x, y: -a.y) }
                if sc.notes && s.blink < 0.5 {
                    lit(notePath(at: CGPoint(x: a.x + e.dx + s.gaze.x, y: a.y + e.dy + s.gaze.y), bounce: s.still ? 0 : sin(t * 12) * 2), alpha: alpha, in: &eye)
                } else if px && s.mood == .dizzy && s.external == .idle && s.blink < 0.5 {
                    // Astro's "hurt" face: X X.
                    var x = Path(); let o = CGPoint(x: a.x + e.dx + s.gaze.x, y: a.y + e.dy + s.gaze.y), r = 8.0
                    x.move(to: CGPoint(x: o.x - r, y: o.y - r)); x.addLine(to: CGPoint(x: o.x + r, y: o.y + r)); x.move(to: CGPoint(x: o.x + r, y: o.y - r)); x.addLine(to: CGPoint(x: o.x - r, y: o.y + r))
                    lit(x.strokedPath(StrokeStyle(lineWidth: 5, lineCap: .round)), alpha: alpha, in: &eye)
                } else {
                    lit(pill(e, at: a, gaze: s.gaze, blink: s.blink), alpha: alpha, in: &eye)
                }
            }
        }
        if sc.hearts > 0.01 {
            for a in [aL, aR] {
                let o = CGPoint(x: a.x + s.gaze.x * 0.5, y: a.y + s.gaze.y * 0.5), size = 11 * (1 + 0.12 * (s.still ? 0 : sin(t * 6)))
                if px { lit(heartPath(at: o, size: size * 1.25), alpha: sc.hearts, in: &c) } else { drawHeart(at: o, size: size, opacity: sc.hearts, in: &c) }
            }
        }
        if sc.book { drawGlasses(left: aL, right: aR, gaze: s.gaze, in: &c) }
        if f.arc > 0.01 {
            for a in [aL, aR] {
                let w = 8 * eyeGrow, h = (px ? 8.0 : 6.0)
                var p = Path(); p.move(to: CGPoint(x: a.x - w + s.gaze.x, y: a.y + 4 + s.gaze.y))
                p.addQuadCurve(to: CGPoint(x: a.x + w + s.gaze.x, y: a.y + 4 + s.gaze.y), control: CGPoint(x: a.x + s.gaze.x, y: a.y - h - 2 + s.gaze.y))
                lit(p.strokedPath(StrokeStyle(lineWidth: px ? 7 : 6, lineCap: .round)), alpha: f.arc, in: &c)
            }
        }
        if f.tear > 0.01 {
            let ph = s.still ? 0.4 : (s.moodAge * 0.7).truncatingRemainder(dividingBy: 1)
            var d = Path(); let o = CGPoint(x: aL.x + s.gaze.x, y: aL.y + 12 + s.gaze.y + ph * 16)
            d.move(to: o); d.addCurve(to: CGPoint(x: o.x, y: o.y + 9), control1: CGPoint(x: o.x - 3, y: o.y + 4), control2: CGPoint(x: o.x - 3, y: o.y + 8))
            d.addCurve(to: o, control1: CGPoint(x: o.x + 3, y: o.y + 8), control2: CGPoint(x: o.x + 3, y: o.y + 4)); d.closeSubpath()
            c.fill(d, with: .color(Color(red: 0.52, green: 0.72, blue: 0.92).opacity(f.tear * (1 - ph) * 0.95)))
        }
        let mouth = CGPoint(x: (aL.x + aR.x) / 2 + s.gaze.x * 0.5, y: max(aL.y, aR.y) + 26 + s.gaze.y * 0.3)
        if sc.prop && !s.prop.isEmpty {
            let bob = s.still ? 0 : sin(t * 9) * 2.5 * sc.chew
            c.draw(Text(s.prop).font(.system(size: 30)), at: CGPoint(x: mouth.x + 26, y: mouth.y + 2 + bob), anchor: .center)
        }
        if sc.book { c.draw(Text("📖").font(.system(size: 34)), at: CGPoint(x: mouth.x, y: mouth.y + 16 + (s.still ? 0 : sin(t * 1.4) * 1.5)), anchor: .center) }
        if sc.pacifier > 0.01 { drawPacifier(at: mouth, amount: sc.pacifier, t: t, still: s.still, in: &c) }
        if sc.snot > 0.01 { drawSnot(at: CGPoint(x: mouth.x, y: mouth.y - 8), amount: sc.snot, t: t, still: s.still, in: &c) }
        if sc.ice > 0.01 { drawIce(amount: sc.ice, in: &c) }
        if s.bird > 0.001 || s.birdLeave > 0.001 { drawBird(arrive: s.bird, leave: s.birdLeave, t: t, still: s.still, in: &c) }
        if sc.box > 0.01 { drawBox(lowered: sc.box, eyeLevel: (aL.y + aR.y) / 2, in: &c) }
    }

    // MARK: LED dots — any lit shape is sampled on one lattice so both eyes share the same pixel grid.
    static let led = Color(red: 0.37, green: 0.88, blue: 1.0)
    static let pitch = 3.2, dot = 2.5
    enum PixelMode { case none, plain, bands, equalizer(Double) }
    static func hash(_ i: Int, _ j: Int) -> Double { var h = UInt32(bitPattern: Int32(truncatingIfNeeded: i &* 374761393 &+ j &* 668265263)); h = (h ^ (h >> 13)) &* 1274126177; return Double(h ^ (h >> 16)) / Double(UInt32.max) }
    static func drawDots(_ path: Path, alpha: Double, mode: PixelMode, t: Double, age: Double, still: Bool, in c: inout GraphicsContext) {
        guard alpha > 0.02 else { return }
        let b = path.boundingRect.insetBy(dx: -pitch, dy: -pitch)
        let i0 = Int(floor(b.minX / pitch)), i1 = Int(ceil(b.maxX / pitch)), j0 = Int(floor(b.minY / pitch)), j1 = Int(ceil(b.maxY / pitch))
        guard i1 > i0, j1 > j0, (i1 - i0) * (j1 - j0) < 4000 else { return }
        var on = Path(), halo = Path(), dim = Path()
        for j in j0...j1 {
            for i in i0...i1 {
                let p = CGPoint(x: Double(i) * pitch, y: Double(j) * pitch)
                guard path.contains(p) else { continue }
                // A new expression switches its dots on in a random order, like a panel refreshing.
                let n = hash(i, j)
                if !still && age < 0.3 && n > age / 0.3 + 0.1 { continue }
                var bright = true
                switch mode {
                case .none, .plain: break
                case .bands: let ph = still ? 0 : Int(t * 9); bright = (i + j + ph) % 4 < 2
                case .equalizer(let lv):
                    let col = Double(i - i0), rows = Double(j1 - j0), fromBottom = Double(j1 - j)
                    let h = (0.25 + lv * 0.75) * (0.6 + 0.4 * abs(sin(col * 1.7 + (still ? 0 : t * 11)))) * rows
                    bright = fromBottom <= h
                }
                let r = CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)
                if bright { on.addRoundedRect(in: r, cornerSize: CGSize(width: 0.8, height: 0.8)); halo.addRoundedRect(in: r.insetBy(dx: -1.1, dy: -1.1), cornerSize: CGSize(width: 1.6, height: 1.6)) }
                else { dim.addRoundedRect(in: r, cornerSize: CGSize(width: 0.8, height: 0.8)) }
            }
        }
        c.fill(halo, with: .color(led.opacity(0.22 * alpha)))
        c.fill(on, with: .color(led.opacity(alpha)))
        c.fill(dim, with: .color(led.opacity(0.28 * alpha)))
    }
    static func heartPath(at o: CGPoint, size r: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: o.x, y: o.y + r))
        p.addCurve(to: CGPoint(x: o.x - r, y: o.y - r * 0.3), control1: CGPoint(x: o.x - r * 0.6, y: o.y + r * 0.5), control2: CGPoint(x: o.x - r, y: o.y + r * 0.1))
        p.addArc(center: CGPoint(x: o.x - r * 0.5, y: o.y - r * 0.4), radius: r * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: o.x + r * 0.5, y: o.y - r * 0.4), radius: r * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: o.x, y: o.y + r), control1: CGPoint(x: o.x + r, y: o.y + r * 0.1), control2: CGPoint(x: o.x + r * 0.6, y: o.y + r * 0.5))
        return p
    }
    // MARK: weather (world space)
    static func drawSky(_ s: CritterEngine.Snapshot, in ctx: inout GraphicsContext) {
        let a = s.area, u = s.unit, t = s.t
        let corner = CGPoint(x: a.maxX - 30 * u, y: a.minY + 6 * u)
        if s.sky.night {
            let disc = Path(ellipseIn: CGRect(x: corner.x - 13 * u, y: corner.y - 13 * u, width: 26 * u, height: 26 * u))
            var moon = disc; moon.addEllipse(in: CGRect(x: corner.x - 5 * u, y: corner.y - 17 * u, width: 26 * u, height: 26 * u))
            var m = ctx; m.clip(to: disc)
            m.fill(moon, with: .color(Color(red: 0.98, green: 0.93, blue: 0.7).opacity(0.85)), style: FillStyle(eoFill: true))
            for (i, p) in [(-90.0, 8.0), (-140.0, 24.0), (-60.0, 40.0), (-190.0, 4.0), (-110.0, 56.0), (-230.0, 36.0), (-30.0, 70.0)].enumerated() {
                let tw = s.still ? 0.7 : 0.5 + 0.5 * sin(t * 2 + Double(i) * 1.7), r = (1.2 + Double(i % 3) * 0.5) * u
                ctx.fill(Path(ellipseIn: CGRect(x: corner.x + p.0 * u - r, y: corner.y + p.1 * u - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(0.35 + 0.5 * tw)))
            }
        }
        if s.sky.kind == .sunny || s.sky.kind == .heat {
            let hot = s.sky.kind == .heat
            let col = hot ? Color(red: 1, green: 0.5, blue: 0.2) : Color(red: 1, green: 0.82, blue: 0.25)
            var rays = Path()
            for i in 0..<10 {
                let ang = Double(i) * .pi / 5 + (s.still ? 0 : t * 0.25), r0 = 20.0 * u, r1 = (28 + (i % 2 == 0 ? 6 : 0)) * u
                rays.move(to: CGPoint(x: corner.x + cos(ang) * r0, y: corner.y + sin(ang) * r0)); rays.addLine(to: CGPoint(x: corner.x + cos(ang) * r1, y: corner.y + sin(ang) * r1))
            }
            ctx.stroke(rays, with: .color(col.opacity(0.8)), style: StrokeStyle(lineWidth: 2.2 * u, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: corner.x - 15 * u, y: corner.y - 15 * u, width: 30 * u, height: 30 * u)), with: .color(col))
            if hot {
                // Heat shimmer over the floor.
                var shimmer = Path()
                for i in 0..<5 {
                    let x = a.minX + 20 * u + Double(i) * (a.width - 40 * u) / 4, y0 = s.groundY - 26 * u
                    shimmer.move(to: CGPoint(x: x, y: y0))
                    for j in 1...4 { let ph = s.still ? 0 : t * 3 + Double(i); shimmer.addLine(to: CGPoint(x: x + sin(ph + Double(j) * 1.6) * 3 * u, y: y0 - Double(j) * 6 * u)) }
                }
                ctx.stroke(shimmer, with: .color(Color(red: 1, green: 0.6, blue: 0.3).opacity(0.35)), style: StrokeStyle(lineWidth: 1.2 * u, lineCap: .round))
            }
        }
    }
    static func drawSnow(_ s: CritterEngine.Snapshot, in ctx: inout GraphicsContext) {
        let a = s.area, u = s.unit
        var flakes = Path()
        for i in 0..<30 {
            let fall = s.still ? 0.4 : (s.t * 0.18 + Double(i) * 0.137).truncatingRemainder(dividingBy: 1)
            let x = a.minX + Double((i * 71) % Int(max(1, a.width))) + (s.still ? 0 : sin(s.t * 1.1 + Double(i)) * 8 * u)
            let y = a.minY - 10 * u + fall * (s.groundY - a.minY + 10 * u), r = (1.6 + Double(i % 3) * 0.7) * u
            flakes.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        ctx.fill(flakes, with: .color(.white.opacity(0.85)))
        let pile = min(1, s.sky.age / 120)
        if pile > 0.05 { ctx.fill(Path(roundedRect: CGRect(x: a.minX, y: s.groundY - 2 * u - 4 * u * pile, width: a.width, height: 6 * u * pile + 2 * u), cornerRadius: 3 * u), with: .color(.white.opacity(0.7))) }
    }
    static func drawWind(_ s: CritterEngine.Snapshot, in ctx: inout GraphicsContext) {
        let a = s.area, u = s.unit
        var streaks = Path()
        for i in 0..<7 {
            let ph = s.still ? 0.4 : (s.t * 0.5 + Double(i) * 0.19).truncatingRemainder(dividingBy: 1)
            let x = a.minX - 40 * u + ph * (a.width + 80 * u), y = a.minY + 14 * u + Double(i) * (a.height - 30 * u) / 6
            streaks.move(to: CGPoint(x: x, y: y))
            streaks.addCurve(to: CGPoint(x: x + 36 * u, y: y), control1: CGPoint(x: x + 12 * u, y: y - 5 * u), control2: CGPoint(x: x + 24 * u, y: y + 5 * u))
        }
        ctx.stroke(streaks, with: .color(Color(white: 0.75).opacity(0.55)), style: StrokeStyle(lineWidth: 1.4 * u, lineCap: .round))
        for i in 0..<3 {
            let ph = s.still ? 0.5 : (s.t * 0.35 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
            let x = a.minX - 20 * u + ph * (a.width + 40 * u), y = a.minY + 30 * u + Double(i) * 34 * u + (s.still ? 0 : sin(s.t * 3 + Double(i)) * 10 * u)
            var leaf = ctx; leaf.translateBy(x: x, y: y); leaf.rotate(by: .radians(s.still ? 0.6 : s.t * 4 + Double(i)))
            leaf.fill(Path(ellipseIn: CGRect(x: -5 * u, y: -2.5 * u, width: 10 * u, height: 5 * u)), with: .color([Color(red: 0.55, green: 0.7, blue: 0.3), Color(red: 0.9, green: 0.55, blue: 0.2), Color(red: 0.8, green: 0.35, blue: 0.2)][i]))
        }
    }
    static func drawSnowCap(amount: Double, in c: inout GraphicsContext) {
        var cap = Path()
        cap.move(to: CGPoint(x: -40 * amount, y: -22 - 20 * amount))
        cap.addQuadCurve(to: CGPoint(x: 40 * amount, y: -22 - 20 * amount), control: CGPoint(x: 0, y: -60 - 6 * amount))
        cap.addQuadCurve(to: CGPoint(x: -40 * amount, y: -22 - 20 * amount), control: CGPoint(x: 0, y: -30 - 10 * amount))
        c.fill(cap, with: .color(.white.opacity(0.92 * min(1, amount * 3))))
    }
    // MARK: cartoon gags (body space)
    static func drawAfterimages(direction: Double, in c: inout GraphicsContext) {
        for i in 1...3 {
            let off = -direction * Double(i) * 30
            c.fill(Path(ellipseIn: CGRect(x: off - 46, y: -46, width: 92, height: 92)), with: .color(ink.opacity(0.32 / Double(i))))
        }
        var lines = Path()
        for y in [-30.0, -10.0, 12.0, 30.0] { lines.move(to: CGPoint(x: -direction * 60, y: y)); lines.addLine(to: CGPoint(x: -direction * (110 + abs(y)), y: y)) }
        c.stroke(lines, with: .color(ink.opacity(0.5)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }
    static func drawDust(t: Double, still: Bool, in c: inout GraphicsContext) {
        for i in 0..<6 {
            let ph = still ? 0.5 : (t * 1.4 + Double(i) * 0.17).truncatingRemainder(dividingBy: 1)
            let x = -50 + Double(i) * 20 + sin(ph * 7 + Double(i)) * 6, y = 40 - ph * 14, r = 8 + ph * 8
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(Color(white: 0.6).opacity((1 - ph) * 0.5)))
        }
    }
    static func drawAnvil(drop: Double, flat: Double, in c: inout GraphicsContext) {
        let bodyTop = 46 - 92 * (1 - 0.85 * flat)
        let bottom = bodyTop - (1 - drop) * 150
        var p = Path()
        p.move(to: CGPoint(x: -34, y: bottom - 34)); p.addLine(to: CGPoint(x: 34, y: bottom - 34)); p.addLine(to: CGPoint(x: 22, y: bottom - 16))
        p.addLine(to: CGPoint(x: 14, y: bottom - 16)); p.addLine(to: CGPoint(x: 18, y: bottom)); p.addLine(to: CGPoint(x: -18, y: bottom)); p.addLine(to: CGPoint(x: -14, y: bottom - 16)); p.addLine(to: CGPoint(x: -22, y: bottom - 16)); p.closeSubpath()
        c.fill(p, with: .color(Color(white: 0.3)))
        c.stroke(p, with: .color(Color(white: 0.55)), lineWidth: 1.5)
    }
    static func drawHeart(at o: CGPoint, size r: Double, opacity: Double, in c: inout GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: o.x, y: o.y + r))
        p.addCurve(to: CGPoint(x: o.x - r, y: o.y - r * 0.3), control1: CGPoint(x: o.x - r * 0.6, y: o.y + r * 0.5), control2: CGPoint(x: o.x - r, y: o.y + r * 0.1))
        p.addArc(center: CGPoint(x: o.x - r * 0.5, y: o.y - r * 0.4), radius: r * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: o.x + r * 0.5, y: o.y - r * 0.4), radius: r * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: o.x, y: o.y + r), control1: CGPoint(x: o.x + r, y: o.y + r * 0.1), control2: CGPoint(x: o.x + r * 0.6, y: o.y + r * 0.5))
        c.fill(p, with: .color(Color(red: 0.95, green: 0.3, blue: 0.45).opacity(opacity)))
    }
    static func drawGlasses(left: CGPoint, right: CGPoint, gaze: CGPoint, in c: inout GraphicsContext) {
        var g = Path()
        for a in [left, right] { g.addEllipse(in: CGRect(x: a.x + gaze.x - 12, y: a.y + gaze.y - 15, width: 24, height: 30)) }
        g.move(to: CGPoint(x: left.x + gaze.x + 12, y: left.y + gaze.y - 2)); g.addLine(to: CGPoint(x: right.x + gaze.x - 12, y: right.y + gaze.y - 2))
        c.stroke(g, with: .color(Color(white: 0.8)), lineWidth: 2)
    }
    // MARK: set-piece props. Body-space helpers work in the 92-unit body (radius 46), world helpers in panel points.
    static func drawRain(_ s: CritterEngine.Snapshot, in ctx: inout GraphicsContext) {
        let a = s.area, u = s.unit
        var drops = Path()
        for i in 0..<34 {
            let x = a.minX + Double((i * 61) % Int(max(1, a.width)))
            let fall = s.still ? 0.4 : (s.t * 1.7 + Double(i) * 0.173).truncatingRemainder(dividingBy: 1)
            let y = a.minY - 30 * u + fall * (s.groundY - a.minY + 30 * u)
            drops.move(to: CGPoint(x: x, y: y)); drops.addLine(to: CGPoint(x: x - 2 * u, y: y + 9 * u))
        }
        ctx.stroke(drops, with: .color(sky.opacity(0.75)), style: StrokeStyle(lineWidth: max(1, 1.4 * u), lineCap: .round))
        var splash = Path()
        for i in 0..<9 {
            let ph = s.still ? 0.3 : (s.t * 2.1 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
            let x = a.minX + Double((i * 97 + 20) % Int(max(1, a.width)))
            splash.addEllipse(in: CGRect(x: x - 5 * u * ph, y: s.groundY - 1.5 * u * ph, width: 10 * u * ph, height: 3 * u * ph))
        }
        ctx.stroke(splash, with: .color(sky.opacity(0.5)), lineWidth: max(0.8, 0.9 * u))
    }
    static func drawManhole(_ s: CritterEngine.Snapshot, open: Double, in ctx: inout GraphicsContext) {
        let r = s.drawRadius, w = r * 2.6, h = r * 0.62, cx = s.center.x, cy = s.groundY
        let hole = Path(ellipseIn: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
        ctx.fill(hole, with: .color(Color(white: 0.16)))
        ctx.stroke(hole, with: .color(Color(white: 0.42)), lineWidth: max(1, 1.5 * s.unit))
        // The lid slides left and tips up as it opens.
        var lid = ctx
        lid.translateBy(x: cx - open * w * 0.95, y: cy - open * h * 0.6)
        lid.rotate(by: .degrees(-open * 28))
        let lidPath = Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        lid.fill(lidPath, with: .color(Color(white: 0.36)))
        lid.stroke(lidPath, with: .color(Color(white: 0.62)), lineWidth: max(1, 1.5 * s.unit))
        var grooves = Path()
        for i in -2...2 { grooves.move(to: CGPoint(x: Double(i) * w * 0.15, y: -h * 0.3)); grooves.addLine(to: CGPoint(x: Double(i) * w * 0.15, y: h * 0.3)) }
        lid.stroke(grooves, with: .color(Color(white: 0.22).opacity(0.8)), lineWidth: max(0.8, 1.2 * s.unit))
    }
    static func drawBolt(_ s: CritterEngine.Snapshot, intensity: Double, in ctx: inout GraphicsContext) {
        ctx.fill(Path(CGRect(x: s.area.minX - 40, y: s.area.minY - 200, width: s.area.width + 80, height: s.area.height + 300)), with: .color(.white.opacity(0.45 * intensity)))
        var p = Path()
        let top = CGPoint(x: s.center.x + 22 * s.unit, y: s.area.minY - 60 * s.unit), bottom = CGPoint(x: s.center.x, y: s.center.y - s.drawRadius)
        p.move(to: top)
        for (i, q) in [0.28, 0.5, 0.72, 1.0].enumerated() {
            let zig = (i % 2 == 0 ? -1.0 : 1.0) * 16 * s.unit * (q < 1 ? 1 : 0)
            p.addLine(to: CGPoint(x: top.x + (bottom.x - top.x) * q + zig, y: top.y + (bottom.y - top.y) * q))
        }
        ctx.stroke(p, with: .color(Color(red: 1, green: 0.9, blue: 0.3).opacity(0.9 * intensity)), style: StrokeStyle(lineWidth: 7 * s.unit, lineCap: .round, lineJoin: .round))
        ctx.stroke(p, with: .color(.white.opacity(intensity)), style: StrokeStyle(lineWidth: 2.5 * s.unit, lineCap: .round, lineJoin: .round))
    }
    static func drawBurst(at o: CGPoint, radius: Double, age: Double, unit: Double, in ctx: inout GraphicsContext) {
        let q = min(1, age / 0.4), fade = 1 - q
        var rays = Path(), bits = Path()
        for i in 0..<12 {
            let a = Double(i) * .pi / 6 + 0.2
            rays.move(to: CGPoint(x: o.x + cos(a) * radius * (0.3 + q * 0.6), y: o.y + sin(a) * radius * (0.3 + q * 0.6)))
            rays.addLine(to: CGPoint(x: o.x + cos(a) * radius * (0.6 + q * 0.9), y: o.y + sin(a) * radius * (0.6 + q * 0.9)))
            if i % 2 == 0 { let d = radius * (0.5 + q * 1.3), r = radius * 0.09 * fade; bits.addEllipse(in: CGRect(x: o.x + cos(a + 0.3) * d - r, y: o.y + sin(a + 0.3) * d - r + q * q * radius * 0.5, width: 2 * r, height: 2 * r)) }
        }
        ctx.stroke(rays, with: .color(ink.opacity(fade)), style: StrokeStyle(lineWidth: max(1.5, 3 * unit), lineCap: .round))
        ctx.fill(bits, with: .color(ink.opacity(fade)))
    }
    static func drawBalloon(amount: Double, t: Double, still: Bool, in c: inout GraphicsContext) {
        let sway = still ? 0 : sin(t * 1.3) * 8, top = -46.0 - 80 * amount
        var string = Path(); string.move(to: CGPoint(x: 0, y: -44))
        string.addQuadCurve(to: CGPoint(x: sway, y: top), control: CGPoint(x: sway * 0.2 - 6, y: -46 - 35 * amount))
        c.stroke(string, with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        var knot = Path(); knot.move(to: CGPoint(x: sway - 4, y: top - 1)); knot.addLine(to: CGPoint(x: sway + 4, y: top - 1)); knot.addLine(to: CGPoint(x: sway, y: top + 4)); knot.closeSubpath()
        c.fill(knot, with: .color(balloonRed))
        let w = 66 * amount, h = 82 * amount
        let body = Path(ellipseIn: CGRect(x: sway - w / 2, y: top - h, width: w, height: h))
        c.fill(body, with: .color(balloonRed))
        c.fill(Path(ellipseIn: CGRect(x: sway - w * 0.28, y: top - h * 0.84, width: w * 0.16, height: h * 0.3)), with: .color(.white.opacity(0.45)))
    }
    static func drawUmbrella(t: Double, still: Bool, in c: inout GraphicsContext) {
        // Wagasa: a wide, shallow paper canopy on many thin bamboo ribs, a thin straight handle — held up to the side.
        var u = c
        u.translateBy(x: 12, y: -26 + (still ? 0 : sin(t * 2) * 1.5))
        u.rotate(by: .degrees(-12))
        let top = CGPoint(x: 0, y: -50), r = 72.0, depth = 28.0
        var pole = Path(); pole.move(to: CGPoint(x: 0, y: top.y - 4)); pole.addLine(to: CGPoint(x: 0, y: 44))
        u.stroke(pole, with: .color(Color(red: 0.55, green: 0.42, blue: 0.25)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        var canopy = Path()
        canopy.move(to: CGPoint(x: -r, y: top.y + depth))
        canopy.addQuadCurve(to: CGPoint(x: r, y: top.y + depth), control: CGPoint(x: 0, y: top.y - depth * 0.9))
        canopy.closeSubpath()
        u.fill(canopy, with: .color(Color(white: 0.16)))
        var ribs = Path()
        for i in 0...14 {
            let x = -r + Double(i) * (2 * r / 14), yy = top.y + depth - (1 - (x / r) * (x / r)) * depth * 0.95
            ribs.move(to: CGPoint(x: 0, y: top.y - 2)); ribs.addLine(to: CGPoint(x: x, y: yy))
        }
        u.stroke(ribs, with: .color(.white.opacity(0.22)), lineWidth: 0.8)
        u.stroke(canopy, with: .color(.white.opacity(0.5)), lineWidth: 1.2)
        var rim = Path(); rim.move(to: CGPoint(x: -r, y: top.y + depth)); rim.addLine(to: CGPoint(x: r, y: top.y + depth))
        u.stroke(rim, with: .color(.white.opacity(0.35)), lineWidth: 0.8)
        u.fill(Path(ellipseIn: CGRect(x: -2.5, y: top.y - 8, width: 5, height: 6)), with: .color(Color(red: 0.55, green: 0.42, blue: 0.25)))
    }
    static func drawNinja(bomb: Double, cloud: Double, door: Double, doorOpen: Double, t: Double, still: Bool, in c: inout GraphicsContext) {
        if door > 0.01 {
            // A door standing on the floor behind where it stood: frame, panel swinging open toward the viewer's left.
            var d = c; d.translateBy(x: -6, y: 46); d.scaleBy(x: 1, y: door)
            let frame = CGRect(x: -34, y: -100, width: 68, height: 100)
            d.fill(Path(roundedRect: frame, cornerRadius: 3), with: .color(Color(red: 0.50, green: 0.34, blue: 0.20)))
            d.fill(Path(CGRect(x: -29, y: -95, width: 58, height: 95)), with: .color(Color(white: 0.10)))
            var panel = d; panel.translateBy(x: -29, y: 0); panel.scaleBy(x: max(0.04, 1 - doorOpen * 0.92), y: 1); panel.translateBy(x: 29, y: 0)
            panel.fill(Path(CGRect(x: -29, y: -95, width: 58, height: 95)), with: .color(Color(red: 0.70, green: 0.50, blue: 0.30)))
            panel.stroke(Path(CGRect(x: -22, y: -88, width: 44, height: 36)), with: .color(Color(red: 0.50, green: 0.34, blue: 0.20)), lineWidth: 2)
            panel.stroke(Path(CGRect(x: -22, y: -44, width: 44, height: 36)), with: .color(Color(red: 0.50, green: 0.34, blue: 0.20)), lineWidth: 2)
            panel.fill(Path(ellipseIn: CGRect(x: 16, y: -52, width: 6, height: 6)), with: .color(Color(red: 0.9, green: 0.75, blue: 0.3)))
        }
        if bomb > 0.01 {
            let y = -20 + 66 * bomb, x = 10 + 8 * bomb
            c.fill(Path(ellipseIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14)), with: .color(Color(white: 0.25)))
            var fuse = Path(); fuse.move(to: CGPoint(x: x + 3, y: y - 6)); fuse.addQuadCurve(to: CGPoint(x: x + 9, y: y - 13), control: CGPoint(x: x + 3, y: y - 13))
            c.stroke(fuse, with: .color(Color(white: 0.6)), lineWidth: 1.5)
            c.fill(Path(ellipseIn: CGRect(x: x + 7, y: y - 15, width: 4, height: 4)), with: .color(Color(red: 1, green: 0.6, blue: 0.2)))
        }
        if cloud > 0.01 {
            for (i, (dx, dy, k)) in [(0.0, 10.0, 1.0), (-38.0, 20.0, 0.8), (40.0, 18.0, 0.85), (-22.0, -20.0, 0.7), (26.0, -24.0, 0.75), (0.0, -40.0, 0.6), (-50.0, -6.0, 0.55), (52.0, -4.0, 0.55)].enumerated() {
                let wob = still ? 0 : sin(t * 3 + Double(i)) * 3
                let r = (30 + 22 * cloud) * k
                c.fill(Path(ellipseIn: CGRect(x: dx * (0.6 + 0.6 * cloud) - r + wob, y: dy * (0.6 + 0.6 * cloud) - r, width: 2 * r, height: 2 * r)), with: .color(Color(white: 0.62).opacity(0.85 * min(1, cloud * 1.5))))
            }
        }
    }
    static func notePath(at o: CGPoint, bounce: Double) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: o.x - 9, y: o.y + 4 + bounce, width: 12, height: 9))
        p.addRoundedRect(in: CGRect(x: o.x + 1, y: o.y - 14 + bounce, width: 3.5, height: 22), cornerSize: CGSize(width: 1.5, height: 1.5))
        p.move(to: CGPoint(x: o.x + 4.5, y: o.y - 14 + bounce))
        p.addQuadCurve(to: CGPoint(x: o.x + 11, y: o.y - 2 + bounce), control: CGPoint(x: o.x + 13, y: o.y - 12 + bounce))
        p.addQuadCurve(to: CGPoint(x: o.x + 4.5, y: o.y - 8 + bounce), control: CGPoint(x: o.x + 9, y: o.y - 6 + bounce))
        p.closeSubpath()
        return p
    }
    static func drawClouds(_ s: CritterEngine.Snapshot, in ctx: inout GraphicsContext) {
        let a = s.area, u = s.unit
        for i in 0..<3 {
            let span = a.width + 140 * u
            let x = a.maxX + 70 * u - (s.still ? Double(i) * 90 * u : (s.t * 55 * u + Double(i) * 105 * u).truncatingRemainder(dividingBy: span))
            let y = a.minY + 12 * u + Double(i) * 26 * u, r = (11 + Double(i % 2) * 4) * u
            var cloud = Path()
            for (dx, dy, k) in [(-1.2, 0.2, 0.8), (0.0, -0.2, 1.0), (1.2, 0.25, 0.75), (0.5, 0.5, 0.7)] { cloud.addEllipse(in: CGRect(x: x + dx * r - r * k, y: y + dy * r - r * k, width: 2 * r * k, height: 2 * r * k)) }
            ctx.fill(cloud, with: .color(.white.opacity(0.88)))
        }
    }
    static func drawDisco(_ s: CritterEngine.Snapshot, in ctx: inout GraphicsContext) {
        let a = s.area, u = s.unit
        let colors = [Color(red: 0.95, green: 0.3, blue: 0.5), Color(red: 0.3, green: 0.8, blue: 1.0), Color(red: 1.0, green: 0.85, blue: 0.3), Color(red: 0.55, green: 0.4, blue: 1.0), Color(red: 0.3, green: 0.9, blue: 0.5)]
        for i in 0..<7 {
            let x = a.minX + (Double(i) + 0.5) * a.width / 7, beat = s.still ? 0.6 : 0.5 + 0.5 * sin(s.t * 6.3 + Double(i) * 1.1)
            let r = (9 + 5 * beat) * u, col = colors[(i + (s.still ? 0 : Int(s.t * 2))) % colors.count]
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: s.groundY - r * 0.35, width: 2 * r, height: r * 0.7)), with: .color(col.opacity(0.28 + 0.25 * beat)))
        }
    }
    static func drawWater(_ s: CritterEngine.Snapshot, level: Double, in ctx: inout GraphicsContext) {
        let a = s.area, u = s.unit, top = s.groundY - level * s.drawRadius
        var w = Path(); w.move(to: CGPoint(x: a.minX - 20 * u, y: top))
        var x = a.minX - 20 * u
        while x < a.maxX + 20 * u { let nx = x + 24 * u; w.addQuadCurve(to: CGPoint(x: nx, y: top), control: CGPoint(x: x + 12 * u, y: top + (s.still ? 3 : sin(s.t * 3 + x / (30 * u)) * 3.5) * u)); x = nx }
        w.addLine(to: CGPoint(x: a.maxX + 20 * u, y: a.maxY + 40 * u)); w.addLine(to: CGPoint(x: a.minX - 20 * u, y: a.maxY + 40 * u)); w.closeSubpath()
        ctx.fill(w, with: .color(Color(red: 0.45, green: 0.72, blue: 1.0).opacity(0.42)))
        ctx.stroke(w, with: .color(.white.opacity(0.55)), lineWidth: 1.5 * u)
    }
    static func drawGlass(amount: Double, pouring: Bool, streamTo: Double, t: Double, still: Bool, in c: inout GraphicsContext) {
        var g = c
        g.translateBy(x: 70, y: -120 - (1 - amount) * 80)
        g.rotate(by: .degrees(-70 * amount))
        let glass = Path(roundedRect: CGRect(x: -16, y: -28, width: 32, height: 52), cornerRadius: 4)
        g.fill(glass, with: .color(.white.opacity(0.18)))
        g.stroke(glass, with: .color(.white.opacity(0.8)), lineWidth: 2)
        g.fill(Path(CGRect(x: -14, y: pouring ? 2 : -6, width: 28, height: pouring ? 20 : 28)), with: .color(Color(red: 0.45, green: 0.72, blue: 1.0).opacity(0.6)))
        if pouring {
            var stream = Path(); stream.move(to: CGPoint(x: 42, y: -92))
            stream.addQuadCurve(to: CGPoint(x: 6, y: streamTo), control: CGPoint(x: 30, y: -30))
            c.stroke(stream, with: .color(Color(red: 0.45, green: 0.72, blue: 1.0).opacity(0.75)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            c.stroke(stream, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
    static func drawBubbles(t: Double, still: Bool, in c: inout GraphicsContext) {
        for i in 0..<5 {
            let ph = still ? 0.3 + Double(i) * 0.15 : (t * 0.5 + Double(i) * 0.2).truncatingRemainder(dividingBy: 1)
            let x = -20 + Double(i) * 10 + sin(ph * 6 + Double(i)) * 5, y = -40 - ph * 90, r = 2.5 + Double(i % 3) * 1.5
            c.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity((1 - ph) * 0.8)), lineWidth: 1.2)
        }
    }
    static func drawPlane(at o: CGPoint, t: Double, still: Bool, in c: inout GraphicsContext) {
        let body = Color(white: 0.92), dark = Color(white: 0.45), red = Color(red: 0.86, green: 0.24, blue: 0.24)
        c.fill(Path(ellipseIn: CGRect(x: o.x - 64, y: o.y - 15, width: 128, height: 30)), with: .color(body))
        c.stroke(Path(ellipseIn: CGRect(x: o.x - 64, y: o.y - 15, width: 128, height: 30)), with: .color(dark), lineWidth: 1.5)
        var wing = Path(); wing.move(to: CGPoint(x: o.x - 10, y: o.y)); wing.addLine(to: CGPoint(x: o.x - 40, y: o.y + 22)); wing.addLine(to: CGPoint(x: o.x - 18, y: o.y + 22)); wing.addLine(to: CGPoint(x: o.x + 14, y: o.y)); wing.closeSubpath()
        c.fill(wing, with: .color(dark))
        var tail = Path(); tail.move(to: CGPoint(x: o.x - 60, y: o.y - 4)); tail.addLine(to: CGPoint(x: o.x - 70, y: o.y - 26)); tail.addLine(to: CGPoint(x: o.x - 52, y: o.y - 26)); tail.addLine(to: CGPoint(x: o.x - 40, y: o.y - 8)); tail.closeSubpath()
        c.fill(tail, with: .color(red))
        c.fill(Path(CGRect(x: o.x - 30, y: o.y - 4, width: 60, height: 5)), with: .color(red))
        for i in 0..<3 { c.fill(Path(ellipseIn: CGRect(x: o.x + 10 + Double(i) * 14, y: o.y - 10, width: 8, height: 8)), with: .color(Color(red: 0.55, green: 0.8, blue: 1.0))) }
        var prop = Path(); let ang = still ? 0.4 : t * 40
        prop.move(to: CGPoint(x: o.x + 64 + cos(ang) * 14, y: o.y + sin(ang) * 14)); prop.addLine(to: CGPoint(x: o.x + 64 - cos(ang) * 14, y: o.y - sin(ang) * 14))
        c.stroke(prop, with: .color(dark.opacity(0.8)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }
    static func drawBird(arrive: Double, leave: Double, t: Double, still: Bool, in c: inout GraphicsContext) {
        // A small blue bird: flies in from the upper right, perches on the head, flies off the same way when the body wakes.
        let perch = CGPoint(x: 4, y: -62), away = CGPoint(x: 150, y: -190)
        let q = leave > 0 ? leave : 1 - arrive
        let ease = q * q * (3 - 2 * q)
        let o = CGPoint(x: perch.x + (away.x - perch.x) * ease, y: perch.y + (away.y - perch.y) * ease - (q > 0 && q < 1 ? sin(q * .pi) * 30 : 0))
        let moving = q > 0.01 && q < 0.99
        let flap = still ? 0.3 : (moving ? sin(t * 26) : sin(t * 1.5) * 0.15)
        let blue = Color(red: 0.25, green: 0.52, blue: 0.95), light = Color(red: 0.55, green: 0.75, blue: 1.0)
        let bob = still || moving ? 0 : sin(t * 2.5) * 0.8
        var b = c; b.translateBy(x: o.x, y: o.y + bob); b.scaleBy(x: 1.6, y: 1.6)
        var tail = Path(); tail.move(to: CGPoint(x: -8, y: 0)); tail.addLine(to: CGPoint(x: -16, y: -5)); tail.addLine(to: CGPoint(x: -15, y: 3)); tail.closeSubpath()
        b.fill(tail, with: .color(blue))
        b.fill(Path(ellipseIn: CGRect(x: -10, y: -6, width: 20, height: 13)), with: .color(blue))
        b.fill(Path(ellipseIn: CGRect(x: -6, y: -1, width: 12, height: 7)), with: .color(light))
        var wing = Path(); wing.move(to: CGPoint(x: -4, y: -3)); wing.addQuadCurve(to: CGPoint(x: 6, y: -3), control: CGPoint(x: 1, y: -3 - 14 * flap - 2)); wing.closeSubpath()
        b.fill(wing, with: .color(light))
        b.fill(Path(ellipseIn: CGRect(x: 4, y: -13, width: 12, height: 12)), with: .color(blue))
        var beak = Path(); beak.move(to: CGPoint(x: 15, y: -8)); beak.addLine(to: CGPoint(x: 22, y: -6)); beak.addLine(to: CGPoint(x: 15, y: -4)); beak.closeSubpath()
        b.fill(beak, with: .color(Color(red: 1.0, green: 0.6, blue: 0.2)))
        b.fill(Path(ellipseIn: CGRect(x: 10, y: -10, width: 2.6, height: 2.6)), with: .color(ink))
        if !moving && !still && sin(t * 0.7) > 0.95 { b.fill(Path(ellipseIn: CGRect(x: 9.5, y: -9, width: 3.6, height: 1.2)), with: .color(blue)) }
    }
    // MARK: eyes-and-posture set pieces
    static func drawFlyingEyes(left: CGPoint, right: CGPoint, out: Double, t: Double, still: Bool, pixel: Bool, in c: inout GraphicsContext) {
        // Gear 5: the eyeballs shoot out to the side the body is turned away from, leaving a stack of themselves behind.
        let wob = still ? 0 : sin(t * 30) * 2
        for (i, a) in [(0, right), (1, left)] {
            let far = i == 0 ? 78.0 : 108.0, rad = (i == 0 ? 19.0 : 25.0) * (0.4 + 0.6 * out)
            let e = CGPoint(x: a.x - far * out, y: a.y - (i == 0 ? 44 : 64) * out + wob)
            for k in 0..<5 {
                let q = Double(k) / 4, ghost = CGPoint(x: a.x + (e.x - a.x) * q, y: a.y + (e.y - a.y) * q), gr = rad * (0.45 + 0.55 * q)
                c.fill(Path(ellipseIn: CGRect(x: ghost.x - gr, y: ghost.y - gr, width: 2 * gr, height: 2 * gr)), with: .color(.white.opacity(k == 4 ? 1 : 0.25 + 0.15 * q)))
            }
            c.stroke(Path(ellipseIn: CGRect(x: e.x - rad, y: e.y - rad, width: 2 * rad, height: 2 * rad)), with: .color(Color(red: 0.7, green: 0.5, blue: 0.8)), lineWidth: 1.5)
            let p = CGPoint(x: e.x - rad * 0.45, y: e.y + rad * 0.1), pr = rad * 0.32
            c.fill(Path(ellipseIn: CGRect(x: p.x - pr, y: p.y - pr, width: 2 * pr, height: 2 * pr)), with: .color(pixel ? led : Color(red: 0.85, green: 0.3, blue: 0.5)))
            c.fill(Path(ellipseIn: CGRect(x: p.x - pr * 0.45, y: p.y - pr * 0.45, width: pr * 0.9, height: pr * 0.9)), with: .color(ink))
        }
    }
    static func drawSpeedLines(amount: Double, t: Double, still: Bool, in c: inout GraphicsContext) {
        var p = Path()
        for i in 0..<22 {
            let a = Double(i) * .pi * 2 / 22 + (still ? 0 : sin(t * 40 + Double(i)) * 0.03), len = 30 + Double((i * 37) % 40)
            p.move(to: CGPoint(x: cos(a) * 62, y: sin(a) * 62)); p.addLine(to: CGPoint(x: cos(a) * (62 + len), y: sin(a) * (62 + len)))
        }
        c.stroke(p, with: .color(ink.opacity(0.55 * amount)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }
    static func drawAura(t: Double, still: Bool, in c: inout GraphicsContext) {
        for (i, r) in [58.0, 72.0].enumerated() {
            let ph = still ? 0.5 : 0.5 + 0.5 * sin(t * 2 + Double(i) * 1.5), rr = r + ph * 5
            c.stroke(Path(ellipseIn: CGRect(x: -rr, y: -rr, width: 2 * rr, height: 2 * rr)), with: .color(led.opacity(0.18 + 0.15 * ph)), lineWidth: 2)
        }
    }
    static func drawGhost(amount: Double, t: Double, still: Bool, in c: inout GraphicsContext) {
        var g = c
        g.translateBy(x: -74 + (still ? 0 : sin(t * 2.2) * 5), y: -26 - 30 * amount + (still ? 0 : sin(t * 3) * 4))
        g.scaleBy(x: 0.5 + 0.5 * amount, y: 0.5 + 0.5 * amount)
        var body = Path()
        body.move(to: CGPoint(x: -22, y: 0)); body.addArc(center: CGPoint(x: 0, y: 0), radius: 22, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        body.addLine(to: CGPoint(x: 22, y: 26))
        for i in 0..<4 { body.addQuadCurve(to: CGPoint(x: 22 - Double(i + 1) * 11, y: 26), control: CGPoint(x: 22 - Double(i) * 11 - 5.5, y: 26 + (i % 2 == 0 ? 8 : -6))) }
        body.closeSubpath()
        g.fill(body, with: .color(.white.opacity(0.92 * amount)))
        for x in [-8.0, 8.0] { g.fill(Path(ellipseIn: CGRect(x: x - 3, y: -4, width: 6, height: 9)), with: .color(ink.opacity(amount))) }
    }
    static func drawIce(amount: Double, in c: inout GraphicsContext) {
        let r = CGRect(x: -58, y: -58, width: 116, height: 110)
        let cube = Path(roundedRect: r, cornerRadius: 10)
        c.fill(cube, with: .color(Color(red: 0.62, green: 0.85, blue: 1.0).opacity(0.42 * amount)))
        c.stroke(cube, with: .color(.white.opacity(0.75 * amount)), lineWidth: 2)
        var shine = Path()
        shine.move(to: CGPoint(x: -46, y: -30)); shine.addLine(to: CGPoint(x: -30, y: -46)); shine.move(to: CGPoint(x: -46, y: -18)); shine.addLine(to: CGPoint(x: -18, y: -46))
        c.stroke(shine, with: .color(.white.opacity(0.7 * amount)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        if amount < 0.99 {
            var cracks = Path()
            cracks.move(to: CGPoint(x: -40, y: -50)); cracks.addLine(to: CGPoint(x: -10, y: -10)); cracks.addLine(to: CGPoint(x: 20, y: -30)); cracks.addLine(to: CGPoint(x: 50, y: 10))
            cracks.move(to: CGPoint(x: -10, y: -10)); cracks.addLine(to: CGPoint(x: -30, y: 40)); cracks.move(to: CGPoint(x: 20, y: -30)); cracks.addLine(to: CGPoint(x: 10, y: 48))
            c.stroke(cracks, with: .color(.white.opacity(1 - amount)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
    static func drawBox(lowered: Double, eyeLevel: Double, in c: inout GraphicsContext) {
        var b = c
        b.translateBy(x: 0, y: -170 * (1 - lowered))
        let r = CGRect(x: -60, y: -66, width: 120, height: 118), brown = Color(red: 0.78, green: 0.62, blue: 0.42), dark = Color(red: 0.55, green: 0.40, blue: 0.24)
        var box = Path(r); box.addEllipse(in: CGRect(x: -30, y: eyeLevel - 20, width: 60, height: 40))
        b.fill(box, with: .color(brown), style: FillStyle(eoFill: true))
        b.stroke(Path(r), with: .color(dark), lineWidth: 2)
        b.stroke(Path(ellipseIn: CGRect(x: -30, y: eyeLevel - 20, width: 60, height: 40)), with: .color(dark), lineWidth: 2)
        var tape = Path(); tape.move(to: CGPoint(x: 0, y: -66)); tape.addLine(to: CGPoint(x: 0, y: eyeLevel - 22))
        b.stroke(tape, with: .color(Color(red: 0.9, green: 0.78, blue: 0.5)), lineWidth: 8)
        var flaps = Path()
        flaps.move(to: CGPoint(x: -60, y: -66)); flaps.addLine(to: CGPoint(x: -78, y: -92)); flaps.addLine(to: CGPoint(x: -24, y: -92)); flaps.addLine(to: CGPoint(x: -6, y: -66))
        flaps.move(to: CGPoint(x: 60, y: -66)); flaps.addLine(to: CGPoint(x: 78, y: -92)); flaps.addLine(to: CGPoint(x: 24, y: -92)); flaps.addLine(to: CGPoint(x: 6, y: -66))
        b.fill(flaps, with: .color(brown)); b.stroke(flaps, with: .color(dark), lineWidth: 2)
    }
    static func drawShootingStar(_ s: CritterEngine.Snapshot, progress: Double, in ctx: inout GraphicsContext) {
        let a = s.area, u = s.unit
        let from = CGPoint(x: a.minX + 10 * u, y: a.minY - 40 * u), to = CGPoint(x: a.maxX - 20 * u, y: a.minY + 60 * u)
        let p = CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
        let tail = CGPoint(x: p.x - (to.x - from.x) * 0.18, y: p.y - (to.y - from.y) * 0.18)
        var line = Path(); line.move(to: tail); line.addLine(to: p)
        ctx.stroke(line, with: .color(Color(red: 1, green: 0.95, blue: 0.7).opacity(0.5)), style: StrokeStyle(lineWidth: 4 * u, lineCap: .round))
        ctx.stroke(line, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.6 * u, lineCap: .round))
        var star = Path()
        for j in 0..<8 { let ang = Double(j) * .pi / 4 + progress * 4, rr = j % 2 == 0 ? 5 * u : 2 * u; let q = CGPoint(x: p.x + cos(ang) * rr, y: p.y + sin(ang) * rr); j == 0 ? star.move(to: q) : star.addLine(to: q) }
        star.closeSubpath(); ctx.fill(star, with: .color(Color(red: 1, green: 0.95, blue: 0.6)))
    }
    static func drawSmoke(t: Double, still: Bool, in c: inout GraphicsContext) {
        for i in 0..<4 {
            let ph = still ? 0.35 + Double(i) * 0.15 : (t * 0.45 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
            let x = -12 + Double(i) * 8 + sin(ph * 5 + Double(i)) * 7, y = -52 - ph * 70, r = 5 + ph * 11
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(Color(white: 0.5).opacity((1 - ph) * 0.5)))
        }
    }
    static func drawDroplets(age: Double, in c: inout GraphicsContext) {
        for i in 0..<7 {
            let spread = Double(i) - 3, x = 42 + age * 220 * (0.7 + Double(i % 3) * 0.15), y = 6 + spread * 5 + age * age * 160, r = 2.6 - age * 2
            guard r > 0 else { continue }
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(sky.opacity(1 - age * 1.6)))
        }
    }
    static func drawCharred(amount: Double, t: Double, still: Bool, in c: inout GraphicsContext) {
        c.fill(Path(ellipseIn: CGRect(x: -46, y: -46, width: 92, height: 92)), with: .color(Color(red: 0.30, green: 0.24, blue: 0.21).opacity(amount * 0.9)))
        var ash = Path()
        for (x, y, w, h) in [(-26.0, -8.0, 14.0, 7.0), (14.0, 18.0, 16.0, 8.0), (-6.0, 30.0, 10.0, 5.0), (26.0, -18.0, 9.0, 5.0)] { ash.addEllipse(in: CGRect(x: x, y: y, width: w, height: h)) }
        c.fill(ash, with: .color(Color(white: 0.62).opacity(amount * 0.55)))
        // Singed frizz standing up from the top, and a couple of embers that still glow.
        var frizz = Path()
        for (i, a) in [-40.0, -22.0, -6.0, 10.0, 26.0, 42.0].enumerated() {
            let rad = (a - 90) * .pi / 180, len = 9.0 + Double(i % 3) * 4
            frizz.move(to: CGPoint(x: cos(rad) * 44, y: sin(rad) * 44)); frizz.addLine(to: CGPoint(x: cos(rad) * (44 + len) + (i % 2 == 0 ? 3 : -3), y: sin(rad) * (44 + len)))
        }
        c.stroke(frizz, with: .color(Color(red: 0.22, green: 0.17, blue: 0.15).opacity(amount)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        let glow = still ? 0.6 : 0.5 + 0.5 * sin(t * 6)
        for (x, y) in [(-18.0, 22.0), (22.0, -4.0)] { c.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(Color(red: 1, green: 0.45, blue: 0.1).opacity(amount * glow))) }
    }
    static func drawPacifier(at m: CGPoint, amount: Double, t: Double, still: Bool, in c: inout GraphicsContext) {
        let suck = still ? 0 : sin(t * 4) * 1.2
        let shield = Path(ellipseIn: CGRect(x: m.x - 12, y: m.y - 7 + suck, width: 24, height: 14))
        c.fill(shield, with: .color(pacifierYellow.opacity(amount)))
        c.stroke(shield, with: .color(Color(red: 0.75, green: 0.55, blue: 0.05).opacity(amount)), lineWidth: 1.2)
        c.fill(Path(ellipseIn: CGRect(x: m.x - 5, y: m.y - 3 + suck, width: 10, height: 6)), with: .color(Color(red: 0.98, green: 0.90, blue: 0.5).opacity(amount)))
        c.stroke(Path(ellipseIn: CGRect(x: m.x - 4.5, y: m.y + 4 + suck, width: 9, height: 7)), with: .color(Color(red: 0.75, green: 0.55, blue: 0.05).opacity(amount)), lineWidth: 2)
    }
    static func drawSnot(at o: CGPoint, amount: Double, t: Double, still: Bool, in c: inout GraphicsContext) {
        let breathe = still ? 0.5 : 0.5 + 0.5 * sin(t * 2.6), len = 6 + amount * 12
        var drip = Path()
        drip.move(to: CGPoint(x: o.x - 2.2, y: o.y))
        drip.addCurve(to: CGPoint(x: o.x, y: o.y + len), control1: CGPoint(x: o.x - 2.6, y: o.y + len * 0.5), control2: CGPoint(x: o.x - 1.5, y: o.y + len * 0.9))
        drip.addCurve(to: CGPoint(x: o.x + 2.2, y: o.y), control1: CGPoint(x: o.x + 1.5, y: o.y + len * 0.9), control2: CGPoint(x: o.x + 2.6, y: o.y + len * 0.5))
        drip.closeSubpath()
        let green = Color(red: 0.62, green: 0.86, blue: 0.45)
        c.fill(drip, with: .color(green.opacity(0.95 * amount)))
        let r = 3 + breathe * 4 * amount
        c.fill(Path(ellipseIn: CGRect(x: o.x - r, y: o.y + len - r * 0.6, width: 2 * r, height: 2 * r)), with: .color(green.opacity(0.7 * amount)))
        c.fill(Path(ellipseIn: CGRect(x: o.x - r * 0.5, y: o.y + len - r * 0.4, width: r * 0.5, height: r * 0.5)), with: .color(.white.opacity(0.5 * amount)))
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
    static let sceneNames: [(Critter.Scene, String)] = [(.inflate, "พองจนระเบิด แล้วเกิดใหม่"), (.lightning, "ฟ้าผ่า"), (.rainUmbrella, "ฝนตก มีร่ม"), (.rain, "ฝนตก ไม่มีร่ม"), (.balloon, "ลูกโป่งลอย"), (.manhole, "เปิดฝาท่อ โดดลงไป"), (.sneeze, "จาม น้ำมูกไหล"), (.hiccup, "สะอึก"), (.spinJump, "กระโดดหมุนตัว"), (.levitate, "นั่งสมาธิลอย"), (.ghost, "ผีโผล่หลอก"), (.shootingStar, "ดาวตก ขอพร"), (.box, "ซ่อนในกล่อง"), (.melt, "ร้อนจนละลาย"), (.freeze, "แข็งเป็นน้ำแข็ง"), (.trip, "สะดุดล้มตีลังกา"), (.flood, "น้ำท่วม ว่ายขึ้นฝั่ง"), (.plane, "ขึ้นเครื่องบิน โดดลงมา"), (.dance, "เต้นบนฟลอร์"), (.ninja, "ระเบิดควันนินจา หายตัว"), (.eat, "กินข้าว"), (.read, "อ่านหนังสือ"), (.heartEyes, "ตาเป็นหัวใจ")]
    static let gagNames: [(Critter.Scene, String)] = [(.eyePop, "ตาถลนพุ่งออก (Gear 5)"), (.tornado, "หมุนติ้วทอร์นาโด"), (.pancake, "ทั่งตกใส่ แบนแต๊ดแต๋"), (.rubber, "ตัวยางยืด (Nika)"), (.dash, "วิ่งหายวูบ บี๊บบี๊บ")]
    static let weatherNames: [(Critter.Weather, String)] = Critter.Weather.allCases.map { ($0, Critter.weatherNames[$0] ?? $0.rawValue) }
    private let moodNames: [Critter.Mood: String] = [.normal: "ปกติ", .bored: "เบื่อ", .thinking: "คิด", .sleepy: "ง่วง", .asleep: "หลับ", .curious: "สงสัย", .happy: "ดีใจ", .done: "เสร็จ", .shy: "เขิน", .sad: "เศร้า", .wow: "ว้าว", .startled: "ตกใจ", .worried: "กังวล", .dizzy: "เวียนหัว", .peek: "ยืดมอง", .cold: "สั่น", .listening: "ฟัง", .annoyed: "หงุดหงิด", .bye: "บอกลา", .back: "กลับมา", .hungry: "หิว", .sulky: "งอน", .loved: "รัก", .laugh: "หัวเราะ", .full: "อิ่ม", .hot: "ร้อน", .zen: "สงบ", .pant: "หอบ", .groove: "เต้น"]
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
                Toggle("พูด", isOn: $model.critterSpeech).toggleStyle(.switch).controlSize(.mini)
            }
            Text("ฉากพิเศษ (นาน ๆ เกิดเองที · กดดูได้เลย)").font(.caption).foregroundStyle(.secondary)
            FlowButtons(items: CritterPlayground.sceneNames.map { (sc: (Critter.Scene, String)) -> (String, () -> Void) in (sc.1, { engine.perform(scene: sc.0) }) })
            Text("มุกการ์ตูน").font(.caption).foregroundStyle(.secondary)
            FlowButtons(items: CritterPlayground.gagNames.map { (sc: (Critter.Scene, String)) -> (String, () -> Void) in (sc.1, { engine.perform(scene: sc.0) }) })
            Text("อากาศ").font(.caption).foregroundStyle(.secondary)
            FlowButtons(items: CritterPlayground.weatherNames.map { (w: (Critter.Weather, String)) -> (String, () -> Void) in (w.1, { engine.setWeather(w.0 == .clear ? nil : w.0) }) } + [("ฝน+ร่ม", { engine.setWeather(.rain, umbrella: true) })])
            Text("ดูแล (ลากบนตัว = ลูบ · ดับเบิลคลิก = เล่นหัว · คลิกขวา = เมนู)").font(.caption).foregroundStyle(.secondary)
            FlowButtons(items: Critter.Care.Food.allCases.map { (f: Critter.Care.Food) -> (String, () -> Void) in (f.emoji + " " + f.name, { engine.act(.feed(f)) }) } + [("อ่านหนังสือ", { engine.act(.read) }), ("เล่นด้วยกัน", { engine.act(.play) }), ("เล่นหัว", { engine.act(.tease) }), ("ลูบ", { engine.act(.stroke) })])
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
/// The same character inside the settings card: live, at real size, with everything on a menu.
struct CritterPreviewCard: View {
    @ObservedObject var model: Model
    var showsCare = false            // on the friend page: care buttons act on this preview and on the real character
    @StateObject private var engine = CritterEngine()
    @State private var holding = false
    @State private var levelTimer: Timer?
    @State private var lang: Mode = .th
    private let moves: [(Critter.Move, String)] = [(.roll, "กลิ้ง"), (.hop, "เด้ง"), (.dribble, "ดริบเบิล"), (.throwUp, "โยนชนเพดาน"), (.pinball, "พินบอล"), (.wallClimb, "ปีนกำแพง"), (.zigzag, "ซิกแซก"), (.peek, "ยืดมอง"), (.shiver, "ตัวสั่น"), (.sway, "โยกตัว"), (.deep, "กลิ้งลึกเข้าไป")]
    private let moods: [(Critter.Mood, String)] = [(.normal, "ปกติ"), (.happy, "ดีใจ"), (.shy, "เขิน"), (.sad, "เศร้า"), (.wow, "ว้าว"), (.startled, "ตกใจ"), (.worried, "กังวล"), (.dizzy, "เวียนหัว"), (.bored, "เบื่อ"), (.curious, "สงสัย"), (.sleepy, "ง่วง"), (.asleep, "หลับ"), (.cold, "สั่น"), (.annoyed, "หงุดหงิด"), (.peek, "ยืดมอง"), (.bye, "บอกลา"), (.back, "กลับมา"), (.hungry, "หิว"), (.sulky, "งอน"), (.loved, "รัก"), (.laugh, "หัวเราะ"), (.full, "อิ่ม"), (.hot, "ร้อน"), (.zen, "สงบ"), (.pant, "หอบ"), (.groove, "เต้น")]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05))
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: engine.area.width, height: engine.area.height).offset(y: (engine.inset.height - 12) / 2)
                CritterView(engine: engine)
            }.frame(width: engine.panelSize.width, height: engine.panelSize.height)
            HStack(spacing: 6) {
                Menu("ฉากพิเศษ") { ForEach(CritterPlayground.sceneNames, id: \.0) { sc in Button(sc.1) { engine.perform(scene: sc.0) } } }
                Menu("มุกการ์ตูน") { ForEach(CritterPlayground.gagNames, id: \.0) { sc in Button(sc.1) { engine.perform(scene: sc.0) } } }
                Menu("อากาศ") { ForEach(CritterPlayground.weatherNames, id: \.0) { w in Button(w.1) { engine.setWeather(w.0 == .clear ? nil : w.0) } }; Button("ฝนตก มีร่ม") { engine.setWeather(.rain, umbrella: true) } }
                Menu("ท่า") { ForEach(moves, id: \.0) { mv in Button(mv.1) { engine.perform(mv.0) } } }
                Menu("อารมณ์") { ForEach(moods, id: \.0) { m in Button(m.1) { engine.setMood(m.0, hold: 4) } } }
            }.controlSize(.small).fixedSize()
            if showsCare {
                HStack(spacing: 6) {
                    Menu("ให้อาหาร") { ForEach(Critter.Care.Food.allCases, id: \.self) { f in Button(f.emoji + " " + f.name + "  (+\(Int(f.fill)) อิ่ม)") { care(.feed(f)) } } }.fixedSize()
                    Button("อ่านหนังสือ") { care(.read) }
                    Button("เล่นด้วยกัน") { care(.play) }
                    Button("เล่นหัว") { care(.tease) }
                    Button("ลูบ") { care(.stroke) }
                }.controlSize(.small)
            }
            HStack(spacing: 6) {
                Button(holding ? "กำลังฟัง…" : "Fn ค้าง") {}
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in if !holding { startHold() } }.onEnded { _ in endHold() })
                Button("TH/EN") { lang = lang == .th ? .en : .th; engine.cue(.language(lang)) }
                Button("หน้าต่างใหญ่") { model.playgroundAction?() }
            }.controlSize(.small)
        }
        .onAppear { sync(); engine.start() }
        .onDisappear { engine.stop() }
        .onChange(of: model.critterPlayfulness) { _, _ in sync() }
        .onChange(of: model.critterReduceMotion) { _, _ in sync() }
        .onChange(of: model.critterSpeech) { _, _ in sync() }
        .onChange(of: model.critterCartoon) { _, _ in sync() }
        .onChange(of: model.critterEyeTracking) { _, _ in sync() }
        .onChange(of: model.critterWeather) { _, _ in sync() }
        .onChange(of: model.critterEyeStyle) { _, _ in sync() }
    }
    /// The preview reacts with the real bond state, and the corner character gets the same action.
    private func care(_ a: Critter.Care.Action) {
        engine.care = model.care
        engine.act(a)
        model.careAction?(a)
    }
    private func sync() {
        engine.scheduler.playfulness = model.critterPlayfulness
        engine.reduceMotion = model.critterReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        engine.quiet = !model.critterSpeech
        engine.scheduler.cartoon = model.critterCartoon; engine.eyeTracking = model.critterEyeTracking; engine.weatherEnabled = model.critterWeather
        engine.pixelEyes = model.critterEyeStyle == "pixel"
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
        engine.mouseAnywhere = { [weak self] in
            guard let self, self.isVisible else { return nil }
            let m = NSEvent.mouseLocation
            return CGPoint(x: m.x - self.frame.minX, y: self.frame.maxY - m.y)
        }
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
