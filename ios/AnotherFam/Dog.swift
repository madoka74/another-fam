import Foundation
import RealityKit
import simd

/// 강아지 한 마리: 몸(DogSkin) + 움직임(DogAnimator) + 길찾기 이동 + 행동 고르기.
/// 행동은 욕구(배고픔·목마름·잠·배변·놀이·사랑), 현실 시각, 나이 단계, 손·물건·사람 자리로 정함.
/// 규칙(어나더 스페이스 기준서 5와 같음): 이동은 늘 길찾기, 막히면 곧 다른 행동, 가구·벽과 겹치지 않게, 동작이 끊길 때 이어지는 값은 초기화
@MainActor
final class Dog {
    enum Act: Equatable {
        case idle, wander, sleep, eat, drink, potty, greet, come, ask, fetch, toy, tug, petted, held, hand, trick, nurse, perch, watch, zoom, heel, fall
    }

    let entity = Entity()
    let mouth = Entity()                 // 소리 나는 자리 (입)
    private let hit = Entity()           // 바라보고 집는 자리 (갓난 강아지는 작아서 넉넉히 키움)
    private let body = Entity()          // 몸 부딪힘 (장난감이 몸을 뚫고 지나가지 않게 — 몸통을 따라 움직임)
    let anim: DogAnimator
    let skin: DogSkin
    unowned let s: PlaySession

    var pos = SIMD3<Float>(0, 0, 0)
    var yaw: Float = 0
    private var path: [SIMD2<Float>] = []
    private var pathGoal = SIMD2<Float>(9e9, 9e9)
    private var repathAt: Double = 0
    private var stuckN = 0
    private var lastPos = SIMD3<Float>(0, 0, 0)
    private var velo = SIMD3<Float>(0, 0, 0)

    private(set) var act: Act = .idle
    private var actT: Float = 0
    private var phase = 0
    private var until: Double = 0
    private var target: Prop?
    private var spot = SIMD2<Float>(0, 0)
    private var carry: Prop?
    private var trickName = ""
    private var needPoop = false
    private var onPerch: Perch?
    private var vy: Float = 0
    private var nextVoice: Double = 0
    private var nextFidget: Double = 0
    private var nextChat: Double = 0                 // 혼잣소리 (가만있을 때도 소리를 냄)
    private var idleFidgetAt: Double = 0
    private var sniffy = false, prancy = false        // 이번 걸음: 냄새 맡으며 / 신나서 깡총
    private var aboveT: Float = 0                     // 머리 위에 손을 들고 있는 시간
    private var heldToyT: Float = 0
    private var holdStopAt: Double = 0                // 가만있을 때 잠깐 붙든 되풀이 동작을 끝낼 때
    private var greeted = false
    private var lureT: Float = 0
    private var lureKind = ""
    // 손
    private(set) var touching = false
    private(set) var lastTouchAt: Double = -9
    private var touchRegion = ""
    private var touchT: Float = 0, untouchT: Float = 9
    private var heldT: Float = 0, unheldT: Float = 0
    private var offerT: Float = 0
    private var strokes: Float = 0
    var foam: Float = 0                  // 샴푸 거품 (0~1)

    init?(_ session: PlaySession) {
        guard let d = DogData.shared, let sk = DogSkin() else { return nil }
        s = session
        anim = DogAnimator(d)
        skin = sk
        entity.addChild(sk.entity)
        entity.addChild(mouth)
        // 눌러서 메뉴 보기
        hit.position = SIMD3<Float>(0, 0.16, 0.02)
        hit.components.set(CollisionComponent(shapes: [.generateBox(size: SIMD3<Float>(0.2, 0.3, 0.42))]))
        hit.components.set(InputTargetComponent())
        hit.components.set(DogTag())
        entity.addChild(hit)
        body.components.set(CollisionComponent(shapes: [.generateBox(size: SIMD3<Float>(0.13, 0.12, 0.30))]))
        var pb = PhysicsBodyComponent(massProperties: .default, material: PhysicsMaterialResource.generate(friction: 0.8, restitution: 0.1), mode: .kinematic)
        pb.isAffectedByGravity = false
        body.components.set(pb)
        body.components.set(InputTargetComponent())         // 몸을 바라보고 집어도 메뉴 (부딪힘 상자가 누르는 상자를 가리지 않게)
        body.components.set(DogTag())
        entity.addChild(body)
    }

    // MARK: 값
    private var pet: PetState {
        get { s.pet }
        set { s.pet = newValue }
    }
    var age: Double { anim.age }
    var stage: Stage { anim.stage }
    private var g: Float { anim.growth.g }
    private var xz: SIMD2<Float> { SIMD2<Float>(pos.x, pos.z) }
    private var fwd: SIMD3<Float> { SIMD3<Float>(sin(yaw), 0, cos(yaw)) }
    private var baby: Bool { stage == .neonatal || stage == .transitional }
    private var standName: String { baby ? "newborn" : "stand" }
    /// 목소리 높이 (어릴수록 높고 가늘게, 늙으면 조금 낮게)
    private var pitch: Double { Double(Q.interp(Float(age), [0, 30, 90, 365, 3650, 4745], [1.75, 1.5, 1.28, 1.0, 0.95, 0.9])) }

    /// 입·머리 자리 (세계)
    var mouthWorld: SIMD3<Float> {
        let l: SIMD3<Float> = skin.T[J.jaw] + skin.R[J.jaw] * (skin.S[J.jaw] * SIMD3<Float>(0, -0.004, 0.04))
        return entity.convert(position: l, to: nil)
    }
    var headWorld: SIMD3<Float> { entity.convert(position: skin.T[J.head], to: nil) }
    var bodyWorld: SIMD3<Float> { entity.convert(position: (skin.T[J.root] + skin.T[J.chest]) * 0.5, to: nil) }

    func place(at p: SIMD3<Float>, yaw y: Float) {
        pos = p; yaw = y; lastPos = p
        entity.position = p
        entity.orientation = Q.ry(y)
    }

    // MARK: 소리
    func say(_ base: String, gain: Double = -8, head: String? = nil) {
        let sp = pitch
        if let name = SoundBank.shared.play(base, on: mouth, gain: gain, speed: sp) {
            anim.speak(SoundBank.shared.envelope(name), rate: Float(sp))
        }
        if let head { anim.overlay(head) }
    }

    private func fx(_ base: String, gain: Double) {
        SoundBank.shared.play(base, on: mouth, gain: gain, speed: 1)
    }

    private func bark() {
        if baby { say("mewl", gain: -14, head: "whine"); return }
        if age < 56 { say("yip", gain: -8, head: "bark"); return }
        let k = Int.random(in: 0..<3)
        say(k == 0 ? "bark_double" : "bark", gain: -5, head: k == 0 ? "bark2" : "bark")
        if anim.posture == "stand" && !anim.moving && !anim.busy { anim.play("bark_body") }
    }

    /// 혼잣소리: 깨어 있으면 나이·기분·하는 일에 맞춰 이따금 소리를 냄 (0.5.x 는 가만있을 때 거의 조용했음)
    private func chatter() {
        guard s.now > nextChat else { return }
        nextChat = s.now + (baby ? Double.random(in: 6...14) : (stage == .senior ? Double.random(in: 22...45) : Double.random(in: 10...28)))
        guard act != .sleep, act != .eat, act != .drink, act != .nurse, act != .potty, act != .tug, act != .fall else { return }
        let p = pet
        if baby { say("mewl", gain: -17, head: "whine"); return }
        if p.food < 0.3 || (p.water < 0.3 && age >= 21) || p.love < 0.3 { whine(); return }
        switch act {
        case .fetch, .toy, .zoom: if Bool.random() { bark() } else { fx("pant", gain: -22) }
        case .greet, .come: say(age < 56 ? "yip" : "woof", gain: -14, head: "bark")
        case .petted, .held: return
        default:
            let near = simd_distance(pos, s.userPos) < 2.2
            switch Int.random(in: 0..<7) {
            case 0: fx("sniff", gain: -20); anim.overlay("sniff_air")
            case 1: fx("sigh", gain: -20)
            case 2: if p.energy < 0.6 { say("yawn", gain: -18, head: "yawn") } else { fx("sniff", gain: -22) }
            case 3: if near && p.mood > 0.45 { say(age < 56 ? "yip" : "woof", gain: -16, head: "bark") } else { fx("sigh", gain: -22) }
            case 4: if near { say("whimper", gain: -22) }      // 곁에 와 달라는 가는 소리
            case 5: if p.energy > 0.4 && stage != .senior { fx("pant", gain: -26) } else { fx("sigh", gain: -22) }
            default: if anim.posture == "stand" || anim.posture == "sit" { fx("shake", gain: -26); anim.overlay("shake_head") } else { fx("sigh", gain: -22) }
            }
        }
    }

    private func whine() {
        if baby { say("mewl", gain: -14, head: "whine") } else { say("whine", gain: -12, head: "whine") }
    }

    // MARK: 이동
    private func gaitName(_ level: Int) -> String {
        switch stage {
        case .neonatal: return "crawl"
        case .transitional: return age < 17 ? "crawl" : "army"
        case .social: return age < 35 ? "toddle" : (level >= 1 ? (prancy ? "prance" : "bound") : "walk")
        case .senior: return level >= 1 ? "walk" : (sniffy ? "walk_sniff" : "walk_senior")
        default:
            if pet.health < 0.4 { return "walk" }
            if level == 0 && sniffy { return "walk_sniff" }
            if level == 1 && prancy && stage != .mature { return "prance" }
            return level >= 2 ? "run" : (level == 1 ? "trot" : "walk")
        }
    }

    private func stopMoving() {
        if anim.moving { anim.setGait(nil) }
        path.removeAll()
        pathGoal = SIMD2<Float>(9e9, 9e9)
    }

