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
    // 0.10.0 자리: 고정점은 처음 알려 준 자리 그대로가 아니라, 비전프로가 방을 다시 알아보며 고쳐 주는 자리를 끝까지 따라감
    @ObservationIgnored private var homeApplied: simd_float4x4?           // 지금 물건들이 놓인 기준이 된 집 고정점
    @ObservationIgnored private var homeFirstAt: Double = 0
    @ObservationIgnored private var homeMovedAt: Double = 0
    @ObservationIgnored private var propAnchor: [String: UUID] = [:]      // 바닥 물건(담요·그릇·방석·패드·계단)마다 자기 고정점
    @ObservationIgnored private var anchorM: [UUID: simd_float4x4] = [:]
    @ObservationIgnored private var anchorApplied: [UUID: simd_float4x4] = [:]
    @ObservationIgnored private var adding = 0
    @ObservationIgnored private var beatAt: Double = 0
    @ObservationIgnored private var tools = ToolWork()
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
        if let m = UserDefaults.standard.dictionary(forKey: "af.anchors") as? [String: String] {
            for (k, v) in m { if let id = UUID(uuidString: v) { propAnchor[k] = id } }
        }
        // 함께 있는 동안은 아이폰 알림을 멈추게 알림 (폰은 이 표시가 있는 동안 알림을 예약하지 않음)
        pet.together = true
        Store.save(pet, force: true)
        beatAt = CACurrentMediaTime() + 1200
        now = CACurrentMediaTime()
        if let note = await room.start() { toast(note) }
        ear.onWord = { [weak self] w in self?.dog?.hear(w) }
        ear.hint(Dog.cueWords + [pet.name] + Array(pet.words.keys))
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
        pet.together = false
        AppModel.shared.pet = pet
        Store.saveFinal(pet)
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
            // 손에 든 것은 빼고 (0.9: 패드를 들고 방석 위를 지나가면 강아지가 패드 위로 옮겨졌다 돌아왔음)
            if props.contains(where: { ($0.kind != .fixed || roomOnly || $0.heldBy != nil) && under(h.entity, $0.entity) }) { continue }
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
    /// 바탕 종류로 찾기 (담요 자리에 쿠션 매트를 깔았어도 잠자리로 — 0.10.7)
    func propBase(_ b: String) -> Prop? { props.first { $0.id == b } ?? props.first { $0.base == b } }

    // MARK: 집 자리 (방에 고정한 기준점 — 물건 자리를 다음에도 그대로)
    // 0.10.0 진짜 원인: 비전프로는 다시 켠 직후 고정점을 '아직 방을 다 알아보기 전의 어림 자리'로 먼저 알려 주고,
    // 방을 알아볼수록(둘러볼수록) 고친 자리를 계속 다시 알려 줌. 0.9 까지는 처음 온 자리에 한 번 놓고 고친 자리는 무시했고,
    // 저장할 때는 고친 자리를 기준으로 셈 → 어긋남이 저장에 그대로 들어가 켤 때마다 쌓이고(점점 한쪽으로), 시작한 곳·시선에 따라 달라졌음.
    // 이제: 고정점이 움직이면 그 차이만큼 물건·강아지를 함께 옮기고, 자리가 멈춘 뒤에 보여 주며, 바닥 물건은 저마다 자기 고정점에 붙임
    private func anchor(_ a: WorldAnchor, _ removed: Bool) {
        if removed { anchorM[a.id] = nil; return }
        let pinned = propAnchor.values.contains(a.id)
        if a.id == homeId {
            guard a.isTracked else { return }
            let m = a.originFromAnchorTransform
            let t = CACurrentMediaTime()
            if homeM == nil { homeFirstAt = t; homeMovedAt = t }
            else if let o = homeM, PlaySession.moved(m * o.inverse, 0.01) { homeMovedAt = t }
            homeM = m
            canRehome = false
            if spawned { followHome() }
        } else if pinned {
            guard a.isTracked else { return }
            anchorM[a.id] = a.originFromAnchorTransform
            if spawned, let k = propAnchor.first(where: { $0.value == a.id })?.key, let p = prop(k) { followAnchor(p, a.id) }
        } else if a.id == oldHomeId {
            if a.isTracked { restoreHome(a) }
        } else if adding == 0 && !makingHome {
            Task { await room.removeAnchor(a.id) }          // 지난번에 쓰고 버린 고정점 정리
        }
    }

    /// 변환이 문턱보다 크게 움직였는지 (자리 mm 단위 떨림은 무시)
    private static func moved(_ d: simd_float4x4, _ lim: Float = 0.004) -> Bool {
        let t = SIMD3<Float>(d.columns.3.x, d.columns.3.y, d.columns.3.z)
        let yaw = abs(atan2(d.columns.2.x, d.columns.2.z))
        return simd_length(t) > lim || yaw > lim * 0.8
    }

    private static func yawOf(_ m: simd_float4x4) -> Float { atan2(m.columns.2.x, m.columns.2.z) }

    private static func pose(_ p: SIMD3<Float>, yaw: Float) -> simd_float4x4 {
        var m = simd_float4x4(Q.ry(yaw))
        m.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
        return m
    }

    /// 집 고정점이 고쳐짐: 그만큼 강아지·장난감·치울 것·(자기 고정점이 아직 없는) 바닥 물건을 함께 옮김
    private func followHome() {
        guard let m = homeM else { return }
        guard let a = homeApplied else { homeApplied = m; return }
        let d = m * a.inverse
        guard PlaySession.moved(d) else { return }
        homeApplied = m
        let dy = PlaySession.yawOf(d)
        let fy = room.floorY
        for p in props where p.heldBy == nil && !p.inMouth {
            if p.kind == .fixed, let id = propAnchor[p.id], anchorM[id] != nil { continue }
            let w = d * SIMD4<Float>(p.pos.x, p.pos.y, p.pos.z, 1)
            var q = SIMD3<Float>(w.x, w.y, w.z)
            if let fy, p.kind != .toy && p.kind != .tool { q.y = fy }
            if p.kind == .toy { p.setVelocity(.zero) }
            p.entity.setPosition(q, relativeTo: nil)
            p.entity.setOrientation(Q.ry(dy) * p.entity.orientation(relativeTo: nil), relativeTo: nil)
        }
        dog?.shift(d)
        settleFixed()
    }

    /// 바닥 물건 하나를 자기 고정점 자리로 (강아지가 그 위에 있었으면 같이)
    private func followAnchor(_ p: Prop, _ id: UUID) {
        guard p.heldBy == nil, let m = anchorM[id] else { return }
        if let ap = anchorApplied[id], !PlaySession.moved(m * ap.inverse) { return }
        anchorApplied[id] = m
        let fy = room.floorY ?? m.columns.3.y
        let before = PlaySession.pose(p.pos, yaw: PlaySession.yawOf(p.entity.transformMatrix(relativeTo: nil)))
        let on = dog.map { $0.entity.isEnabled && $0.isOn(p) } ?? false
        let at = SIMD3<Float>(m.columns.3.x, fy, m.columns.3.z)
        p.entity.setPosition(at, relativeTo: nil)
        p.entity.setOrientation(Q.ry(PlaySession.yawOf(m)), relativeTo: nil)
        settleFixed()
        if on, let d = dog { d.shift(PlaySession.pose(p.pos, yaw: PlaySession.yawOf(m)) * before.inverse) }
    }

    /// 바닥 물건을 지금 자리에 고정 (꺼내거나 옮겨 놓았을 때). 예전 고정점은 지움
    private func pinProp(_ p: Prop) {
        guard p.kind == .fixed, spawned else { return }
        let m = PlaySession.pose(SIMD3<Float>(p.pos.x, room.floorY ?? p.pos.y, p.pos.z), yaw: PlaySession.yawOf(p.entity.transformMatrix(relativeTo: nil)))
        let key = p.id
        let old = propAnchor[key]
        adding += 1
        Task {
            let id = await room.addAnchor(m)
            adding -= 1
            guard let id else { return }
            guard prop(key) != nil else { await room.removeAnchor(id); return }
            propAnchor[key] = id
            anchorM[id] = m
            anchorApplied[id] = m
            savePins()
            if let o = old, o != id { anchorM[o] = nil; anchorApplied[o] = nil; await room.removeAnchor(o) }
        }
    }

    private func unpinProp(_ key: String) {
        guard let id = propAnchor[key] else { return }
        propAnchor[key] = nil
        anchorM[id] = nil
        anchorApplied[id] = nil
        savePins()
        Task { await room.removeAnchor(id) }
    }

    private func savePins() {
        var d: [String: String] = [:]
        for (k, v) in propAnchor { d[k] = v.uuidString }
        UserDefaults.standard.set(d, forKey: "af.anchors")
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
        if let d = dog, d.entity.isEnabled, !d.holding, let b = propBase("bed") ?? propBase("blanket") {
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
            homeApplied = nil
            homeFirstAt = CACurrentMediaTime()
            homeMovedAt = homeFirstAt
            homeNew = true
            makingHome = false
            // 새 자리: 예전 물건 고정점은 버림 (다른 곳에 새로 놓으므로)
            for k in Array(propAnchor.keys) { unpinProp(k) }
            pet.layout = [:]
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
        // 같은 거리라면 나와 가까운 쪽부터 (0.9 까지 늘 +x 쪽부터 찾아 자리가 한쪽으로 치우쳤음)
        let me = SIMD2<Float>(userPos.x, userPos.z)
        var r: Float = 0.12
        while r <= within {
            let n = max(8, Int(2 * Float.pi * r / 0.12))
            var cands: [SIMD2<Float>] = []
            for i in 0..<n {
                let a = Float(i) / Float(n) * 2 * .pi
                cands.append(want + SIMD2<Float>(cos(a), sin(a)) * r)
            }
            cands.sort { simd_distance($0, me) < simd_distance($1, me) }
            for q in cands where clear(q) { return q }
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
        // 지난 자리: 비전프로가 방을 다시 알아보며 고정점을 고치는 동안은 기다림 (1.5초 동안 1cm 넘게 안 움직이면, 길어도 10초)
        if !homeNew && !(now - homeMovedAt > 1.5 || now - homeFirstAt > 10) { note("지난 자리를 맞추는 중"); return }
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
        // 물건이 실제로 따라 놓인 기준(homeApplied)으로 셈 — 기준과 저장 기준이 다르면 어긋남이 저장에 쌓임 (0.9 까지의 원인)
        guard let m = homeApplied ?? homeM, oldHomeId == nil, spawned else { return }
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
        homeApplied = homeM
        var repin: [Prop] = []
        for id in pet.placed {
            let p = Prop(id)
            var at = SIMD3<Float>(0, 0, 0), yaw: Float = 0
            if p.kind == .fixed, let aid = propAnchor[id], let m = anchorM[aid] {
                // 자기 고정점을 이미 찾음: 그 자리 그대로
                at = SIMD3<Float>(m.columns.3.x, fy, m.columns.3.z); yaw = PlaySession.yawOf(m)
                anchorApplied[aid] = m
            } else if let l = pet.layout[id], let w = toWorld(l) {
                at = w.0; yaw = w.1
                if p.kind == .fixed {
                    at.y = fy
                    // 자기 고정점이 없는 예전 자료: 집 기준 자리가 가구와 겹치면 가까운 빈 바닥으로 옮기고 새로 고정
                    if propAnchor[id] == nil {
                        if let q = clearSpot(near: SIMD2<Float>(at.x, at.z), half: 0.18, within: 0.8) { at.x = q.x; at.z = q.y }
                        repin.append(p)
                    }
                } else {
                    at.y = max(at.y, fy) + 0.03
                    if let q = clearSpot(near: SIMD2<Float>(at.x, at.z), half: 0.05, within: 0.6) { at.x = q.x; at.z = q.y }
                }
            }
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
            if p.kind == .fixed && propAnchor[id] == nil && !repin.contains(where: { $0 === p }) { repin.append(p) }
        }
        // 치우지 않은 똥: 저장된 자리 그대로. 자리가 없는 것(앱을 끈 동안 생긴 것)은 잠자리 곁의 위가 트인 빈 바닥에 한 번 정해 저장
        // (0.7.0 까지: 켤 때마다 '내 앞 1.4m' 둘레 아무 곳에 새로 놓아 매번 자리가 바뀌고 가구 밑에도 생겼음)
        for i in 0..<min(6, pet.poops) {
            if let l = pet.layout["_poop\(i)"], let w = toWorld(l) { addMessProp("poop", at: SIMD3<Float>(w.0.x, fy, w.0.z)); continue }
            let c = propBase("bed")?.pos ?? propBase("blanket")?.pos ?? base
            let a = Float(i) * 2.1 + 0.7
            let want = SIMD2<Float>(c.x + cos(a) * 0.55, c.z + sin(a) * 0.55)
            let q = clearSpot(near: want, half: 0.06, within: 0.8) ?? want
            addMessProp("poop", at: SIMD3<Float>(q.x, fy, q.y))
        }
        if let d = dog {
            var at = base
            var yaw = atan2(-f.x, -f.z)
            if let b = propBase("bed") ?? propBase("blanket") { at = b.pos }
            else if let l = pet.layout["_dog"], let w = toWorld(l) { at = w.0; yaw = w.1 }
            at.y = fy
            d.place(at: at, yaw: yaw)
            d.entity.isEnabled = true
            d.arrive()
        }
        settleFixed()
        loading = false
        spawned = true
        for p in repin { pinProp(p) }
        if homeNew { toast("새 자리에 놓았어요") }
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
        for p in list.filter({ flat.contains($0.base) }) + list.filter({ !flat.contains($0.base) }) {
            let q = p.pos
            let y = flat.contains(p.base) ? (room.floorY ?? q.y) : restY(p, q.x, q.z)
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
    /// 손에 쥐고 쓰는 것 (0.10.0: 사료 봉지·물병·새 패드·배변 봉투도 실제처럼 손에 들고 씀)
    static let handTools: Set<String> = ["bottle", "brush", "treat", "dental", "shampoo", "foodbag", "jug", "padsheet", "bag"]

    /// 반환: 안 될 때 까닭
    func takeOut(_ id: String) -> String? {
        guard spawned, let fy = room.floorY else { return "공간을 알아보는 중이에요" }
        commitHome()
        let f = userFwd
        var key = id
        var foodId = ""
        // 보관함의 사료 = 사료 봉지, 패드 = 손에 든 새 패드 한 장, 배변 봉투 = 손에 든 봉투 한 장
        if Catalog.item(id)?.cat == .food && !Catalog.isTreat(id) && id != "formula" { foodId = id; key = "foodbag" }
        if id == "pad" { key = "padsheet" }
        let kindProbe = Prop(key)
        if key == "foodbag" {
            if let b = prop("foodbag") { if !foodId.isEmpty { b.foodId = foodId }; return nil }
            if foodId.isEmpty { foodId = Catalog.foodFor(pet.age()).first(where: { $0 != "formula" && pet.count($0) > 0 }) ?? "" }
            guard !foodId.isEmpty else { return "맞는 사료가 없어요" }
            kindProbe.foodId = foodId
        } else if key == "padsheet" || key == "bag" {
            guard pet.use(id) else { return id == "bag" ? "배변 봉투가 없어요" : "패드가 없어요" }
        } else if kindProbe.kind == .fixed || kindProbe.kind == .toy {
            if pet.placed.contains(id) { return "이미 꺼내 두었어요" }
            pet.placed.append(id)
        } else if Catalog.isTreat(id) {
            guard pet.use(id) else { return "남은 것이 없어요" }
        } else if props.contains(where: { $0.id == key }) { return "이미 꺼내 두었어요" }
        // 손에 쥘 것은 오른손 앞 아래에 (0.5.0: 바로 앞 가슴 높이라 강아지 위 카드와 겹쳐 보였음)
        // 손이 보이면 그 손 바로 위에 띄워 잡기 쉽게 (0.9: 작은 간식을 공중에서 잡기 어려웠음)
        var at = userPos + f * 0.42 + SIMD3<Float>(-f.z, 0, f.x) * 0.2
        at.y = max(fy + 0.1, userPos.y - 0.5)
        if kindProbe.kind == .tool, let h = room.hands.first(where: { $0.seen && $0.right }) ?? room.hands.first(where: { $0.seen }),
           simd_distance(h.palm, userPos) < 0.75 {
            at = h.palm + SIMD3<Float>(0, 0.07, 0) + f * 0.03
        }
        if kindProbe.kind == .fixed {
            let want = SIMD2<Float>(userPos.x + f.x * 0.8, userPos.z + f.z * 0.8)
            let q = clearSpot(near: want, half: 0.22, within: 1.0) ?? want
            at = SIMD3<Float>(q.x, fy, q.y)
        }
        add(kindProbe, at: at, yaw: atan2(-f.x, -f.z))
        if kindProbe.kind == .fixed { settleFixed(); pinProp(kindProbe) }
        if kindProbe.kind == .tool { kindProbe.setMode(.kinematic) }       // 손에 쥘 것은 집을 때까지 내 앞에 떠 있음
        saveLayout()
        if id == "bowl_food" { kindProbe.fill = pet.foodBowl }
        if id == "bowl_water" { kindProbe.fill = pet.waterBowl }
        publish()
        return nil
    }

    func putBack(_ id: String) {
        commitHome()
        var keys = [id]
        if Catalog.item(id)?.cat == .food && !Catalog.isTreat(id) { keys = ["foodbag"] }
        if id == "pad" { keys = ["pad", "padsheet"] }
        if id == "bag" { keys = ["bag"] }
        for p in props.filter({ keys.contains($0.id) }) {
            if Catalog.isTreat(p.id) || (p.id == "padsheet" && !p.used) || (p.id == "bag" && !p.used) {
                let inv = p.id == "padsheet" ? "pad" : p.id
                pet.inv[inv] = pet.count(inv) + 1
            }
            removeProp(p)
        }
        if keys.contains("pad") || Catalog.placeable.contains(id) {
            pet.placed.removeAll { $0 == id }
            unpinProp(id)
        }
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
    func tapDog(at w: SIMD3<Float>? = nil) {
        guard now - lastGrabAt > 0.7, let d = dog else { return }
        if d.holding { return }
        // 손가락이 실제로 닿은 자리에서 온 탭(쓰다듬기)만 거름. 바라보고 집은 탭은 손이 강아지 곁에 있어도 받음
        // (0.9 까지: 손이 강아지 몸 30cm 안에만 있어도 탭을 버려서, 가까이 있으면 카드가 절대 안 떴음)
        // 탭이 '바라보고 엄지·검지를 모아 집은 것'인지 '손가락으로 직접 닿은 것(쓰다듬기)'인지 손 모양으로 가림 (0.10.7):
        // 시스템은 손가락이 강아지 몸에 닿았다 떨어지는 것도 탭으로 보내서, 쓰다듬는 동안 카드가 자꾸 떴음.
        // 집기 탭은 탭 직전 0.5초 안에 엄지·검지가 모여 있음 — 손 위치는 상관없어 가까이 있어도 카드가 뜸.
        // 다만 강아지 털을 직접 집은 것(집은 자리가 탭 자리)은 쓰다듬기로 봄
        if now - handSeenAt < 1.0 {
            guard now - pinchAt < 0.5 else { return }
            if let w, simd_distance(pinchGrip, w) < 0.05 { return }
        } else if let w { if touchedDirectly(w) { return } }
        else if d.touching || now - d.lastTouchAt < 1.5 { return }
        if !cardOn && AppModel.shared.mainOpen { AppModel.shared.closeMain?() }     // 메뉴는 늘 하나만
        cardOn.toggle()
        cardUntil = now + 15
        ringInfo = nil
    }

    @ObservationIgnored private var handSeenAt: Double = -9
    @ObservationIgnored private var pinchAt: Double = -9
    @ObservationIgnored private var pinchGrip = SIMD3<Float>(0, -9, 0)

    /// 탭 자리에 손가락·손바닥이 닿아 있음 = 직접 만진 것 (손이 안 보일 때만 씀)
    private func touchedDirectly(_ w: SIMD3<Float>) -> Bool {
        for h in room.hands where h.seen {
            if simd_distance(h.index, w) < 0.04 || simd_distance(h.thumb, w) < 0.04 || simd_distance(h.middle, w) < 0.04 || simd_distance(h.palm, w) < 0.06 { return true }
        }
        return false
    }

    /// 카드의 고리를 보고 집음: 그 욕구의 지금 상태와 앞으로 (아이폰·메인 메뉴와 같은 글)
    var ringInfo: String?
    func showRing(_ key: String) {
        cardUntil = now + 15
        let t = NeedInfo.text(pet, key)
        ringInfo = ringInfo == t ? nil : t
    }

    // MARK: 강아지 메뉴 (강아지를 누르면 뜨는 카드의 단추)
    func closeCard() { cardOn = false }

    /// 밥 주기: 젖먹이는 젖병, 그 뒤로는 사료 봉지를 손 앞에 꺼내 줌 → 봉지를 들고 그릇 위에서 기울이면 사료가 쏟아짐 (0.10.0)
    func feed() {
        cardUntil = now + 12
        let age = pet.age()
        if age < Catalog.weanAge && !(age >= 21 && pet.has("bowl_food") && Catalog.foodFor(age).contains(where: { $0 != "formula" && pet.count($0) > 0 })) {
            guard pet.has("bottle"), pet.count("formula") > 0 || pet.bottle > 0.01 else { AppModel.shared.showMain(tab: 2, note: "젖병과 분유가 필요해요"); return }
            if !isOut("bottle"), let why = takeOut("bottle") { toast(why); return }
            toast("젖병을 집어 입에 대 주세요")
            return
        }
        // 봉지를 이미 꺼냈으면 다시 누를 때 넣음 (0.10.0: 꺼낸 봉지·물병을 치울 방법이 없었음)
        if isOut("foodbag") { putBack("foodbag"); toast("사료 봉지를 넣었어요"); return }
        guard pet.has("bowl_food") else { AppModel.shared.showMain(tab: 2, note: "밥그릇이 필요해요"); return }
        if let b = prop("bowl_food"), b.fill > 0.95 { toast("밥그릇이 가득 차 있어요"); return }
        guard Catalog.foodFor(age).contains(where: { $0 != "formula" && pet.count($0) > 0 }) else { AppModel.shared.showMain(tab: 2, note: "맞는 사료가 없어요"); return }
        if !isOut("bowl_food"), let why = takeOut("bowl_food") { toast(why); return }
        if !isOut("foodbag"), let why = takeOut("foodbag") { toast(why); return }
        toast("봉지를 집어 밥그릇 위에서 기울여 주세요")
    }

    func giveWater() {
        cardUntil = now + 12
        if pet.age() < 21 { toast("아직 젖만 먹어요"); return }
        if isOut("jug") { putBack("jug"); toast("물병을 넣었어요"); return }
        if let b = prop("bowl_water"), b.fill > 0.95 { toast("물그릇이 가득 차 있어요"); return }
        if !isOut("bowl_water"), let why = takeOut("bowl_water") { toast(why); return }
        if !isOut("jug"), let why = takeOut("jug") { toast(why); return }
        toast("물병을 집어 물그릇 위에서 기울여 주세요")
    }

    func tapProp(_ e: Entity, at w: SIMD3<Float>? = nil) {
        guard now - lastGrabAt > 0.7 else { return }
        if let w, touchedDirectly(w) { return }
        var x: Entity? = e
        var uid = ""
        while let c = x { if let t = c.components[PropTag.self] { uid = t.id; break }; x = c.parent }
        guard let p = props.first(where: { $0.uid == uid }) else { return }
        useProp(p)
    }

    /// 바라보고 집기: 그릇·치울 것·패드는 어떻게 하는지 알려 줌 (바로 사라지거나 차지 않음 — 0.10.0, 그릇도 도구를 저절로 꺼내지 않음 — 0.10.2)
    private func useProp(_ p: Prop) {
        switch p.id {
        // 그릇 탭: 봉지·물병을 저절로 꺼내지 않고 하는 법만 알려 줌 (0.10.2 요청 — 도구는 보관함에서 꺼냄)
        case "bowl_food":
            if pet.age() < 21 { toast("아직 젖만 먹어요 · 보관함에서 젖병을 꺼내 주세요") }
            else if p.fill > 0.95 { toast("밥그릇이 가득 차 있어요") }
            else if isOut("foodbag") { toast("사료 봉지를 집어 밥그릇 위에서 기울여 주세요") }
            else { toast("보관함에서 사료를 꺼내 밥그릇 위에서 기울여 주세요") }
        case "bowl_water":
            if pet.age() < 21 { toast("아직 젖만 먹어요") }
            else if p.fill > 0.95 { toast("물그릇이 가득 차 있어요") }
            else if isOut("jug") { toast("물병을 집어 물그릇 위에서 기울여 주세요") }
            else { toast("보관함에서 물병을 꺼내 물그릇 위에서 기울여 주세요") }
        case "pad":
            // 몇 번 썼고 몇 번 남았는지 (패드 한 장 = 3번)
            let n = p.padUsed
            let new = pet.count("pad") > 0 ? "보관함에서 새 패드를 꺼내 바닥에 깔면 갈아져요" : "새 패드가 없어요 · 상점에서 살 수 있어요"
            if n >= 3 { toast("패드를 3번 다 썼어요 · " + new) }
            else if n == 0 { toast("새 패드예요 · 3번 쓸 수 있어요") }
            else { toast("패드를 \(n)번 썼어요 · \(3 - n)번 더 쓸 수 있어요") }
        case "poop": toast(pet.count("bag") > 0 || isOut("bag") ? "배변 봉투를 들고 집어 주세요" : "배변 봉투가 필요해요")
        case "pee": toast(pet.count("pad") > 0 || isOut("padsheet") ? "패드를 한 장 꺼내 들고 닦아 주세요" : "닦을 패드가 필요해요")
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
            // 길찾기에선 그릇 둘레 + 강아지 몸 반폭만큼 비켜 감 (0.10.3: 0.09 라 몸이 그릇을 걸치고 지나갔음 — 몸은 Dog.clearBody 가 마저 밀어냄)
            if p.id == "bowl_food" || p.id == "bowl_water" { ex.append((SIMD2<Float>(p.pos.x, p.pos.z), 0.11)) }
            else if p.id == "poop" { ex.append((SIMD2<Float>(p.pos.x, p.pos.z), 0.07)) }
            else if p.id == "steps" { ex.append((SIMD2<Float>(p.pos.x, p.pos.z), 0.28)) }
        }
        // 내 몸: 스캔 그물에 사람은 안 잡히므로 머리 자리로 몸이 차지한 바닥을 어림 (0.9: 강아지가 내 몸을 뚫고 와 앉았음).
        // 서 있으면 발 둘레, 앉아 있으면(눈높이 1.25m 아래) 다리가 앞으로 뻗은 자리까지
        if let fy = room.floorY {
            let u = SIMD2<Float>(userPos.x, userPos.z), f2 = SIMD2<Float>(userFwd.x, userFwd.z)
            let sitting = userPos.y - fy < 1.25
            // 앉으면 무릎·발(앞 0.45m 까지)만 — 0.10.6 까지 앞 0.8m 까지 막아 불러도 손이 닿지 않는 곳에 멈췄음
            ex.append((u, 0.24))
            if sitting { ex.append((u + f2 * 0.22, 0.16)); ex.append((u + f2 * 0.42, 0.14)) }
            else { ex.append((u + f2 * 0.12, 0.2)) }
            // 내 몸 안(발 둘레 22cm)에 멈춰 있는 장난감은 살며시 밖으로 굴려 냄 — 몸 안에 있으면 손이 닿지 않음 (0.10.7)
            // 단, 몸을 숙였거나(눈높이 1.3m 아래) 손이 가까이 있으면(집으려는 중) 그대로 둠 — 0.10.1 처럼 집으려는 것을 밀어내지 않게
            let reaching = userPos.y - fy < 1.3 || room.hands.contains { $0.seen && $0.palm.y - fy < 0.6 }
            for p in props where !reaching && p.kind == .toy && p.heldBy == nil && !p.inMouth {
                let d = SIMD2<Float>(p.pos.x, p.pos.z) - u, r = simd_length(d)
                guard r > 1e-3, r < 0.22, p.pos.y < userPos.y - 0.5, simd_length(p.velocity) < 0.15 else { continue }
                let n = d / r
                p.setVelocity(SIMD3<Float>(n.x * 0.35, 0.05, n.y * 0.35))
            }
            // 굴러오는 장난감이 내 몸을 뚫지 않게: 몸통(눈 8cm 뒤, 반지름 20cm) 안으로 '들어오는 중'인 것만 튕겨 냄.
            // 0.10.1 은 몸·다리를 물리 상자로 둬서 ① 아래로 쏘는 면 찾기에 상자가 잡혀 내려놓은 팸·물건이 그 위(10~20cm)에 떴고
            // ② 몸을 숙이면 상자가 머리를 따라 앞으로 와 바닥 장난감을 밀어냈음 → 상자 없이 속도만 바꿈, 서 있을 때만
            if userPos.y - fy > 1.3 {
                let c = SIMD2<Float>(userPos.x - userFwd.x * 0.08, userPos.z - userFwd.z * 0.08)
                for p in props where p.kind == .toy && p.heldBy == nil {
                    let q = p.pos, d = SIMD2<Float>(q.x, q.z) - c, r = simd_length(d)
                    guard r > 1e-3, r < 0.2, q.y < userPos.y - 0.2 else { continue }
                    let n = d / r, v = p.velocity, vn = v.x * n.x + v.z * n.y
                    if vn < -0.15 {
                        let out = SIMD2<Float>(v.x, v.z) - n * (1.35 * vn)
                        p.setVelocity(SIMD3<Float>(out.x, v.y, out.y))
                    }
                }
            }
        }
        room.nav.extra = ex
        // 가림 그물: 강아지를 안고 있을 때만 끔 (안은 강아지는 늘 내 앞이라 가릴 것이 없고, 내 몸 스캔 면에 잘리지 않게).
        // 0.10.3 까지는 강아지가 75cm 안이거나 만지기만 해도 방 전체의 가림을 꺼서, 소파에 앉아 곁에 강아지가 있으면
        // 소파·가구 뒤의 그릇·패드·강아지까지 모두 가구를 뚫고 보였음. 속의 눈·혀가 보이던 진짜 원인(눈앞 잘림)은 0.10.1 에서 고침
        if let d = dog {
            let off = d.holding
            if room.occlusion == off { room.occlusion = !off }
        }
        live(dt)
        hands(dt)
        toolsWork(dt)
        if now > beatAt {
            // 함께 있다는 표시를 20분마다 다시 올림 (아이폰은 이 표시가 2시간 넘게 안 오면 다시 알림을 울림)
            beatAt = now + 1200
            pet.lastSim = Date().timeIntervalSince1970
            Store.save(pet, force: true)
        }
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
        pet.energy = c(pet.energy + (sleeping ? 0.22 : -st.awakeDrain * active) * h)
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
        for h in hs where h.seen {
            handSeenAt = now
            if h.pinch { pinchAt = now; pinchGrip = h.grip }
        }
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
                    // 작은 것(간식·덴탈 껌·공)은 손이 조금 빗나가도 잡히게 (0.9: 공중에 뜬 간식을 잡기 어려웠음)
                    var lim: Float = p.small ? 0.055 : 0.035
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
                    // 삑삑이를 손으로 쥐면 삑 — 강아지가 듣고 돌아봄·달려옴 (0.10.3)
                    if p.base == "squeak" { SoundBank.shared.play("squeak", on: p.entity, gain: -8); dog?.heardSqueak(p) }
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
                pinProp(p)                   // 옮겨 놓은 자리에 새로 고정 (다음에도 그 자리 그대로)
                saveLayout()
                Store.save(pet)
            }
            return
        }
        p.showStream(nil, nil, water: false)
        if p.id == "padsheet" || p.id == "bag" {
            if p.used {
                // 닦은 패드·채운 봉투는 묶어서 버림
                SoundBank.shared.play("rustle", on: p.entity, gain: -14)
                removeProp(p)
                publish()
                return
            }
            if p.id == "padsheet" && p.pos.y - fy < 0.3 { layPad(p); return }
        }
        p.setMode(.dynamic)
        var v = h.seen ? h.vel : SIMD3<Float>(0, 0, 0)
        let sp = simd_length(v)
        if sp > 7 { v *= 7 / sp }
        p.setVelocity(v, spin: SIMD3<Float>(Float.random(in: -3...3), Float.random(in: -3...3), Float.random(in: -3...3)) * min(1, sp))
        p.thrownAt = now
        if p.kind == .toy { if sp > 1.1 { dog?.thrown(p) } else { dog?.noticed(p) } }      // 던지면 쫓아가고, 곁에 내려놓으면 다가와 봄
    }

    // MARK: 손에 든 도구 (0.10.0) — 봉지·물병을 그릇 위에서 기울여 붓기, 패드로 오줌 닦기, 봉투로 똥 줍기
    private func toolsWork(_ dt: Float) {
        let fy = room.floorY ?? 0
        for p in props where p.heldBy != nil {
            switch p.id {
            case "foodbag", "jug": pour(p, dt)
            case "padsheet": wipe(p, dt, fy)
            case "bag": scoop(p)
            default: break
            }
        }
    }

    private func pour(_ p: Prop, _ dt: Float) {
        let water = p.id == "jug"
        let up = p.entity.convert(direction: SIMD3<Float>(0, 1, 0), to: nil)
        let tilt = acos(min(1, max(-1, up.y)))
        let mouth = p.entity.convert(position: p.spout, to: nil)
        var bowl: Prop?
        // 입구가 아래로 기울고(물병 60°·봉지 65° 넘게) 그 바로 아래에 그릇이 있을 때만 쏟아짐
        if tilt > (water ? 1.05 : 1.13), let b = prop(water ? "bowl_water" : "bowl_food"), b.heldBy == nil {
            let dxz = simd_distance(SIMD2<Float>(mouth.x, mouth.z), SIMD2<Float>(b.pos.x, b.pos.z))
            let h = mouth.y - b.pos.y
            if dxz < 0.08 && h > 0.03 && h < 0.7 { bowl = b }
        }
        guard let b = bowl, b.fill < 0.999 else {
            p.showStream(nil, nil, water: water)
            if bowl == nil { tools.fullTold = false }
            return
        }
        if water {
            b.fill = min(1, b.fill + dt * 0.42)
            pet.waterBowl = b.fill
        } else {
            if tools.credit <= 0.0001 {
                let fid = !p.foodId.isEmpty && pet.count(p.foodId) > 0 ? p.foodId : (Catalog.foodFor(pet.age()).first(where: { $0 != "formula" && pet.count($0) > 0 }) ?? "")
                guard !fid.isEmpty, pet.use(fid) else { p.showStream(nil, nil, water: false); tell("사료가 다 떨어졌어요"); return }
                pet.foodKind = fid
                tools.credit = 1                       // 한 끼 = 빈 그릇 하나 가득
            }
            let add = min(1 - b.fill, dt * 0.5, tools.credit)
            b.fill += add
            tools.credit -= add
            pet.foodBowl = b.fill
        }
        p.showStream(mouth, SIMD3<Float>(b.pos.x, b.pos.y + b.contentY, b.pos.z), water: water)
        if now > tools.soundAt {
            tools.soundAt = now + (water ? 1.1 : 0.55)
            SoundBank.shared.play(water ? "pour" : "kibble", on: b.entity, gain: water ? -12 : -10)
        }
        if b.fill >= 0.999 && !tools.fullTold { tools.fullTold = true; tell(water ? "물을 가득 채웠어요" : "사료를 가득 담았어요") }
        dog?.foodComing(b)
    }

    /// 손에 든 새 패드를 오줌 위에 대고 문지르면 닦임
    private func wipe(_ p: Prop, _ dt: Float, _ fy: Float) {
        guard !p.used, let i = p.heldBy else { return }
        let c = SIMD2<Float>(p.pos.x, p.pos.z)
        guard let pee = props.first(where: { $0.id == "pee" && simd_distance(SIMD2<Float>($0.pos.x, $0.pos.z), c) < 0.13 }), p.pos.y - fy < 0.08 else {
            tools.wipeT = max(0, tools.wipeT - dt)
            return
        }
        if simd_length(room.hands[i].vel) > 0.05 { tools.wipeT += dt }
        pee.fill = max(0, 1 - tools.wipeT / 1.3)
        if now > tools.soundAt { tools.soundAt = now + 0.45; SoundBank.shared.play("brush", on: p.entity, gain: -16) }
        if tools.wipeT > 1.3 {
            tools.wipeT = 0
            removeProp(pee)
            p.used = true
            pet.clean = min(1, pet.clean + 0.02)
            tell("깨끗이 닦았어요")
            publish()
        }
    }

    /// 손에 든 배변 봉투를 똥에 대면 주워 담음 (봉투를 놓으면 묶어서 버림)
    private func scoop(_ p: Prop) {
        guard let poop = props.first(where: { $0.id == "poop" && $0.grabDist(p.pos) < 0.055 }) else { return }
        removeProp(poop)
        pet.poops = max(0, pet.poops - 1)
        pet.clean = min(1, pet.clean + 0.02)
        p.used = true
        SoundBank.shared.play("rustle", on: p.entity, gain: -12)
        saveLayout()
        publish()
    }

    /// 손에 든 새 패드를 바닥 가까이에서 놓음 → 그 자리에 깔림 (깔려 있던 패드는 걷어 냄)
    private func layPad(_ sheet: Prop) {
        let fy = room.floorY ?? sheet.pos.y
        let at = SIMD3<Float>(sheet.pos.x, fy, sheet.pos.z)
        let yaw = PlaySession.yawOf(sheet.entity.transformMatrix(relativeTo: nil))
        removeProp(sheet)
        if let old = prop("pad") { removeProp(old) } else { pet.placed.append("pad") }
        let pad = Prop("pad")
        add(pad, at: at, yaw: yaw)
        pad.fill = 0
        pet.padUses = 3
        settleFixed()
        pinProp(pad)
        SoundBank.shared.play("rustle", on: pad.entity, gain: -12)
        saveLayout()
        Store.save(pet)
        publish()
    }

    @ObservationIgnored private var tellAt: Double = 0
    private func tell(_ t: String) {
        guard now > tellAt else { return }
        tellAt = now + 4
        toast(t)
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
