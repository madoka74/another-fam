import Foundation
import SwiftUI
import RealityKit
import ARKit
import simd
import QuartzCore

/// 함께하는 공간 (현실이 보이는 섞인 몰입 공간): 공간 인식 + 강아지 + 물건 + 손
/// 육성 값(PetState)은 여는 동안 여기서만 고치고, 0.5초마다 메인 창에 알림·15초마다 저장
@MainActor @Observable
final class PlaySession {
    @ObservationIgnored let root = Entity()
    @ObservationIgnored let room = Room()
    @ObservationIgnored var dog: Dog?
    @ObservationIgnored var props: [Prop] = []
    @ObservationIgnored var pet = PetState()
    @ObservationIgnored var now: Double = 0
    @ObservationIgnored var hour: Double = 12
    @ObservationIgnored var userPos = SIMD3<Float>(0, 1.4, 0)
    @ObservationIgnored var userFwd = SIMD3<Float>(0, 0, -1)
    @ObservationIgnored var updateSub: EventSubscription?
    @ObservationIgnored private var headOK = false

    // 화면에 보이는 것
    var cardOn = false
    var toastText: String?
    var shown = PetState()
    var walking = false
    var loading = true
    var holding = false                 // 안고 있는 동안: 손이 강아지를 가리지 않게

    @ObservationIgnored private var card: Entity?
    @ObservationIgnored private var cardUntil: Double = 0
    @ObservationIgnored private var toastUntil: Double = 0
    @ObservationIgnored private var publishAt: Double = 0
    @ObservationIgnored private var saveAt: Double = 0
    @ObservationIgnored private var homeId: UUID?
    @ObservationIgnored private var homeM: simd_float4x4?
    @ObservationIgnored private var homeWaitUntil: Double = 0
    @ObservationIgnored private var homeNew = false
    @ObservationIgnored private var spawned = false
    @ObservationIgnored private var makingHome = false
    @ObservationIgnored private var held: [Prop?] = [nil, nil]
    @ObservationIgnored private var wasGrab = [false, false]
    @ObservationIgnored private var openN = [0, 0]
    @ObservationIgnored private var grabStart: [(at: Double, pos: SIMD3<Float>)] = [(0, .zero), (0, .zero)]
    @ObservationIgnored private var lastGrabAt: Double = 0
    @ObservationIgnored private var palmGap: Float = 1
    @ObservationIgnored private var clapAt: Double = 0
    @ObservationIgnored private var lastUser = SIMD3<Float>(0, 0, 0)
    @ObservationIgnored private var leash: ModelEntity?
    @ObservationIgnored private var foamBalls: [ModelEntity] = []
    @ObservationIgnored private var ended = false
    @ObservationIgnored private var hourAt: Double = -99
    @ObservationIgnored private var startAt: Double = 0
    @ObservationIgnored private var lastFloor: Float = -999

    // MARK: 시작·끝
    func start() async {
        let model = AppModel.shared
        guard var p = model.pet else { return }
        p.catchUp()
        if p.placed.isEmpty && p.layout.isEmpty { p.placed = ["blanket", "bowl_water"] }      // 입양 키트를 처음 한 번 꺼내 둠
        pet = p
        shown = p
        model.session = self
        SoundBank.shared.preload()
        root.addChild(room.root)
        room.onAnchor = { [weak self] a, removed in self?.anchor(a, removed) }
        if let s = UserDefaults.standard.string(forKey: "af.home"), let id = UUID(uuidString: s) { homeId = id }
        now = CACurrentMediaTime()
        if let note = await room.start() { toast(note) }
        now = CACurrentMediaTime()
        startAt = now
        homeWaitUntil = now + 10
        if let d = Dog(self) {
            dog = d
            d.entity.isEnabled = false
            root.addChild(d.entity)
        } else { toast("강아지 모델을 읽지 못했어요") }
    }

    func stop() {
        guard !ended else { return }
        ended = true
        room.stop()
        saveLayout()
        pet.lastSim = Date().timeIntervalSince1970
        AppModel.shared.pet = pet
        Store.save(pet)
        if AppModel.shared.session === self { AppModel.shared.session = nil }
        AppModel.shared.playClosed()
    }

    func attachCard(_ e: Entity) {
        card = e
        e.isEnabled = false
        root.addChild(e)
    }