    /// target 으로 감. 반환: 0 가는 중, 1 닿음, -1 못 감
    private func travel(_ dt: Float, to t: SIMD2<Float>, reach: Float, fast: Int) -> Int {
        let d = simd_distance(xz, t)
        if d <= reach { stopMoving(); return 1 }
        if onPerch != nil { return -1 }
        if anim.posture != standName { anim.setPosture(standName); return 0 }
        if !anim.moving && anim.busy { return 0 }
        let nav = s.room.nav
        if path.isEmpty || simd_distance(pathGoal, t) > 0.2 || s.now > repathAt {
            guard nav.ready, let p = nav.path(from: xz, to: t) else {
                stuckN += 1
                stopMoving()
                return stuckN > 2 ? -1 : 0
            }
            path = p; pathGoal = t; repathAt = s.now + 1.5
        }
        guard let wp = path.first else { return 1 }
        let dv = wp - xz
        let dw = simd_length(dv)
        if dw < 0.06 * max(0.5, g) || (path.count == 1 && dw <= reach) {
            path.removeFirst()
            if path.isEmpty { stopMoving(); return simd_distance(xz, t) <= reach + 0.12 ? 1 : -1 }
            return 0
        }
        let want = atan2(dv.x, dv.y)
        let dy = Q.adiff(want, yaw)
        let turn: Float = (baby ? 1.2 : (stage == .senior ? 2.2 : 4.5)) * dt
        yaw += max(-turn, min(turn, dy))
        let level = d > 2.0 ? fast : (d > 0.8 ? min(fast, 1) : 0)
        anim.setGait(gaitName(level))
        let align: Float = abs(dy) < 0.5 ? 1 : max(0, cos(dy)) * 0.5
        let step: Float = min(dw, anim.speed * dt * align)
        let np = xz + SIMD2<Float>(sin(yaw), cos(yaw)) * step
        if nav.open || nav.walkable(np.x, np.y) || !nav.walkable(pos.x, pos.z) {
            pos.x = np.x; pos.z = np.y
            stuckN = 0
        } else {
            path.removeAll()
            stuckN += 1
            if stuckN > 20 { stopMoving(); return -1 }
        }
        return 0
    }

    private func face(_ p: SIMD3<Float>, _ dt: Float, rate: Float = 3) -> Bool {
        let want = atan2(p.x - pos.x, p.z - pos.z)
        let dy = Q.adiff(want, yaw)
        let turn = rate * dt
        yaw += max(-turn, min(turn, dy))
        return abs(dy) < 0.25
    }

    private func supportY(_ x: Float, _ z: Float) -> Float {
        let fy = s.room.floorY ?? pos.y
        if let p = onPerch { return p.center.y }
        // 담요·방석·패드 위에서는 그 높이만큼 올라섬 (0.1.x 는 바닥 높이만 봐서 묻혔음)
        var y = fy
        let w = SIMD3<Float>(x, fy, z)
        for p in s.props where p.kind == .fixed {
            if let t = p.top(at: w) { y = max(y, p.pos.y + t) }
        }
        return y
    }

    /// 안겨 있는지 (손이 강아지를 가리지 않게 화면에서 손 보이기를 끔)
    var holding: Bool { act == .held }
    /// 이 물건 위에 있는지 (강아지가 올라가 있는 잠자리는 손으로 옮겨지지 않게)
    func isOn(_ p: Prop) -> Bool { p.top(at: pos) != nil }

    // MARK: 행동 바꾸기
    private func begin(_ a: Act, for dur: Double = 0) {
        if act == .tug || act == .toy || act == .fetch { if a != .toy && a != .fetch && a != .tug { dropCarry() } }
        if act == .eat || act == .drink || act == .nurse { anim.stop() }
        anim.overlay(nil)
        if act == .sleep && a != .sleep { pet.asleep = false }
        act = a
        actT = 0
        phase = 0
        sniffy = a == .wander && Float.random(in: 0...1) < 0.4
        prancy = (a == .come || a == .greet) && pet.mood > 0.6 && Float.random(in: 0...1) < 0.5
        until = dur > 0 ? s.now + dur : 0
        stuckN = 0
        if a != .wander && a != .come && a != .fetch && a != .zoom && a != .heel { stopMoving() }
    }

    private func dropCarry() {
        guard let c = carry else { return }
        carry = nil
        c.inMouth = false
        c.setMode(.dynamic)
        c.setVelocity(fwd * 0.3 + SIMD3<Float>(0, 0.2, 0))
    }

    private func grab(_ p: Prop) {
        carry = p
        p.inMouth = true
        p.heldBy = nil
        p.setMode(.kinematic)
        anim.overlay("carry", hold: true)
        if p.id == "squeak" { fx("squeak", gain: -8) }
    }

    /// 처음 만났을 때·다시 왔을 때
    func arrive() {
        greeted = false
        if PetState.sleepy(hour: s.hour, stage: stage, energy: pet.energy) || pet.asleep { begin(.sleep); phase = 1 }
        else { begin(.idle, for: 0.5) }
    }

    /// 시험용으로 나이를 바꿨을 때: 하던 일을 그만두고 그 나이의 기본 자세에서 다시 시작
    func ageChanged() {
        anim.age = pet.age(Date().timeIntervalSince1970)        // 자세 고르기 전에 새 나이로 (standName 이 나이를 봄)
        dropCarry()
        onPerch = nil
        anim.stop()
        anim.overlay(nil)
        anim.setPosture(standName)
        begin(.idle, for: 1)
    }

    func heard(_ loud: Bool) {
        // 손뼉: 자고 있으면 깸, 깨어 있으면 쳐다보고 옴
        if baby { return }
        if act == .sleep {
            if loud { begin(.idle, for: 1.5); anim.play("wake", then: "down"); pet.asleep = false }
            return
        }
        if act == .eat || act == .potty || act == .held { return }
        anim.overlay("ear_perk")
        if Float.random(in: 0...1) < 0.35 + 0.6 * pet.bond { begin(.come); phase = 0 }
    }

    func thrown(_ p: Prop) {
        // 아직 어린 강아지(3주 전): 쫓아가진 못하고 소리 난 쪽을 봄
        if baby || stage.rawValue < Stage.social.rawValue { if act != .sleep { anim.overlay("ear_perk") }; return }
        guard !baby, act != .sleep, act != .held, act != .potty, stage.rawValue >= Stage.social.rawValue else { return }
        target = p
        begin(.fetch)
        anim.overlay("ear_perk")
        if Float.random(in: 0...1) < 0.7 { bark() }
    }

    // MARK: 손
    private func senseHands(_ dt: Float) {
        var touch = false
        var region = ""
        var fastHit = false
        let headC: SIMD3<Float> = skin.T[J.head] + skin.R[J.head] * SIMD3<Float>(0, 0.02, 0.03)
        let a = skin.T[J.root], b = skin.T[J.chest]
        for h in s.room.hands where h.seen {
            for pt in [h.palm, h.index] {
                let l = entity.convert(position: pt, from: nil)
                let dh = simd_distance(l, headC)
                let ab = b - a
                let tt = min(1, max(0, simd_dot(l - a, ab) / max(1e-6, simd_dot(ab, ab))))
                let c: SIMD3<Float> = a + ab * tt
                let db = simd_distance(l, c)
                if dh < 0.085 {
                    touch = true
                    region = l.y < headC.y - 0.015 ? "chin" : "head"
                } else if db < 0.098 {
                    touch = true
                    if region.isEmpty { region = l.y > c.y + 0.01 ? "back" : "belly" }
                }
            }
            if touch && simd_length(h.vel - velo) > 2.2 { fastHit = true }
        }
        if touch { touchT += dt; untouchT = 0; touchRegion = region } else { untouchT += dt; if untouchT > 0.4 { touchT = 0 } }
        touching = touch
        if touch || act == .held { lastTouchAt = s.now }
        if fastHit && touchT < 0.12 && act != .held && act != .sleep && !baby && pet.bond < 0.6 {
            begin(.idle, for: 2)
            anim.play("startle")
            say("yip", gain: -8)
            pet.love = max(0, pet.love - 0.03)
            return
        }
        // 안기: 두 손바닥이 몸 아래를 받침 (갓난 강아지는 한 손으로도)
        var hold = false
        var mid = SIMD3<Float>(0, 0, 0)
        let hs = s.room.hands
        let bodyC = entity.convert(position: (a + b) * 0.5, to: nil)
        let reachR: Float = 0.10 + 0.16 * g
        if hs[0].seen && hs[1].seen && hs[0].palmN.y > 0.25 && hs[1].palmN.y > 0.25 {
            let m: SIMD3<Float> = (hs[0].palm + hs[1].palm) * 0.5
            let apart = simd_distance(hs[0].palm, hs[1].palm)
            let horiz = simd_distance(SIMD2<Float>(m.x, m.z), SIMD2<Float>(bodyC.x, bodyC.z))
            if apart < 0.34 && horiz < reachR && m.y < bodyC.y + 0.05 && m.y > bodyC.y - 0.22 * g - 0.06 { hold = true; mid = m }
        }
        if !hold && g < 0.5 {
            for h in hs where h.seen && h.palmUp {
                let horiz = simd_distance(SIMD2<Float>(h.palm.x, h.palm.z), SIMD2<Float>(bodyC.x, bodyC.z))
                if horiz < 0.09 && h.palm.y < bodyC.y + 0.03 && h.palm.y > bodyC.y - 0.1 { hold = true; mid = h.palm }
            }
        }
        if hold { heldT += dt; unheldT = 0 } else { unheldT += dt; if unheldT > 0.35 { heldT = 0 } }
        if act == .held {
            if hold {
                let want = SIMD3<Float>(mid.x, mid.y + 0.012 - 0.105 * g * anim.growth.legY, mid.z)
                pos += (want - pos) * min(1, dt * 14)
                _ = face(s.userPos, dt, rate: 2)
            } else if unheldT > 0.35 {
                begin(.fall)
                vy = 0
                anim.setPosture(standName)
            }
        } else if heldT > 0.3 && act != .potty && act != .fall {
            let liftable = g < 0.75 || pet.bond > 0.25
            if liftable {
                onPerch = nil
                begin(.held)
                anim.setPosture("held")
                if act == .sleep { pet.asleep = false }
            }
        }
    }

