import Foundation
import simd

/// 움직임 이어 붙이기: 몸 전체 동작(자세·걸음·한 번 하는 동작) + 머리 겹치기 동작 + 늘 얹는 것(숨·눈 깜빡임·꼬리·귀·바라보기·소리 맞춘 입)
/// 자세(posture) 사이는 구워 둔 이음 동작('sit>down' 등)으로 넘어가고, 없으면 부드럽게 섞음
@MainActor
final class DogAnimator {
    let D: DogData
    var age: Double = 400 { didSet { growth = Growth.at(Float(age)); stage = Stage.of(age) } }
    private(set) var growth = Growth.at(400)
    private(set) var stage: Stage = .adult

    // 몸 동작
    private var cur: Clip
    private var curT: Float = 0
    private var from: Pose?
    private var fade: Float = 1, fadeDur: Float = 0.25
    private var queue: [String] = []
    private(set) var posture = "stand"            // 지금(또는 가고 있는) 자세
    private var gait: String?
    private var oneShot = false
    private var after: String?                    // 한 번 하는 동작이 끝난 뒤의 자세
    var rate: Float = 1
    // 머리 겹치기
    private var ov: Clip?
    private var ovT: Float = 0, ovW: Float = 0
    private var ovHold = false
    // 늘 얹는 것
    var wagBoost: Float = 1                       // 기분 (0 안 흔듦 ~ 2 신남)
    var look: SIMD3<Float>?                       // 바라볼 곳 (개 기준, 성견 단위)
    var lookOn: Float = 1
    private var lookYP = SIMD2<Float>(0, 0)
    var asleep = false
    var breathRate: Float = 0.38                  // 초당 숨 (쉬는 개 20~30회/분)
    private var breathPh: Float = 0, wagPh: Float = 0, noisePh: Float = Float.random(in: 0...10)
    private var blinkT: Float = 2, blink: Float = 0
    private var voice: [Float] = []
    private var voiceT: Float = -1, voiceRate: Float = 1
    private var earV = SIMD2<Float>(0, 0), earX = SIMD2<Float>(0, 0)
    private var lift: Float = 0
    /// 이번 화면에 지나간 동작 속 사건 (발 디딤·핥기 등)
    private(set) var events: [String] = []
    private(set) var pose = Pose()

    init(_ d: DogData) {
        D = d
        cur = d.clips["stand"] ?? Clip(name: "stand", n: 1, loop: true, speed: 0, events: [], mask: false, tag: "pose", off: 0)
    }

    // MARK: 지시
    var moving: Bool { gait != nil }
    /// 자세가 자리 잡았는지 (이음 동작·한 번 하는 동작이 끝남)
    var settled: Bool { queue.isEmpty && !oneShot && gait == nil && cur.name == posture && fade >= 1 }
    var dip: Float = 0                                // 고개를 더 숙이는 양 (라디안, + 가 아래)
    var busy: Bool { oneShot || inTransition }
    /// 자세를 바꾸는 이음 동작(앉았다 일어서기 등)이 아직 끝나지 않음.
    /// 0.10.6 까지: 마지막 이음 동작은 대기열에서 빠진 채 재생돼 '바쁘지 않음'으로 보였음 → 다리가 굽은 채 걸음·제자리 돌기·다른 동작이
    /// 그 위에 끼어들어, 다리를 구부린 채 빙글빙글 돌거나 누운 자세에서 걸음으로 몸이 휙 뒤집혔음
    var inTransition: Bool { !queue.isEmpty || (cur.tag == "trans" && curT < cur.dur) }
    var current: String { cur.name }
    /// 지금 걸음의 빠르기 (m/s, 실제 크기)
    var speed: Float { gait != nil ? cur.speed * rate * growth.g * fade : 0 }

    private func start(_ c: Clip, fade f: Float) {
        from = pose
        fade = f <= 0 ? 1 : 0
        fadeDur = max(0.01, f)
        cur = c
        curT = 0
    }

    /// 자세 바꾸기. 이음 동작 길을 찾아 차례로
    func setPosture(_ p: String) {
        guard D.clips[p] != nil else { return }
        if gait != nil { gait = nil }
        if p == posture && (cur.name == p || inTransition) && !oneShot { return }
        let src = oneShot ? (after ?? posture) : posture
        oneShot = false
        queue = path(src, p)
        posture = p
        if queue.isEmpty { start(D.clips[p]!, fade: 0.45) } else { next() }
    }