    func toast(_ s: String) {
        toastText = s
        toastUntil = CACurrentMediaTime() + 4
    }

    func prop(_ id: String) -> Prop? { props.first { $0.id == id } }

    // MARK: 집 자리 (방에 고정한 기준점 — 물건 자리를 다음에도 그대로)
    private func anchor(_ a: WorldAnchor, _ removed: Bool) {
        if a.id == homeId {
            if !removed && a.isTracked {
                // 자리만 기억함 — 놓기는 바닥을 안 뒤에 tick 이 함.
                // (0.1.x: 여기서 바로 놓으려다 바닥을 아직 몰라 그만두고 다시 하지 않아, 두 번째 실행부터 아무것도 안 나왔음)
                homeM = a.originFromAnchorTransform
            }
        } else if !removed && !makingHome {
            Task { await room.removeAnchor(a.id) }
        }
    }

    private func makeHome() {
        guard !makingHome, let fy = room.floorY, headOK else { return }
        makingHome = true
        let f = userFwd
        // 내 앞 1.1m 근처에서 '둘레 35cm 가 빈 바닥'인 자리 (가구 뒤·가구 속이 아니게)
        let want = SIMD2<Float>(userPos.x + f.x * 1.1, userPos.z + f.z * 1.1)
        let q = room.nav.openSpot(near: want, clear: 0.35) ?? want
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(q.x, fy, q.y, 1)
        Task {
            if let id = await room.addAnchor(m) {
                homeId = id
                UserDefaults.standard.set(id.uuidString, forKey: "af.home")
            }
            homeM = m
            homeNew = true
            makingHome = false
        }
    }

    private func note(_ s: String) {
        if toastText != s { toastText = s }
        toastUntil = now + 1
    }

    /// 시작 순서: 머리 자리 → 바닥(바닥 면을 알아볼 때까지, 8초 넘으면 어림) → 집 자리(지난번 것을 10초 기다림, 없으면 새로) → 놓기
    private func stepStart() {
        guard headOK else { return }
        guard room.floorY != nil, room.floorFromPlane || now - startAt > 8 || !room.sensingOK else { note("바닥을 찾는 중"); return }
        if homeM == nil {
            if homeId != nil && now < homeWaitUntil { note("집을 찾는 중"); return }
            if !(room.nav.ready || now - startAt > 12) { note("바닥을 둘러봐 주세요"); return }
            makeHome()
            return
        }
        spawnAll()
    }

    private func toWorld(_ l: [Float]) -> (SIMD3<Float>, Float)? {
        guard let m = homeM, l.count >= 4, !homeNew else { return nil }
        let w = m * SIMD4<Float>(l[0], l[1], l[2], 1)
        let hy = atan2(m.columns.2.x, m.columns.2.z)
        return (SIMD3<Float>(w.x, w.y, w.z), l[3] + hy)
    }

    private func saveLayout() {
        guard let m = homeM else { return }
        let inv = m.inverse
        let hy = atan2(m.columns.2.x, m.columns.2.z)
        var lay: [String: [Float]] = [:]
        for p in props where p.kind == .fixed || p.kind == .toy {
            let w = p.pos
            let l = inv * SIMD4<Float>(w.x, w.y, w.z, 1)
            let f = p.entity.orientation(relativeTo: nil).act(SIMD3<Float>(0, 0, 1))
            lay[p.id] = [l.x, l.y, l.z, atan2(f.x, f.z) - hy]
        }
        if let d = dog, d.entity.isEnabled {
            let l = inv * SIMD4<Float>(d.pos.x, d.pos.y, d.pos.z, 1)
            lay["_dog"] = [l.x, 0, l.z, d.yaw - hy]
        }
        pet.layout = lay
    }