    // MARK: 매 화면
    func tick(_ dt: Float) {
        guard dt > 0 else { return }
        let now = s.now
        anim.age = pet.age(Date().timeIntervalSince1970)
        actT += dt
        senseHands(dt)
        react(dt)
        step(dt)
        chatter()
        // 높이: 디딘 면에 붙음 (안겼을 때·떨어질 때 빼고)
        if act != .held && act != .fall && act != .perch {
            let sy = supportY(pos.x, pos.z)
            pos.y += (sy - pos.y) * min(1, dt * 12)
        }
        velo = (pos - lastPos) / dt
        lastPos = pos
        entity.position = pos
        entity.orientation = Q.ry(yaw)
        entity.scale = SIMD3<Float>(repeating: g)
        hit.scale = SIMD3<Float>(repeating: max(1, 0.55 / g))
        // 기분에 따른 꼬리·숨
        let p = pet
        anim.asleep = act == .sleep && phase >= 2
        anim.wagBoost = act == .sleep ? 0 : (0.35 + 1.1 * p.mood + (touching ? 0.6 : 0) + (act == .greet ? 0.8 : 0))
        anim.breathRate = (act == .zoom || act == .fetch) ? 1.6 : 0.38
        anim.rate = stage == .social ? 1.1 : (stage == .juvenile ? 1.05 : 1 - 0.22 * Growth.old(Float(age)))
        // 바라볼 곳: 손에 든 것 > 쓰다듬는 손 > 사람 얼굴 > 장난감
        var look: SIMD3<Float>?
        if let t = lookTarget() { look = entity.convert(position: t, from: nil) }
        anim.look = look
        anim.lookOn = (act == .eat || act == .drink || act == .sleep || act == .potty) ? 0 : 1
        var job = anim.tick(dt)
        let lv: SIMD3<Float> = simd_quatf(angle: -yaw, axis: SIMD3<Float>(0, 1, 0)).act(velo)
        job.sway = simd_clamp(lv * (-0.22), SIMD3<Float>(repeating: -0.5), SIMD3<Float>(repeating: 0.5))
        let dist = simd_distance(pos, s.userPos)
        job.shells = dist > 3.5 ? 9 : (dist > 2 ? 12 : SkinK.N)
        if act == .held || act == .fall { job.floorD = -9 }
        skin.update(job)
        let old = Growth.old(Float(age))
        skin.setTone(clean: p.clean, thin: old)
        skin.setEyeAge(old)
        mouth.position = skin.T[J.head] + SIMD3<Float>(0, 0, 0.04)
        let ra = skin.T[J.root], ch = skin.T[J.chest]
        body.position = (ra + ch) * 0.5 + SIMD3<Float>(0, -0.01, 0)
        let ax = ch - ra
        body.orientation = simd_length(ax) > 1e-4 ? simd_quatf(from: SIMD3<Float>(0, 0, 1), to: simd_normalize(ax)) : Q.ry(0)
        // 동작 속 사건 → 소리
        for e in anim.events {
            switch e {
            case "step":
                if g > 0.45 { fx(g < 0.7 ? "stepsoft" : "step", gain: anim.current == "run" ? -24 : -30) }
            case "squeak": if carry?.id == "squeak" || target?.id == "squeak" { fx("squeak", gain: -8) }
            case "whimper": say("whimper", gain: -16)
            case "yawn": say("yawn", gain: -18)
            case "sneeze": say("sneeze", gain: -12)
            default: if SoundBank.shared.has(e) { fx(e, gain: e == "thump" ? -16 : -20) }
            }
        }
        // 물고 있는 것
        if let c = carry {
            c.entity.setPosition(mouthWorld, relativeTo: nil)
            c.entity.setOrientation(Q.ry(yaw + .pi / 2), relativeTo: nil)
        }
        _ = now
    }

    private func lookTarget() -> SIMD3<Float>? {
        if let t = s.props.first(where: { $0.heldBy != nil && ($0.id == "treat" || $0.id == "dental" || $0.kind == .toy || $0.id == "bottle") }),
           simd_distance(t.pos, pos) < 1.6, !baby { return t.pos }
        if touching, let h = s.room.hands.first(where: { $0.seen }) { return h.palm }
        if act == .fetch || act == .toy, let t = target, carry == nil { return t.pos }
        if act == .hand, let h = s.room.hands.first(where: { $0.seen }) { return h.palm }
        if baby { return nil }
        let d = simd_distance(pos, s.userPos)
        if d < 3.2 && (act == .idle || act == .ask || act == .greet || act == .come || act == .trick || act == .petted || act == .held || act == .watch) { return s.userPos }
        return nil
    }

    /// 손·물건에 대한 반응 (하던 일을 끊고 들어옴)
    private func react(_ dt: Float) {
        guard act != .held, act != .fall, act != .potty else { return }
        // 젖병: 젖꼭지가 입 가까이. 자고 있어도 배고프면 깨어 먹음
        // (0.4.0: 갓난 강아지는 늘 자는 상태라 자는 중엔 젖병을 대도 안 먹었음)
        if act != .nurse, age < 60, let b = s.props.first(where: { $0.id == "bottle" && $0.heldBy != nil }),
           simd_distance(b.pos, mouthWorld) < 0.10 {
            if pet.food >= 0.95 { tell("배불러해요") }
            else if pet.bottle > 0.01 || pet.count("formula") > 0 {
                if act == .sleep { pet.asleep = false }
                begin(.nurse)
                return
            } else { tell("분유가 없어요") }
        }
        // 쓰다듬기
        if touching && touchT > 0.25 {
            if act == .sleep {
                // 자는 중: 살살 만지면 계속 자고, 오래 만지면 깸 (갓난 강아지는 꼬물거림)
                if baby { if anim.current != "nb_squirm" && phase >= 2 { anim.hold("nb_squirm") } }
                else if touchT > 3.5 { pet.asleep = false; begin(.petted); anim.play("wake", then: "down") }
                return
            }
            if act != .petted && act != .nurse && act != .trick {
                begin(.petted)
                // 손이 닿자마자 소리로 반김
                if baby { say("mewl", gain: -18) }
                else if pet.bond < 0.1 && Float.random(in: 0...1) < 0.5 { anim.overlay("ear_back") }
                else if Bool.random() { fx("sigh", gain: -20) } else { say("whimper", gain: -22) }
            }
        }
        if act == .sleep { return }
        // 손에 든 간식·장난감을 향해
        if !baby && act != .trick && act != .eat && act != .nurse && act != .petted && act != .tug && act != .fetch {
            if let t = s.props.first(where: { $0.heldBy != nil && ($0.id == "treat" || $0.id == "dental") }), simd_distance(t.pos, pos) < 1.8 {
                target = t
                begin(.trick)
            } else if let t = s.props.first(where: { $0.heldBy != nil && ["rope", "blanky", "squeak", "chewbone"].contains($0.id) }),
                      simd_distance(t.pos, pos) < 1.2, pet.energy > 0.2, t.pos.y - pos.y < 0.5, stage.rawValue >= Stage.social.rawValue {
                // 손에 든 인형·장난감을 입 가까이 → 물고 당기기 (0.5.x 는 줄만 했음)
                target = t
                begin(.tug)
            } else if let t = s.props.first(where: { $0.heldBy != nil && $0.kind == .toy }), simd_distance(t.pos, pos) < 2.2,
                      act == .idle || act == .wander || act == .watch || act == .come, stage.rawValue >= Stage.social.rawValue {
                // 손에 든 공 등: 던져 주길 기다리며 엎드려 엉덩이 들기·짖기
                heldToyT += dt
                if heldToyT > 0.6 { heldToyT = 0; target = t; begin(.ask, for: 8); phase = 10 }
            } else { heldToyT = 0 }
        }
        // 머리 위에 손을 들고 가만히: 올려다보며 앉음 (유대가 깊은 큰 강아지는 두 발 들고 조름)
        if !baby && (act == .idle || act == .wander || act == .ask) && !touching {
            var above = false
            let hc = headWorld
            for h in s.room.hands where h.seen && simd_length(h.vel) < 0.2 {
                let dy = h.palm.y - hc.y
                if dy > 0.08 && dy < 0.5 && simd_distance(SIMD2<Float>(h.palm.x, h.palm.z), SIMD2<Float>(hc.x, hc.z)) < 0.3 { above = true }
            }
            aboveT = above ? aboveT + dt : 0
            if aboveT > 0.8 {
                aboveT = -6
                begin(.ask, for: 5)
                if stage.rawValue >= Stage.juvenile.rawValue && pet.bond > 0.5 && stage != .senior { anim.setPosture("sit"); anim.hold("beg_paws") }
                else { anim.setPosture("sit"); anim.overlay("tilt_lr") }
                if Float.random(in: 0...1) < 0.5 { say(age < 56 ? "yip" : "woof", gain: -16, head: "bark") }
            }
        }
        // 내민 손: 낮게 가만히 내민 빈 손에 다가와 냄새 맡고 핥음
        if !baby && (act == .idle || act == .wander || act == .watch) {
            var offered = false
            for h in s.room.hands where h.seen {
                let low = h.palm.y - pos.y < 0.45 * max(0.6, g) + 0.2
                if low && simd_length(h.vel) < 0.15 && simd_distance(h.palm, pos) < 1.3 && !h.fist { offered = true }
            }
            offerT = offered ? offerT + dt : 0
            if offerT > 1.0 { offerT = 0; begin(.hand) }
        }
    }

    private var tellAt: Double = 0
    /// 짧은 알림 (같은 말이 계속 뜨지 않게 6초에 한 번)
    private func tell(_ t: String) {
        guard s.now > tellAt else { return }
        tellAt = s.now + 6
        s.toast(t)
    }