    private func next() {
        guard !queue.isEmpty else {
            if let c = D.clips[posture] { start(c, fade: 0.2) }
            return
        }
        var name = queue.removeFirst()
        if stage == .senior {                                     // 노견은 힘겹게 일어나고 천천히 엎드림
            if name == "down>stand" { name = "senior_rise" }
            if name == "stand>down" { name = "senior_down" }
        }
        if let c = D.clips[name] { start(c, fade: 0.15) } else { next() }
    }

    private func path(_ a: String, _ b: String) -> [String] {
        if a == b { return [] }
        var prev: [String: String] = [a: ""]
        var open = [a]
        while !open.isEmpty {
            let x = open.removeFirst()
            if x == b { break }
            for k in D.clips.keys where k.hasPrefix(x + ">") {
                let y = String(k.dropFirst(x.count + 1))
                if prev[y] == nil { prev[y] = x; open.append(y) }
            }
        }
        guard prev[b] != nil else { return [] }
        var out: [String] = []
        var y = b
        while let x = prev[y], !x.isEmpty { out.insert(x + ">" + y, at: 0); y = x }
        return out
    }

    /// 걷기·뛰기 (nil 이면 멈춤). 서 있는 자세(갓난 강아지는 엎드린 자세)에서만
    func setGait(_ g: String?) {
        if g == gait { return }
        gait = g
        oneShot = false
        queue.removeAll()
        if let g, let c = D.clips[g] {
            let ph = cur.tag == "loco" ? curT / max(0.01, cur.dur) : 0
            start(c, fade: 0.22)
            curT = ph * c.dur
        } else if let c = D.clips[posture] {
            start(c, fade: 0.25)
        }
    }

    /// 한 번 하는 동작. then = 끝난 뒤 자세 (없으면 지금 자세로 돌아감)
    func play(_ name: String, then: String? = nil, fade f: Float = 0.2) {
        guard let c = D.clips[name] else { return }
        gait = nil
        queue.removeAll()
        oneShot = true
        after = then
        start(c, fade: f)
        once = true
    }

    /// play 로 튼 동작은 되풀이 동작이어도 한 바퀴만 (0.7.0: 땅 파기·냄새 맡기·제자리 돌기 등 되풀이 동작을 play 로 틀면 끝나지 않아
    /// '자는 중'인데 계속 바닥을 긁는 소리를 내며 멈춰 있었음). 붙들어 두는 것은 hold
    private var once = false

    /// 되풀이 동작을 자세처럼 유지 (먹기·핥기 등). stop 으로 끝냄
    func hold(_ name: String) {
        guard let c = D.clips[name], cur.name != name else { return }
        gait = nil
        queue.removeAll()
        oneShot = true
        after = nil
        start(c, fade: 0.3)
        once = false
    }

    func stop() {
        guard oneShot else { return }
        oneShot = false
        if let a = after { posture = a }
        if let c = D.clips[posture] { start(c, fade: 0.3) }
    }

    /// 머리 동작 겹치기 (hold: 되풀이 유지)
    func overlay(_ name: String?, hold: Bool = false) {
        guard let name, let c = D.clips[name], c.mask else { ovHold = false; return }
        if ov?.name == name && ovHold && hold { return }
        ov = c; ovT = 0; ovHold = hold
    }
    var overlayName: String? { (ovHold || (ov != nil && ovT < (ov?.dur ?? 0))) ? ov?.name : nil }

    /// 목소리에 맞춰 입 벌리기
    func speak(_ env: [Float], rate r: Float) {
        voice = env; voiceT = 0; voiceRate = r
    }

    // MARK: 매 화면
    private func fire(_ c: Clip, _ t0: Float, _ t1: Float) {
        for e in c.events {
            if c.loop && t1 >= c.dur {
                if e.t >= t0 || e.t < t1 - c.dur { events.append(e.name) }
            } else if e.t >= t0 && e.t < t1 { events.append(e.name) }
        }
    }