    /// 꺼내 둔 물건·강아지를 제자리에
    private func spawnAll() {
        guard let fy = room.floorY, homeM != nil else { return }
        spawned = true
        lastFloor = fy
        let f = userFwd, side = SIMD3<Float>(-f.z, 0, f.x)
        let base = homeM.map { SIMD3<Float>($0.columns.3.x, fy, $0.columns.3.z) } ?? (userPos + f * 1.1)
        // 처음 놓을 때: 잠자리는 집 자리에, 나머지는 그 둘레의 빈 바닥에 하나씩
        let ring: [(Float, Float)] = [(0.5, 0), (-0.5, 0), (0.5, 0.45), (-0.5, 0.45), (0, 0.55), (0.9, 0), (-0.9, 0)]
        var k = 0
        for id in pet.placed {
            let p = Prop(id)
            var at = SIMD3<Float>(0, 0, 0), yaw: Float = 0
            if let l = pet.layout[id], let w = toWorld(l) { at = w.0; yaw = w.1; if p.kind == .fixed { at.y = fy } else { at.y = max(at.y, fy) + 0.03 } }
            else if id == "blanket" || id == "bed" {
                at = base
                yaw = atan2(-f.x, -f.z)
            } else {
                at = base + side * 0.5
                while k < ring.count {
                    let c: SIMD3<Float> = base + side * ring[k].0 - f * ring[k].1
                    k += 1
                    if room.nav.open || room.nav.walkable(c.x, c.z) { at = c; break }
                }
                at.y = fy + (p.kind == .fixed ? 0 : 0.05)
            }
            add(p, at: at, yaw: yaw)
            if id == "bowl_food" { p.fill = pet.foodBowl }
            if id == "bowl_water" { p.fill = pet.waterBowl }
            if id == "pad" { p.fill = 1 - Float(min(3, pet.padUses)) / 3 }
        }
        for i in 0..<min(3, pet.poops) {
            let base = prop("pad")?.pos ?? (userPos + f * 1.4)
            let a = Float(i) * 2.1
            addMessProp("poop", at: SIMD3<Float>(base.x + cos(a) * 0.45, fy, base.z + sin(a) * 0.45))
        }
        if let d = dog {
            var at = base
            var yaw = atan2(-f.x, -f.z)
            if let b = prop("bed") ?? prop("blanket") { at = b.pos }
            else if let l = pet.layout["_dog"], let w = toWorld(l) { at = w.0; yaw = w.1 }
            at.y = fy
            d.place(at: at, yaw: yaw)
            d.entity.isEnabled = true
            d.arrive()
        }
        loading = false
        toastText = nil
        saveLayout()
    }

    private func add(_ p: Prop, at: SIMD3<Float>, yaw: Float) {
        p.entity.position = at
        p.entity.orientation = Q.ry(yaw)
        root.addChild(p.entity)
        props.append(p)
    }

    func removeProp(_ p: Prop) {
        for i in 0..<2 where held[i] === p { held[i] = nil }
        p.entity.removeFromParent()
        props.removeAll { $0 === p }
    }

    // MARK: 보관함에서 꺼내기·넣기
    /// 반환: 안 될 때 까닭
    func takeOut(_ id: String) -> String? {
        guard spawned, let fy = room.floorY else { return "공간을 알아보는 중이에요" }
        let f = userFwd
        let kindProbe = Prop(id)
        if kindProbe.kind == .fixed || kindProbe.kind == .toy {
            if pet.placed.contains(id) { return "이미 꺼내 두었어요" }
            if id == "pad" { guard pet.use("pad") else { return "패드가 없어요" }; pet.padUses = 3 }
            pet.placed.append(id)
        } else if id == "treat" || id == "dental" {
            guard pet.use(id) else { return "남은 것이 없어요" }
        } else if props.contains(where: { $0.id == id }) { return "이미 꺼내 두었어요" }
        var at = userPos + f * 0.5
        at.y = max(fy + 0.1, userPos.y - 0.35)
        if kindProbe.kind == .fixed {
            let want = SIMD2<Float>(userPos.x + f.x * 0.8, userPos.z + f.z * 0.8)
            let q = room.nav.openSpot(near: want, clear: 0.15, within: 1.0) ?? want
            at = SIMD3<Float>(q.x, fy, q.y)
        }
        add(kindProbe, at: at, yaw: atan2(-f.x, -f.z))
        if kindProbe.kind == .tool { kindProbe.setMode(.kinematic) }       // 손에 쥘 것은 집을 때까지 내 앞에 떠 있음
        saveLayout()
        if id == "bowl_food" { kindProbe.fill = pet.foodBowl }
        if id == "bowl_water" { kindProbe.fill = pet.waterBowl }
        publish()
        return nil
    }

    func putBack(_ id: String) {
        for p in props.filter({ $0.id == id }) {
            if id == "treat" || id == "dental" { pet.inv[id] = pet.count(id) + 1 }
            removeProp(p)
        }
        pet.placed.removeAll { $0 == id }
        if id == "pad" { pet.padUses = 0 }
        saveLayout()
        publish()
    }