    // MARK: 행동 한 걸음
    private func step(_ dt: Float) {
        let now = s.now
        switch act {
        case .idle:
            if holdStopAt > 0 && now > holdStopAt { holdStopAt = 0; anim.stop() }
            if until > 0 && now < until {
                if until - now > 2.5 && now > idleFidgetAt && !anim.busy { idleFidgetAt = now + Double.random(in: 3...7); fidget() }
                return
            }
            if anim.busy { return }
            think()
        case .wander:
            let r = travel(dt, to: spot, reach: 0.1, fast: 0)
            if r != 0 { begin(.idle, for: Double.random(in: 1.5...5)); fidget() }
        case .sleep: sleepStep(dt)
        case .eat, .drink: mealStep(dt)
        case .potty: pottyStep(dt)
        case .greet: greetStep(dt)
        case .come:
            let u = SIMD2<Float>(s.userPos.x, s.userPos.z)
            let r = travel(dt, to: u, reach: 0.55 + 0.25 * g, fast: 1)
            if r == 1 { begin(.ask, for: 6); anim.setPosture(baby ? "newborn" : "sit") }
            else if r == -1 { begin(.idle, for: 2); whine() }
        case .ask:
            if phase >= 20 {
                // 말로 시킨 재주: 사람을 보며 자세를 잡고, 이어 할 동작(굴러·손)이 있으면 함
                _ = face(s.userPos, dt, rate: 4)
                if let k = pendingTrick, anim.settled {
                    pendingTrick = nil
                    if k == "roll" { anim.play("roll_over", then: "down"); rolledAt = now + 1.6 }
                    if k == "paw" { anim.play(Bool.random() ? "paw_l" : "paw_r", then: "sit"); pawAt = now }
                }
                if now > until { begin(.idle, for: 1) }
                return
            }
            if phase >= 10 {
                // 손에 든 장난감을 보며 던져 달라고 조름
                guard let t = target, t.heldBy != nil else { anim.stop(); begin(.idle, for: 1); return }
                _ = face(t.pos, dt, rate: 4)
                if phase == 10 && anim.settled { phase = 11; anim.setPosture("stand"); anim.hold("bow_wiggle"); bark() }
                if now > nextVoice { nextVoice = now + Double.random(in: 2.5...5); if Bool.random() { bark() } else { say("whine", gain: -16, head: "whine") } }
                if now > until { anim.stop(); begin(.idle, for: 1) }
                return
            }
            _ = face(s.userPos, dt)
            if actT > 1.5 && phase == 0 { phase = 1; if pet.love < 0.4 || pet.food < 0.3 { whine() } else { anim.overlay(Bool.random() ? "tilt_l" : "tilt_r") } }
            if actT > 3.5 && phase == 1 { phase = 2; if !baby && anim.posture == "sit" { anim.play("paw_at", then: "sit") } }
            if now > until { anim.stop(); begin(.idle, for: 1) }
        case .fetch: fetchStep(dt)
        case .toy: toyStep(dt)
        case .tug: tugStep(dt)
        case .petted: pettedStep(dt)
        case .held:
            if phase == 0 && anim.settled {
                phase = 1
                anim.hold(pet.bond > 0.3 || baby ? "held_calm" : "held_wiggle")
                if baby { say("mewl", gain: -18) }
            }
            pet.love = min(1, pet.love + 0.02 * dt)
            pet.bond = min(1, pet.bond + 0.0015 * dt)
            if actT > 2 && now > nextVoice {
                nextVoice = now + Double.random(in: 3...7)
                if baby { say("mewl", gain: -18) }
                else if pet.bond > 0.4 && Bool.random() { anim.overlay("lick"); fx("lick", gain: -20) }
                else if pet.bond < 0.2 { whine() }
                else { Bool.random() ? fx("sigh", gain: -20) : say("whimper", gain: -22) }
            }
        case .fall:
            // 내려놓은 자리 아래 처음 닿는 면(소파·탁자·바닥)에 내려앉음 — 0.5.x 까지는 늘 바닥까지 떨어져 소파 속으로 사라졌음
            let fy = s.room.floorY ?? pos.y
            if phase == 0 || Int(actT * 10) % 3 == 0 {
                phase = 1
                landY = s.surfaceBelow(pos, from: pos.y + 0.06) ?? fy
            }
            vy -= 9.8 * dt
            pos.y += vy * dt
            if pos.y <= landY {
                let hard = vy < -1.6
                pos.y = landY
                fx("thump", gain: hard ? -10 : -20)
                if landY > fy + 0.12 { landUp(landY) } else { begin(.idle, for: 1.5) }
                if hard { anim.play(g < 0.7 ? "plop" : "startle"); say(baby ? "mewl" : "yip", gain: -10); pet.love = max(0, pet.love - 0.05) }
            }
        case .hand: handStep(dt)
        case .trick: trickStep(dt)
        case .nurse: nurseStep(dt)
        case .perch: perchStep(dt)
        case .watch:
            let r = travel(dt, to: spot, reach: 0.25, fast: 0)
            if r == 1 && phase == 0 { phase = 1; anim.play("alert", then: "sit"); until = now + Double.random(in: 8...20) }
            if r == -1 || (phase == 1 && now > until) { begin(.idle, for: 1) }
            if phase == 1 && now > nextVoice { nextVoice = now + Double.random(in: 6...14); if Float.random(in: 0...1) < 0.3 { say("woof", gain: -10, head: "bark") } else { anim.overlay("sniff_air") } }
        case .zoom:
            let r = travel(dt, to: spot, reach: 0.2, fast: 2)
            if r != 0 {
                phase += 1
                if phase > 5 || now > until { begin(.idle, for: 2); anim.overlay("pant", hold: true); until = now + 4; pet.energy = max(0, pet.energy - 0.05) }
                else if let q = s.room.nav.randomSpot(near: xz, rMin: 0.8, rMax: 2.4) { spot = q }
                else { begin(.idle, for: 1) }
            }
        case .heel:
            // 산책: 사람 왼쪽 옆 조금 앞을 따라가고, 멈추면 냄새를 맡음
            guard s.walking else { begin(.idle, for: 1); return }
            let f = s.userFwd, side = SIMD3<Float>(f.z, 0, -f.x)
            let hp: SIMD3<Float> = s.userPos + f * 0.45 + side * 0.4
            let r = travel(dt, to: SIMD2<Float>(hp.x, hp.z), reach: 0.3, fast: 1)
            if r == 1 && !anim.busy && now > nextFidget {
                nextFidget = now + Double.random(in: 4...9)
                anim.play("sniff_ground", then: "stand")
            }
        }
    }

    // MARK: 무엇을 할지
    private func think() {
        var p = pet
        let now = s.now
        let sleepy = PetState.sleepy(hour: s.hour, stage: stage, energy: p.energy)
        if let pc = onPerch {
            // 소파 위에서 다른 일을 하다 돌아옴: 조금 더 쉬다가 내려감
            perchGoal = pc
            begin(.perch)
            phase = 4
            until = now + Double.random(in: 10...40)
            return
        }
        if s.walking && !baby { begin(.heel); return }
        if baby {
            if p.food < 0.35 && now > nextVoice { nextVoice = now + Double.random(in: 4...9); say("mewl", gain: -12, head: "whine"); anim.play("nb_root", then: "newborn"); begin(.idle, for: 3); return }
            if sleepy || p.energy < 0.8 { begin(.sleep); return }
            // 따뜻한 곳(담요·손) 쪽으로 꼬물꼬물
            if let b = s.prop("blanket") ?? s.prop("bed"), simd_distance(b.pos, pos) > 0.15 { spot = SIMD2<Float>(b.pos.x, b.pos.z); begin(.wander); return }
            if stage == .transitional && Bool.random() { anim.play("wobble", then: "newborn") }      // 눈 뜨는 시기: 비틀비틀 일어서 보기
            else { anim.play(Bool.random() ? "nb_squirm" : "nb_root", then: "newborn") }
            begin(.idle, for: 4)
            return
        }
        if !greeted {
            greeted = true
            if simd_distance(pos, s.userPos) < 6 && p.bond > 0.03 { begin(.greet); return }
        }
        if p.potty < 0.22 || (needPoop && p.potty < 0.6) { begin(.potty); return }
        if sleepy && p.food > 0.15 { p.asleep = true; pet = p; begin(.sleep); return }
        if p.food < 0.5, let b = s.prop("bowl_food") {
            if b.fill > 0.05 { target = b; begin(.eat); return }
            if p.food < 0.3 && now > nextVoice { nextVoice = now + 25; target = b; begin(.eat); return }       // 빈 그릇 앞에서 조름
        }
        if p.water < 0.5, let b = s.prop("bowl_water"), b.fill > 0.05, age >= 21 { target = b; begin(.drink); return }
        if (p.food < 0.25 || (p.water < 0.25 && age >= 21) || p.love < 0.3) && simd_distance(pos, s.userPos) > 0.9 { begin(.come); return }
        // 놀이
        let playful: Float = (1 - p.fun) * (stage == .senior ? 0.4 : 1) * (p.energy > 0.25 ? 1 : 0.2)
        if Float.random(in: 0...1) < playful * 0.7 {
            let toys = s.props.filter { $0.kind == .toy && $0.heldBy == nil && simd_distance($0.pos, pos) < 5 && $0.pos.y - (s.room.floorY ?? 0) < 0.25 }
            if let t = toys.randomElement() { target = t; begin(.toy); return }
            if (stage == .juvenile || stage == .adolescent || stage == .social) && Float.random(in: 0...1) < 0.35, let q = s.room.nav.randomSpot(near: xz, rMin: 0.8, rMax: 2.5) {
                spot = q; begin(.zoom); until = now + 9
                if Float.random(in: 0...1) < 0.5 { bark() }
                return
            }
        }
        // 그 밖: 거닐기·구경·소파·쉬기
        let r = Float.random(in: 0...1)
        if r < 0.30, let q = s.room.nav.randomSpot(near: xz, rMin: 0.5, rMax: 2.2) { spot = q; begin(.wander); return }
        if r < 0.38, let w = (Array(s.room.windows.values) + Array(s.room.doors.values)).randomElement(), simd_distance(w, pos) < 6,
           let c = s.room.nav.nearest(w.x, w.z, r: 12) {
            spot = s.room.nav.center(c); begin(.watch); return
        }
        if r < 0.46, stage.rawValue >= Stage.adolescent.rawValue, stage != .senior || p.has("steps"),
           let pc = s.room.perches.values.min(by: { simd_distance($0.center, pos) < simd_distance($1.center, pos) }), simd_distance(pc.center, pos) < 4 {
            onPerch = nil
            perchGoal = pc
            begin(.perch)
            return
        }
        if r < 0.60 && simd_distance(pos, s.userPos) > 1.4 { begin(.come); return }
        begin(.idle, for: Double.random(in: 3...9))
        fidget()
    }
    private var perchGoal: Perch?

