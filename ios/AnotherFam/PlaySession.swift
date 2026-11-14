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
    var canRehome = false                // 지난 자리를 못 찾을 때: '여기에 새로 자리 잡기' 단추
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
    @ObservationIgnored let ear = VoiceEar()                    // 사람 목소리 (말로 부르기·시키기)
    @ObservationIgnored private var homeLost = false             // 저장된 집 고정점이 기기에 없음 → 기다리지 않고 새로 만들어 확정
    @ObservationIgnored private var oldHomeId: UUID?           // 지난 집을 제때 못 찾아 임시 집을 만든 동안: 늦게라도 찾으면 원래 자리로
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
        root.components.set(PhysicsSimulationComponent())      // 물리 기준을 공간 하나로 (중력 9.8m/s²)
        room.onAnchor = { [weak self] a, removed in self?.anchor(a, removed) }
        if let s = UserDefaults.standard.string(forKey: "af.home"), let id = UUID(uuidString: s) { homeId = id }
        now = CACurrentMediaTime()
        if let note = await room.start() { toast(note) }
        ear.onWord = { [weak self] w in self?.dog?.hear(w) }
        Task { if let why = await ear.start() { toast(why) } }
        now = CACurrentMediaTime()
        startAt = now
        homeWaitUntil = now + 15
        // 지난 자리(공간 고정점)는 절대 저절로 바꾸지 않음. 찾을 때까지 기다리고, 15초가 지나면 '여기에 새로 자리 잡기'를 보여 줌.
        // (0.4~0.7: 몇 초 안에 못 찾으면 시선 앞에 새 자리를 만들어, 같은 자리에서 다시 켜도 점점 옆으로 밀리고 가구 밑에도 생겼음.
        //  0.6 의 allAnchors 확인은 방을 다시 알아보기 전엔 빈 목록이라 '없어짐'으로 잘못 판단해 매번 새 자리를 만들었음)
        if let h = homeId {
            Task {
                // 방을 알아본 뒤(목록이 비어 있지 않음)에도 없을 때만 '없어짐'
                guard let ids = await room.savedAnchorIds(), !ids.isEmpty, !ids.contains(h) else { return }
                homeLost = true
            }
        }
        if let d = Dog(self) {
            dog = d
            d.entity.isEnabled = false
            root.addChild(d.entity)
        } else { toast("강아지 모델을 읽지 못했어요") }
    }

    func stop() {
        guard !ended else { return }
        ended = true
        ear.stop()
        room.stop()
        saveLayout()
        pet.lastSim = Date().timeIntervalSince1970
        AppModel.shared.pet = pet
        Store.save(pet, force: true)
        if AppModel.shared.session === self { AppModel.shared.session = nil }
        AppModel.shared.playClosed()
    }

    func attachCard(_ e: Entity) {
        card = e
        e.isEnabled = false
        root.addChild(e)
    }

    /// 눈에서 판(가운데·네 모서리)까지 가는 길에 처음 부딪히는 것까지의 거리 (판·강아지는 빼고). 없으면 아주 큰 값
    private func freeDist(eye: SIMD3<Float>, center: SIMD3<Float>, halfW: Float, halfH: Float, skip: [Entity]) -> Float {
        guard let sc = root.scene else { return .infinity }
        let fwd = simd_normalize(center - eye)
        var r = simd_cross(SIMD3<Float>(0, 1, 0), fwd)
        r = simd_length(r) > 1e-3 ? simd_normalize(r) : SIMD3<Float>(1, 0, 0)
        let up = simd_cross(fwd, r)
        var best = Float.infinity
        for (sx, sy) in [(Float(0), Float(0)), (1, 1), (-1, 1), (1, -1), (-1, -1)] {
            let p = center + r * (halfW * sx) + up * (halfH * sy)
            let len = simd_distance(eye, p)
            for h in sc.raycast(from: eye, to: eye + (p - eye) / len * (len + 0.05), query: .all, mask: .all, relativeTo: nil) {
                if skip.contains(where: { under(h.entity, $0) }) { continue }
                if let d = dog, under(h.entity, d.entity) { continue }
                if props.contains(where: { $0.heldBy != nil && under(h.entity, $0.entity) }) { continue }
                // 판 쪽 거리로 바꿔 셈 (모서리 길은 가운데보다 김)
                best = min(best, h.distance * simd_distance(eye, center) / len)
            }
        }
        return best
    }

    /// 이 자리 바로 아래로 처음 닿는 면의 높이 — 스캔한 가구(소파·탁자 등)·바닥·바닥에 놓은 것 (강아지·장난감·카드는 뺌)
    func surfaceBelow(_ p: SIMD3<Float>, from top: Float, roomOnly: Bool = false) -> Float? {
        guard let sc = root.scene else { return nil }
        let fy = room.floorY ?? p.y
        let a = SIMD3<Float>(p.x, top, p.z), b = SIMD3<Float>(p.x, fy - 0.05, p.z)
        var best: Float?
        for h in sc.raycast(from: a, to: b, query: .all, mask: .all, relativeTo: nil) {
            if let d = dog, under(h.entity, d.entity) { continue }
            if let c = card, under(h.entity, c) { continue }
            if props.contains(where: { ($0.kind != .fixed || roomOnly) && under(h.entity, $0.entity) }) { continue }
            best = max(best ?? -999, h.position.y)
        }
        return best
    }

    private func under(_ e: Entity, _ a: Entity) -> Bool {
        var x: Entity? = e
        while let y = x { if y === a { return true }; x = y.parent }
        return false
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
                canRehome = false
            }
        } else if a.id == oldHomeId {
            // 지난 집을 늦게 찾음: 임시 집에 놓았던 것들을 원래 자리로 되돌림
            if !removed && a.isTracked { restoreHome(a) }
        } else if !removed && !makingHome {
            Task { await room.removeAnchor(a.id) }
        }
    }

    /// 임시 집 → 늦게 찾은 지난 집. 꺼내 둔 것들을 저장된 자리로 옮기고 강아지도 잠자리로
    private func restoreHome(_ a: WorldAnchor) {
        guard let old = oldHomeId else { return }
        let temp = homeId
        oldHomeId = nil
        homeId = old
        homeM = a.originFromAnchorTransform
        homeNew = false
        if let t = temp, t != old { Task { await room.removeAnchor(t) } }
        guard spawned, let fy = room.floorY else { return }
        for p in props where p.kind == .fixed || p.kind == .toy {
            guard p.heldBy == nil, !p.inMouth, let l = pet.layout[p.id], let w = toWorld(l) else { continue }
            var at = w.0
            at.y = p.kind == .fixed ? fy : max(at.y, fy) + 0.03
            if p.kind == .toy { p.setVelocity(.zero) }
            p.entity.setPosition(at, relativeTo: nil)
            p.entity.setOrientation(Q.ry(w.1), relativeTo: nil)
        }
        settleFixed()
        if let d = dog, d.entity.isEnabled, !d.holding, let b = prop("bed") ?? prop("blanket") {
            d.place(at: SIMD3<Float>(b.pos.x, fy, b.pos.z), yaw: d.yaw)
        }
    }

    /// 임시 집을 그대로 집으로 삼음 (임시 집에서 내가 물건을 옮기거나 꺼냈을 때)
    private func commitHome() {
        guard let old = oldHomeId, let id = homeId else { return }
        oldHomeId = nil
        UserDefaults.standard.set(id.uuidString, forKey: "af.home")
        Task { await room.removeAnchor(old) }
    }

    private func makeHome() {
        guard !makingHome, let fy = room.floorY, headOK else { return }
        makingHome = true
        canRehome = false
        let f = userFwd
        // 내 앞 1.1m 근처, 둘레 35cm 가 빈 바닥이면서 위가 트인(탁자·가구 밑이 아닌) 자리
        let want = SIMD2<Float>(userPos.x + f.x * 1.1, userPos.z + f.z * 1.1)
        let q = clearSpot(near: want, half: 0.35, within: 1.4) ?? want
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(q.x, fy, q.y, 1)
        let old = homeId
        oldHomeId = nil
        Task {
            if let id = await room.addAnchor(m) {
                homeId = id
                UserDefaults.standard.set(id.uuidString, forKey: "af.home")
                if let o = old, o != id { await room.removeAnchor(o) }
            }
            homeM = m
            homeNew = true
            makingHome = false
        }
    }

    /// 사람이 고른 새 자리 (지난 자리를 찾지 못했을 때만)
    func rehome() {
        guard homeM == nil, !makingHome else { return }
        makeHome()
    }

    /// 바닥에 물건을 둘 만한 자리: 길찾기 칸이 비어 있고, 가운데·네 모서리 위로 1.5m 안에 가구가 없음(탁자·소파 밑 아님)
    func clearSpot(near want: SIMD2<Float>, half: Float, within: Float) -> SIMD2<Float>? {
        guard let fy = room.floorY else { return nil }
        func clear(_ q: SIMD2<Float>) -> Bool {
            if !(room.nav.open || room.nav.walkable(q.x, q.y)) { return false }
            for (dx, dz) in [(Float(0), Float(0)), (half, half), (-half, half), (half, -half), (-half, -half)] {
                let p = SIMD3<Float>(q.x + dx, fy, q.y + dz)
                if !(room.nav.open || room.nav.walkable(p.x, p.z)) { return false }
                if let top = surfaceBelow(p, from: fy + 1.5, roomOnly: true), top > fy + 0.04 { return false }
            }
            return true
        }
        if clear(want) { return want }
        var r: Float = 0.12
        while r <= within {
            let n = max(8, Int(2 * Float.pi * r / 0.12))
            for i in 0..<n {
                let a = Float(i) / Float(n) * 2 * .pi
                let q = want + SIMD2<Float>(cos(a), sin(a)) * r
                if clear(q) { return q }
            }
            r += 0.12
        }
        return nil
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
            if homeId != nil {
                // 지난 자리: 찾을 때까지 기다림 (저절로 옮기지 않음)
                if homeLost { note("지난 자리를 찾지 못했어요"); canRehome = true }
                else {
                    note("지난번 자리를 찾는 중 · 그쪽을 둘러봐 주세요")
                    if now > homeWaitUntil { canRehome = true }
                }
                return
            }
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
        // 임시 집인 동안은 저장하지 않음 (지난 집 기준 자리를 덮어쓰지 않게)
        guard let m = homeM, oldHomeId == nil else { return }
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
        for (i, p) in props.filter({ $0.id == "poop" }).prefix(6).enumerated() {
            let w = p.pos
            let l = inv * SIMD4<Float>(w.x, w.y, w.z, 1)
            lay["_poop\(i)"] = [l.x, l.y, l.z, 0]
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
                    // 위가 트인 빈 바닥만 (탁자·가구 밑에 생겨 보이지도 잡히지도 않았음)
                    if let q = clearSpot(near: SIMD2<Float>(c.x, c.z), half: 0.18, within: 0.3) { at = SIMD3<Float>(q.x, fy, q.y); break }
                }
                at.y = fy + (p.kind == .fixed ? 0 : 0.05)
            }
            add(p, at: at, yaw: yaw)
            if id == "bowl_food" { p.fill = pet.foodBowl }
            if id == "bowl_water" { p.fill = pet.waterBowl }
            if id == "pad" { p.fill = 1 - Float(min(3, pet.padUses)) / 3 }
        }
        // 치우지 않은 똥: 저장된 자리 그대로. 자리가 없는 것(앱을 끈 동안 생긴 것)은 잠자리 곁의 위가 트인 빈 바닥에 한 번 정해 저장
        // (0.7.0 까지: 켤 때마다 '내 앞 1.4m' 둘레 아무 곳에 새로 놓아 매번 자리가 바뀌고 가구 밑에도 생겼음)
        for i in 0..<min(6, pet.poops) {
            if let l = pet.layout["_poop\(i)"], let w = toWorld(l) { addMessProp("poop", at: SIMD3<Float>(w.0.x, fy, w.0.z)); continue }
            let c = prop("bed")?.pos ?? prop("blanket")?.pos ?? base
            let a = Float(i) * 2.1 + 0.7
            let want = SIMD2<Float>(c.x + cos(a) * 0.55, c.z + sin(a) * 0.55)
            let q = clearSpot(near: want, half: 0.06, within: 0.8) ?? want
            addMessProp("poop", at: SIMD3<Float>(q.x, fy, q.y))
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
        settleFixed()
        loading = false
        // 어느 길로 놓였는지 알림 (자리 문제 원인 확인용)
        toast(homeNew ? "새 자리에 놓았어요" : "지난 자리 그대로예요")
        saveLayout()
    }

    /// 바닥에 놓는 것의 높이: 아래에 깔린 담요·패드·방석이 있으면 그 위 (0.4.0: 담요 위에 놓인 그릇·똥이 담요에 묻혔음)
    private func restY(_ p: Prop, _ x: Float, _ z: Float) -> Float {
        let fy = room.floorY ?? p.pos.y
        var y = fy
        for q in props where q !== p && q.kind == .fixed && q.heldBy == nil {
            if let t = q.top(at: SIMD3<Float>(x, fy, z)) { y = max(y, q.pos.y + t) }
        }
        return y
    }

    /// 바닥에 놓인 것들을 차례로 내려앉힘 (깔개 먼저, 그 위에 그릇·패드·치울 것)
    private func settleFixed() {
        let flat: Set<String> = ["blanket", "pad", "bed"]
        let list = props.filter { ($0.kind == .fixed || $0.kind == .mess) && $0.heldBy == nil }
        for p in list.filter({ flat.contains($0.id) }) + list.filter({ !flat.contains($0.id) }) {
            let q = p.pos
            let y = flat.contains(p.id) ? (room.floorY ?? q.y) : restY(p, q.x, q.z)
            if abs(q.y - y) > 0.0005 { p.entity.setPosition(SIMD3<Float>(q.x, y, q.z), relativeTo: nil) }
        }
    }

    private func add(_ p: Prop, at: SIMD3<Float>, yaw: Float) {
        p.entity.position = at
        p.entity.orientation = Q.ry(yaw)
        root.addChild(p.entity)
        props.append(p)
        p.started()
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
        commitHome()
        let f = userFwd
        let kindProbe = Prop(id)
        if kindProbe.kind == .fixed || kindProbe.kind == .toy {
            if pet.placed.contains(id) { return "이미 꺼내 두었어요" }
            if id == "pad" { guard pet.use("pad") else { return "패드가 없어요" }; pet.padUses = 3 }
            pet.placed.append(id)
        } else if id == "treat" || id == "dental" {
            guard pet.use(id) else { return "남은 것이 없어요" }
        } else if props.contains(where: { $0.id == id }) { return "이미 꺼내 두었어요" }
        // 손에 쥘 것은 오른손 앞 아래에 (0.5.0: 바로 앞 가슴 높이라 강아지 위 카드와 겹쳐 보였음)
        var at = userPos + f * 0.42 + SIMD3<Float>(-f.z, 0, f.x) * 0.2
        at.y = max(fy + 0.1, userPos.y - 0.5)
        if kindProbe.kind == .fixed {
            let want = SIMD2<Float>(userPos.x + f.x * 0.8, userPos.z + f.z * 0.8)
            let q = clearSpot(near: want, half: 0.22, within: 1.0) ?? want
            at = SIMD3<Float>(q.x, fy, q.y)
        }
        add(kindProbe, at: at, yaw: atan2(-f.x, -f.z))
        if kindProbe.kind == .fixed { settleFixed() }
        if kindProbe.kind == .tool { kindProbe.setMode(.kinematic) }       // 손에 쥘 것은 집을 때까지 내 앞에 떠 있음
        saveLayout()
        if id == "bowl_food" { kindProbe.fill = pet.foodBowl }
        if id == "bowl_water" { kindProbe.fill = pet.waterBowl }
        publish()
        return nil
    }

    func putBack(_ id: String) {
        commitHome()
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
        if id == "poop" { saveLayout() }
    }

    private func addMessProp(_ id: String, at: SIMD3<Float>) {
        let p = Prop(id)
        var q = at
        q.y = room.floorY ?? at.y
        add(p, at: q, yaw: Float.random(in: 0...6))
        q.y = restY(p, q.x, q.z)
        p.entity.setPosition(q, relativeTo: nil)
    }

    func padFull(_ pad: Prop) { toast("패드를 갈아 주세요") }

    // MARK: 누르기 (멀리서 바라보고 집기)
    /// 강아지를 바라보고 집기 → 메뉴 카드.
    /// 쓰다듬기·안기처럼 손이 강아지에 닿아 생긴 탭은 무시 (0.4.0: 만질 때마다 카드가 떴음 — 손가락이 몸에 닿는 것도 시스템이 탭으로 보냄)
    func tapDog() {
        guard now - lastGrabAt > 0.7, let d = dog else { return }
        if d.holding || d.touching || now - d.lastTouchAt < 1.5 { return }
        let c = d.bodyWorld
        let reach: Float = 0.12 + 0.2 * d.entity.scale.x
        for h in room.hands where h.seen {
            if simd_distance(h.palm, c) < reach + 0.1 || simd_distance(h.index, c) < reach + 0.06 { return }
        }
        cardOn.toggle()
        cardUntil = now + 15
    }

    // MARK: 강아지 메뉴 (강아지를 누르면 뜨는 카드의 단추)
    func closeCard() { cardOn = false }

    /// 밥 주기: 젖먹이는 젖병을 꺼내 주고, 그 뒤로는 밥그릇에 사료를 담음. 없는 것이 있으면 상점을 엶
    func feed() {
        cardUntil = now + 12
        let age = pet.age()
        if age < 21 {
            guard pet.has("bottle"), pet.count("formula") > 0 || pet.bottle > 0.01 else { AppModel.shared.showMain(tab: 2, note: "젖병과 분유가 필요해요"); return }
            if !isOut("bottle"), let why = takeOut("bottle") { toast(why); return }
            toast("젖병을 집어 입에 대 주세요")
            return
        }
        guard pet.has("bowl_food") else { AppModel.shared.showMain(tab: 2, note: "밥그릇이 필요해요"); return }
        guard Catalog.foodFor(age).contains(where: { $0 != "formula" && pet.count($0) > 0 }) else { AppModel.shared.showMain(tab: 2, note: "맞는 사료가 없어요"); return }
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
            saveLayout()
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
        ear.tick(now: now)
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
            settleFixed()
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
    @ObservationIgnored private var cardGoal: (at: SIMD3<Float>, k: Float, from: SIMD3<Float>)?

    /// 카드 자리: 뜰 때 한 번 정하고 그대로 둠 (0.7.0 까지 매 화면 강아지 머리를 따라가 강아지가 움직이면 같이 흔들려 어지러웠음).
    /// 강아지가 50cm 넘게 옮겨 가거나 내가 60cm 넘게 움직였을 때만 새 자리로 부드럽게 옮김
    private func showCard() {
        guard let c = card else { return }
        if cardOn && now >= cardUntil { cardOn = false }
        if toastText != nil && now >= toastUntil { toastText = nil }
        let on = cardOn || toastText != nil
        if c.isEnabled != on { c.isEnabled = on }
        guard on else { cardGoal = nil; return }
        let want = cardSpot(c)
        if let g = cardGoal {
            if simd_distance(g.at, want.at) > 0.5 || simd_distance(g.from, userPos) > 0.6 { cardGoal = (want.at, want.k, userPos) }
        } else {
            cardGoal = (want.at, want.k, userPos)
            c.position = want.at
            c.scale = SIMD3<Float>(repeating: want.k)
        }
        guard let g = cardGoal else { return }
        let a = min(1, Float(1.0 / 60.0) * 5)
        c.position += (g.at - c.position) * a
        let k = c.scale.x + (g.k - c.scale.x) * a
        c.scale = SIMD3<Float>(repeating: k)
        c.look(at: c.position - (g.from - c.position), from: c.position, relativeTo: nil)
    }

    /// 카드가 있을 곳: 강아지 몸 위(머리처럼 흔들리는 곳이 아닌 서 있는 자리 기준), 나를 향해 조금 앞. 앞을 가리는 것이 있으면 그보다 가까이
    private func cardSpot(_ c: Entity) -> (at: SIMD3<Float>, k: Float) {
        var at = userPos + userFwd * 0.9 - SIMD3<Float>(0, 0.15, 0)
        var k = min(1.8, max(0.8, simd_distance(userPos, at) * 0.85))
        if let d = dog, d.entity.isEnabled {
            let g = d.entity.scale.x
            at = SIMD3<Float>(d.pos.x, d.pos.y + 0.36 * g, d.pos.z)
            k = min(1.8, max(0.8, simd_distance(userPos, at) * 0.85))
            at.y += 0.12 + 0.17 * k
            let v = userPos - at
            let l = simd_length(v)
            if l > 0.01 { at += v / l * min(0.15, l * 0.3) }
        }
        let d0 = simd_distance(userPos, at)
        if d0 > 0.3 {
            let b = c.visualBounds(relativeTo: c).extents
            let fr = freeDist(eye: userPos, center: at, halfW: b.x * k / 2, halfH: b.y * k / 2, skip: [c])
            if fr < d0 {
                let nd = max(0.4, fr - 0.06)
                at = userPos + (at - userPos) * (nd / d0)
                k *= nd / d0
            }
        }
        return (at, k)
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
                settleFixed()
                lastGrabAt = 0
                useProp(p)
                lastGrabAt = now
            } else {
                p.entity.setPosition(SIMD3<Float>(p.pos.x, fy, p.pos.z), relativeTo: nil)
                settleFixed()
                SoundBank.shared.play("thump", on: p.entity, gain: -22)
                commitHome()
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
        if p.kind == .toy { if sp > 1.1 { dog?.thrown(p) } else { dog?.noticed(p) } }      // 던지면 쫓아가고, 곁에 내려놓으면 다가와 봄
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