    func isOut(_ id: String) -> Bool { props.contains { $0.id == id } }

    func setWalking(_ on: Bool) {
        walking = on
        if !on { leash?.isEnabled = false }
    }

    // MARK: 치울 것
    func addMess(_ id: String, at: SIMD3<Float>) {
        if id == "poop" { pet.poops = min(6, pet.poops + 1) }
        addMessProp(id, at: at)
    }

    private func addMessProp(_ id: String, at: SIMD3<Float>) {
        let p = Prop(id)
        var q = at
        q.y = room.floorY ?? at.y
        add(p, at: q, yaw: Float.random(in: 0...6))
    }

    func padFull(_ pad: Prop) { toast("패드를 갈아 주세요") }

    // MARK: 누르기 (멀리서 바라보고 집기)
    func tapDog() {
        guard now - lastGrabAt > 0.7 else { return }
        cardOn.toggle()
        cardUntil = now + 12
    }

    // MARK: 강아지 메뉴 (강아지를 누르면 뜨는 카드의 단추)
    func closeCard() { cardOn = false }

    /// 밥 주기: 젖먹이는 젖병을 꺼내 주고, 그 뒤로는 밥그릇에 사료를 담음. 없는 것이 있으면 상점을 엶
    func feed() {
        cardUntil = now + 12
        let age = pet.age()
        if age < 21 {
            guard pet.has("bottle"), pet.count("formula") > 0 else { AppModel.shared.showMain(tab: 1, note: "젖병과 분유가 필요해요"); return }
            if !isOut("bottle"), let why = takeOut("bottle") { toast(why); return }
            toast("젖병을 집어 입에 대 주세요")
            return
        }
        guard pet.has("bowl_food") else { AppModel.shared.showMain(tab: 1, note: "밥그릇이 필요해요"); return }
        guard Catalog.foodFor(age).contains(where: { $0 != "formula" && pet.count($0) > 0 }) else { AppModel.shared.showMain(tab: 1, note: "맞는 사료가 없어요"); return }
        if !isOut("bowl_food"), let why = takeOut("bowl_food") { toast(why); return }
        if let b = prop("bowl_food") { useProp(b) }
    }

    func giveWater() {
        cardUntil = now + 12
        if pet.age() < 21 { toast("아직 젖만 먹어요"); return }
        if !isOut("bowl_water"), let why = takeOut("bowl_water") { toast(why); return }
        if let b = prop("bowl_water") { useProp(b) }
    }

    func tapProp(_ e: Entity) {
        guard now - lastGrabAt > 0.7 else { return }
        var x: Entity? = e
        var uid = ""
        while let c = x { if let t = c.components[PropTag.self] { uid = t.id; break }; x = c.parent }
        guard let p = props.first(where: { $0.uid == uid }) else { return }
        useProp(p)
    }

    private func useProp(_ p: Prop) {
        let age = pet.age()
        switch p.id {
        case "bowl_food":
            if p.fill > 0.9 { return }
            guard let fid = Catalog.foodFor(age).first(where: { $0 != "formula" && pet.count($0) > 0 }) else {
                toast(age < 21 ? "아직 젖병으로 먹어요" : "맞는 사료가 없어요")
                return
            }
            _ = pet.use(fid)
            pet.foodKind = fid
            pet.foodBowl = 1
            p.fill = 1
            SoundBank.shared.play("kibble", on: p.entity, gain: -8)
        case "bowl_water":
            if p.fill > 0.95 { return }
            pet.waterBowl = 1
            p.fill = 1
            SoundBank.shared.play("water", on: p.entity, gain: -10)
        case "pad":
            if p.fill < 0.3 { return }
            if pet.use("pad") { p.fill = 0; pet.padUses = 3; SoundBank.shared.play("rustle", on: p.entity, gain: -12) }
            else { toast("새 패드가 없어요"); if p.fill >= 0.99 { pet.placed.removeAll { $0 == "pad" }; removeProp(p) } }
        case "poop":
            guard pet.use("bag") else { toast("배변 봉투가 필요해요"); return }
            pet.poops = max(0, pet.poops - 1)
            pet.clean = min(1, pet.clean + 0.02)
            SoundBank.shared.play("rustle", on: p.entity, gain: -12)
            removeProp(p)
        case "pee":
            SoundBank.shared.play("rustle", on: p.entity, gain: -14)
            removeProp(p)
        default: break
        }
        publish()
    }