    func tick(_ dt: Float) -> SkinJob {
        events.removeAll(keepingCapacity: true)
        let d = dt * rate
        // 몸
        let t0 = curT
        curT += d
        fire(cur, t0, curT)
        if cur.loop && !(once && oneShot) { if curT >= cur.dur { curT -= cur.dur } }
        else if curT >= cur.dur {
            once = false
            curT = cur.dur
            if !queue.isEmpty || cur.tag == "trans" { next() }
            else if oneShot {
                oneShot = false
                if let a = after { posture = a }
                if let c = D.clips[posture] { start(c, fade: 0.25) }
            }
        }
        var p = D.sample(cur, curT)
        if fade < 1, let f = from {
            fade = min(1, fade + dt / fadeDur)
            p = Pose.mix(f, p, Q.ss(fade))
        }
        let base = p
        // 머리 겹치기
        if let o = ov {
            ovT += d
            let live = ovHold || ovT < o.dur
            ovW += ((live ? 1 : 0) - ovW) * min(1, dt * 9)
            if live || ovW > 0.01 {
                fire(o, ovT - d, ovT)
                let tt = o.loop ? ovT.truncatingRemainder(dividingBy: o.dur) : min(ovT, o.dur)
                let q = D.sample(o, tt)
                for j in [J.neck, J.head, J.jaw, J.earL, J.earR] {
                    p.q[j] = Q.nlerp(p.q[j], p.q[j] * q.q[j], ovW)
                }
                p.lid = max(p.lid, q.lid * ovW)
                p.tongue = max(p.tongue, q.tongue * ovW)
            } else if !live { ov = nil }
        }
        extras(&p, dt)
        guardHead(&p, base: base, dt)
        guardBody(&p, dt)
        // 고개 숙이기 더하기 (먹기·물기에서 입을 그릇·물건 높이에 맞춤 — Dog 가 조절)
        if abs(dip) > 1e-3 {
            p.q[J.neck] = p.q[J.neck] * Q.rx(dip * 0.55)
            p.q[J.head] = p.q[J.head] * Q.rx(dip * 0.45)
        }
        pose = p
        // 땅에 맞춤 (뛰는 동작은 그대로)
        let (R, T, S) = D.fk(p, growth)
        let air = cur.tag == "jump" || cur.name == "hop" || cur.name == "pounce" || cur.name == "greet_jump" || cur.name == "startle" || cur.name == "held" || cur.name.hasPrefix("held_")
        if !air {
            let want = -D.lowest(R, T, S)
            lift += (want - lift) * min(1, dt * 14)
        }
        var job = SkinJob()
        job.pose = p
        job.growth = growth
        job.lift = lift
        job.eyeOpen = Float(min(1, max(0, (age - 10) / 4)))
        return job
    }

    /// 늘 얹는 것: 숨·깜빡임·꼬리·귀·바라보기·입·작은 흔들림
    /// 목·머리 안전장치 (0.10.6): 몸 동작 + 머리 겹치기 + 바라보기 + 목소리가 한꺼번에 더해져도
    /// ① 목·머리가 몸 동작에 든 각도(또는 목 0.9·머리 0.8 라디안)보다 더 꺾이지 않고
    /// ② 초당 7 라디안보다 빠르게 돌지 않게 (몸 털기·머리 털기·재채기처럼 원래 빠른 동작은 그대로)
    private var prevNeck = Q.id, prevHead = Q.id, prevOK = false
    private func guardHead(_ p: inout Pose, base: Pose, _ dt: Float) {
        func ang(_ q: simd_quatf) -> Float { 2 * acos(min(1, abs(q.real))) }
        func cap(_ q: simd_quatf, _ m: Float) -> simd_quatf {
            let a = ang(q)
            guard a > m, a > 1e-4 else { return q }
            return Q.nlerp(Q.id, q, m / a)
        }
        p.q[J.neck] = cap(p.q[J.neck], max(0.9, ang(base.q[J.neck]) + 0.05))
        p.q[J.head] = cap(p.q[J.head], max(0.8, ang(base.q[J.head]) + 0.05))
        let fast = cur.name.hasPrefix("shake") || ov?.name == "shake_head" || ov?.name == "sneeze" || cur.name == "startle"
        if prevOK && !fast && dt > 0 {
            let lim: Float = 7 * dt
            for (j, prev) in [(J.neck, prevNeck), (J.head, prevHead)] {
                let d = ang(prev.inverse * p.q[j])
                if d > lim { p.q[j] = Q.nlerp(prev, p.q[j], lim / d) }
            }
        }
        prevNeck = p.q[J.neck]; prevHead = p.q[J.head]; prevOK = true
    }