    /// 가만있을 때의 작은 행동들 (나이·기분·자세에 맞게)
    private func fidget() {
        guard !baby else { return }
        let p = pet
        let r = Int.random(in: 0..<30)
        let young = stage == .social || stage == .juvenile
        switch r {
        case 0: anim.setPosture("sit")
        case 1: anim.setPosture(stage == .senior ? "rest" : "down")
        case 2: anim.setPosture(p.energy < 0.4 ? "rest" : "down_alert")
        case 3: anim.setPosture(young ? "sploot" : "sit_lazy")
        case 4: if anim.posture == "stand" { anim.play("shake") }
        case 5: if anim.posture == "stand" { anim.play(Bool.random() ? "stretch_front" : "stretch_back") }
        case 6: anim.setPosture("sit"); anim.play(Bool.random() ? "scratch_l" : "scratch_r", then: "sit")
        case 7: anim.overlay("yawn")
        case 8: anim.overlay(Bool.random() ? "look_l" : "look_r")
        case 9: anim.overlay("sniff_air"); fx("sniff", gain: -22)
        case 10: if anim.posture == "stand" { anim.play("sniff_ground", then: "stand") }
        case 11: anim.setPosture("down"); anim.hold("lick_paw"); until = s.now + 6; holdStopAt = s.now + 5.8
        case 12: if young && anim.posture == "stand" { anim.play(Bool.random() ? "spin_l" : "spin_r", then: "stand"); until = s.now + 2.7 }
        case 13: if p.mood > 0.6 && stage != .senior { anim.setPosture("belly"); anim.hold("belly_wriggle"); until = s.now + 4; holdStopAt = s.now + 3.8 }
        case 14: if young && anim.posture == "stand" { anim.play(Bool.random() ? "tumble" : "plop", then: "sit") }
        case 15: if stage == .senior { anim.setPosture("sit"); anim.hold("doze_sit"); until = s.now + 8; holdStopAt = s.now + 7.8 } else { anim.overlay("lick_lips") }
        case 16: anim.overlay("tilt_lr")
        case 17: if anim.posture == "stand" { anim.play("look_back", then: "stand") }
        case 18: anim.overlay("sneeze")
        case 19: if anim.posture == "sit" { anim.play("shake_sit", then: "sit") } else { anim.overlay("shake_head"); fx("shake", gain: -24) }
        case 20: if anim.posture == "sit" || anim.posture == "stand" { anim.setPosture("sit"); anim.hold("hind_paw"); until = s.now + 2.5; holdStopAt = s.now + 2.4; fx("scratch", gain: -22) }
        case 21: if stage != .senior { anim.setPosture("side"); anim.play("side_stretch", then: "side"); until = s.now + 5 }
        case 22: anim.overlay("look_down")
        case 23: if p.energy < 0.5 { anim.overlay("sleepy") } else { anim.overlay("tilt_l") }
        case 24: if stage.rawValue >= Stage.adolescent.rawValue && Float.random(in: 0...1) < 0.25 { anim.overlay("howl"); say("howl", gain: -14) } else { anim.overlay("sniff_air"); fx("sniff", gain: -22) }
        case 25: if anim.posture == "stand" { anim.play("shake") } else { anim.overlay("ear_back") }
        case 26: if young && anim.posture == "stand" { anim.play("pounce", then: "stand"); say("yip", gain: -16) }
        case 27: anim.overlay("nod")
        case 28: if anim.posture == "stand" { anim.play("look_back", then: "stand") } else { anim.overlay("look_l") }
        default: anim.overlay("ear_perk")
        }
    }

    // MARK: 잠
    private func sleepStep(_ dt: Float) {
        let now = s.now
        switch phase {
        case 0:
            // 잠자리로
            if let b = s.prop("bed") ?? s.prop("blanket") {
                let r = travel(dt, to: SIMD2<Float>(b.pos.x, b.pos.z), reach: 0.10, fast: 0)
                if r == 0 { return }
            }
            phase = 1
            if baby { anim.setPosture("newborn") }
            else {
                if !anim.busy && Float.random(in: 0...1) < 0.5 { anim.play(Bool.random() ? "spin_l" : "dig", then: "stand") }
                until = now + 1.6
            }
        case 1:
            if now < until || anim.busy { return }
            let poses = baby ? ["nb_sleep"] : (stage == .senior ? ["sleep_side", "sleep_rest"] : ["sleep_curl", "sleep_side", "sleep_rest", "sleep_belly"])
            let name = poses.randomElement() ?? "sleep_curl"
            let via = name == "sleep_side" ? "side" : (name == "sleep_curl" ? "curl" : (name == "sleep_belly" ? "belly" : "rest"))
            if baby { anim.hold("nb_sleep") } else { anim.setPosture(via); sleepPose = name }
            phase = 2
            until = now + 3
            pet.asleep = true
        case 2:
            if !baby && anim.settled && anim.current != sleepPose && now > until { anim.hold(sleepPose) }
            // 가끔 꿈
            if now > nextFidget {
                nextFidget = now + Double.random(in: 25...70)
                if !baby && sleepPose == "sleep_side" && Float.random(in: 0...1) < 0.5 { anim.hold("dream"); until = now + 6; say("whimper", gain: -22) }
                else if Float.random(in: 0...1) < 0.3 { fx("sigh", gain: -24) }
            }
            // 깰 때: 잘 시간이 지났고 기운이 참 (갓난 강아지는 배고프면)
            let p = pet
            let sleepy = PetState.sleepy(hour: s.hour, stage: stage, energy: p.energy)
            let hungryBaby = baby && p.food < 0.3
            if (!sleepy && p.energy > 0.85 && actT > 20) || hungryBaby {
                pet.asleep = false
                anim.stop()
                if baby { begin(.idle, for: 1) }
                else {
                    anim.setPosture("down")
                    begin(.idle, for: 4)
                    anim.overlay("yawn")
                    nextFidget = 0
                }
            }
        default: break
        }
    }
    private var sleepPose = "sleep_curl"

    // MARK: 밥·물
    private func mealStep(_ dt: Float) {
        guard let b = target else { begin(.idle, for: 1); return }
        let eat = act == .eat
        switch phase {
        case 0:
            let d = b.pos - pos
            let l = max(1e-3, simd_length(SIMD2<Float>(d.x, d.z)))
            let stand: SIMD2<Float> = SIMD2<Float>(b.pos.x, b.pos.z) - SIMD2<Float>(d.x, d.z) / l * (0.075 + 0.11 * g)
            let r = travel(dt, to: stand, reach: 0.06, fast: pet.food < 0.3 ? 1 : 0)
            if r == -1 { begin(.idle, for: 3); return }
            if r == 1 { phase = 1 }
        case 1:
            if !face(b.pos, dt) { return }
            if b.fill <= 0.05 {
                // 빈 그릇: 냄새 맡고, 사람을 보고 낑낑, 그릇을 밀어 봄
                anim.play("nose_push", then: "sit")
                fx("clink", gain: -14)
                phase = 9; until = s.now + 2.2
                return
            }
            anim.hold(eat ? "eat" : "drink")
            phase = 2
        case 2:
            let rate: Float = dt / (eat ? 38 : 16)
            var p = pet
            if eat {
                let take = min(b.fill, rate)
                b.fill -= take
                p.foodBowl = b.fill
                p.food = min(1, p.food + stage.meal * take)
            } else {
                let take = min(b.fill, rate * 0.34)
                b.fill -= take
                p.waterBowl = b.fill
                p.water = min(1, p.water + rate * 0.6)
            }
            let done = b.fill <= 0.01 || (eat ? p.food >= 0.99 : p.water >= 0.99)
            if done {
                if eat { p.meals += 1; p.potty = max(0, p.potty - 0.25); needPoop = true }
                else { p.potty = max(0, p.potty - 0.15) }
            }
            pet = p
            if done {
                anim.stop()
                anim.overlay("lick_lips")
                begin(.idle, for: 2.5)
            }
        default:
            _ = face(s.userPos, dt)
            if s.now > until {
                whine()
                begin(.ask, for: 5)
            }
        }
    }

    // MARK: 배변
    private func pottyStep(_ dt: Float) {
        let now = s.now
        switch phase {
        case 0:
            // 패드를 아는 만큼(배변 훈련) 패드로, 아니면 가까운 구석으로
            let pad = s.prop("pad")
            if let pad, Float.random(in: 0...1) < 0.25 + 0.75 * pet.train || age > 400 {
                spot = SIMD2<Float>(pad.pos.x, pad.pos.z); target = pad
            } else {
                target = nil
                spot = s.room.nav.randomSpot(near: xz, rMin: 0.4, rMax: 1.6) ?? xz
            }
            phase = 1
        case 1:
            let r = travel(dt, to: spot, reach: 0.09, fast: 1)
            if r == 0 { return }
            anim.play("sniff_ground", then: "stand")
            fx("sniff", gain: -22)
            phase = 2; until = now + 1.6
        case 2:
            if now < until { return }
            let poop = needPoop
            let clip = poop ? "poop" : ((pet.male && age > 240) ? "pee_leg" : "pee_squat")
            anim.hold(clip)
            if !poop { fx("pee", gain: -20) }
            phase = 3; until = now + (poop ? 5 : 3.2)
        case 3:
            if now < until { return }
            anim.stop()
            var p = pet
            let poop = needPoop
            let back: SIMD3<Float> = pos - fwd * (0.10 * g)
            if let pad = target, simd_distance(SIMD2<Float>(pad.pos.x, pad.pos.z), xz) < 0.24 {
                p.train = min(1, p.train + 0.06)
                if poop { s.addMess("poop", at: back) }
                else {
                    pad.fill = min(1, pad.fill + 0.34)
                    p.padUses = max(0, p.padUses - 1)
                    if pad.fill >= 0.99 { s.padFull(pad) }
                }
            } else {
                s.addMess(poop ? "poop" : "pee", at: back)
                p.clean = max(0, p.clean - 0.03)
            }
            if poop { needPoop = false; p.potty = max(p.potty, 0.6) } else { p.potty = 1 }
            pet = p
            phase = 4
            if !baby && Float.random(in: 0...1) < 0.5 { anim.play("kick_back", then: "stand"); fx("scratch", gain: -20) }
            until = now + 1.4
        default:
            if now > until { begin(.idle, for: 1) }
        }
    }