    // MARK: 매 화면
    func tick(_ dt0: Float) {
        guard !ended else { return }
        let dt = min(0.1, dt0)
        now = CACurrentMediaTime()
        if now - hourAt > 20 {
            hourAt = now
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            hour = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        }
        room.tick(now: now, dt: dt)
        if let h = room.head() {
            userPos = simd_make_float3(h.columns.3)
            var f = -simd_make_float3(h.columns.2)
            f.y = 0
            if simd_length(f) > 0.05 { userFwd = simd_normalize(f) }
            if !headOK { headOK = true; lastUser = userPos }
        }
        if !spawned { stepStart() }
        showCard()
        guard spawned else { return }
        // 바닥 높이가 바뀌면(더 정확한 바닥 면을 알아봄) 놓아 둔 것들도 따라 내려앉힘
        if let fy = room.floorY, abs(fy - lastFloor) > 0.004 {
            lastFloor = fy
            for p in props where (p.kind == .fixed || p.kind == .mess) && p.heldBy == nil {
                let q = p.pos
                p.entity.setPosition(SIMD3<Float>(q.x, fy, q.z), relativeTo: nil)
            }
        }
        // 그릇·계단은 길찾기에서 비켜 감
        var ex: [(c: SIMD2<Float>, r: Float)] = []
        for p in props where p.heldBy == nil {
            if p.id == "bowl_food" || p.id == "bowl_water" { ex.append((SIMD2<Float>(p.pos.x, p.pos.z), 0.09)) }
            else if p.id == "steps" { ex.append((SIMD2<Float>(p.pos.x, p.pos.z), 0.28)) }
        }
        room.nav.extra = ex
        live(dt)
        hands(dt)
        dog?.tick(dt)
        let hold = dog?.holding ?? false
        if hold != holding { holding = hold }
        walk(dt)
        foamShow()
        // 물리로 굴러간 것이 바닥 밑·너무 멀리 가면 내 앞으로
        if let fy = room.floorY {
            for p in props where (p.kind == .toy || p.kind == .tool) && p.heldBy == nil && !p.inMouth {
                let q = p.pos
                if q.y < fy - 0.4 || simd_distance(q, userPos) > 9 {
                    p.setVelocity(.zero)
                    p.entity.setPosition(SIMD3<Float>(userPos.x + userFwd.x * 0.6, fy + 0.2, userPos.z + userFwd.z * 0.6), relativeTo: nil)
                }
            }
        }
        if now > publishAt { publish() }
        if now > saveAt { saveAt = now + 15; saveLayout(); Store.save(pet) }
    }

    /// 강아지 메뉴 카드: 강아지 위에서 나를 봄. 강아지가 아직 없으면(준비 중) 내 앞에
    private func showCard() {
        guard let c = card else { return }
        if cardOn && now >= cardUntil { cardOn = false }
        if toastText != nil && now >= toastUntil { toastText = nil }
        let on = cardOn || toastText != nil
        if c.isEnabled != on { c.isEnabled = on }
        guard on else { return }
        var at = userPos + userFwd * 0.9 - SIMD3<Float>(0, 0.15, 0)
        if let d = dog, d.entity.isEnabled {
            at = d.headWorld + SIMD3<Float>(0, 0.24, 0)
            let v = userPos - at
            let l = simd_length(v)
            if l > 0.01 { at += v / l * min(0.15, l * 0.3) }
        }
        let l = simd_distance(userPos, at)
        c.position = at
        c.look(at: at - (userPos - at), from: at, relativeTo: nil)
        c.scale = SIMD3<Float>(repeating: min(1.6, max(0.6, l * 0.8)))
    }

    private func publish() {
        publishAt = now + 0.5
        pet.lastSim = Date().timeIntervalSince1970
        if shown != pet { shown = pet; AppModel.shared.pet = pet }
    }