    /// 몸통 안전장치 (0.10.7): 몸·허리·가슴이 초당 6 라디안보다 빠르게 돌지 않게.
    /// 동작 156개 가운데 이보다 빠른 것은 구르기·제자리 돌기·덮치기·뒤돌기·털기뿐(그대로 둠) —
    /// 그 밖에 이보다 빠르면 서로 다른 자세 사이를 갑자기 섞은 것(누운 자세 → 걸음 등)이라 천천히 이어 줌
    private var prevBody = [simd_quatf](repeating: Q.id, count: 3), prevBodyOK = false
    private func guardBody(_ p: inout Pose, _ dt: Float) {
        let n = cur.name
        let fast = n == "roll_over" || n.hasPrefix("spin") || n == "pounce" || n.hasPrefix("turn_") || n.hasPrefix("shake") || n == "tumble" || n == "startle" || cur.tag == "jump" || n.hasPrefix("held")
        let js = [J.root, J.spine, J.chest]
        if prevBodyOK && !fast && dt > 0 {
            let lim: Float = 6 * dt
            for (k, j) in js.enumerated() {
                let q = prevBody[k].inverse * p.q[j]
                let d = 2 * acos(min(1, abs(q.real)))
                if d > lim { p.q[j] = Q.nlerp(prevBody[k], p.q[j], lim / d) }
            }
        }
        for (k, j) in js.enumerated() { prevBody[k] = p.q[j] }
        prevBodyOK = true
    }

