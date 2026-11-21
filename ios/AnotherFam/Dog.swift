import Foundation
import RealityKit
import simd

/// 강아지 한 마리: 몸(DogSkin) + 움직임(DogAnimator) + 길찾기 이동 + 행동 고르기.
/// 행동은 욕구(배고픔·목마름·잠·배변·놀이·사랑), 현실 시각, 나이 단계, 손·물건·사람 자리로 정함.
/// 규칙(어나더 스페이스 기준서 5와 같음): 이동은 늘 길찾기, 막히면 곧 다른 행동, 가구·벽과 겹치지 않게, 동작이 끊길 때 이어지는 값은 초기화
@MainActor
final class Dog {
    enum Act: Equatable {
        case idle, wander, sleep, eat, drink, potty, greet, come, ask, fetch, toy, tug, petted, held, hand, trick, nurse, perch, watch, zoom, heel, fall, social
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
    private var pathShort = false                    // 길이 목표에 못 미쳐 끝남 (목표 자리가 막힘)
    private var goalRef = SIMD2<Float>(9e9, 9e9), bestD: Float = 0, bestAt: Double = 0   // 다가가는지 감시
    private var clipName = "", clipSince: Double = 0                                       // 같은 되풀이 동작 감시
    private var turnSince: Double = 0, travelSeen: Double = 0
    private var mvRef = SIMD2<Float>(0, 0), mvYaw: Float = 0, mvAt: Double = 0
    private var lastDt: Float = 1.0 / 90
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
    // 다른 팸 (0.11.0): 함께 사는 팸끼리 인사·놀기·맞붙기·다툼·모른 척
    enum Social { case sniff, chase, wrestle, quarrel, ignore }
    weak var mate: Dog?
    private(set) var social: Social = .sniff
    private var leadSocial = false
    private var socialRest: Double = 0
    private var socialNext: Double = 0
    private var packWaitUntil: Double = 0
    private let tag: ModelEntity                // 목 이름표

    /// 이 몸이 맡은 팸 (0.11.0 여러 팸)
    let pid: String

    init?(_ session: PlaySession, pid: String) {
        guard let d = DogData.shared, let sk = DogSkin() else { return nil }
        s = session
        self.pid = pid
        anim = DogAnimator(d)
        skin = sk
        tag = NameTag.collar(session.fam.pet(pid)?.name ?? "")
        entity.addChild(sk.entity)
        entity.addChild(mouth)
        entity.addChild(tag)
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
        get { s.idx(pid).map { s.fam.pets[$0] } ?? PetState() }
        set { if let i = s.idx(pid) { s.fam.pets[i] = newValue } }
    }
    /// 공용 살림까지 보이는 내 상태 (보관함 수 등 읽기용)
    private var mine: PetState { s.view(pid) ?? pet }
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

    /// 공간 고정점이 고쳐져 방 전체가 조금 옮겨짐: 강아지·가던 곳도 같이 옮기고 길은 새로 찾음 (0.10.0)
    func shift(_ d: simd_float4x4) {
        func mv(_ p: SIMD3<Float>) -> SIMD3<Float> { let w = d * SIMD4<Float>(p.x, p.y, p.z, 1); return SIMD3<Float>(w.x, w.y, w.z) }
        func mv2(_ p: SIMD2<Float>) -> SIMD2<Float> { let w = mv(SIMD3<Float>(p.x, 0, p.y)); return SIMD2<Float>(w.x, w.z) }
        pos = mv(pos)
        yaw += atan2(d.columns.2.x, d.columns.2.z)
        lastPos = pos
        spot = mv2(spot)
        perchSpot = mv2(perchSpot)
        fromP = mv(fromP); toP = mv(toP)
        if var pc = onPerch { pc.center = mv(pc.center); onPerch = pc }
        if var pc = perchGoal { pc.center = mv(pc.center); perchGoal = pc }
        path.removeAll()
        pathGoal = SIMD2<Float>(9e9, 9e9)
        entity.position = pos
        entity.orientation = Q.ry(yaw)
    }

    /// 사람이 사료·물을 붓는 중: 배가 고프면(또는 먹보면) 그릇 앞으로 와서 기다렸다 먹음
    func foodComing(_ b: Prop) {
        let eat = b.base == "bowl_food"
        guard !baby, act != .eat, act != .drink, act != .held, act != .fall, act != .potty, act != .nurse else { return }
        if act == .sleep && (eat ? pet.food > 0.4 : pet.water > 0.4) { return }
        guard eat ? pet.food < 0.9 : pet.water < 0.8, simd_distance(b.pos, pos) < 4 else { return }
        if act == .sleep { pet.asleep = false; anim.stop() }
        target = b
        begin(eat ? .eat : .drink)
        anim.overlay("ear_perk")
    }

    // MARK: 소리
    /// 목소리: 나이에 맞게 녹음한 소리를 고름 (아기 강아지 '_pup', 노견 '_old' 가 있으면 그것) — 0.9.0 부터 일레븐랩스로 만든 실제 같은 소리.
    /// 높이를 억지로 바꾸지 않고 ±4% 만 흔들어 같은 소리도 매번 조금씩 다르게
    func say(_ base: String, gain: Double = -8, head: String? = nil) {
        let bank = SoundBank.shared
        var name = base
        if age < 90, bank.has(base + "_pup") { name = base + "_pup" }
        else if stage == .senior, bank.has(base + "_old") { name = base + "_old" }
        let young = base == "yip" || base == "mewl" || name.hasSuffix("_pup")
        let sp = !young && age < 90 ? min(1.12, pitch) * Double.random(in: 0.97...1.03) : Double.random(in: 0.96...1.04)
        if let n = bank.play(name, on: mouth, gain: gain, speed: sp) {
            anim.speak(bank.envelope(n), rate: Float(sp))
        }
        if let head { anim.overlay(head) }
    }