    /// 여는 동안의 시간 흐름 (욕구는 현실 시간으로, 포인트는 쓴 시간으로)
    private func live(_ dt: Float) {
        let h = dt / 3600
        let st = pet.stage
        let d = st.decay
        let sleeping = pet.asleep
        let k: Float = sleeping ? 0.45 : 1
        let active: Float = (dog?.act == .zoom || dog?.act == .fetch || dog?.act == .tug) ? 6 : 1
        func c(_ v: Float) -> Float { min(1, max(0, v)) }
        pet.food = c(pet.food - d.food * h * k)
        pet.water = c(pet.water - d.water * h * k * (active > 1 ? 2 : 1))
        pet.potty = c(pet.potty - d.potty * h * k)
        pet.energy = c(pet.energy + (sleeping ? 0.22 : -0.06 * active) * h)
        if !sleeping { pet.fun = c(pet.fun - d.fun * h); pet.love = c(pet.love - d.love * h * 0.5) }
        pet.clean = c(pet.clean - 0.004 * h)
        if pet.food < 0.08 || (pet.water < 0.08 && d.water > 0) { pet.health = max(0.25, pet.health - 0.02 * h) } else { pet.health = min(1, pet.health + 0.012 * h) }
        pet.usedSec += Double(dt)
        pet.pointFrac += Double(dt) / Sim.secPerPoint
        if pet.pointFrac >= 1 { let n = Int(pet.pointFrac); pet.points += n; pet.pointFrac -= Double(n) }
    }

    // MARK: 손으로 집기·던지기·손뼉
    private func handFrame(_ h: HandState) -> simd_float4x4 {
        let z = h.fingers
        var y = h.palmN - z * simd_dot(h.palmN, z)
        y = simd_length(y) > 1e-4 ? simd_normalize(y) : SIMD3<Float>(0, 1, 0)
        let x = simd_cross(y, z)
        return simd_float4x4(SIMD4<Float>(x, 0), SIMD4<Float>(y, 0), SIMD4<Float>(z, 0), SIMD4<Float>(h.grip, 1))
    }

    private func hands(_ dt: Float) {
        let hs = room.hands
        for i in 0..<2 {
            let h = hs[i]
            let grab = h.seen && (h.pinch || h.fist)
            if let p = held[i] {
                if !h.seen {
                    if now - h.lastT > 0.25 { release(i, p, h) }
                    continue
                }
                if !grab { openN[i] += 1 } else { openN[i] = 0 }
                if openN[i] >= 2 { release(i, p, h); continue }
                let m = handFrame(h) * p.grabRel.matrix
                p.entity.setTransformMatrix(m, relativeTo: nil)
                if p.id == "shampoo", let d = dog, d.foam <= 0, simd_distance(p.pos, d.headWorld) < 0.22 * d.entity.scale.x + 0.08 {
                    if pet.use("shampoo") { d.foam = 1; toast("손으로 문질러 주세요"); SoundBank.shared.play("rustle", on: p.entity, gain: -14) }
                }
            } else if grab && !wasGrab[i] {
                // 쥔 자리가 물건 겉에 닿을 만큼 가까울 때만 잡힘 (멀리서는 안 잡힘).
                // 바닥에 놓아 둔 것(담요·그릇…)은 엄지·검지로 집을 때만, 강아지를 만지는 손·강아지가 올라가 있는 잠자리는 안 잡힘
                // (0.1.x: 둘레 원으로 재서 담요 위 강아지를 쓰다듬는 손에 담요가 딸려 옴)
                let petting = dog?.touching ?? false
                var best: Prop?
                var bd: Float = 9
                for p in props where p.kind != .mess && p.heldBy == nil && !p.inMouth {
                    var lim: Float = 0.035
                    var gp = h.fist ? h.palm : h.grip
                    if p.kind == .fixed {
                        if !h.pinch || petting { continue }
                        if let d = dog, d.entity.isEnabled, d.isOn(p) { continue }
                        gp = h.grip
                        lim = 0.02
                    } else if petting { lim = 0.015 }
                    let d = p.grabDist(gp)
                    if d < lim && d < bd { bd = d; best = p }
                }
                if let p = best {
                    if p.inMouth { continue }
                    held[i] = p
                    p.heldBy = i
                    openN[i] = 0
                    p.setMode(.kinematic)
                    let pm = p.entity.transformMatrix(relativeTo: nil)
                    p.grabRel = Transform(matrix: handFrame(h).inverse * pm)
                    grabStart[i] = (now, p.pos)
                    lastGrabAt = now
                }
            }
            wasGrab[i] = grab
        }
        // 손뼉
        if hs[0].seen && hs[1].seen {
            let gap = simd_distance(hs[0].palm, hs[1].palm)
            let closing = (palmGap - gap) / max(dt, 1e-3)
            if gap < 0.09 && closing > 0.9 && now - clapAt > 1.2 && held[0] == nil && held[1] == nil {
                clapAt = now
                dog?.heard(true)
            }
            palmGap = gap
        } else { palmGap = 1 }
    }