    private func extras(_ p: inout Pose, _ dt: Float) {
        // 숨 (잠들면 느리고 깊게)
        let br = asleep ? breathRate * 0.55 : breathRate
        breathPh += dt * br * 2 * .pi
        let b = sin(breathPh)
        p.sq = b * (asleep ? 1.0 : 0.55)
        p.q[J.chest] = p.q[J.chest] * Q.rx(-0.012 * b)
        // 눈 깜빡임
        if !asleep {
            blinkT -= dt
            if blinkT <= 0 { blinkT = Float.random(in: 1.8...6.5); blink = 0.16 }
            if blink > 0 { blink -= dt; p.lid = max(p.lid, sin(.pi * (1 - blink / 0.16))) }
        } else { p.lid = 1 }
        // 꼬리: 나이 자세(갓난 강아지는 곧게) + 흔들기
        let a = Float(age)
        let young = Q.interp(a, [0, 21, 90], [1, 0.6, 0])
        if young > 0 {
            p.q[J.tail1] = p.q[J.tail1] * Q.rx(-0.9 * young)
            for j in [J.tail2, J.tail3, J.tail4] { p.q[j] = p.q[j] * Q.rx(-0.35 * young) }
        }
        // 나이 듦: 고개·꼬리가 처지고 몸이 조금 낮아지고 눈꺼풀이 무거움 (노견이 젊은 개와 똑같아 보였음)
        let old = Growth.old(a)
        if old > 0.01 {
            p.q[J.neck] = p.q[J.neck] * Q.rx(0.16 * old)
            p.q[J.head] = p.q[J.head] * Q.rx(0.06 * old)
            p.q[J.tail1] = p.q[J.tail1] * Q.rx(-0.5 * old)
            p.q[J.spine] = p.q[J.spine] * Q.rx(-0.04 * old)
            p.root.y -= 0.006 * old
            if !asleep { p.lid = max(p.lid, 0.22 * old) }
        }
        let amp = min(1.4, p.wag * wagBoost) * (a < 14 ? 0 : (a < 21 ? 0.4 : 1)) * (1 - 0.45 * old)
        if amp > 0.02 && !asleep {
            wagPh += dt * (3.2 + 2.6 * min(1.2, amp)) * 2 * .pi
            let x = SIMD3<Float>(1, 0, 0)
            let wk: [Float] = [0.42, 0.22, 0.18, 0.14]
            for (k, j) in [J.tail1, J.tail2, J.tail3, J.tail4].enumerated() {
                let nextRest: SIMD3<Float> = j == J.tail4 ? SIMD3<Float>(0, -0.006, 0.038) : D.rest[j + 1] - D.rest[j]
                let dir = p.q[j].act(simd_normalize(nextRest))
                var ax = simd_cross(dir, x)
                let l = simd_length(ax)
                if l < 1e-4 { continue }
                ax /= l
                let ph: Float = wagPh - Float(k) * 0.55
                let w: Float = amp * wk[k] * sin(ph)
                p.q[j] = simd_quatf(angle: w, axis: ax) * p.q[j]
            }
            p.q[J.root] = p.q[J.root] * Q.ry(0.025 * min(1, amp) * sin(wagPh + 2.6))        // 엉덩이도 살짝
        }
        // 바라보기 (목·머리에 나눠)
        // 0.10.6: 쓰다듬는 손처럼 바라볼 곳이 머리에 거의 붙어 있으면 방향(atan2)이 손 떨림마다 좌우·앞뒤로 뒤집혀
        // 목이 무섭게 빠르게 휙휙 돌았음 → 가까울수록·등 뒤일수록 덜 보고(부드럽게 0으로), 고개 돌리는 빠르기에 한도.
        // 옆으로·배를 보이고 누운 자세는 머리가 바닥에 있어 바라보지 않음
        var want = SIMD2<Float>(0, 0)
        let lying = cur.name.hasPrefix("belly") || cur.name.hasPrefix("side") || cur.name.hasPrefix("sleep") || cur.name == "pet_side" || cur.name == "curl"
        if let t = look, lookOn > 0, !asleep, !lying {
            let h = D.rest[J.head] + SIMD3<Float>(0, p.root.y, 0)
            let d = t - h
            let hz = max(1e-3, (d.x * d.x + d.z * d.z).squareRoot())
            let rawYaw = atan2(d.x, d.z)
            let nearW = Q.ss(max(0, min(1, (simd_length(d) - 0.12) / 0.18)))       // 12cm 안: 안 봄, 30cm 밖: 다 봄
            let backW = Q.ss(max(0, min(1, (2.3 - abs(rawYaw)) / 0.8)))            // 등 뒤(130° 넘음): 안 봄
            let w = lookOn * nearW * backW
            let yaw: Float = max(-1.2, min(1.2, rawYaw))
            let pit: Float = max(-0.75, min(0.6, -atan2(d.y, hz)))
            want = SIMD2<Float>(yaw * w, pit * w)
        }
        let step = (want - lookYP) * min(1, dt * 6)
        let maxStep = 3.0 * dt                                                        // 고개 돌리기 초당 3 라디안까지
        lookYP += simd_clamp(step, SIMD2<Float>(repeating: -maxStep), SIMD2<Float>(repeating: maxStep))
        if abs(lookYP.x) > 0.005 || abs(lookYP.y) > 0.005 {
            p.q[J.neck] = p.q[J.neck] * Q.ry(lookYP.x * 0.45) * Q.rx(lookYP.y * 0.45)
            p.q[J.head] = p.q[J.head] * Q.ry(lookYP.x * 0.55) * Q.rx(lookYP.y * 0.55)
        }
        // 가만있지 않는 작은 움직임 (깨어 있을 때)
        if !asleep {
            noisePh += dt
            let n1: Float = sin(noisePh * 0.7) * sin(noisePh * 0.23 + 1.3)
            let n2: Float = sin(noisePh * 0.51 + 2) * sin(noisePh * 0.17)
            p.q[J.head] = p.q[J.head] * Q.ry(0.035 * n1) * Q.rx(0.02 * n2)
            p.q[J.spine] = p.q[J.spine] * Q.ry(0.01 * n2)
        }
        // 귀: 머리 움직임에 뒤따라 출렁임
        let hv = SIMD2<Float>(lookYP.x, p.q[J.head].vector.z * 2)
        let acc: SIMD2<Float> = (hv - earX) / max(dt, 1e-3)
        earX = hv
        let push: SIMD2<Float> = acc * (-0.02) - earV * 9
        earV += push * dt
        earV = simd_clamp(earV, SIMD2<Float>(repeating: -0.5), SIMD2<Float>(repeating: 0.5))
        let flap: Float = abs(earV.y) * 0.4
        let outL: Float = max(0, earV.x) * 0.8 + flap
        let outR: Float = min(0, earV.x) * 0.8 - flap
        let back: Float = earV.x * 0.3
        p.q[J.earL] = p.q[J.earL] * Q.rz(outL) * Q.rx(back)
        p.q[J.earR] = p.q[J.earR] * Q.rz(outR) * Q.rx(-back)
        // 소리에 맞춘 입
        if voiceT >= 0 {
            let i = Int(voiceT * 60 * voiceRate)
            if i < voice.count {
                let e = voice[i]
                p.q[J.jaw] = p.q[J.jaw] * Q.rx(0.42 * e.squareRoot())
                p.q[J.head] = p.q[J.head] * Q.rx(-0.06 * e)
                voiceT += dt
            } else { voiceT = -1 }
        }
    }
}