    private func fx(_ base: String, gain: Double) {
        // 킁킁은 어디서 불러도 4초에 한 번까지 (여러 곳에서 겹쳐 울려 잡음처럼 들렸음)
        if base == "sniff" { guard s.now > fxGap["sniffAny", default: 0] else { return }; fxGap["sniffAny"] = s.now + 4 }
        let bank = SoundBank.shared
        let name = stage == .senior && bank.has(base + "_old") ? base + "_old" : base
        bank.play(name, on: mouth, gain: gain, speed: Double.random(in: 0.97...1.03))
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
            // 혼잣소리는 '강아지 목소리' 위주로 (0.10.9): 0.10.8 까지 킁킁·숨·머리 털기 같은 효과음이 절반 넘게 차지해
            // 무슨 소리인지 알 수 없었음. 곁에 있으면 반가운 짧은 소리·관심 끄는 가는 소리, 졸리면 하품, 누워 있으면 한숨
            let near = simd_distance(pos, s.userPos) < 2.2
            let lying = anim.posture == "down" || anim.posture == "rest" || anim.posture == "side" || anim.posture == "curl"
            let r = Float.random(in: 0...1)
            if near && p.mood > 0.45 && r < 0.4 { say(age < 56 ? "yip" : "woof", gain: -16, head: "bark") }
            else if near && r < 0.7 { say(p.love < 0.5 ? "whine" : "whimper", gain: -20, head: p.love < 0.5 ? "whine" : nil) }
            else if p.energy < 0.5 && !lying { say("yawn", gain: -18, head: "yawn") }
            else if lying { fx("sigh", gain: -20) }
            else if r < 0.85 { say(age < 56 ? "yip" : "woof", gain: -18, head: "bark") }
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
    private func travel(_ dt: Float, to t0: SIMD2<Float>, reach: Float, fast: Int) -> Int {
        // 목표가 내 몸 안이면(손에 든 간식·줄·내민 손 등) 몸 바깥 가장 가까운 곳으로 (0.10.9)
        let t = outsidePack(outsideUser(t0))
        let d = simd_distance(xz, t)
        if d <= reach { stopMoving(); return 1 }
        if s.now < packWaitUntil { if anim.moving { anim.setGait(nil) }; return 0 }      // 다른 팸에게 길을 비켜 주는 중
        if onPerch != nil { return -1 }
        if anim.posture != standName { anim.setPosture(standName); return 0 }
        if !anim.moving && anim.busy { return 0 }
        let nav = s.room.nav
        // 다가가지 못하는 채 4초: 포기 (0.10.3 까지: 가구 가장자리에서 길 점을 맴돌거나 막힌 걸음을 되풀이하며
        // 제자리에서 빙글빙글 돌았고, 손뼉 등으로 할 일이 바뀌어야 멈췄음)
        if s.now - travelSeen > 0.5 { bestD = d; bestAt = s.now }   // 동작을 기다리느라 쉰 시간은 세지 않음
        travelSeen = s.now
        if simd_distance(goalRef, t) > 0.2 { goalRef = t; bestD = d; bestAt = s.now }
        if d < bestD - 0.08 { bestD = d; bestAt = s.now }
        if s.now - bestAt > 4 { bestAt = s.now; bestD = d; stopMoving(); stuckN = 0; return -1 }
        if path.isEmpty || simd_distance(pathGoal, t) > 0.2 || s.now > repathAt {
            // 다른 팸 몸은 길찾기에서 비켜 감 (지금 붙어 있는 팸은 빼고 — 시작 자리가 막혀 길을 못 찾지 않게)
            let saved = nav.extra
            for o in others where !(act == .social && mate === o) {
                let r = 0.17 * o.size + 0.12 * g
                if simd_distance(xz, o.xz) > r + 0.03 { nav.extra.append((c: o.xz, r: r)) }
            }
            let found = nav.ready ? nav.path(from: xz, to: t) : nil
            nav.extra = saved
            guard let p = found else {
                stuckN += 1
                stopMoving()
                return stuckN > 2 ? -1 : 0
            }
            path = p; pathGoal = t; repathAt = s.now + 1.5
            pathShort = (p.last.map { simd_distance($0, t) } ?? 0) > reach + 0.05
        }
        // 이미 지나친 길 점은 건너뜀 (다음 점 쪽으로 넘어섰으면 되돌아가 맴돌지 않게)
        if path.count > 1, simd_dot(path[1] - path[0], xz - path[0]) > 0, simd_distance(xz, path[0]) < 0.3 { path.removeFirst() }
        guard let wp = path.first else { return 1 }
        let dv = wp - xz
        let dw = simd_length(dv)
        if dw < 0.06 * max(0.5, g) || (path.count == 1 && dw <= reach) {
            path.removeFirst()
            // 목표 자리가 막혀 있으면(사람 몸·다리 둘레 등) 갈 수 있는 가장 가까운 곳에 닿은 것으로 끝냄 —
            // 0.10.6 까지: 그 자리에서 길을 다시 찾고 또 닿기를 되풀이하며 발만 움직이고 자리는 그대로였음
            if path.isEmpty { stopMoving(); return simd_distance(xz, t) <= reach + 0.12 || (pathShort && simd_distance(xz, t) < 1.4) ? 1 : -1 }
            return 0
        }
        let want = atan2(dv.x, dv.y)
        let dy = Q.adiff(want, yaw)
        let omega: Float = baby ? 1.2 : (stage == .senior ? 2.2 : 4.5)
        let turn: Float = omega * dt
        yaw += max(-turn, min(turn, dy))
        // 가까운 목표·좁은 곳(길 점이 가까움)에선 걷기 — 빠른 걸음으로 조금씩만 움직여 발과 몸이 따로 놀지 않게
        let level = dw < 0.25 && path.count > 1 ? 0 : (d > 2.0 ? fast : (d > 0.8 ? min(fast, 1) : 0))
        anim.setGait(gaitName(level))
        // 크게 틀어져 있으면 먼저 돌고, 가까운 점은 그 거리 안에서 돌 수 있는 빠르기로 (돌기 반경 = 빠르기 ÷ 도는 빠르기)
        // — 0.10.3 까지는 반쯤 돈 채 제 빠르기로 걸어 가까운 길 점 둘레를 계속 맴돌 수 있었음
        let align: Float = abs(dy) < 0.35 ? 1 : (abs(dy) < 0.9 ? max(0, cos(dy)) * 0.45 : 0)
        let v = min(anim.speed, omega * max(dw, 0.05) * 0.9)
        let step: Float = min(dw, v * dt * align)
        let dir = SIMD2<Float>(sin(yaw), cos(yaw))
        let np = xz + dir * step
        if intoPack(np) {
            // 다른 팸 몸으로 들어가는 걸음: 그 자리에 멈춰 잠깐 기다렸다가 비켜 가는 길을 다시 찾음 (0.11.0)
            stopMoving(); path.removeAll()
            packWaitUntil = s.now + Double.random(in: 0.3...0.7)
            repathAt = 0
            return simd_distance(xz, t) < reach + 0.25 ? 1 : 0
        } else if intoUser(np) {
            // 내 몸 안으로 들어가는 걸음은 하지 않음 (바깥에서 멈춤)
            stopMoving(); path.removeAll()
            return simd_distance(xz, t) < reach + 0.35 ? 1 : 0
        } else if nav.open || nav.walkable(np.x, np.y) || !nav.walkable(pos.x, pos.z) {
            pos.x = np.x; pos.z = np.y
            stuckN = 0
        } else if step > 0, nav.walkable(xz.x + dir.x * step, xz.y), abs(dv.x) > 0.01 {
            pos.x += dir.x * step                              // 막힌 쪽은 미끄러지듯 비켜 감 (모서리에 걸리지 않게)
        } else if step > 0, nav.walkable(xz.x, xz.y + dir.y * step), abs(dv.y) > 0.01 {
            pos.z += dir.y * step
        } else if step > 0 {
            // 막힌 걸음: 걸음 동작을 멈추고(제자리 걸음 없이) 길을 다시 찾음
            path.removeAll()
            stopMoving()
            stuckN += 1
            if stuckN > 20 { return -1 }
        }
        return 0
    }

    /// 몸 돌리기 (0.10.0): 서 있으면 발을 디디며 돎(제자리 걸음), 조금 벗어난 것은 고개로만 봄.
    /// 앉거나 엎드려 있으면 몸은 그대로 두고 고개로 보다가, 크게 벗어나면 일어나서 돎
    /// (0.9: 손·사람이 조금만 움직여도 앉은 채·선 채로 몸 전체가 빙글 돌아 통째로 좌우로 미끄러지는 것처럼 보였음)
    private func face(_ p: SIMD3<Float>, _ dt: Float, rate: Float = 3) -> Bool {
        let want = atan2(p.x - pos.x, p.z - pos.z)
        let dy = Q.adiff(want, yaw)
        if act == .held {
            // 안겨 있을 땐 다리를 디딜 일이 없음 — 그냥 몸을 돌림
            yaw += max(-rate * dt, min(rate * dt, dy))
            return abs(dy) < 0.25
        }
        // 이음 동작(일어서는 중)이 끝나야 선 것으로 침 — 그 전에 돌면 다리를 구부린 채 빙글빙글 돌았음 (0.10.7)
        let standing = (anim.posture == standName && !anim.inTransition) || anim.moving
        if !standing {
            if abs(dy) < 1.1 { return abs(dy) < 0.6 }
            if !anim.busy && !baby { anim.setPosture(standName) }
            return false
        }
        if !turning && abs(dy) < 0.45 {
            if turnGait { turnGait = false; if path.isEmpty { anim.setGait(nil) } }
            return true
        }
        turning = abs(dy) > 0.1
        let r = min(rate, baby ? 1.2 : (stage == .senior ? 1.8 : 2.8))
        yaw += max(-r * dt, min(r * dt, dy))
        if turning && !anim.busy && path.isEmpty {
            // 제자리에서 돌 땐 '걷기' 대신 제자리 돌기 걸음(앞발은 도는 쪽, 뒷발은 반대쪽으로 옮겨 디딤) — 0.10.13
            if !anim.moving { anim.setGait(baby || stage.rawValue < Stage.social.rawValue ? gaitName(0) : (dy > 0 ? "pivot_l" : "pivot_r")); turnGait = true }
        } else if turnGait && !turning {
            turnGait = false
            if path.isEmpty { anim.setGait(nil) }
        }
        return abs(dy) < 0.25
    }
    private var turning = false, turnGait = false

    private func supportY(_ x: Float, _ z: Float) -> Float {
        let fy = s.room.floorY ?? pos.y
        if let p = onPerch { return p.center.y }
        // 담요·방석·패드 위에서는 그 높이만큼 올라섬 (0.1.x 는 바닥 높이만 봐서 묻혔음)
        var y = fy
        let w = SIMD3<Float>(x, fy, z)
        for p in s.props where p.kind == .fixed && p.heldBy == nil {
            if let t = p.top(at: w) { y = max(y, p.pos.y + t) }
        }
        return y
    }

    /// 몸이 그릇·계단·똥을 뚫고 서지 않게: 몸통(엉덩이~가슴 선분 + 반폭)이 겹치면 겹친 만큼 바깥으로 밀어냄.
    /// 길찾기는 몸 가운데 한 점만 피해서, 멈춰 선 자리·돌 때·먹는 그릇 옆 다른 그릇·사람을 따라올 때 몸이 그릇을 걸쳤음 (0.10.3)
    private func clearBody() {
        guard act != .held && act != .fall && act != .perch && onPerch == nil else { return }
        let f2 = SIMD2<Float>(fwd.x, fwd.z)
        let a = xz - f2 * (0.13 * g), b = xz + f2 * (0.14 * g)
        let wid: Float = 0.055 * g
        var push = SIMD2<Float>(0, 0)
        for p in s.props where p.heldBy == nil && !p.inMouth {
            // 지금 먹고 마시는 그릇은 입을 그릇 위로 맞추는 동작(mealStep)이 자리를 잡음 — 옆의 다른 그릇은 피함
            if (act == .eat || act == .drink) && p === target { continue }
            let c = SIMD2<Float>(p.pos.x, p.pos.z)
            switch p.base {
            case "bowl_food", "bowl_water", "poop":
                let rr: Float = p.base == "poop" ? 0.035 : 0.085
                let ab = b - a
                let t = max(0, min(1, simd_dot(c - a, ab) / max(1e-6, simd_dot(ab, ab))))
                let q = a + ab * t
                let d = q - c, dl = simd_length(d), need = rr + wid
                if dl < need {
                    let n = dl > 1e-4 ? d / dl : SIMD2<Float>(-f2.y, f2.x)
                    push += n * (need - dl)
                }
            case "steps":
                // 계단: 실제 상자(36×50cm) 밖으로
                for k in 0...2 {
                    let w = k == 0 ? a : (k == 1 ? xz : b)
                    let l = p.entity.convert(position: SIMD3<Float>(w.x, p.pos.y, w.y), from: nil)
                    let hx: Float = 0.18 + wid, hz: Float = 0.25 + wid
                    guard abs(l.x) < hx && abs(l.z) < hz else { continue }
                    let ox = hx - abs(l.x), oz = hz - abs(l.z)
                    let lo = ox < oz ? SIMD3<Float>(l.x < 0 ? -ox : ox, 0, 0) : SIMD3<Float>(0, 0, l.z < 0 ? -oz : oz)
                    let wv = p.entity.convert(direction: lo, to: nil)
                    push += SIMD2<Float>(wv.x, wv.z)
                    break
                }
            default: continue
            }
        }
        // 다른 팸과 몸이 겹쳐 있으면(둘 다 멈춰 있는 동안 자세가 바뀌어 커진 경우 등) 천천히 떼어 놓음 — 맞붙어 노는 짝은 조금 허용
        for o in others where o.act != .held && o.act != .fall {
            let gp = gap(to: o)
            let allow: Float = (act == .social && mate === o && social == .wrestle) ? -0.025 * g : 0
            guard gp < allow else { continue }
            var n = xz - o.xz
            let nl = simd_length(n)
            n = nl > 1e-4 ? n / nl : SIMD2<Float>(-f2.y, f2.x)
            push += n * (allow - gp) * 0.5            // 둘이 반씩
        }
        let pl = simd_length(push)
        if pl > 1e-4 {
            let m = min(pl, 0.35 * lastDt)                 // 조금씩만 (0.10.7 까지 한 화면에 25cm 까지 밀려 미끄러지듯 보였음)
            pos.x += push.x / pl * m
            pos.z += push.y / pl * m
        }
    }

    /// 내 몸이 차지한 바닥 (0.10.9): 서 있으면 발 둘레 17cm, 앉아 있으면 엉덩이 둘레 + 무릎·발.
    /// 반지름에 강아지 몸 반 길이(가슴·엉덩이가 들어오지 않게)를 더함
    private func userZone() -> [(SIMD2<Float>, Float)] {
        guard let fy = s.room.floorY, !s.userPos.x.isNaN else { return [] }
        let u = SIMD2<Float>(s.userPos.x, s.userPos.z), f = SIMD2<Float>(s.userFwd.x, s.userFwd.z)
        let m = 0.15 * g
        if s.userPos.y - fy < 1.25 { return [(u, 0.2 + m), (u + f * 0.25, 0.13 + m), (u + f * 0.42, 0.11 + m)] }
        return [(u, 0.17 + m)]
    }
    /// 이 자리로 옮기면 내 몸에 더 깊이 들어가는지 (지금보다 깊어질 때만 참 — 이미 겹친 강아지가 밖으로 나가는 걸음은 막지 않음)
    private func intoUser(_ q: SIMD2<Float>) -> Bool {
        for (c, r) in userZone() {
            let dn = simd_distance(q, c)
            if dn < r && dn < simd_distance(xz, c) - 1e-4 { return true }
        }
        return false
    }
    /// 목표가 내 몸 안이면 몸 바깥 가장 가까운 곳 (강아지가 있는 쪽으로)
    private func outsideUser(_ t: SIMD2<Float>) -> SIMD2<Float> {
        var q = t
        for _ in 0..<2 {
            for (c, r) in userZone() {
                let d = q - c, dl = simd_length(d)
                if dl < r {
                    let side = dl > 1e-3 ? d / dl : (simd_length(xz - c) > 1e-3 ? simd_normalize(xz - c) : SIMD2<Float>(1, 0))
                    q = c + side * (r + 0.01)
                }
            }
        }
        return q
    }

    /// 내가 선 채로 팸이 있는 자리에 1초 넘게 머물면 팸이 '걸어서' 비켜남 (0.10.8).
    /// 0.10.7 은 내 몸 둘레에 들어온 팸을 걸음 없이 밀어내서, 다가가거나 손을 뻗기만 해도(머리가 앞으로 나가면)
    /// 발도 안 움직이고 스케이트 타듯 미끄러져 멀어졌음 → 밀어내기를 없애고, 손을 뻗는 중·앉아 있을 때·만지는 중엔 그대로 둠
    private func yieldToUser() {
        guard act == .idle || act == .watch || act == .wander, !touching, !baby, onPerch == nil, let fy = s.room.floorY else { return }
        let u = SIMD2<Float>(s.userPos.x, s.userPos.z)
        guard s.userPos.y - fy > 1.3, simd_distance(u, userRef) < 0.1 else { userRef = u; userStillAt = s.now; return }
        guard s.now - userStillAt > 1.0 else { return }
        if s.room.hands.contains(where: { $0.seen && simd_distance($0.palm, bodyWorld) < 0.5 }) { return }
        let d = xz - u, dl = simd_length(d)
        guard dl < 0.2 + 0.1 * g else { return }
        let n = dl > 1e-3 ? d / dl : SIMD2<Float>(-sin(yaw), -cos(yaw))
        spot = u + n * (0.5 + 0.15 * g)
        userStillAt = s.now
        begin(.wander)
    }
    private var userRef = SIMD2<Float>(0, 0), userStillAt: Double = 0

    /// 같은 되풀이 동작이 비현실적으로 길게 이어지지 않게 (0.10.4):
    /// ① 걸음 없이 제자리에서 몸만 도는 걸음(turnGait)이 3초 넘으면 멈춤
    /// ② 놀이·조르기·땅 파기 같은 되풀이 동작이 정한 시간보다 길면 끝내고 다른 일을 고름
    ///    (잠·먹기·마시기·씹기·안기기·쓰다듬기처럼 끝나는 때가 따로 있는 것은 제외)
    private func watchLoops() {
        // 제자리 걸음: 걸음 동작인데 1.2초 동안 걸음 빠르기의 30% 도 못 움직이고 돌지도 않았으면 걸음을 멈춤 (0.10.7)
        if anim.moving && !turnGait {
            if simd_distance(xz, mvRef) > max(0.02, 0.3 * anim.speed * 1.2) || abs(Q.adiff(yaw, mvYaw)) > 0.5 { mvRef = xz; mvYaw = yaw; mvAt = s.now }
            else if s.now - mvAt > 1.2 { stopMoving(); path.removeAll(); mvAt = s.now }
        } else { mvRef = xz; mvYaw = yaw; mvAt = s.now }
        if turnGait && path.isEmpty {
            if turnSince == 0 { turnSince = s.now }
            else if s.now - turnSince > 3 { turnSince = 0; turnGait = false; turning = false; anim.setGait(nil) }
        } else { turnSince = 0 }
        let c = anim.current
        if c != clipName { clipName = c; clipSince = s.now; return }
        let limit: Double
        switch c {
        case "shake_toy", "bow_wiggle", "greet_jump", "dig", "spin_l", "spin_r", "alert", "belly_wriggle": limit = 8
        case "wiggle", "beg_paws", "sniff_ground", "nb_root", "nb_squirm": limit = 12
        case "lick_paw", "tug": limit = 25
        default: return
        }
        guard s.now - clipSince > limit, act != .held, act != .petted else { return }
        clipSince = s.now
        anim.stop()
        if act != .sleep && act != .eat && act != .drink && act != .potty { begin(.idle, for: Double.random(in: 1...3)) }
    }

    /// 삑삑이: 무는 대로 삑삑 (한 번 물 때 1~3번) + 입도 그만큼 깨묾
    private func squeakBurst(_ n: Int) {
        var env: [Float] = []
        for k in 0..<n {
            squeakQ.append(s.now + Double(k) * 0.17 + Double.random(in: 0...0.04))
            env += [0.3, 0.8, 1, 0.9, 0.5, 0.2, 0, 0, 0, 0]
        }
        anim.speak(env, rate: 1)
    }
    private var squeakQ: [Double] = []
    private var fxGap: [String: Double] = [:]          // 같은 효과음 사이 최소 간격
    private var nextSqueak: Double = 0
    private var ballNudges = 0

    /// 사람이 손으로 삑삑이를 쥠: 귀 쫑긋하고 돌아봄, 놀 기분이면 달려옴
    func heardSqueak(_ p: Prop) {
        if baby || stage.rawValue < Stage.social.rawValue { if act != .sleep { anim.overlay("ear_perk") }; return }
        if act == .sleep { if pet.energy > 0.5 && Float.random(in: 0...1) < 0.3 { begin(.idle, for: 1.5); anim.play("wake", then: "down"); pet.asleep = false }; return }
        guard act == .idle || act == .wander || act == .watch || act == .ask || act == .come else { return }
        anim.overlay(Bool.random() ? "tilt_l" : "tilt_r")
        if simd_distance(p.pos, pos) > 1.2 && pet.energy > 0.25 && Float.random(in: 0...1) < 0.5 + 0.4 * pet.bond {
            begin(.come); phase = 0
        }
    }

    /// 안겨 있는지 (손이 강아지를 가리지 않게 화면에서 손 보이기를 끔)
    var holding: Bool { act == .held }
    /// 이 물건 위에 있는지 (강아지가 올라가 있는 잠자리는 손으로 옮겨지지 않게)
    func isOn(_ p: Prop) -> Bool { p.top(at: pos) != nil }

    /// 이 점(세계 좌표)이 강아지 몸(관절들을 감싼 상자 + 털 두께) 가까이인지 — pad 는 세계 m (0.10.15 탭 거르기)
    func nearBody(_ w: SIMD3<Float>, pad: Float) -> Bool {
        guard entity.isEnabled else { return false }
        let l = entity.convert(position: w, from: nil)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for t in skin.T { lo = simd_min(lo, t); hi = simd_max(hi, t) }
        let g = max(0.2, entity.scale.x)
        let m = SIMD3<Float>(repeating: 0.07 + pad / g)          // 털 7cm(모델 크기 1 기준) + 여유
        let a = lo - m, b = hi + m
        return l.x >= a.x && l.y >= a.y && l.z >= a.z && l.x <= b.x && l.y <= b.y && l.z <= b.z
    }

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
        turning = false; turnGait = false
        pickTarget = nil
        if a != .wander && a != .come && a != .fetch && a != .zoom && a != .heel { stopMoving() }
    }