    private func release(_ i: Int, _ p: Prop, _ h: HandState) {
        held[i] = nil
        p.heldBy = nil
        lastGrabAt = now
        let fy = room.floorY ?? p.pos.y
        if p.kind == .fixed {
            // 바닥에 반듯하게 내려놓음. 거의 안 옮기고 바로 놓았으면 누른 것으로
            let moved = simd_distance(p.pos, grabStart[i].pos)
            let f = p.entity.orientation(relativeTo: nil).act(SIMD3<Float>(0, 0, 1))
            p.entity.setOrientation(Q.ry(atan2(f.x, f.z)), relativeTo: nil)
            if moved < 0.03 && now - grabStart[i].at < 0.6 {
                p.entity.setPosition(SIMD3<Float>(grabStart[i].pos.x, fy, grabStart[i].pos.z), relativeTo: nil)
                lastGrabAt = 0
                useProp(p)
                lastGrabAt = now
            } else {
                p.entity.setPosition(SIMD3<Float>(p.pos.x, fy, p.pos.z), relativeTo: nil)
                SoundBank.shared.play("thump", on: p.entity, gain: -22)
                saveLayout()                 // 옮겨 놓은 자리가 그대로 집이 됨
                Store.save(pet)
            }
            return
        }
        p.setMode(.dynamic)
        var v = h.seen ? h.vel : SIMD3<Float>(0, 0, 0)
        let sp = simd_length(v)
        if sp > 7 { v *= 7 / sp }
        p.setVelocity(v, spin: SIMD3<Float>(Float.random(in: -3...3), Float.random(in: -3...3), Float.random(in: -3...3)) * min(1, sp))
        p.thrownAt = now
        if p.kind == .toy && sp > 1.1 { dog?.thrown(p) }
    }

    // MARK: 산책·거품
    private func walk(_ dt: Float) {
        let moved = simd_distance(SIMD2<Float>(userPos.x, userPos.z), SIMD2<Float>(lastUser.x, lastUser.z))
        lastUser = userPos
        guard walking, let d = dog, d.entity.isEnabled else { return }
        if moved < 0.2 {
            pet.walkM += moved
            pet.fun = min(1, pet.fun + moved * 0.01)
            pet.energy = max(0, pet.energy - moved * 0.0008)
            pet.bond = min(1, pet.bond + moved * 0.0004)
        }
        // 줄: 강아지 목 ↔ 내 손(없으면 허리께)
        let a = d.headWorld - SIMD3<Float>(0, 0.03, 0)
        var b = userPos - SIMD3<Float>(0, 0.55, 0)
        if let h = room.hands.first(where: { $0.seen && $0.right }) ?? room.hands.first(where: { $0.seen }) { b = h.palm }
        let v = b - a
        let l = simd_length(v)
        if leash == nil {
            let e = ModelEntity(mesh: .generateBox(width: 0.006, height: 1, depth: 0.003), materials: [Geo.mat(SIMD3<Float>(0.75, 0.25, 0.22), rough: 0.9)])
            root.addChild(e)
            leash = e
        }
        guard let e = leash, l > 0.05 else { return }
        e.isEnabled = true
        e.position = (a + b) * 0.5
        e.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: v / l)
        e.scale = SIMD3<Float>(1, l, 1)
    }

    private func foamShow() {
        guard let d = dog else { return }
        if d.foam > 0 && foamBalls.isEmpty {
            let m = UnlitMaterial(color: UIColor(white: 0.97, alpha: 1))
            for i in 0..<14 {
                let a = Float(i) * 2.4
                let e = ModelEntity(mesh: .generateSphere(radius: 0.016 + 0.006 * Float(i % 3)), materials: [m])
                e.position = SIMD3<Float>(cos(a) * 0.05, 0.19 + 0.02 * sin(a * 1.7), -0.08 + 0.02 * Float(i))
                d.entity.addChild(e)
                foamBalls.append(e)
            }
        }
        for (i, e) in foamBalls.enumerated() {
            let on = d.foam > Float(i) / 14
            if e.isEnabled != on { e.isEnabled = on }
        }
    }
}