    // MARK: 반기기
    private func greetStep(_ dt: Float) {
        let u = SIMD2<Float>(s.userPos.x, s.userPos.z)
        switch phase {
        case 0:
            let r = travel(dt, to: u, reach: 0.5 + 0.2 * g, fast: 2)
            if r == -1 { begin(.idle, for: 1); return }
            if r == 1 { phase = 1; until = s.now + 5; bark() }
        default:
            _ = face(s.userPos, dt, rate: 5)
            if !anim.busy && anim.posture == "stand" {
                if stage == .senior || age < 60 { anim.hold("wiggle") } else { anim.hold(pet.bond > 0.5 ? "greet_jump" : "wiggle") }
            }
            if s.now > until {
                anim.stop()
                pet.love = min(1, pet.love + 0.1)
                begin(.idle, for: 1)
            }
        }
    }

    // MARK: 장난감
    private func fetchStep(_ dt: Float) {
        guard let t = target, s.props.contains(where: { $0 === t }) else { begin(.idle, for: 1); return }
        switch phase {
        case 0:
            if t.heldBy != nil { begin(.idle, for: 1); return }
            let tp = SIMD2<Float>(t.pos.x, t.pos.z)
            let r = travel(dt, to: tp, reach: 0.10 + 0.08 * g, fast: 2)
            if r == -1 || actT > 14 { begin(.idle, for: 2); anim.overlay("confused"); return }
            if r == 1 && simd_length(t.velocity) < 1.2 && t.pos.y - pos.y < 0.3 {
                grab(t)
                pet.fun = min(1, pet.fun + 0.12)
                pet.energy = max(0, pet.energy - 0.02)
                // 유대가 깊을수록 물어 옴, 아니면 물고 달아나 흔듦
                phase = Float.random(in: 0...1) < 0.35 + 0.65 * pet.bond ? 1 : 3
                until = s.now + 4
            }
        case 1:
            let u = SIMD2<Float>(s.userPos.x, s.userPos.z)
            let r = travel(dt, to: u, reach: 0.6 + 0.2 * g, fast: 1)
            if r != 0 {
                dropCarry()
                anim.overlay(nil)
                pet.bond = min(1, pet.bond + 0.004)
                phase = 2; until = s.now + 4
                if anim.posture == "stand" { anim.hold("bow_wiggle") }
            }
        case 2:
            _ = face(s.userPos, dt)
            if s.now > until { anim.stop(); anim.setPosture("stand"); begin(.idle, for: 1) }
        default:
            if anim.posture == "stand" && !anim.busy { anim.hold("shake_toy") }
            if s.now > until { anim.stop(); dropCarry(); anim.overlay(nil); begin(.idle, for: 1) }
        }
    }

    private func toyStep(_ dt: Float) {
        guard let t = target, s.props.contains(where: { $0 === t }), t.heldBy == nil else { begin(.idle, for: 1); return }
        switch phase {
        case 0:
            let r = travel(dt, to: SIMD2<Float>(t.pos.x, t.pos.z), reach: 0.16 + 0.1 * g, fast: 1)
            if r == -1 { begin(.idle, for: 2); return }
            if r == 1 {
                phase = 1
                if stage != .senior && Float.random(in: 0...1) < 0.6 { anim.play("pounce", then: "stand") }
                until = s.now + 0.9
            }
        case 1:
            _ = face(t.pos, dt)
            if s.now < until { return }
            if simd_distance(SIMD2<Float>(t.pos.x, t.pos.z), xz) > 0.3 + 0.1 * g { phase = 0; return }
            let chewy = t.id == "chewbone" || t.id == "blanky"
            if t.id == "blanky" && Float.random(in: 0...1) < 0.55, let bed = s.prop("bed") ?? s.prop("blanket"), simd_distance(bed.pos, t.pos) > 0.25 {
                // 애착 인형: 물고 잠자리로 가서 껴안고 엎드림
                grab(t)
                spot = SIMD2<Float>(bed.pos.x, bed.pos.z)
                phase = 4
                pet.fun = min(1, pet.fun + 0.06)
                return
            }
            if chewy && Float.random(in: 0...1) < 0.6 {
                // 엎드려 씹기·껴안고 핥기
                anim.setPosture("down")
                anim.hold(t.id == "blanky" ? "lick_paw" : "chew")
                phase = 3; until = s.now + Double.random(in: 8...18)
            } else {
                grab(t)
                phase = 2; until = s.now + Double.random(in: 3...6)
                if t.id == "ball" || t.id == "squeak" { anim.hold("shake_toy") }
                else if let q = s.room.nav.randomSpot(near: xz, rMin: 0.6, rMax: 1.8) { spot = q }
            }
            pet.fun = min(1, pet.fun + 0.08)
        case 2:
            if !anim.busy { _ = travel(dt, to: spot, reach: 0.15, fast: 1) }
            pet.fun = min(1, pet.fun + 0.01 * dt)
            if s.now > until { anim.stop(); dropCarry(); anim.overlay(nil); begin(.idle, for: 1.5) }
        case 4:
            let r = travel(dt, to: spot, reach: 0.12, fast: 0)
            if r != 0 {
                dropCarry()
                anim.overlay(nil)
                anim.setPosture(Bool.random() ? "down" : "curl")
                anim.hold("lick_paw")
                fx("sigh", gain: -20)
                phase = 3; until = s.now + Double.random(in: 12...30)
            }
        default:
            pet.fun = min(1, pet.fun + 0.012 * dt)
            if s.now > nextVoice && t.id == "squeak" { nextVoice = s.now + Double.random(in: 1.5...4); anim.overlay("squeak_bite") }
            if s.now > until { anim.stop(); begin(.idle, for: 2) }
        }
    }

    /// 곁에 장난감을 내려놓음: 다가와 냄새 맡고 놀기 (갓난 강아지는 인형 곁으로 꼬물꼬물)
    func noticed(_ p: Prop) {
        guard act != .sleep, act != .held, act != .potty, act != .eat, act != .nurse, simd_distance(p.pos, pos) < 2.5 else { return }
        if baby {
            if p.id == "blanky" && age >= 7 { spot = SIMD2<Float>(p.pos.x, p.pos.z); begin(.wander); say("mewl", gain: -18) }
            return
        }
        guard act == .idle || act == .wander || act == .watch || act == .ask || act == .come else { return }
        anim.overlay("ear_perk")
        target = p
        begin(.toy)
        if Float.random(in: 0...1) < 0.35 { bark() }
    }

    private func tugStep(_ dt: Float) {
        guard let t = target, t.heldBy != nil, simd_distance(t.pos, pos) < 1.6 else {
            anim.stop()
            if phase == 1, let t = target, t.heldBy == nil { grab(t); target = t; act = .toy; phase = 2; until = s.now + 3; anim.hold("shake_toy"); return }
            begin(.idle, for: 1)
            return
        }
        switch phase {
        case 0:
            // 줄 끝 아래로 와서 묾
            let r = travel(dt, to: SIMD2<Float>(t.pos.x, t.pos.z) - SIMD2<Float>(sin(yaw), cos(yaw)) * 0.0, reach: 0.22 * g + 0.06, fast: 1)
            if r == -1 { begin(.idle, for: 1); return }
            if r == 1 && t.pos.y - pos.y < 0.32 * g + 0.12 { phase = 1; anim.hold("tug"); say("growl_play", gain: -14, head: "growl") }
            else if r == 1 && !anim.busy { anim.play("hop", then: "stand") }
        default:
            _ = face(t.pos, dt, rate: 5)
            // 입이 줄을 문 채 뒤로 버팀: 줄이 멀어지면 끌려가고, 가까우면 뒤로 당김
            let d = SIMD2<Float>(t.pos.x - pos.x, t.pos.z - pos.z)
            let l = simd_length(d)
            let want: Float = 0.15 * g + 0.05
            if l > want + 0.03 { let m: SIMD2<Float> = d / l * min(l - want, 1.2 * dt); pos.x += m.x; pos.z += m.y }
            pet.fun = min(1, pet.fun + 0.03 * dt)
            pet.energy = max(0, pet.energy - 0.004 * dt)
            pet.bond = min(1, pet.bond + 0.0006 * dt)
            if s.now > nextVoice { nextVoice = s.now + Double.random(in: 2.5...6); say("growl_play", gain: -14, head: "growl") }
            if t.pos.y - pos.y > 0.5 * g + 0.2 { anim.stop(); begin(.idle, for: 1) }
        }
    }