    private func dropCarry(soft: Bool = false) {
        dropAt = 0
        guard let c = carry else { return }
        carry = nil
        c.inMouth = false
        c.setMode(.dynamic)
        c.setVelocity(soft ? fwd * 0.04 + SIMD3<Float>(0, -0.05, 0) : fwd * 0.3 + SIMD3<Float>(0, 0.2, 0))
        anim.overlay(nil)
    }

    // 물기·내려놓기 (0.10.0): 고개를 숙여 입이 물건에 닿는 순간 묾 / 고개를 숙여 바닥 가까이에서 입을 벌려 내려놓음
    // (0.9: 다가가자마자 장난감이 입으로 순간 이동했고, 내려놓을 때는 서 있는 채로 입에서 툭 튀어 나갔음)
    private var pickTarget: Prop?
    private var pickAt: Double = 0
    private var dropAt: Double = 0

    /// 물기 (0.10.13): 먼저 입이 물건 바로 위에 오도록 걸어서 자리를 맞추고(몸이 물건과 겹치지 않게) 고개를 숙여 입을 물건까지
    /// 내린 뒤 물음. 물건은 순간이동 없이 입으로 0.15초에 걸쳐 들어옴.
    /// 0.10.12 까지: 몸 가운데가 10cm 남짓 거리에 오면 고개 숙이는 동작과 함께 물건이 입으로 휙 옮겨 붙었음
    private func pickUp(_ p: Prop) {
        pickTarget = p
        pickStarted = false
        pickAt = s.now + 99
        pickGiveUp = s.now + 4
    }
    private var pickStarted = false, pickByClip = false, pickGiveUp: Double = 0
    private var carryFrom = SIMD3<Float>(0, 0, 0), carryBlend: Float = 1

    /// 물건 앞 자리 잡기 → 고개 숙여 물기. 이 동안은 다른 할 일을 멈춤
    private func pickApproach(_ dt: Float) {
        guard let t = pickTarget, s.props.contains(where: { $0 === t }), t.heldBy == nil, s.now < pickGiveUp else { pickTarget = nil; return }
        let tp = SIMD2<Float>(t.pos.x, t.pos.z)
        var dv = tp - xz
        let dl = simd_length(dv)
        if dl > 1e-3 { dv /= dl } else { dv = SIMD2<Float>(sin(yaw), cos(yaw)) }
        let reach: Float = 0.17 * g                                   // 고개를 숙였을 때 몸 가운데 → 입
        let standAt = tp - dv * reach
        if baby || anim.posture != standName {
            pickStarted = true; pickByClip = false; pickAt = s.now + 0.1; return
        }
        if simd_distance(xz, standAt) > 0.03 {
            if travel(dt, to: standAt, reach: 0.02, fast: 0) == -1 { pickTarget = nil }
            return
        }
        stopMoving()
        if !face(t.pos, dt, rate: 4) { return }
        pickStarted = true; pickByClip = true
        pickAt = s.now + 0.34
        anim.play("pick_up", then: standName)
    }

    private func putDown() {
        guard carry != nil else { return }
        if anim.posture == standName && !anim.moving { anim.play("drop_toy", then: standName); dropAt = s.now + 0.38 }
        else { dropCarry(soft: true) }
    }

    /// 머리의 세계 방향 (물고 있는 것이 고개를 따라 움직이게)
    private var headRotWorld: simd_quatf { entity.orientation(relativeTo: nil) * simd_quatf(skin.R[J.head]) }

    private func grab(_ p: Prop) {
        carry = p
        p.inMouth = true
        p.heldBy = nil
        p.setMode(.kinematic)
        anim.overlay("carry", hold: true)
        if p.base == "squeak" { fx("squeak", gain: -8) }
    }