    // MARK: 쓰다듬기
    private func pettedStep(_ dt: Float) {
        var p = pet
        if baby {
            // 갓난 강아지: 어른 동작(서서 기대기·배 보이기)은 못 함 — 엎드린 채 손 쪽으로 꼬물거리고 가늘게 욺
            if touching {
                p.love = min(1, p.love + 0.035 * dt)
                p.bond = min(1, p.bond + 0.0012 * dt)
                pet = p
                if anim.posture != "newborn" { anim.setPosture("newborn") }
                else if anim.current != "nb_root" && anim.current != "nb_squirm" { anim.hold(Bool.random() ? "nb_root" : "nb_squirm") }
                if s.now > nextVoice { nextVoice = s.now + Double.random(in: 2.5...5); say("mewl", gain: -18, head: "whine") }
            } else if untouchT > 1.3 {
                anim.stop()
                begin(.idle, for: 2)
            }
            return
        }
        if touching {
            let brush = s.props.contains { $0.id == "brush" && $0.heldBy != nil && simd_distance($0.pos, pos) < 0.35 }
            p.love = min(1, p.love + 0.035 * dt)
            p.bond = min(1, p.bond + 0.0012 * dt)
            strokes += dt
            if brush { p.clean = min(1, p.clean + 0.03 * dt); if s.now > nextVoice { nextVoice = s.now + 0.7; fx("brush", gain: -18) } }
            if foam > 0 { foam = max(0, foam - 0.09 * dt); p.clean = min(1, p.clean + 0.12 * dt); if foam == 0 { pet = p; begin(.idle, for: 2); anim.setPosture("stand"); anim.play("shake"); return } }
            // 닿은 곳·자세에 맞는 반응
            let want: String
            switch anim.posture {
            case "belly": want = "belly_rub"
            case "down", "rest", "side", "curl", "sploot", "down_alert": want = "pet_down"
            default:
                if touchRegion == "head" { want = "pet_head" }
                else if touchRegion == "chin" { want = "pet_chin" }
                else if touchRegion == "belly" && p.bond > 0.4 && stage != .senior && strokes > 4 { want = "belly" }
                else { want = strokes > 6 && p.bond > 0.3 ? "lean" : "pet_back" }
            }
            if want == "belly" { strokes = 0; anim.stop(); anim.setPosture("belly") }
            else if anim.settled || (anim.busy && anim.current != want && anim.current.hasPrefix("pet_")) || (anim.current == "lean" && want != "lean") {
                if anim.current != want { anim.hold(want) }
            }
            if s.now > nextVoice && strokes > 1.5 {
                nextVoice = s.now + Double.random(in: 2.5...5.5)
                let r = Float.random(in: 0...1)
                let young = stage == .social || stage == .juvenile
                if (touchRegion == "head" || touchRegion == "chin") && young && r < 0.3 { anim.overlay("nibble"); fx("chew", gain: -26) }      // 어린 강아지는 손가락을 살살 깨묾
                else if (touchRegion == "head" || touchRegion == "chin") && p.bond > 0.3 && r < 0.55 { anim.overlay("lick"); fx("lick", gain: -20) }  // 손을 핥음
                else if r < 0.75 { fx("sigh", gain: -20); anim.overlay("blink_slow") }
                else { say("whimper", gain: -22) }        // 좋아서 내는 가는 소리
            }
        } else if untouchT > 1.3 {
            pet = p
            anim.stop()
            strokes = 0
            begin(.idle, for: 1.5)
            if p.love < 0.6 && !baby { anim.overlay("nuzzle") }
            return
        }
        pet = p
    }

    // MARK: 내민 손
    private func handStep(_ dt: Float) {
        guard let h = s.room.hands.first(where: { $0.seen && simd_distance($0.palm, pos) < 1.8 }) else { begin(.idle, for: 1); return }
        switch phase {
        case 0:
            // 손 바로 앞까지 (코가 손에 닿을 만큼)
            let d = SIMD2<Float>(h.palm.x - pos.x, h.palm.z - pos.z)
            let l = max(1e-3, simd_length(d))
            let stand: SIMD2<Float> = SIMD2<Float>(h.palm.x, h.palm.z) - d / l * (0.16 * g + 0.05)
            let r = travel(dt, to: stand, reach: 0.07, fast: 0)
            if r == -1 || actT > 8 { begin(.idle, for: 1); return }
            if r == 1 { phase = 1; until = s.now + 2; anim.overlay("sniff_hand"); fx("sniff", gain: -20) }
        case 1:
            _ = face(h.palm, dt)
            if s.now > until {
                phase = 2; until = s.now + 3
                if anim.posture == "sit" && pet.bond > 0.35 && stage.rawValue >= Stage.juvenile.rawValue && Float.random(in: 0...1) < 0.4 {
                    anim.play(Bool.random() ? "paw_l" : "paw_r", then: "sit")             // 내민 손에 앞발을 올림
                    pawAt = s.now
                } else if pet.bond > 0.15 { anim.overlay("lick", hold: true); fx("lick", gain: -18) } else { anim.overlay("nuzzle") }
                if Float.random(in: 0...1) < 0.4 { fx("sniff", gain: -20) }
            }
        default:
            _ = face(h.palm, dt)
            pet.love = min(1, pet.love + 0.02 * dt)
            pet.bond = min(1, pet.bond + 0.001 * dt)
            let gone = simd_distance(h.palm, mouthWorld) > 0.3
            if gone && actT < 20 && simd_length(h.vel) < 0.6 && h.palm.y - pos.y < 0.45 * max(0.6, g) + 0.25 && !h.fist {
                phase = 0; anim.overlay(nil)                      // 손을 천천히 옮기면 코로 따라옴
            } else if s.now > until || gone { anim.overlay(nil); begin(.idle, for: 1.5) }
        }
    }

    // MARK: 간식으로 가르치기
    /// 손에 든 간식의 자리로 동작을 끌어냄: 머리 위 = 앉아, 바닥 = 엎드려, 높이 = 두 발로, 옆으로 돌리기 = 굴러. 해내면 간식을 먹고 그 재주가 늚
    private func trickStep(_ dt: Float) {
        guard let t = target, s.props.contains(where: { $0 === t }), t.heldBy != nil else {
            if let t = target, s.props.contains(where: { $0 === t }), t.heldBy == nil, simd_distance(t.pos, pos) < 2.5 { phase = 5 } else { begin(.idle, for: 1); return }
            guard let t2 = target else { return }
            // 떨어뜨린 간식은 가서 먹음
            let r = travel(dt, to: SIMD2<Float>(t2.pos.x, t2.pos.z), reach: 0.12 * g + 0.04, fast: 1)
            if r == 1 { eatTreat(t2, learned: nil) } else if r == -1 { begin(.idle, for: 1) }
            return
        }
        let tp = t.pos
        let d = SIMD2<Float>(tp.x - pos.x, tp.z - pos.z)
        let l = simd_length(d)
        // 간식 앞까지 옴
        if l > 0.42 * g + 0.12 && anim.posture == "stand" {
            let stand: SIMD2<Float> = SIMD2<Float>(tp.x, tp.z) - d / max(1e-3, l) * (0.3 * g + 0.08)
            if travel(dt, to: stand, reach: 0.06, fast: 1) == -1 { begin(.idle, for: 1) }
            lureT = 0
            return
        }
        stopMoving()
        if l > 0.75 { anim.setPosture("stand"); return }
        _ = face(tp, dt, rate: 4)
        let headH: Float = 0.26 * g
        let h = tp.y - pos.y
        var want = ""
        if h < 0.07 && l < 0.4 * g + 0.1 { want = "down" }
        else if h > headH + 0.26 * g && l < 0.22 { want = age > 150 && stage != .senior ? "hind" : "sit" }
        else if h > headH + 0.04 && l < 0.3 * g + 0.08 { want = anim.posture == "sit" && h > headH + 0.16 * g && age > 120 ? "beg" : "sit" }
        // 입에 닿으면 먹음
        if simd_distance(tp, mouthWorld) < 0.045 + 0.02 * g {
            eatTreat(t, learned: lureT > 0.8 ? lureKind : nil)
            return
        }
        // 엎드린 채 간식을 어깨 옆으로 돌리면 굴러 (엎드려를 조금 익힌 뒤)
        if anim.posture == "down" && h < 0.14 && l < 0.4 {
            let lx = simd_dot(d, SIMD2<Float>(cos(yaw), -sin(yaw)))
            if abs(lx) > 0.08 * g + 0.05 {
                if !anim.busy && s.now > rolledAt + 1 && (pet.tricks["down"] ?? 0) > 0.25 { anim.play("roll_over", then: "down"); rolledAt = s.now + 1.6 }
                return
            }
        }
        if want.isEmpty { lureT = 0; return }
        if want != lureKind { lureKind = want; lureT = 0 }
        let skill = pet.tricks[want] ?? 0
        if anim.posture != want && !anim.busy {
            // 처음엔 서툴러서 가끔 딴짓 (짖거나 뛰어오름)
            if Float.random(in: 0...1) < 0.012 * (1 - skill) { anim.play("hop", then: anim.posture); bark() }
            else if actT > 0.6 { anim.setPosture(want) }
        }
        if anim.posture == want && anim.settled { lureT += dt }
    }

    private func eatTreat(_ t: Prop, learned lured: String?) {
        var p = pet
        // 방금 한 재주에 대한 상: 굴러·손(앞발)·말로 시킨 재주·간식으로 이끈 자세 차례로
        var learned = lured
        if s.now - rolledAt < 5 { learned = "roll" }
        else if learned == nil && s.now - pawAt < 8 { learned = "paw" }
        else if learned == nil && s.now - commandAt < 8 && !commandTrick.isEmpty { learned = commandTrick }
        if let k = learned, !k.isEmpty { associate(k, &p) }
        commandAt = -99; pawAt = -99; rolledAt = -99
        p.food = min(1, p.food + 0.04)
        p.fun = min(1, p.fun + 0.05)
        p.bond = min(1, p.bond + 0.006)
        if t.id == "dental" { p.clean = min(1, p.clean + 0.05) }
        pet = p
        s.removeProp(t)
        target = nil
        fx("chomp", gain: -12)
        anim.overlay("chew_head", hold: true)
        begin(.idle, for: 2.5)
        anim.overlay("chew_head", hold: true)
        lureT = 0
    }

    // MARK: 말 알아듣기
    private var heardWords: [(String, Double)] = []
    private var pendingTrick: String?
    private var commandAt: Double = -99, pawAt: Double = -99, rolledAt: Double = -99
    private var commandTrick = ""

    /// 사람이 한 낱말. 이름이면 돌아보고 오고, 배운 말이면 익힌 만큼 그 재주를 함 (모르면 고개만 갸웃)
    func hear(_ w: String) {
        let now = s.now
        heardWords.append((w, now))
        heardWords.removeAll { now - $0.1 > 6 }
        let name = pet.name.lowercased().replacingOccurrences(of: " ", with: "")
        if name.count >= 2 && w.contains(name) {
            if act == .sleep || act == .held || act == .eat || act == .nurse { if act != .sleep { anim.overlay("ear_perk") }; return }
            anim.overlay("ear_perk")
            heard(false)
            return
        }
        guard !baby, stage.rawValue >= Stage.social.rawValue else { return }
        guard act != .sleep, act != .eat, act != .drink, act != .nurse, act != .potty, act != .held, act != .fall, act != .tug, act != .trick, act != .perch else { return }
        guard simd_distance(pos, s.userPos) < 5, let m = pet.words[w], let best = m.max(by: { $0.value < $1.value }), best.value >= 0.2 else { return }
        let chance = min(1, best.value * 1.1) * (0.55 + 0.45 * pet.bond) * (stage == .senior ? 0.85 : 1)
        if Float.random(in: 0...1) < chance { obey(best.key) }
        else { anim.overlay(Bool.random() ? "tilt_l" : "tilt_r") }          // 알아들을 듯 말 듯
    }

    private func obey(_ k: String) {
        begin(.ask, for: 6)
        phase = 20
        commandAt = s.now
        commandTrick = k
        switch k {
        case "sit": anim.setPosture("sit")
        case "down": anim.setPosture("down")
        case "beg", "hind": anim.setPosture(k)
        case "roll": anim.setPosture("down"); pendingTrick = "roll"
        case "paw": anim.setPosture("sit"); pendingTrick = "paw"
        default: break
        }
    }

    /// 재주를 해서 간식을 받음: 그 재주를 더 익히고, 6초 안에 들은 낱말을 그 재주와 짝지음 (다른 재주와의 짝은 조금 약해짐)
    private func associate(_ k: String, _ p: inout PetState) {
        let v = min(1, (p.tricks[k] ?? 0) + 0.12)
        let first = (p.tricks[k] ?? 0) < 1 && v >= 1
        p.tricks[k] = v
        if first { s.toast("'\(Dog.trickTitle(k))'를 익혔어요") }
        let name = p.name.lowercased().replacingOccurrences(of: " ", with: "")
        let ws = Set(heardWords.filter { s.now - $0.1 < 6 }.map { $0.0 }).filter { name.isEmpty || !$0.contains(name) }
        for w in ws {
            var m = p.words[w] ?? [:]
            let before = m[k] ?? 0
            m[k] = min(1, before + 0.2)
            for (o, x) in m where o != k { m[o] = max(0, x - 0.08) }
            p.words[w] = m
            if before < 0.2 && (m[k] ?? 0) >= 0.2 { s.toast("'\(w)' 소리에 귀를 기울여요") }
            if before < 0.8 && (m[k] ?? 0) >= 0.8 { s.toast("'\(w)'를 알아들어요 · \(Dog.trickTitle(k))") }
        }
        // 너무 많아지면 약한 짝부터 버림
        if p.words.count > 80 {
            let keep = p.words.sorted { ($0.value.values.max() ?? 0) > ($1.value.values.max() ?? 0) }.prefix(60)
            p.words = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        heardWords.removeAll()
    }

    nonisolated static func trickTitle(_ k: String) -> String {
        switch k {
        case "sit": return "앉아"
        case "down": return "엎드려"
        case "beg": return "빵야 자세"
        case "hind": return "두 발로 서기"
        case "roll": return "굴러"
        case "paw": return "손"
        default: return k
        }
    }

    // MARK: 젖병
    /// 젖병 한 번 = 분유 1회분(pet.bottle 1). 한 번 탄 분유는 다 먹을 때까지 남아 있어 다시 대면 이어 먹음.
    /// (0.4.0: 젖병이 입에서 조금만 떨어졌다 닿아도 새 분유를 써서 8회분이 금방 없어졌고, 다 먹은 뒤에도 게이지가 다 차지 않았음)
    private func nurseStep(_ dt: Float) {
        guard let b = s.props.first(where: { $0.id == "bottle" && $0.heldBy != nil }), simd_distance(b.pos, mouthWorld) < 0.16 else {
            anim.stop()
            begin(.idle, for: 2)
            return
        }
        var p = pet
        if phase == 0 {
            phase = 1
            if baby { anim.setPosture("newborn"); anim.hold("nb_nurse") } else { anim.overlay("suckle", hold: true) }
        }
        if p.bottle <= 0.001 {
            guard p.use("formula") else { anim.stop(); begin(.idle, for: 2); tell("분유가 없어요"); return }
            p.bottle = 1
        }
        // 1회분을 40초쯤에 먹음. 1회분 = 한 끼(갓난 0.7) — 바닥에서 먹이면 게이지가 70% 참
        let sip = min(p.bottle, dt / 40)
        p.bottle -= sip
        p.food = min(1, p.food + sip * stage.meal)
        p.love = min(1, p.love + 0.01 * dt)
        p.bond = min(1, p.bond + 0.002 * dt)
        let done = p.bottle <= 0.001
        if done { p.bottle = 0; p.meals += 1; p.potty = max(0, p.potty - 0.3) }
        pet = p
        if done || p.food >= 0.99 {
            anim.stop()
            begin(.idle, for: 2)
            fx("sigh", gain: -22)
            if !done { tell("배불러해요") }
        }
    }

    // MARK: 소파
    private func perchStep(_ dt: Float) {
        guard let pc = perchGoal else { begin(.idle, for: 1); return }
        let fy = s.room.floorY ?? pos.y
        switch phase {
        case 0:
            // 면 가장자리 앞 바닥으로
            let c = SIMD2<Float>(pc.center.x, pc.center.z)
            let dir = xz - c
            let l = max(1e-3, simd_length(dir))
            let edge: Float = min(pc.half.x, pc.half.y) + 0.22
            guard let cell = s.room.nav.nearest(c.x + dir.x / l * edge, c.y + dir.y / l * edge, r: 8) else { begin(.idle, for: 1); return }
            perchSpot = s.room.nav.center(cell)
            phase = 1
        case 1:
            let r = travel(dt, to: perchSpot, reach: 0.08, fast: 0)
            if r == -1 { perchGoal = nil; begin(.idle, for: 1); return }
            if r == 1 { phase = 2 }
        case 2:
            if !face(pc.center, dt, rate: 4) { return }
            // 오를 수 있는 높이인지 (어른 50cm, 계단이 있으면 노견도)
            let h = pc.center.y - fy
            if h > 0.52 * g + (pet.has("steps") ? 0.2 : 0) { perchGoal = nil; anim.overlay("look_up"); begin(.idle, for: 2); return }
            anim.play("jump_up", then: "stand")
            fromP = pos
            let c = SIMD3<Float>(pc.center.x, pc.center.y, pc.center.z)
            let v = c - pos
            let hl = max(1e-3, simd_length(SIMD2<Float>(v.x, v.z)))
            let inset: Float = min(hl, 0.30)
            toP = SIMD3<Float>(pos.x + v.x / hl * inset, pc.center.y, pos.z + v.z / hl * inset)
            phase = 3; actT = 0
        case 3:
            let u = min(1, max(0, (actT - 0.3) / 0.4))
            let arc: Float = 0.08 * sin(.pi * u)
            pos = fromP + (toP - fromP) * u
            pos.y = fromP.y + (toP.y - fromP.y) * Q.ss(u) + arc
            if actT > 0.9 { onPerch = pc; phase = 4; fx("thump", gain: -18); anim.setPosture(["rest", "curl", "sit", "sploot"].randomElement() ?? "rest"); until = s.now + Double.random(in: 30...120) }
        case 4:
            if s.now > until || pet.potty < 0.25 || (pet.food < 0.3 && s.prop("bowl_food")?.fill ?? 0 > 0.05) {
                anim.setPosture("stand"); phase = 5
            }
        case 5:
            if !anim.settled { return }
            if pos.y - fy > 0.62 * g + 0.25 + (pet.has("steps") ? 0.15 : 0) || baby {
                // 너무 높음: 내려다보며 낑낑, 안아 내려 주길 기다림
                anim.setPosture(baby ? "newborn" : "sit")
                anim.overlay("look_down")
                whine()
                phase = 4
                until = s.now + Double.random(in: 15...30)
                return
            }
            if !face(SIMD3<Float>(perchSpot.x, pos.y, perchSpot.y), dt, rate: 4) { return }
            anim.play("jump_down", then: "stand")
            fromP = pos
            toP = SIMD3<Float>(perchSpot.x, fy, perchSpot.y)
            onPerch = nil
            phase = 6; actT = 0
        default:
            let u = min(1, max(0, (actT - 0.25) / 0.4))
            pos = fromP + (toP - fromP) * u
            pos.y = fromP.y + (toP.y - fromP.y) * (u * u)
            if actT > 1.0 { fx("thump", gain: -16); perchGoal = nil; begin(.idle, for: 1) }
        }
    }
    private var fromP = SIMD3<Float>(0, 0, 0), toP = SIMD3<Float>(0, 0, 0)
    private var perchSpot = SIMD2<Float>(0, 0)
    private var landY: Float = 0

    /// 소파·탁자 위에 내려놓임: 그 면 위에서 쉬다가, 뛰어내릴 만한 높이면 스스로 내려옴 (너무 높으면 낑낑대며 안아 주길 기다림)
    private func landUp(_ y: Float) {
        let c = SIMD3<Float>(pos.x, y, pos.z)
        var pc = s.room.perches.values.first(where: { p in
            let d = c - p.center
            return abs(simd_dot(d, p.ax)) < p.half.x + 0.06 && abs(simd_dot(d, p.az)) < p.half.y + 0.06 && abs(d.y) < 0.12
        }) ?? Perch(center: c, ax: SIMD3<Float>(1, 0, 0), az: SIMD3<Float>(0, 0, 1), half: SIMD2<Float>(0.15, 0.15))
        pc.center.y = y
        onPerch = pc
        perchGoal = pc
        if let cell = s.room.nav.nearest(pos.x, pos.z, r: 10) { perchSpot = s.room.nav.center(cell) }
        else {
            let u = SIMD2<Float>(s.userPos.x, s.userPos.z) - xz
            perchSpot = xz + (simd_length(u) > 0.01 ? simd_normalize(u) : SIMD2<Float>(0, 1)) * 0.45
        }
        begin(.perch)
        phase = 4
        until = s.now + Double.random(in: 20...80)
        anim.setPosture(baby ? "newborn" : (["sit", "down", "rest"].randomElement() ?? "sit"))
    }
}