    /// 처음 만났을 때·다시 왔을 때
    func arrive() {
        greeted = false
        // 사람이 오면(앱을 열면) 낮잠은 깨서 반김. 밤잠·갓난 강아지·아주 지친 때는 계속 잠
        let night = s.hour >= 23 || s.hour < 7
        let sleepy = PetState.sleepy(hour: s.hour, stage: stage, energy: pet.energy) || pet.asleep
        if sleepy && (night || baby || pet.energy < 0.3) { begin(.sleep); phase = 1 }
        else {
            if pet.asleep { pet.asleep = false; anim.setPosture("down"); anim.overlay("yawn") }
            begin(.idle, for: 1.2)
        }
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

    /// 장난감을 쫓을 수 있는 때 (던진 장난감을 맡을 팸 고르기)
    var canPlay: Bool {
        !baby && stage.rawValue >= Stage.social.rawValue && act != .sleep && act != .held && act != .potty && act != .eat
            && act != .drink && act != .nurse && act != .fall && act != .tug && act != .trick
    }
    func playScore(_ p: Prop) -> Float {
        (1.2 - pet.fun) * (0.4 + pet.energy) * (0.6 + pet.bond * 0.6) - simd_distance(p.pos, pos) * 0.12 + (act == .fetch || act == .toy ? -0.3 : 0)
    }

    // MARK: 손
    private func senseHands(_ dt: Float) {
        var touch = false
        var region = ""
        var fastHit = false
        let headC: SIMD3<Float> = skin.T[J.head] + skin.R[J.head] * SIMD3<Float>(0, 0.02, 0.03)
        let a = skin.T[J.root], b = skin.T[J.chest]
        for h in s.room.hands where h.seen {
            for pt in [h.palm, h.index, h.middle, h.thumb] {          // 쓰다듬을 땐 가운뎃손가락·엄지가 먼저 닿기도 함 (0.10.9)
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
                    // 배는 몸 아래로 손이 들어갔을 때만 (0.10.0: 옆구리를 쓰다듬어도 배로 쳐서 매번 배를 보였음)
                    if region.isEmpty { region = l.y > c.y + 0.01 ? "back" : (l.y < c.y - 0.03 ? "belly" : "side") }
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
                var want = SIMD3<Float>(mid.x, mid.y + 0.012 - 0.105 * g * anim.growth.legY, mid.z)
                // 눈에 너무 가까이 오지 않게 (비전프로는 눈앞 아주 가까운 것을 잘라 그려서, 얼굴 앞에 바짝 들면
                // 털·살갗이 잘려 나가고 그보다 안쪽의 눈알·혀만 보였음 — 0.10.0 의 가림 끄기로는 안 고쳐짐)
                let minD: Float = 0.30 + 0.12 * g
                let off = want - s.userPos
                if simd_length(off) < minD { want = s.userPos + simd_normalize(off + SIMD3<Float>(s.userFwd.x, 0, s.userFwd.z) * 1e-3) * minD }
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
        // 맡은 물건은 붙들고 있는 동안 계속 맡음 (다른 팸이 같은 간식·장난감으로 몰려오지 않게)
        if let t = target, act == .trick || act == .tug || act == .fetch || act == .toy || act == .ask { _ = s.claim(t, pid) }
        lastDt = min(0.1, dt)
        let now = s.now
        anim.age = pet.age(Date().timeIntervalSince1970)
        actT += dt
        senseHands(dt)
        react(dt)
        step(dt)
        chatter()
        // 높이: 디딘 면에 붙음 (안겼을 때·떨어질 때 빼고)
        // 앞발·뒷발 아래 높이를 따로 봄: 방석 둘레 쿠션처럼 높이가 다른 곳에선 몸을 기울여 넘어감
        // (0.9: 가운데 한 점 높이만 봐서 쿠션을 몸 반쯤 파묻힌 채 지나가다 끝에서 갑자기 올라섰음)
        // 올라가 있던 면(소파 등) 밖으로 끌려 나오면 떨어짐 — 0.10.2 까지: 소파 위에서 장난감을 문 채 끌려 나와,
        // 높이를 '올라가 있는 면 높이'로만 셈해 소파 밖 공중을 바닥처럼 딛고 섰음
        if let pc = onPerch, act != .held && act != .fall && act != .perch {
            let d = pos - pc.center
            if abs(simd_dot(d, pc.ax)) > pc.half.x + 0.04 || abs(simd_dot(d, pc.az)) > pc.half.y + 0.04 {
                onPerch = nil
                if carry != nil { dropCarry(soft: true) }
                vy = 0
                begin(.fall)
                anim.setPosture(standName)
            }
        }
        clearBody()
        yieldToUser()
        watchLoops()
        var tilt: Float = 0
        if act != .held && act != .fall && act != .perch {
            let L: Float = 0.12 * g
            let fp = pos + fwd * L, bp = pos - fwd * L
            let yf = supportY(fp.x, fp.z), yb = supportY(bp.x, bp.z), yc = supportY(pos.x, pos.z)
            let sy = max(yc, (yf + yb) * 0.5)
            pos.y += (sy - pos.y) * min(1, dt * 10)
            tilt = max(-0.45, min(0.45, atan2(yf - yb, 2 * L)))
        }
        bodyTilt += (tilt - bodyTilt) * min(1, dt * 8)
        velo = (pos - lastPos) / dt
        lastPos = pos
        entity.position = pos
        entity.orientation = Q.ry(yaw) * Q.rx(-bodyTilt)
        if let t = pickTarget, pickStarted, s.now >= pickAt {
            pickTarget = nil
            if s.props.contains(where: { $0 === t }), t.heldBy == nil, simd_distance(t.pos, mouthWorld) < (pickByClip ? 0.08 + 0.06 * g : 0.16 + 0.1 * g) {
                carryFrom = t.pos; carryBlend = 0
                grab(t)
            }
        }
        // 고개 높이 맞추기: 먹고 마실 땐 입을 그릇 속 사료·물 높이까지, 물 땐 물건 높이까지 (동작만으론 큰 강아지 입이 그릇 위 10cm 에 떠 있었음)
        var dipY: Float?
        if (act == .eat || act == .drink) && phase == 2, let b = target { dipY = b.pos.y + b.contentY + 0.006 }
        if let t = pickTarget, pickStarted { dipY = t.pos.y + 0.004 }
        if let y = dipY {
            anim.dip = max(-0.25, min(0.9, anim.dip + (mouthWorld.y - y) * 9 * dt))
        } else { anim.dip *= max(0, 1 - 5 * dt) }
        if dropAt > 0 && s.now >= dropAt { dropCarry(soft: true) }
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
        // 먹고 마실 때는 그릇 속을 내려다봄 (입이 사료·물에 닿게)
        anim.lookOn = (act == .eat || act == .drink) ? (phase == 2 ? 0.8 : 1) : ((act == .sleep || act == .potty) ? 0 : 1)
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
        // 목 이름표: 목 앞 아래(턱 밑 목둘레 털 바깥)에 목을 따라 — 몸 크기(g)대로 저절로 작아지고 커짐
        // 털 길이만큼 바깥에 (아기는 털이 짧아 몸에 가깝게) — 목 굵기(S)도 따름
        let nr = skin.R[J.neck]
        let coat = anim.growth.coatBody
        tag.position = skin.T[J.neck] + nr * (skin.S[J.neck] * SIMD3<Float>(0, -0.032, 0.04 + 0.02 * coat))
        tag.orientation = simd_quatf(nr) * simd_quatf(angle: 0.3, axis: SIMD3<Float>(1, 0, 0))
        let ra = skin.T[J.root], ch = skin.T[J.chest]
        body.position = (ra + ch) * 0.5 + SIMD3<Float>(0, -0.01, 0)
        let ax = ch - ra
        body.orientation = simd_length(ax) > 1e-4 ? simd_quatf(from: SIMD3<Float>(0, 0, 1), to: simd_normalize(ax)) : Q.ry(0)
        // 동작 속 사건 → 소리
        for e in anim.events {
            // 동작에 붙은 소리 (0.10.9): 실제로 귀에 들리는 것만 — 발소리(걸음마다 '틱' 소리)·눕는 '쿵'·귀 펄럭·앞발 톡은
            // 무슨 소리인지 알 수 없는 잡음으로 가장 자주 났음 → 없앰. 핥기·씹기·킁킁은 간격을 둬 덜 잦게
            switch e {
            case "squeak": if carry?.base == "squeak" || target?.base == "squeak" { fx("squeak", gain: -8) }
            case "whimper": say("whimper", gain: -16)
            case "yawn": say("yawn", gain: -18)
            case "sneeze": say("sneeze", gain: -14)
            case "lap", "suck": fx(e, gain: -20)
            case "shake", "scratch": fx(e, gain: -24)
            case "lick": if s.now > fxGap["lick", default: 0] { fxGap["lick"] = s.now + 0.5; fx("lick", gain: -22) }
            case "chew", "chomp": if s.now > fxGap["chew", default: 0] { fxGap["chew"] = s.now + 0.35; fx(e, gain: -22) }
            case "sniff": if s.now > fxGap["sniff", default: 0] { fxGap["sniff"] = s.now + 4; fx("sniff", gain: -26) }
            default: break
            }
        }
        // 삑삑이를 물고 있는 동안(들고 다니기·흔들기·당기기·물어 오기) 씹을 때마다 삑 (0.10.2 까지: 주울 때 한 번만 났음)
        let squeaky = carry?.base == "squeak" || (act == .tug && target?.base == "squeak")
        if squeaky && s.now > nextSqueak {
            let rough = anim.current == "shake_toy" || act == .tug
            nextSqueak = s.now + Double.random(in: rough ? 0.5...1.4 : 1.0...3.0)
            squeakBurst(Int.random(in: 1...(rough ? 3 : 2)))
        }
        // 헐떡이는 입 모양엔 헐떡임 소리 (0.10.9: 입만 벌리고 소리가 없었음)
        if anim.overlayName == "pant" && s.now > fxGap["pant", default: 0] { fxGap["pant"] = s.now + Double.random(in: 1.3...1.8); fx("pant", gain: -24) }
        while let t = squeakQ.first, s.now >= t { squeakQ.removeFirst(); fx("squeak", gain: -8 - Double.random(in: 0...5)) }
        // 물고 있는 것: 입에 물린 채 고개를 따라 기울고 돎 (길쭉한 것은 가로로 묾, 인형은 옆으로 늘어뜨림)
        if let c = carry {
            let hq = headRotWorld
            let hf = hq.act(SIMD3<Float>(0, 0, 1))
            var at = mouthWorld + hf * (c.base == "ball" ? 0.012 : 0.004) - SIMD3<Float>(0, c.base == "blanky" ? 0.03 : 0, 0)
            if carryBlend < 1 { carryBlend = min(1, carryBlend + dt / 0.15); at = carryFrom + (at - carryFrom) * carryBlend }   // 입으로 들어오는 0.15초
            c.entity.setPosition(at, relativeTo: nil)
            c.entity.setOrientation(c.base == "blanky" ? hq * Q.rz(.pi / 2) : hq * Q.ry(.pi / 2), relativeTo: nil)
        }
        _ = now
    }

    private var bodyTilt: Float = 0

    private func lookTarget() -> SIMD3<Float>? {
        if (act == .eat || act == .drink), let b = target, phase >= 1 { return SIMD3<Float>(b.pos.x, b.pos.y + b.contentY - 0.004, b.pos.z) }
        if act == .social, let m = mate { return social == .ignore && !leadSocial ? nil : m.headWorld }
        if let t = s.props.first(where: { $0.heldBy != nil && ($0.base == "treat" || $0.base == "dental" || $0.kind == .toy || $0.base == "bottle") }),
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
        if act != .nurse, let b = s.props.first(where: { $0.base == "bottle" && $0.heldBy != nil && ($0.owner == nil || $0.owner == s.petKey(pid)) }),
           simd_distance(b.pos, mouthWorld) < 0.10 {
            // 젖떼기: 5주가 지나면 젖병을 거절 (0.9: 7주차에도 젖병을 먹어 게이지가 찼음 — 젖병은 4주까지)
            if age >= Double(Catalog.weanAge) {
                if s.now > tellAt { anim.overlay(Bool.random() ? "look_l" : "look_r"); fx("sniff", gain: -22) }
                tell("이제 젖병은 안 먹어요 · 밥그릇에 사료를 주세요")
            }
            else if pet.food >= 0.95 { tell("배불러해요") }
            else if pet.bottle > 0.01 || mine.count("formula") > 0 {
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
            if let t = s.props.first(where: { $0.heldBy != nil && ($0.base == "treat" || $0.base == "dental") }), simd_distance(t.pos, pos) < 1.8, s.claim(t, pid) {
                target = t
                begin(.trick)
            } else if let t = s.props.first(where: { $0.heldBy != nil && ["rope", "blanky", "squeak", "chewbone"].contains($0.base) }),
                      simd_distance(t.pos, pos) < 1.2, pet.energy > 0.2, t.pos.y - pos.y < 0.5, stage.rawValue >= Stage.social.rawValue, s.claim(t, pid) {
                // 손에 든 인형·장난감을 입 가까이 → 물고 당기기 (0.5.x 는 줄만 했음)
                target = t
                begin(.tug)
            } else if let t = s.props.first(where: { $0.heldBy != nil && $0.kind == .toy }), simd_distance(t.pos, pos) < 2.2,
                      act == .idle || act == .wander || act == .watch || act == .come, stage.rawValue >= Stage.social.rawValue, s.claim(t, pid) {
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
        if pickTarget != nil && !pickStarted { pickApproach(dt); if pickTarget != nil { return } }
        let now = s.now
        switch act {
        case .idle:
            if holdStopAt > 0 && now > holdStopAt { holdStopAt = 0; anim.stop() }
            if until > 0 && now < until {
                if until - now > 1.5 && now > idleFidgetAt && !anim.busy { idleFidgetAt = now + Double.random(in: stage == .senior ? 4...8 : 2...4.5); fidget() }
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
                    if k == "spin" { anim.play(Bool.random() ? "spin_l" : "spin_r", then: "stand"); spunAt = now + 2.6 }
                    if k == "speak" { bark(); barkedAt = now }
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
                fx("thump", gain: hard ? -16 : -26)
                if landY > fy + 0.12 { landUp(landY) } else { begin(.idle, for: 1.5) }
                if hard { anim.play(g < 0.7 ? "plop" : "startle"); say(baby ? "mewl" : "yip", gain: -10); pet.love = max(0, pet.love - 0.05) }
            }
        case .hand: handStep(dt)
        case .social: socialStep(dt)
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
            guard (s.walkPid == pid) else { begin(.idle, for: 1); return }
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
        if (s.walkPid == pid) && !baby { begin(.heel); return }
        if baby {
            if p.food < 0.35 && now > nextVoice { nextVoice = now + Double.random(in: 4...9); say("mewl", gain: -12, head: "whine"); anim.play("nb_root", then: "newborn"); begin(.idle, for: 3); return }
            if sleepy || p.energy < 0.8 { begin(.sleep); return }
            // 따뜻한 곳(담요·손) 쪽으로 꼬물꼬물
            if let b = s.bed(pid), simd_distance(b.pos, pos) > 0.15 { spot = SIMD2<Float>(b.pos.x, b.pos.z); begin(.wander); return }
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
        // 배고프거나 목마른데 그릇에 있으면 먹고 나서 잠 (0.9: 밤엔 그릇에 사료가 가득해도 굶은 채 계속 잤음)
        let foodThere = (s.own("bowl_food", pid)?.fill ?? 0) > 0.05, waterThere = (s.own("bowl_water", pid)?.fill ?? 0) > 0.05 && age >= 21
        if sleepy && !(p.food < 0.45 && foodThere) && !(p.water < 0.45 && waterThere) { p.asleep = true; pet = p; sleepTries = 0; begin(.sleep); return }
        if p.food < 0.5, let b = s.own("bowl_food", pid) {
            if b.fill > 0.05 { target = b; begin(.eat); return }
            if p.food < 0.3 && now > nextVoice { nextVoice = now + 25; target = b; begin(.eat); return }       // 빈 그릇 앞에서 조름
        }
        if p.water < 0.5, let b = s.own("bowl_water", pid), b.fill > 0.05, age >= 21 { target = b; begin(.drink); return }
        if (p.food < 0.25 || (p.water < 0.25 && age >= 21) || p.love < 0.3) && simd_distance(pos, s.userPos) > 0.9 { begin(.come); return }
        // 사람이 자리를 옮기면 졸졸 따라감 (유대가 있을수록)
        let me = SIMD2<Float>(s.userPos.x, s.userPos.z)
        if simd_distance(me, userAnchor) > 0.6 { userAnchor = me; userMovedAt = now }
        let dUser = simd_distance(pos, s.userPos)
        if now - userMovedAt < 4 && dUser > 1.1 && p.energy > 0.2 && Float.random(in: 0...1) < 0.25 + 0.6 * p.bond { begin(.come); return }
        // 놀이: 말티즈는 깨어 있으면 장난이 많음 — 나이마다 다르게 (어린 강아지·청소년기가 가장, 노견은 덜)
        let livelyMap: [Stage: Float] = [.social: 1.0, .juvenile: 1.2, .adolescent: 1.15, .adult: 0.85, .mature: 0.65, .senior: 0.35]
        let lively: Float = livelyMap[stage] ?? 0.8
        let playful: Float = min(1, 0.3 + 0.7 * (1 - p.fun)) * lively * (p.energy > 0.25 ? 1 : 0.25)
        if Float.random(in: 0...1) < playful * 0.75 {
            let toys = s.props.filter { $0.kind == .toy && $0.heldBy == nil && simd_distance($0.pos, pos) < 5 && $0.pos.y - (s.room.floorY ?? 0) < 0.25 }
            if let t = toys.randomElement(), s.claim(t, pid) {
                target = t
                bringToUser = p.bond > 0.2 && dUser < 5 && Float.random(in: 0...1) < 0.3 + 0.4 * p.bond      // 물어 와서 놀자고 내려놓음
                ballNudges = 0; begin(.toy)
                return
            }
            if stage.rawValue >= Stage.social.rawValue && stage != .senior && Float.random(in: 0...1) < 0.5 * lively, let q = s.room.nav.randomSpot(near: xz, rMin: 0.8, rMax: 2.5) {
                spot = q; begin(.zoom); until = now + 9
                if Float.random(in: 0...1) < 0.5 { bark() }
                return
            }
            if dUser < 3 && p.bond > 0.1 && Float.random(in: 0...1) < 0.5 { begin(.come); return }      // 사람에게 와서 놀자고 조름
        }
        // 그 밖: 냄새 맡으며 돌아다니기·구경·소파·쉬기
        let r = Float.random(in: 0...1)
        if r < 0.45, let q = s.room.nav.randomSpot(near: xz, rMin: 0.5, rMax: 2.6) { spot = q; begin(.wander); sniffy = Float.random(in: 0...1) < 0.6; return }
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
        if r < 0.70 && dUser > 1.3 { begin(.come); return }
        let young = stage == .social || stage == .juvenile || stage == .adolescent
        begin(.idle, for: young ? Double.random(in: 1.5...4) : (stage == .senior ? Double.random(in: 4...10) : Double.random(in: 2...6)))
        fidget()
    }
    private var perchGoal: Perch?
    private var bringToUser = false
    private var shakeIt = false
    private var userAnchor = SIMD2<Float>(0, 0)
    private var userMovedAt: Double = -99
    private var sleepTries = 0

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
        case 9: anim.overlay("sniff_air")
        case 10: if anim.posture == "stand" { anim.play("sniff_ground", then: "stand") }
        case 11: anim.setPosture("down"); anim.hold("lick_paw"); until = s.now + 6; holdStopAt = s.now + 5.8
        case 12: if young && anim.posture == "stand" { anim.play(Bool.random() ? "spin_l" : "spin_r", then: "stand"); until = s.now + 3.2 }
        case 13: if p.mood > 0.6 && stage != .senior { anim.setPosture("belly"); anim.hold("belly_wriggle"); until = s.now + 4; holdStopAt = s.now + 3.8 }
        case 14: if young && anim.posture == "stand" { anim.play(Bool.random() ? "tumble" : "plop", then: "sit") }
        case 15: if stage == .senior { anim.setPosture("sit"); anim.hold("doze_sit"); until = s.now + 8; holdStopAt = s.now + 7.8 } else { anim.overlay("lick_lips") }
        case 16: anim.overlay("tilt_lr")
        case 17: if anim.posture == "stand" { anim.play("look_back", then: "stand") }
        case 18: anim.overlay("sneeze")
        case 19: if anim.posture == "sit" { anim.play("shake_sit", then: "sit") } else { anim.overlay("shake_head") }
        case 20: if anim.posture == "sit" { anim.play(Bool.random() ? "scratch_l" : "scratch_r", then: "sit") } else { anim.overlay("ear_perk") }
        case 21: if stage != .senior { anim.setPosture("side"); anim.play("side_stretch", then: "side"); until = s.now + 5 }
        case 22: anim.overlay("look_down")
        case 23: if p.energy < 0.5 { anim.overlay("sleepy") } else { anim.overlay("tilt_l") }
        case 24: anim.overlay("sniff_air")
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
            // 잠자리로: 방석·담요 위, 그릇을 피한 자리. 못 가면 조금 뒤 다시 (세 번 못 가면 그 자리에서)
            // (0.9: 담요 가운데에 그릇이 있으면 길을 못 찾아 그릇 옆 맨바닥에서 잤음)
            if let q = bedSpot() {
                let r = travel(dt, to: q, reach: 0.06, fast: 0)
                if r == 0 { return }
                if r == -1 && sleepTries < 2 && pet.energy > 0.08 {
                    sleepTries += 1
                    pet.asleep = false
                    begin(.idle, for: 2.5)
                    return
                }
            }
            phase = 1
            if baby { anim.setPosture("newborn") }
            else {
                if !anim.busy && Float.random(in: 0...1) < 0.5 { anim.play(Bool.random() ? "spin_l" : "dig", then: "stand") }
                until = now + 1.6
            }
        case 1:
            if now < until || anim.busy { return }
            let poses = baby ? ["nb_sleep"] : (stage == .senior ? ["sleep_side", "sleep_rest"] : (age > 180 && pet.bond > 0.5 ? ["sleep_curl", "sleep_side", "sleep_rest", "sleep_belly"] : ["sleep_curl", "sleep_side", "sleep_rest"]))
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
            // 배고프거나 목마르거나 급하면 깨어 그릇·패드로 (그릇에 있을 때) — 밤에도
            let hungry = !baby && ((p.food < 0.3 && (s.own("bowl_food", pid)?.fill ?? 0) > 0.05) || (p.water < 0.25 && age >= 21 && (s.own("bowl_water", pid)?.fill ?? 0) > 0.05))
            let urgent = !baby && p.potty < 0.15
            if (!sleepy && p.energy > 0.85 && actT > 20) || hungryBaby || ((hungry || urgent) && actT > 6) {
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

    /// 잠자리 위 누울 자리: 가운데에 가깝고 그릇과 떨어진 곳
    private func bedSpot() -> SIMD2<Float>? {
        guard let b = s.bed(pid), b.heldBy == nil else { return nil }
        let c = SIMD2<Float>(b.pos.x, b.pos.z)
        let bowls = s.props.filter { ($0.base == "bowl_food" || $0.base == "bowl_water") && $0.heldBy == nil }.map { SIMD2<Float>($0.pos.x, $0.pos.z) }
        var best = c
        var bs: Float = -99
        var offs: [SIMD2<Float>] = [SIMD2<Float>(0, 0)]
        for k in 0..<8 { let a = Float(k) / 8 * 2 * .pi; offs.append(SIMD2<Float>(cos(a), sin(a)) * 0.07); offs.append(SIMD2<Float>(cos(a), sin(a)) * 0.13) }
        for o in offs {
            let q = c + o
            guard b.top(at: SIMD3<Float>(q.x, b.pos.y, q.y)) != nil else { continue }
            let gap = bowls.map { simd_distance($0, q) }.min() ?? 1
            let sc = min(0.22, gap) * 2 - simd_length(o)
            if sc > bs { bs = sc; best = q }
        }
        return best
    }

    // MARK: 밥·물
    /// 그릇 앞에 서서 고개를 그릇 속으로 숙이고, 입이 사료·물 위에 오도록 발을 조금씩 옮겨 맞춤.
    /// 사료는 몇 입 먹고 고개를 들어 씹다가 다시, 물은 혀로 떠 마시며 가끔 숨을 돌림. 빈 그릇이면 사람이 붓는 동안 앉아 기다림 (0.10.0)
    private func mealStep(_ dt: Float) {
        guard let b = target else { begin(.idle, for: 1); return }
        let eat = act == .eat
        let bc = SIMD2<Float>(b.pos.x, b.pos.z)
        switch phase {
        case 0:
            let d = b.pos - pos
            let l = max(1e-3, simd_length(SIMD2<Float>(d.x, d.z)))
            // 앞발(몸 가운데에서 0.10g 앞)이 그릇 테두리(반지름 7.5cm) 밖, 고개를 숙이면 입(0.185g 앞)이 그릇 안에 닿는 자리
            let stand: SIMD2<Float> = bc - SIMD2<Float>(d.x, d.z) / l * (0.085 + 0.10 * g)
            let r = travel(dt, to: stand, reach: 0.05, fast: pet.food < 0.3 ? 1 : 0)
            if r == -1 { begin(.idle, for: 3); return }
            if r == 1 { phase = 1 }
        case 1:
            if !face(b.pos, dt, rate: 3) { return }
            if b.fill <= 0.05 {
                // 빈 그릇: 사람이 붓고 있으면 앉아 기다리고, 아니면 냄새 맡고 밀어 보고 사람을 보며 낑낑
                if s.props.contains(where: { ($0.id == (eat ? "foodbag" : "jug")) && $0.heldBy != nil }) {
                    if anim.posture != "sit" && !anim.busy { anim.setPosture("sit") }
                    if s.now > nextVoice { nextVoice = s.now + Double.random(in: 2...4); if Bool.random() { say(age < 56 ? "yip" : "woof", gain: -16, head: "bark") } else { anim.overlay("lick_lips") } }
                    if actT > 40 { begin(.idle, for: 1) }
                    return
                }
                anim.play("nose_push", then: "sit")
                fx("clink", gain: -14)
                phase = 9; until = s.now + 2.2
                return
            }
            if anim.posture != standName { anim.setPosture(standName); return }
            if !anim.settled && anim.busy { return }
            anim.hold(eat ? "eat" : "drink")
            nextChewAt = s.now + Double.random(in: 2.5...5)
            phase = 2
        case 2, 3:
            // 입을 그릇 가운데(조금 앞쪽) 위로: 몸을 살짝씩 당기거나 물림
            // 입은 그릇 안 가까운 쪽(가운데에서 2.5cm 앞쪽)으로, 몸은 가슴이 테두리 밖인 거리 안쪽으로는 들어가지 않음
            let m = mouthWorld
            let toDog = simd_normalize(SIMD2<Float>(pos.x, pos.z) - bc + SIMD2<Float>(1e-4, 0))
            let want = bc + toDog * 0.025
            let e = want - SIMD2<Float>(m.x, m.z)
            let el = simd_length(e)
            if el > 0.006 && phase == 2 {
                var np = xz + e / el * min(el, 0.05 * dt)
                let minD: Float = 0.075 + 0.10 * g                   // 앞발이 테두리 안으로 들어가지 않게
                if simd_distance(np, bc) < minD { np = bc + simd_normalize(np - bc + SIMD2<Float>(1e-5, 0)) * minD }
                pos.x = np.x; pos.z = np.y
            }
            if phase == 3 {
                // 고개 들고 씹기 → 다시 그릇으로
                if !anim.busy { anim.hold(eat ? "eat" : "drink"); phase = 2; nextChewAt = s.now + Double.random(in: 2.5...5.5) }
                return
            }
            if s.now > nextChewAt {
                nextChewAt = s.now + 99
                phase = 3
                anim.play(eat ? "eat_lift" : "drink_lift", then: standName)
                if eat { fx("chew", gain: -20) }
                return
            }
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
    private var nextChewAt: Double = 0

    // MARK: 배변
    private func pottyStep(_ dt: Float) {
        let now = s.now
        switch phase {
        case 0:
            // 패드를 아는 만큼(배변 훈련) 패드로, 아니면 가까운 구석으로
            let pad = s.prop("pad")
            // 배변 훈련(pet.train)만큼 패드로: 처음엔 25%, 패드에서 쌀 때마다 훈련 +0.06, 400일 넘으면 늘 패드 (사용자 확인: 원래대로)
            if let pad, Float.random(in: 0...1) < 0.25 + 0.75 * pet.train || age > 400 {
                spot = SIMD2<Float>(pad.pos.x, pad.pos.z); target = pad
            } else {
                target = nil
                // 위가 트인 빈 바닥 (가구 밑에 싸서 보이지 않았음)
                let r = s.room.nav.randomSpot(near: xz, rMin: 0.4, rMax: 1.6) ?? xz
                spot = s.clearSpot(near: r, half: 0.08, within: 0.8) ?? r
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
            // 먼저 알아채고(귀 쫑긋·돌아봄) 종종걸음으로 옴 — 0.10.6 까지: 나오자마자 달리기(초당 3.4m)로 날아오듯 왔음
            if actT < 0.8 { if actT < 0.05 { anim.overlay("ear_perk") }; _ = face(s.userPos, dt); return }
            let r = travel(dt, to: u, reach: 0.5 + 0.2 * g, fast: 1)
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
                if !face(t.pos, dt, rate: 5) { return }
                pickUp(t)
                phase = 5; until = s.now + 1.2
            }
        case 5:
            // 고개 숙여 무는 중
            if carry != nil {
                pet.fun = min(1, pet.fun + 0.12)
                pet.energy = max(0, pet.energy - 0.02)
                // 유대가 깊을수록 물어 옴, 아니면 물고 달아나 흔듦
                phase = Float.random(in: 0...1) < 0.35 + 0.65 * pet.bond ? 1 : 3
                until = s.now + 4
            } else if s.now > until { phase = 0 }
        case 1:
            let u = SIMD2<Float>(s.userPos.x, s.userPos.z)
            let r = travel(dt, to: u, reach: 0.55 + 0.2 * g, fast: 1)
            if r != 0 {
                if r == 1 && !face(s.userPos, dt, rate: 4) { return }
                putDown()
                pet.bond = min(1, pet.bond + 0.004)
                phase = 2; until = s.now + 4.5
            }
        case 2:
            _ = face(s.userPos, dt)
            if carry == nil && !anim.busy && anim.current != "bow_wiggle" && s.now < until - 1 { anim.hold("bow_wiggle"); if Bool.random() { bark() } }
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
            // 장난감마다 그 물건다운 놀이 (0.10.3):
            // 공 = 코·앞발로 툭 쳐서 굴리고 쫓아감, 로프 = 물고 머리를 세게 흔들며 으르렁,
            // 삑삑이 = 엎드려 씹으며 계속 삑삑 / 물고 흔들며 삑삑, 씹는 뼈 = 앞발로 붙잡고 오래 씹음, 블랭키씨 = 잠자리로 물고 가 껴안음
            if t.base == "ball" && ballNudges < 3 && Float.random(in: 0...1) < 0.65 {
                ballNudges += 1
                anim.play(Bool.random() ? "paw_at" : "pounce", then: "stand")
                var d = t.pos - pos; d.y = 0
                let dir = simd_length(d) > 1e-3 ? simd_normalize(d) : fwd
                let side = SIMD3<Float>(-dir.z, 0, dir.x) * Float.random(in: -0.35...0.35)
                t.setVelocity(simd_normalize(dir + side) * Float.random(in: 0.7...1.5) + SIMD3<Float>(0, 0.25, 0))
                fx("bounce", gain: -20)
                pet.fun = min(1, pet.fun + 0.04)
                phase = 0; until = s.now + 0.6
                return
            }
            ballNudges = 0
            let chewy = t.base == "chewbone" || t.base == "blanky" || t.base == "squeak"
            let chewP: Float = t.base == "chewbone" ? 0.85 : (t.base == "squeak" ? 0.45 : 0.6)
            if bringToUser && stage != .senior {
                // 물어 와서 사람 발치에 내려놓고 놀자고 조름 (던져 주면 쫓아감)
                bringToUser = false
                pickUp(t)
                target = t
                act = .fetch; phase = 5; until = s.now + 1.2
                pet.bond = min(1, pet.bond + 0.002)
                return
            }
            if t.base == "blanky" && Float.random(in: 0...1) < 0.55, let bed = s.bed(pid), simd_distance(bed.pos, t.pos) > 0.25 {
                // 애착 인형: 물고 잠자리로 가서 껴안고 엎드림
                pickUp(t)
                spot = SIMD2<Float>(bed.pos.x, bed.pos.z)
                phase = 4
                pet.fun = min(1, pet.fun + 0.06)
                return
            }
            if chewy && Float.random(in: 0...1) < chewP {
                if t.base == "blanky" {
                    // 인형: 곁에 엎드려 껴안고 핥기
                    anim.setPosture("down")
                    anim.hold("lick_paw")
                    phase = 3; until = s.now + Double.random(in: 8...18)
                } else {
                    // 씹는 뼈·삑삑이: 다가가 입으로 물어 든 뒤 엎드려 앞발 사이에 두고 씹음 (0.10.13: 바닥에 둔 채 떨어진 곳에서 허공을 씹었음)
                    pickUp(t)
                    phase = 7; until = s.now + 6
                }
                nextVoice = s.now + 0.6
            } else {
                pickUp(t)
                phase = 2; until = s.now + Double.random(in: 3...6)
                shakeIt = t.base == "rope" || t.base == "squeak" || (t.base == "ball" && Float.random(in: 0...1) < 0.3)
                if !shakeIt, let q = s.room.nav.randomSpot(near: xz, rMin: 0.6, rMax: 1.8) { spot = q }
            }
            pet.fun = min(1, pet.fun + 0.08)
        case 2:
            if carry == nil { if s.now > until { begin(.idle, for: 1) }; return }       // 아직 무는 중
            if shakeIt {
                if !anim.busy { anim.hold("shake_toy") }

            } else if !anim.busy { _ = travel(dt, to: spot, reach: 0.15, fast: 1) }
            pet.fun = min(1, pet.fun + 0.01 * dt)
            if s.now > until { anim.stop(); putDown(); phase = 6; until = s.now + 0.8 }
        case 6:
            if s.now > until { begin(.idle, for: 1.5) }
        case 4:
            if carry == nil && pickTarget == nil { begin(.idle, for: 1); return }
            if carry == nil { return }
            let r = travel(dt, to: spot, reach: 0.12, fast: 0)
            if r != 0 {
                dropCarry(soft: true)
                anim.setPosture(Bool.random() ? "down" : "curl")
                anim.hold("lick_paw")
                fx("sigh", gain: -20)
                phase = 3; until = s.now + Double.random(in: 12...30)
            }
        case 7:
            // 물 때까지 기다렸다가 엎드려 씹기
            if carry != nil {
                anim.setPosture("down")
                anim.hold("chew")
                phase = 3; until = s.now + (t.base == "chewbone" ? Double.random(in: 15...30) : Double.random(in: 8...18))
            } else if pickTarget == nil || s.now > until { begin(.idle, for: 1) }
        default:
            pet.fun = min(1, pet.fun + 0.012 * dt)
            if s.now > nextVoice && t.base == "squeak" { nextVoice = s.now + Double.random(in: 0.7...2.2); anim.overlay("squeak_bite") }
            if s.now > until { anim.stop(); if carry != nil { dropCarry(soft: true) }; begin(.idle, for: 2) }
        }
    }

    /// 곁에 장난감을 내려놓음: 다가와 냄새 맡고 놀기 (갓난 강아지는 인형 곁으로 꼬물꼬물)
    func noticed(_ p: Prop) {
        guard act != .sleep, act != .held, act != .potty, act != .eat, act != .nurse, simd_distance(p.pos, pos) < 2.5 else { return }
        if baby {
            if p.base == "blanky" && age >= 7 { spot = SIMD2<Float>(p.pos.x, p.pos.z); begin(.wander); say("mewl", gain: -18) }
            return
        }
        guard act == .idle || act == .wander || act == .watch || act == .ask || act == .come else { return }
        anim.overlay("ear_perk")
        target = p
        ballNudges = 0; begin(.toy)
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
            if r == 1 && t.pos.y - pos.y < 0.32 * g + 0.12 { phase = 1; anim.hold("tug"); nextVoice = s.now + Double.random(in: 3...8) }
            else if r == 1 && !anim.busy { anim.play("hop", then: "stand") }
        default:
            _ = face(t.pos, dt, rate: 5)
            // 입이 줄을 문 채 뒤로 버팀: 줄이 멀어지면 끌려가고, 가까우면 뒤로 당김
            let d = SIMD2<Float>(t.pos.x - pos.x, t.pos.z - pos.z)
            let l = simd_length(d)
            let want: Float = 0.15 * g + 0.05
            if l > want + 0.03 {
                let m: SIMD2<Float> = d / l * min(l - want, 1.2 * dt)
                if !intoUser(xz + m) { pos.x += m.x; pos.z += m.y }        // 줄을 몸 쪽으로 당겨도 내 몸 안으로는 끌려오지 않음
            }
            pet.fun = min(1, pet.fun + 0.03 * dt)
            pet.energy = max(0, pet.energy - 0.004 * dt)
            pet.bond = min(1, pet.bond + 0.0006 * dt)
            // 당기기 중 장난 으르렁은 가끔만 (0.10.9: 2.5~6초마다라 으르렁이 가장 자주 나는 소리였음)
            if s.now > nextVoice { nextVoice = s.now + Double.random(in: 7...14); if Bool.random() { say("growl_play", gain: -18, head: "growl") } }
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
            let brush = s.props.contains { $0.base == "brush" && $0.heldBy != nil && simd_distance($0.pos, pos) < 0.35 }
            p.love = min(1, p.love + 0.035 * dt)
            p.bond = min(1, p.bond + 0.0012 * dt)
            strokes += dt
            if brush { p.clean = min(1, p.clean + 0.03 * dt); if s.now > nextVoice { nextVoice = s.now + 0.7; fx("brush", gain: -18) } }
            if foam > 0 { foam = max(0, foam - 0.09 * dt); p.clean = min(1, p.clean + 0.12 * dt); if foam == 0 { pet = p; begin(.idle, for: 2); anim.setPosture("stand"); anim.play("shake"); return } }
            // 한 번 쓰다듬는 동안의 '받는 모습'을 그때그때 정함 (0.10.1: 0.10.0 까지는 닿은 곳으로만 정해 늘 같은 몇 가지였고,
            // 옆구리도 배로 쳐서 몇 초면 거의 매번 배를 보였음). 나이·유대·기운·기분에 따라 다르고, 배 보이기는 드물게
            if petStyle.isEmpty { petStyle = pickPetStyle(p) }
            let want: String
            switch anim.posture {
            case "belly": want = "belly_rub"
            case "side": want = "pet_side"
            case "down", "rest", "curl", "sploot", "down_alert": want = "pet_down"
            case "sit", "sit_lazy":
                want = touchRegion == "chin" ? "pet_chin" : (petStyle == "sit_lean" ? "pet_sit_lean" : "pet_head")
            default:
                switch petStyle {
                case "sit", "sit_lean": want = "sitdown"
                case "down": want = "liedown"
                case "side": want = "sidedown"
                case "belly" where touchRegion == "belly" || strokes > 5: want = "belly"
                case "wiggle": want = "wiggle"
                default:
                    if touchRegion == "head" { want = "pet_head" }
                    else if touchRegion == "chin" { want = "pet_chin" }
                    else { want = strokes > 4 && p.bond > 0.3 ? "lean" : "pet_back" }
                }
            }
            switch want {
            case "belly": strokes = 0; lastBellyAt = s.now; anim.stop(); anim.setPosture("belly")
            case "sitdown": if strokes > 1.2 && !anim.busy { anim.setPosture("sit") }
            case "liedown": if strokes > 2 && !anim.busy { anim.setPosture("down") }
            case "sidedown": if strokes > 2.5 && !anim.busy { anim.setPosture("side") }
            default:
                if anim.settled || (anim.busy && anim.current != want && anim.current.hasPrefix("pet_")) || (anim.current == "lean" && want != "lean") {
                    if anim.current != want { anim.hold(want) }
                }
            }
            if s.now > nextVoice && strokes > 1.5 {
                nextVoice = s.now + Double.random(in: 2.5...5.5)
                let r = Float.random(in: 0...1)
                let young = stage == .social || stage == .juvenile
                if (touchRegion == "head" || touchRegion == "chin") && young && r < 0.25 { anim.overlay("nibble"); fx("chew", gain: -26) }      // 어린 강아지는 손가락을 살살 깨묾
                else if (touchRegion == "head" || touchRegion == "chin") && p.bond > 0.3 && r < 0.45 { anim.overlay("lick"); fx("lick", gain: -20) }  // 손을 핥음
                else if r < 0.6 { fx("sigh", gain: -20); anim.overlay("blink_slow") }
                // 옆으로·배를 보이고 누워 있으면 머리가 바닥에 있어 고개 동작 대신 눈만 가늘게 (0.10.6)
                else if r < 0.84 && (anim.posture == "belly" || anim.posture == "side") { anim.overlay("blink_slow") }
                else if r < 0.7 { anim.overlay(Bool.random() ? "tilt_l" : "tilt_r") }
                else if r < 0.78 { anim.overlay("nuzzle") }                  // 손에 얼굴을 비빔
                else if r < 0.84 { anim.overlay("look_up") }
                else if r < 0.88 { anim.overlay("yawn") }
                else { say("whimper", gain: -22) }        // 좋아서 내는 가는 소리
            }
        } else if untouchT > 1.3 {
            pet = p
            let was = anim.posture
            anim.stop()
            strokes = 0
            petStyle = ""
            begin(.idle, for: 1.5)
            // 끝나는 모습도 여러 가지: 몸 털기·기지개·손 쪽으로 더 비비기·더 해 달라고 앞발·그대로 쉬기
            let r = Float.random(in: 0...1)
            if was == "belly" || was == "side" { if r < 0.5 { anim.setPosture("down") } }
            else if r < 0.22 && was == standName { anim.play("shake", then: standName) }
            else if r < 0.36 && was == standName { anim.play("stretch_front", then: standName) }
            else if r < 0.5 && p.bond > 0.3 && (was == "sit" || was == standName) { anim.play("paw_at", then: standName) }
            else if r < 0.7 && p.love < 0.8 { anim.overlay("nuzzle") }
            else if r < 0.8 { anim.overlay("lick_lips") }
            return
        }
        pet = p
    }

    private var petStyle = ""
    private var lastBellyAt: Double = -999

    /// 이번 쓰다듬기를 받는 모습 (서서 기댐·앉음·앉아 기댐·엎드림·옆으로 누움·꼬리 치며 꼼지락·배 보이기)
    private func pickPetStyle(_ p: PetState) -> String {
        var w: [(String, Float)] = [("stand", 1.0), ("sit", 1.0), ("sit_lean", 0.8 * p.bond + 0.2), ("down", 0.6 + (1 - p.energy))]
        if stage == .social || stage == .juvenile || stage == .adolescent { w.append(("wiggle", 0.8 * p.energy)) }
        if stage != .senior { w.append(("side", 0.25 + 0.5 * p.bond)) }
        else { w.append(("down", 1.0)) }
        // 배 보이기: 유대가 깊고, 배를 만지고 있고, 최근 8분 안에 하지 않았을 때만 드물게
        if stage != .senior && p.bond > 0.5 && touchRegion == "belly" && s.now - lastBellyAt > 480 { w.append(("belly", 0.35)) }
        let total = w.reduce(0) { $0 + $1.1 }
        var r = Float.random(in: 0..<max(0.01, total))
        for (k, v) in w { r -= v; if r <= 0 { return k } }
        return "stand"
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
            if r == 1 { phase = 1; until = s.now + 2; anim.overlay("sniff_hand"); fx("sniff", gain: -20); noseAt = s.now }
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
        // 짖어 (0.10.12): 간식을 내 얼굴 높이 이상으로 번쩍 들어 올리면(팸이 절대 닿지 않는 높이), 곁에 와 앉아 올려다보다
        // 2초쯤 뒤 '달라고' 짖음 → 간식을 내려 4초 안에 입에 대 주면 배움 (생후 2개월부터).
        // 팸 머리 근처에서 하는 앉아·애교·일어서와 겹치지 않음 (등 뒤로 숨기면 손이 안 보여 간식을 놓칠 수 있어 높이로 함)
        let u = SIMD2<Float>(s.userPos.x, s.userPos.z)
        let hidden = tp.y > s.userPos.y - 0.1 && tp.y - pos.y > 0.75 && simd_distance(SIMD2<Float>(tp.x, tp.z), u) < 0.5
        if hidden && simd_distance(xz, u) < 1.6 {
            stopMoving()
            _ = face(s.userPos, dt, rate: 4)
            if anim.posture == "stand" && !anim.busy && actT > 1 { anim.setPosture(baby ? "newborn" : "sit") }
            demandT += dt
            if demandT > 2.0 && !anim.busy && age >= 56 { demandT = 0; bark(); barkedAt = s.now }
            lureT = 0
            return
        }
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
        // 돌아: 선 채로 간식을 머리 높이에서 몸 둘레로 빙 돌리면(240° 넘게) 따라 한 바퀴 돎 (생후 3개월부터)
        if anim.posture == "stand" && age >= 90 && l < 0.45 && h > 0.05 && h < headH + 0.2 * g {
            let a = atan2(d.x, d.y)
            if let la = lastLureAng { var da = a - la; if da > .pi { da -= 2 * .pi } else if da < -.pi { da += 2 * .pi }; spinAcc += da }
            lastLureAng = a
            if abs(spinAcc) > 4.2 && !anim.busy { anim.play(spinAcc > 0 ? "spin_l" : "spin_r", then: "stand"); spunAt = s.now + 2.6; spinAcc = 0; return }
        } else { lastLureAng = nil }
        spinAcc *= max(0, 1 - dt * 0.6)
        if abs(spinAcc) > 2.0 || s.now < spunAt { lureT = 0; return }      // 크게 돌리는 중(115° 넘게)엔 앉지 않고 따라 돎      // 돌리는 중엔 앉지 않고 따라 돎
        demandT = 0
        // 손·코 (0.10.12): 간식은 한 손에 든 채, 다른 빈 손을 내밂 — 간식을 들고 있으면 팸이 간식만 보고 있어서
        // 0.10.11 까지의 '빈 손 내밀고 앞발 올리면 간식'은 간식을 꺼내 오는 동안 시간이 지나 배울 수 없었음
        //  손: 앉아 있는 팸 가슴 앞에 빈 손바닥을 낮게(턱 아래) 0.6초 → 앞발을 올림 (생후 8주부터)
        //  코: 서 있는 팸 코앞(10cm 안, 코 높이)에 빈 손바닥을 0.6초 → 코를 댐
        if let hnd = s.room.hands.enumerated().first(where: { $0.offset != t.heldBy && $0.element.seen && !$0.element.fist })?.element,
           simd_length(hnd.vel) < 0.25, !anim.busy {
            let nose = mouthWorld
            let hp = SIMD2<Float>(hnd.palm.x - pos.x, hnd.palm.z - pos.z)
            let ahead = simd_dot(hp, SIMD2<Float>(sin(yaw), cos(yaw)))
            if anim.posture == "sit" && hnd.palm.y < nose.y - 0.03 && hnd.palm.y > pos.y && ahead > 0.05 && simd_length(hp) < 0.18 + 0.15 * g && age >= 56 {
                offerHandT += dt
                if offerHandT > 0.6 && s.now > pawAt + 2 { offerHandT = 0; anim.play(Bool.random() ? "paw_l" : "paw_r", then: "sit"); pawAt = s.now; return }
            } else if anim.posture == "stand" && simd_distance(hnd.palm, nose) < 0.10 && abs(hnd.palm.y - nose.y) < 0.05 {
                offerHandT += dt
                if offerHandT > 0.6 && s.now > noseAt + 2 { offerHandT = 0; anim.overlay("sniff_hand"); fx("sniff", gain: -22); noseAt = s.now; return }
            } else { offerHandT = 0 }
        } else { offerHandT = 0 }
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
        // 동작 재주(굴러·돌아·손·코·짖어)는 한 직후 간식, 자세(앉아·엎드려·애교·일어서)는 1초 유지 뒤 간식
        // 동작 재주는 '가장 최근에 한 것' 하나만 (0.10.12: 코를 댄 뒤 앞발을 올렸는데 '코'로 배우던 것)
        let acts: [(String, Double, Double)] = [("roll", rolledAt, 5), ("spin", spunAt, 4), ("paw", pawAt, 6), ("touch", noseAt, 4), ("speak", barkedAt, 4)]
        if let a = acts.filter({ s.now - $0.1 < $0.2 }).max(by: { $0.1 < $1.1 }) { learned = a.0 }
        else if learned == nil && s.now - commandAt < 8 && !commandTrick.isEmpty { learned = commandTrick }
        if let k = learned, !k.isEmpty { associate(k, &p) }
        commandAt = -99; pawAt = -99; rolledAt = -99; spunAt = -99; noseAt = -99; barkedAt = -99
        p.food = min(1, p.food + 0.04)
        p.fun = min(1, p.fun + 0.05)
        p.bond = min(1, p.bond + 0.006)
        if t.base == "dental" { p.clean = min(1, p.clean + 0.05) }
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
    private var spunAt: Double = -99, noseAt: Double = -99, barkedAt: Double = -99
    private var spinAcc: Float = 0, lastLureAng: Float?, demandT: Float = 0, offerHandT: Float = 0
    private var commandTrick = ""

    /// 사람이 한 낱말. 이름이면 돌아보고 오고, 배운 말이면 익힌 만큼 그 재주를 함 (모르면 고개만 갸웃)
    func hear(_ w: String) {
        let now = s.now
        heardWords.append((w, now))
        // 간식으로 가르치는 중이면 들은 말을 잠깐 보여 줌 (마이크가 알아들었는지 바로 알 수 있게)
        if act == .trick || s.props.contains(where: { ($0.base == "treat" || $0.base == "dental") && $0.heldBy != nil }) { s.toast("들었어요 · '\(w)'") }
        heardWords.removeAll { now - $0.1 > 15 }
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
        case "spin": anim.setPosture("stand"); pendingTrick = "spin"
        case "speak": pendingTrick = "speak"
        case "touch":
            // 내민 손이 보이면 다가가 코를 댐
            if s.room.hands.contains(where: { $0.seen && simd_distance($0.palm, pos) < 1.8 }) { begin(.hand); commandAt = s.now; commandTrick = k }
        default: break
        }
    }

    /// 재주를 해서 간식을 받음: 그 재주를 더 익히고, 6초 안에 들은 낱말을 그 재주와 짝지음 (다른 재주와의 짝은 조금 약해짐)
    private func associate(_ k: String, _ p: inout PetState) {
        let v = min(1, (p.tricks[k] ?? 0) + 0.12)
        p.tricks[k] = v
        let name = p.name.lowercased().replacingOccurrences(of: " ", with: "")
        // 간식을 먹기 전 15초 안에 들은 말 (0.10.4 까지 6초 — 엎드린 뒤 말하고 간식을 주기까지 넘기 쉬웠음)
        let ws = Set(heardWords.filter { s.now - $0.1 < 15 }.map { $0.0 }).filter { name.isEmpty || !$0.contains(name) }
        for w in ws {
            var m = p.words[w] ?? [:]
            let before = m[k] ?? 0
            m[k] = min(1, before + 0.2)
            for (o, x) in m where o != k { m[o] = max(0, x - 0.08) }
            p.words[w] = m
            // 배우는 만큼 바로 보여 줌 (0.9: 20%·80% 넘을 때만 알려 줘 배우는지 알 수 없었음)
            let v2 = m[k] ?? 0
            // 자세(재주)와 말을 구분해 보여 줌 — 0.10.4 까지는 자세 이름도 '엎드려'라 자세 100% 가 말을 익힌 것처럼 보였음
            if before < 0.8 && v2 >= 0.8 { s.toast("말 '\(w)' 익힘 → 이제 '\(w)' 하면 '\(Dog.trickTitle(k))' 재주를 해요") }
            else { s.toast("말 '\(w)' → '\(Dog.trickTitle(k))' 재주 · 배우는 중 \(Int(v2 * 100))%") }
        }
        if ws.isEmpty { s.toast("'\(Dog.trickTitle(k))' 재주 \(Int(v * 100))% · 말은 못 들었어요") }
        // 너무 많아지면 약한 짝부터 버림
        if p.words.count > 80 {
            let keep = p.words.sorted { ($0.value.values.max() ?? 0) > ($1.value.values.max() ?? 0) }.prefix(60)
            p.words = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        heardWords.removeAll()
    }

    /// 인식기에 미리 알려 줄 흔한 재주 말 (어떤 말로 가르칠지는 사람 마음 — 이것은 알아듣기 쉽게 돕는 것일 뿐)
    nonisolated static let cueWords = ["앉아", "엎드려", "손", "굴러", "일어서", "서", "애교", "돌아", "짖어", "코", "기다려", "이리와", "앉자", "옳지", "잘했어"]

    nonisolated static func trickTitle(_ k: String) -> String {
        switch k {
        case "sit": return "앉아"
        case "down": return "엎드려"
        case "beg": return "애교"
        case "hind": return "일어서"
        case "spin": return "돌아"
        case "speak": return "짖어"
        case "touch": return "코"
        case "roll": return "굴러"
        case "paw": return "손"
        default: return k
        }
    }

    // MARK: 젖병
    /// 젖병 한 번 = 분유 1회분(pet.bottle 1). 한 번 탄 분유는 다 먹을 때까지 남아 있어 다시 대면 이어 먹음.
    /// (0.4.0: 젖병이 입에서 조금만 떨어졌다 닿아도 새 분유를 써서 8회분이 금방 없어졌고, 다 먹은 뒤에도 게이지가 다 차지 않았음)
    private func nurseStep(_ dt: Float) {
        guard let b = s.props.first(where: { $0.base == "bottle" && $0.heldBy != nil }), simd_distance(b.pos, mouthWorld) < 0.16 else {
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
            if h > 0.52 * g + (mine.has("steps") ? 0.2 : 0) { perchGoal = nil; anim.overlay("look_up"); begin(.idle, for: 2); return }
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
            if actT > 0.9 { onPerch = pc; phase = 4; fx("thump", gain: -26); anim.setPosture(["rest", "curl", "sit", "sploot"].randomElement() ?? "rest"); until = s.now + Double.random(in: 30...120) }
        case 4:
            if s.now > until || pet.potty < 0.25 || (pet.food < 0.3 && s.own("bowl_food", pid)?.fill ?? 0 > 0.05) {
                anim.setPosture("stand"); phase = 5
            }
        case 5:
            if !anim.settled { return }
            if pos.y - fy > 0.62 * g + 0.25 + (mine.has("steps") ? 0.15 : 0) || baby {
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
            if actT > 1.0 { fx("thump", gain: -24); perchGoal = nil; begin(.idle, for: 1) }
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

// MARK: - 함께 사는 팸들 (0.11.0)
// 몸이 겹치지 않게: 길찾기에서 서로 비켜 감 + 다른 팸 몸으로 들어가는 걸음은 멈추고 기다림 + 겹치면 천천히 떼어 놓음.
// 어울림: PlaySession.pack 이 둘을 골라 짝을 지어 줌 — 냄새 맡기(인사)·쫓고 쫓기·맞붙기(가벼운 놀이 싸움)·다툼(으르렁)·모른 척
extension Dog {
    var others: [Dog] { s.dogs.filter { $0 !== self && $0.entity.isEnabled } }
    /// 몸 크기 (성견 = 1)
    var size: Float { anim.growth.g }

    /// 몸 캡슐 (바닥 위 선분 엉덩이~머리 앞 + 반폭). 옆으로 누우면 폭이 넓어짐
    private func capsule(at q: SIMD2<Float>? = nil) -> (SIMD2<Float>, SIMD2<Float>, Float) {
        let c = q ?? xz
        let f = SIMD2<Float>(sin(yaw), cos(yaw))
        let gg = size
        let wide = anim.posture == "side" || anim.posture == "belly" || anim.posture == "curl"
        return (c - f * (0.15 * gg), c + f * (0.19 * gg), (wide ? 0.09 : 0.06) * gg)
    }

    private static func segDist(_ a0: SIMD2<Float>, _ a1: SIMD2<Float>, _ b0: SIMD2<Float>, _ b1: SIMD2<Float>) -> Float {
        func pt(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            let ab = b - a
            let t = max(0, min(1, simd_dot(p - a, ab) / max(1e-6, simd_dot(ab, ab))))
            return simd_distance(p, a + ab * t)
        }
        // 교차하면 0
        func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
        let r = a1 - a0, sv = b1 - b0, den = cross(r, sv)
        if abs(den) > 1e-8 {
            let t = cross(b0 - a0, sv) / den, u = cross(b0 - a0, r) / den
            if t >= 0 && t <= 1 && u >= 0 && u <= 1 { return 0 }
        }
        return min(pt(a0, b0, b1), pt(a1, b0, b1), pt(b0, a0, a1), pt(b1, a0, a1))
    }

    /// 다른 팸 몸과의 틈 (음수 = 겹침). q 를 주면 내가 그 자리로 옮겼을 때
    func gap(to o: Dog, at q: SIMD2<Float>? = nil) -> Float {
        let a = capsule(at: q), b = o.capsule()
        return Dog.segDist(a.0, a.1, b.0, b.1) - a.2 - b.2
    }

    /// 이 걸음이 다른 팸 몸으로 더 들어가는지 (멀어지는 걸음은 막지 않음)
    func intoPack(_ np: SIMD2<Float>) -> Bool {
        for o in others where o.act != .held {
            let allow: Float = (act == .social && mate === o && social == .wrestle) ? -0.02 * size : 0.012
            let now = gap(to: o), next = gap(to: o, at: np)
            if next < allow && next < now - 1e-4 { return true }
        }
        return false
    }

    /// 목표 자리가 다른 팸 몸 위면 그 둘레 바깥으로 (내가 있는 쪽)
    func outsidePack(_ t: SIMD2<Float>) -> SIMD2<Float> {
        var q = t
        for o in others where o.act != .held && !(act == .social && mate === o) {
            let c = o.xz, r = 0.2 * o.size + 0.17 * size
            let d = q - c, dl = simd_length(d)
            if dl < r {
                let side = dl > 1e-3 ? d / dl : (simd_length(xz - c) > 1e-3 ? simd_normalize(xz - c) : SIMD2<Float>(1, 0))
                q = c + side * (r + 0.01)
            }
        }
        return q
    }

    /// 어울릴 수 있는 때: 깨어 있고, 혼자 쉬거나 돌아다니는 중, 아기(3주 전) 아님, 사람이 만지는 중 아님
    var socialReady: Bool {
        (act == .idle || act == .wander || act == .watch) && !baby && stage.rawValue >= Stage.social.rawValue && !touching
            && onPerch == nil && !pet.asleep && s.now > socialRest && pet.energy > 0.15
    }

    /// 먼저 다가갈 마음 (기운 × 심심함)
    var eagerness: Float { pet.energy * (1.25 - pet.fun) * (stage == .senior ? 0.5 : 1) }
    var mood: Float { pet.mood }
    var isSenior: Bool { stage == .senior }
    var energy: Float { pet.energy }

    /// 무엇을 할지: 아직 서먹하면 냄새부터, 사이가 나쁘거나 상대가 언짢으면 다툼, 지치면 모른 척, 크기가 비슷하면 맞붙기
    static func chooseSocial(_ a: Dog, _ b: Dog, rel: Float) -> Social {
        let r = Float.random(in: 0...1)
        if rel < 0.2 && r < 0.6 { return .sniff }
        let grumpy = b.mood < 0.35 || (b.isSenior && r < 0.5) || rel < -0.25 || b.energy < 0.25
        if grumpy && Float.random(in: 0...1) < (rel < -0.25 ? 0.8 : 0.5) { return .quarrel }
        if min(a.energy, b.energy) < 0.35 { return Bool.random() ? .sniff : .ignore }
        if Float.random(in: 0...1) < 0.12 { return .ignore }
        let similar = min(a.size, b.size) / max(a.size, b.size) > 0.6
        return similar && Bool.random() ? .wrestle : .chase
    }

    func startSocial(with o: Dog, _ k: Social, lead: Bool) {
        begin(.social)
        mate = o
        social = k
        leadSocial = lead
        until = s.now + (k == .chase ? 10 : (k == .wrestle ? 9 : (k == .quarrel ? 6 : 6)))
        socialNext = s.now + 0.3
        anim.setPosture(standName)
    }

    private func endSocial(rest: Double = 10) {
        if let m = mate, m.mate === self, m.act == .social { m.until = min(m.until, s.now + 0.4) }
        mate = nil
        socialRest = s.now + rest + Double.random(in: 0...6)
        anim.stop()
        begin(.idle, for: Double.random(in: 1.5...3))
    }

    /// 짝 둘레의 자리: 옆구리 곁(냄새 맡기) · 정면(맞붙기) · 뒤(쫓기)
    private func spotNear(_ o: Dog, _ where_: Int) -> SIMD2<Float> {
        let f = SIMD2<Float>(sin(o.yaw), cos(o.yaw)), side = SIMD2<Float>(f.y, -f.x)
        let sgn: Float = simd_dot(xz - o.xz, side) >= 0 ? 1 : -1
        switch where_ {
        case 0: return o.xz + side * sgn * (0.12 * o.size + 0.11 * size) - f * (0.06 * o.size)       // 옆구리 곁 (머리를 상대 엉덩이 쪽으로)
        case 1: return o.xz + f * (0.21 * o.size + 0.2 * size)                                         // 정면, 코끝이 거의 닿게
        default: return o.xz - f * (0.2 * o.size + 0.28 * size)                                       // 뒤따라
        }
    }

    private func socialStep(_ dt: Float) {
        guard let o = mate, o.entity.isEnabled, o.act == .social, o.mate === self else { endSocial(rest: 6); return }
        let now = s.now
        if now > until { finishSocial(o); return }
        switch social {
        case .sniff:
            if leadSocial {
                if phase == 0 {
                    let r = travel(dt, to: spotNear(o, 0), reach: 0.05, fast: 0)
                    if r != 0 { phase = 1; socialNext = now + 2.6; fx("sniff", gain: -20); anim.overlay("sniff_air") }
                } else {
                    _ = face(o.pos - SIMD3<Float>(sin(o.yaw), 0, cos(o.yaw)) * (0.1 * o.size), dt, rate: 2)
                    if now > socialNext { finishSocial(o) }
                }
            } else {
                _ = face(o.pos, dt, rate: 2)
                if phase == 0 && simd_distance(xz, o.xz) < 0.45 * max(size, o.size) + 0.1 { phase = 1; anim.overlay(o.pet.bond > 0 ? "sniff_air" : "ear_back") }
            }
        case .chase:
            if phase == 0 {
                // 둘 다 서로 보며 엎드려 엉덩이 들기(같이 놀자) → 앞선 팸이 달아나고 다른 팸이 쫓음
                if face(o.pos, dt, rate: 3) && anim.settled && !anim.busy { phase = 1; anim.play("bow_wiggle", then: standName); if leadSocial { bark() } }
                return
            }
            if phase == 1 && anim.busy { return }
            if leadSocial {
                if phase == 1 || simd_distance(xz, spot) < 0.25 {
                    phase = 2
                    if let q = s.room.nav.randomSpot(near: xz, rMin: 0.9, rMax: 2.2) { spot = q } else { finishSocial(o); return }
                }
                if travel(dt, to: spot, reach: 0.2, fast: 2) == -1 { spot = xz }
            } else {
                phase = 2
                _ = travel(dt, to: spotNear(o, 2), reach: 0.12, fast: 2)
                if now > nextVoice { nextVoice = now + Double.random(in: 1.5...3); if Bool.random() { bark() } else { fx("pant", gain: -22) } }
            }
        case .wrestle:
            // 가벼운 맞붙기: 마주 보고 코끝이 닿을 만큼 다가가 앞발 툭·덮치는 척·엎드려 엉덩이 들기·장난 으르렁, 가끔 한쪽이 배를 보이며 져 줌
            if leadSocial && phase == 0 {
                if travel(dt, to: spotNear(o, 1), reach: 0.06, fast: 1) != 0 { phase = 1 }
                return
            }
            if !leadSocial && phase == 0 { _ = face(o.pos, dt, rate: 3); if simd_distance(xz, o.xz) < 0.5 * max(size, o.size) + 0.12 { phase = 1 }; return }
            _ = face(o.pos, dt, rate: 3)
            if now > socialNext && !anim.busy && anim.settled {
                socialNext = now + Double.random(in: 0.7...1.4)
                let r = Float.random(in: 0...1)
                if r < 0.28 { anim.play("paw_at", then: standName) }
                else if r < 0.5 && leadSocial { anim.play("pounce", then: standName) }
                else if r < 0.7 { anim.play("bow_wiggle", then: standName) }
                else if r < 0.82 { anim.overlay("growl"); say("growl_play", gain: -16) }
                else if r < 0.9 && !leadSocial && pet.bond >= 0 { anim.play("roll_over", then: "down"); socialNext = now + 2.2 }
                else { anim.play("hop", then: standName) }
            }
        case .quarrel:
            // 다툼: 다가간 팸에게 상대가 으르렁·짖음 → 다가간 팸이 몸을 낮추고 뒷걸음질쳐 물러남 (몸은 닿지 않음)
            if leadSocial {
                if phase == 0 {
                    if travel(dt, to: spotNear(o, 1) + (xz - o.xz) * 0.25, reach: 0.12, fast: 0) != 0 { phase = 1; socialNext = now + 1.4 }
                } else if phase == 1 {
                    _ = face(o.pos, dt, rate: 2)
                    if now > socialNext { phase = 2; anim.play("cower", then: standName); socialNext = now + 1.2 }
                } else if phase == 2 && now > socialNext {
                    phase = 3
                    let away = xz + simd_normalize(xz - o.xz + SIMD2<Float>(0.001, 0)) * 1.1
                    spot = s.room.nav.walkable(away.x, away.y) ? away : (s.room.nav.randomSpot(near: xz, rMin: 0.8, rMax: 1.6) ?? xz)
                } else if phase == 3 {
                    if travel(dt, to: spot, reach: 0.15, fast: 1) != 0 { finishSocial(o) }
                }
            } else {
                _ = face(o.pos, dt, rate: 3)
                if phase == 0 && simd_distance(xz, o.xz) < 0.55 * max(size, o.size) + 0.25 {
                    phase = 1
                    anim.overlay("growl", hold: true)
                    say("growl", gain: -12)
                    socialNext = now + 1.2
                } else if phase == 1 && now > socialNext {
                    phase = 2
                    bark()
                }
            }
        case .ignore:
            // 모른 척: 다가가 냄새를 맡으려 하면 상대가 고개를 돌리고 자리를 뜸
            if leadSocial {
                if phase == 0 && travel(dt, to: spotNear(o, 0), reach: 0.08, fast: 0) != 0 { phase = 1; socialNext = now + 1.5; anim.overlay("sniff_air") }
                if phase == 1 && now > socialNext { anim.overlay(Bool.random() ? "tilt_l" : "tilt_r"); finishSocial(o) }
            } else {
                if phase == 0 && simd_distance(xz, o.xz) < 0.5 * max(size, o.size) + 0.15 {
                    phase = 1
                    anim.overlay(Bool.random() ? "look_l" : "look_r")
                    let away = xz + simd_normalize(xz - o.xz + SIMD2<Float>(0.001, 0)) * 0.9
                    spot = s.room.nav.walkable(away.x, away.y) ? away : xz
                }
                if phase == 1 { if travel(dt, to: spot, reach: 0.15, fast: 0) != 0 { phase = 2 } }
            }
        }
    }

    /// 끝: 사이가 달라지고(놀면 가까워지고 다투면 멀어짐) 놀이·사랑·기운이 바뀜. 둘 다 끝냄
    private func finishSocial(_ o: Dog) {
        guard act == .social else { return }
        let k = social
        if leadSocial {
            let dv: Float = k == .chase ? 0.05 : (k == .wrestle ? 0.06 : (k == .sniff ? 0.03 : (k == .quarrel ? -0.05 : -0.01)))
            s.relate(pid, o.pid, dv)
            for d in [self, o] {
                if k == .chase || k == .wrestle {
                    d.pet.fun = min(1, d.pet.fun + 0.18)
                    d.pet.energy = max(0, d.pet.energy - 0.05)
                }
                if k == .sniff { d.pet.love = min(1, d.pet.love + 0.02) }
            }
        }
        let tired = k == .chase || k == .wrestle
        endSocial(rest: tired ? 14 : 9)
        if tired { anim.overlay("pant", hold: true); until = s.now + 3 }
        if o.act == .social, o.mate === self { o.endSocial(rest: tired ? 14 : 9); if tired { o.anim.overlay("pant", hold: true); o.until = s.now + 3 } }
    }
}
