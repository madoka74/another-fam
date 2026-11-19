import Foundation
import ARKit
import RealityKit
import simd
import QuartzCore

/// 손 하나의 지금 모습 (세계 좌표)
struct HandState {
    var seen = false
    var right = false
    var wrist = SIMD3<Float>(0, 0, 0), palm = SIMD3<Float>(0, 0, 0), palmN = SIMD3<Float>(0, -1, 0)
    var index = SIMD3<Float>(0, 0, 0), thumb = SIMD3<Float>(0, 0, 0), middle = SIMD3<Float>(0, 0, 0)
    var fingers = SIMD3<Float>(0, 0, -1)            // 손목 → 손가락 방향
    var vel = SIMD3<Float>(0, 0, 0)
    var pinch = false, fist = false
    var lastT: Double = 0
    /// 집은 자리 (엄지·검지 사이)
    var grip: SIMD3<Float> { (index + thumb) * 0.5 }
    /// 손바닥이 위를 봄
    var palmUp: Bool { palmN.y > 0.55 }
}

/// 개가 올라갈 수 있는 평평한 면 (소파·낮은 의자)
struct Perch {
    var center: SIMD3<Float>
    var ax: SIMD3<Float>, az: SIMD3<Float>          // 면의 가로·세로 방향 (수평)
    var half: SIMD2<Float>
}

/// 바닥 길찾기 격자 (8cm 칸). 스캔 그물에서 '바닥이 보인 칸'과 '개 키 높이 안에 물건이 있는 칸'을 모음
final class NavGrid {
    static let cell: Float = 0.08
    static let n = 160
    var ox: Float = 0, oz: Float = 0                // 격자 한가운데의 세계 자리
    var seen = [UInt8](repeating: 0, count: n * n)
    var block = [UInt16](repeating: 0, count: n * n)
    private var byAnchor: [UUID: [Int32]] = [:]
    /// 공간 인식을 못 쓸 때: 시작한 곳 둘레를 빈 바닥으로 봄
    var open = false
    /// 바닥에 놓인 물건(그릇·계단) — 그 둘레로는 지나가지 않음
    var extra: [(c: SIMD2<Float>, r: Float)] = []
    var ready: Bool { open || seenCount > 40 }
    private(set) var seenCount = 0

    func reset(x: Float, z: Float) {
        ox = x; oz = z
        for i in 0..<seen.count { seen[i] = 0; block[i] = 0 }
        byAnchor.removeAll()
        seenCount = 0
    }

    func index(_ x: Float, _ z: Float) -> Int? {
        let i = Int(((x - ox) / NavGrid.cell).rounded(.down)) + NavGrid.n / 2
        let j = Int(((z - oz) / NavGrid.cell).rounded(.down)) + NavGrid.n / 2
        guard i >= 0, j >= 0, i < NavGrid.n, j < NavGrid.n else { return nil }
        return j * NavGrid.n + i
    }

    func center(_ c: Int) -> SIMD2<Float> {
        let i = c % NavGrid.n, j = c / NavGrid.n
        return SIMD2<Float>(ox + (Float(i - NavGrid.n / 2) + 0.5) * NavGrid.cell, oz + (Float(j - NavGrid.n / 2) + 0.5) * NavGrid.cell)
    }

    /// 한 그물 조각의 표본으로 갱신 (그 조각이 전에 막았던 칸은 풀고 새로 막음)
    func update(_ id: UUID, floorCells: [Int32], blockCells: [Int32]) {
        if let old = byAnchor[id] { for c in old where block[Int(c)] > 0 { block[Int(c)] -= 1 } }
        var uniq = Set<Int32>()
        for c in blockCells where uniq.insert(c).inserted { block[Int(c)] = block[Int(c)] &+ 1 }
        byAnchor[id] = Array(uniq)
        for c in floorCells where seen[Int(c)] == 0 { seen[Int(c)] = 1; seenCount += 1 }
    }

    func free(_ c: Int) -> Bool {
        if open {
            let p = center(c)
            let dx: Float = p.x - ox, dz: Float = p.y - oz
            return dx * dx + dz * dz < 6.25
        }
        guard seen[c] == 1 && block[c] == 0 else { return false }
        if !extra.isEmpty {
            let p = center(c)
            for e in extra where simd_distance(p, e.c) < e.r { return false }
        }
        return true
    }

    /// 몸이 지나갈 수 있는 칸 (둘레 한 칸까지 빔)
    func walkable(_ c: Int) -> Bool {
        guard free(c) else { return false }
        if open { return true }
        let i = c % NavGrid.n, j = c / NavGrid.n
        for dj in -1...1 {
            for di in -1...1 {
                let a = i + di, b = j + dj
                if a < 0 || b < 0 || a >= NavGrid.n || b >= NavGrid.n { continue }
                if block[b * NavGrid.n + a] > 0 { return false }
            }
        }
        return true
    }

    func walkable(_ x: Float, _ z: Float) -> Bool {
        guard let c = index(x, z) else { return false }
        return walkable(c)
    }

    /// 가장 가까운 갈 수 있는 칸 (r 칸 안)
    func nearest(_ x: Float, _ z: Float, r: Int = 10) -> Int? {
        guard let c0 = index(x, z) else { return nil }
        if walkable(c0) { return c0 }
        let i0 = c0 % NavGrid.n, j0 = c0 / NavGrid.n
        var best: Int?
        var bd = Int.max
        for dj in -r...r {
            for di in -r...r {
                let a = i0 + di, b = j0 + dj
                if a < 0 || b < 0 || a >= NavGrid.n || b >= NavGrid.n { continue }
                let d = di * di + dj * dj
                if d < bd && walkable(b * NavGrid.n + a) { bd = d; best = b * NavGrid.n + a }
            }
        }
        return best
    }

    /// 두 점 사이를 곧게 갈 수 있는지
    func clearLine(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
        let d = simd_distance(a, b)
        let steps = max(1, Int(d / (NavGrid.cell * 0.5)))
        for s in 0...steps {
            let p = a + (b - a) * (Float(s) / Float(steps))
            if !walkable(p.x, p.y) { return false }
        }
        return true
    }

    /// 길 (세계 x·z 점들). 못 가면 nil
    func path(from a: SIMD2<Float>, to b: SIMD2<Float>) -> [SIMD2<Float>]? {
        guard let s = nearest(a.x, a.y, r: 6), let g = nearest(b.x, b.y, r: 12) else { return nil }
        if s == g { return [center(g)] }
        if clearLine(center(s), center(g)) { return [center(g)] }
        let N = NavGrid.n
        var cost = [Float](repeating: .infinity, count: N * N)
        var prev = [Int32](repeating: -1, count: N * N)
        var heap: [(f: Float, c: Int)] = []
        func push(_ f: Float, _ c: Int) {
            heap.append((f, c))
            var i = heap.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if heap[p].f <= heap[i].f { break }
                heap.swapAt(p, i); i = p
            }
        }
        func pop() -> (f: Float, c: Int) {
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < heap.count && heap[l].f < heap[m].f { m = l }
                    if r < heap.count && heap[r].f < heap[m].f { m = r }
                    if m == i { break }
                    heap.swapAt(m, i); i = m
                }
            }
            return top
        }
        let gi = g % N, gj = g / N
        func hcost(_ c: Int) -> Float {
            let di = Float(abs(c % N - gi)), dj = Float(abs(c / N - gj))
            return max(di, dj) + 0.41 * min(di, dj)
        }
        cost[s] = 0
        push(hcost(s), s)
        var found = false
        var guardN = 0
        while !heap.isEmpty && guardN < 30000 {
            guardN += 1
            let (_, c) = pop()
            if c == g { found = true; break }
            let ci = c % N, cj = c / N
            for dj in -1...1 {
                for di in -1...1 where di != 0 || dj != 0 {
                    let a2 = ci + di, b2 = cj + dj
                    if a2 < 0 || b2 < 0 || a2 >= N || b2 >= N { continue }
                    let nc = b2 * N + a2
                    if !walkable(nc) { continue }
                    if di != 0 && dj != 0 && (!walkable(cj * N + a2) || !walkable(b2 * N + ci)) { continue }
                    let step: Float = (di != 0 && dj != 0) ? 1.41 : 1
                    let nv = cost[c] + step
                    if nv < cost[nc] { cost[nc] = nv; prev[nc] = Int32(c); push(nv + hcost(nc), nc) }
                }
            }
        }
        guard found else { return nil }
        var cells: [Int] = [g]
        var c = g
        while c != s, prev[c] >= 0 { c = Int(prev[c]); cells.append(c) }
        cells.reverse()
        // 곧게 갈 수 있는 데까지 건너뛰어 길을 폄
        var pts: [SIMD2<Float>] = []
        var i = 0
        while i < cells.count - 1 {
            var j = cells.count - 1
            while j > i + 1 && !clearLine(center(cells[i]), center(cells[j])) { j -= 1 }
            pts.append(center(cells[j]))
            i = j
        }
        return pts
    }

    /// p 에 가장 가까운 '둘레 clear 미터가 모두 빈 바닥'인 자리 (물건·강아지를 처음 놓을 곳). 없으면 nil
    func openSpot(near p: SIMD2<Float>, clear: Float, within: Float = 1.6) -> SIMD2<Float>? {
        if open { return p }
        guard let c0 = index(p.x, p.y) else { return nil }
        let N = NavGrid.n
        let rc = Int((clear / NavGrid.cell).rounded(.up)), rs = Int(within / NavGrid.cell)
        let i0 = c0 % N, j0 = c0 / N
        var best: Int?
        var bd = Int.max
        for dj in -rs...rs {
            for di in -rs...rs {
                let d = di * di + dj * dj
                if d >= bd || d > rs * rs { continue }
                let a = i0 + di, b = j0 + dj
                if a < rc || b < rc || a >= N - rc || b >= N - rc { continue }
                var ok = true
                for v in -rc...rc where ok {
                    for u in -rc...rc where u * u + v * v <= rc * rc {
                        if !free((b + v) * N + a + u) { ok = false; break }
                    }
                }
                if ok { bd = d; best = b * N + a }
            }
        }
        guard let best else { return nil }
        return center(best)
    }

    /// 둘레에서 아무 갈 수 있는 자리 (거닐 때)
    func randomSpot(near p: SIMD2<Float>, rMin: Float, rMax: Float) -> SIMD2<Float>? {
        for _ in 0..<24 {
            let a = Float.random(in: 0..<(2 * .pi)), r = Float.random(in: rMin...rMax)
            let q = p + SIMD2<Float>(cos(a), sin(a)) * r
            if walkable(q.x, q.y) && walkable(q.x + 0.12, q.y) && walkable(q.x - 0.12, q.y) && walkable(q.x, q.y + 0.12) && walkable(q.x, q.y - 0.12) { return q }
        }
        return nil
    }
}

/// 현실 공간 인식: 머리·손 추적, 바닥·가구 면, 스캔 그물(길찾기·가림·장난감 부딪힘)
@MainActor
final class Room {
    let root = Entity()
    private let ar = ARKitSession()
    private var world: WorldTrackingProvider?
    private var handsP: HandTrackingProvider?
    private var planesP: PlaneDetectionProvider?
    private var sceneP: SceneReconstructionProvider?
    private var ended = false
    private(set) var floorY: Float?
    private(set) var floorFromPlane = false
    private var floorPlanes: [UUID: (y: Float, area: Float)] = [:]
    let nav = NavGrid()
    private(set) var perches: [UUID: Perch] = [:]
    private(set) var windows: [UUID: SIMD3<Float>] = [:]
    private(set) var doors: [UUID: SIMD3<Float>] = [:]
    var hands = [HandState(), HandState()]
    private var meshCache: [UUID: MeshAnchor] = [:]
    private var occluders: [UUID: ModelEntity] = [:]
    private var colliders: [UUID: Entity] = [:]
    private var meshAt: [UUID: Double] = [:], shapeAt: [UUID: Double] = [:]
    private let floorSlab = Entity()
    var occlusion = true { didSet { for e in occluders.values { e.isEnabled = occlusion } } }
    var onAnchor: ((WorldAnchor, Bool) -> Void)?
    private(set) var handsOK = false, sensingOK = false
    private(set) var startAt: Double = 0

    /// 시작. 반환: 알릴 말 (없으면 nil)
    func start() async -> String? {
        startAt = CACurrentMediaTime()
        var note: String?
        var want: [ARKitSession.AuthorizationType] = [.worldSensing]
        if HandTrackingProvider.isSupported { want.append(.handTracking) }
        let auth = await ar.requestAuthorization(for: want)
        sensingOK = auth[.worldSensing] == .allowed
        handsOK = HandTrackingProvider.isSupported && auth[.handTracking] == .allowed
        var providers: [any DataProvider] = []
        if WorldTrackingProvider.isSupported {
            let w = WorldTrackingProvider()
            world = w; providers.append(w)
        }
        if handsOK {
            let h = HandTrackingProvider()
            handsP = h; providers.append(h)
        } else { note = "손 추적을 허락하면 쓰다듬고 안아 줄 수 있어요." }
        if sensingOK && PlaneDetectionProvider.isSupported {
            let p = PlaneDetectionProvider(alignments: [.horizontal, .vertical])
            planesP = p; providers.append(p)
        }
        if sensingOK && SceneReconstructionProvider.isSupported {
            let s = SceneReconstructionProvider()
            sceneP = s; providers.append(s)
        } else {
            nav.open = true
            note = "주변 공간 인식을 허락하면 가구를 피해 다니고 소파에도 올라가요."
        }
        guard !providers.isEmpty else { nav.open = true; return "이 기기에서는 공간 인식을 쓸 수 없어요." }
        do { try await ar.run(providers) } catch { nav.open = true; return "공간 인식을 시작하지 못했어요." }
        startAt = CACurrentMediaTime()          // 허락 창에서 기다린 시간은 빼고 셈
        if let w = world { Task { await self.watchWorld(w) } }
        if let p = planesP { Task { await self.watchPlanes(p) } }
        if let s = sceneP { Task { await self.watchScene(s) } }
        floorSlab.components.set(CollisionComponent(shapes: [.generateBox(size: SIMD3<Float>(14, 0.2, 14))], isStatic: true))
        floorSlab.components.set(PhysicsBodyComponent(mode: .static))
        floorSlab.isEnabled = false
        root.addChild(floorSlab)
        return note
    }

    func stop() {
        ended = true
        ar.stop()
    }

    /// 머리(기기) 자리·방향
    func head() -> simd_float4x4? {
        guard let w = world, w.state == .running, let d = w.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), d.isTracked else { return nil }
        return d.originFromAnchorTransform
    }

    // MARK: 집 자리 (방에 고정)
    func addAnchor(_ t: simd_float4x4) async -> UUID? {
        guard let w = world, w.state == .running else { return nil }
        let a = WorldAnchor(originFromAnchorTransform: t)
        do { try await w.addAnchor(a) } catch { return nil }
        return a.id
    }

    /// 기기에 저장돼 있는 이 앱의 공간 고정점 id 들 (앱을 다시 켜도 남음). 못 읽으면 nil
    func savedAnchorIds() async -> Set<UUID>? {
        guard let w = world else { return nil }
        guard let all = try? await w.allAnchors else { return nil }
        return Set(all.map { $0.id })
    }

    func removeAnchor(_ id: UUID) async {
        guard let w = world else { return }
        try? await w.removeAnchor(forID: id)
    }

    private func watchWorld(_ w: WorldTrackingProvider) async {
        for await u in w.anchorUpdates {
            if ended { break }
            var removed = false
            if case .removed = u.event { removed = true }
            onAnchor?(u.anchor, removed)
        }
    }

    // MARK: 면 (바닥·앉는 면·창·문)
    private func watchPlanes(_ p: PlaneDetectionProvider) async {
        for await u in p.anchorUpdates {
            if ended { break }
            let a = u.anchor
            var removed = false
            if case .removed = u.event { removed = true }
            let m = a.originFromAnchorTransform
            let ext = a.geometry.extent
            let em = m * ext.anchorFromExtentTransform
            let c = simd_make_float3(em.columns.3)
            if removed {
                floorPlanes[a.id] = nil; perches[a.id] = nil; windows[a.id] = nil; doors[a.id] = nil
                continue
            }
            if a.alignment == .horizontal {
                if a.classification == .floor {
                    floorPlanes[a.id] = (c.y, ext.width * ext.height)
                    refreshFloor()
                } else if let fy = floorY {
                    let h = c.y - fy
                    let seat = a.classification == .seat || (a.classification == .table && h < 0.5)
                    if seat && h > 0.2 && h < 0.52 && ext.width > 0.4 && ext.height > 0.4 {
                        var ax = simd_make_float3(em.columns.0), az = simd_make_float3(em.columns.1)
                        ax.y = 0; az.y = 0
                        if simd_length(ax) > 0.1 && simd_length(az) > 0.1 {
                            perches[a.id] = Perch(center: c, ax: simd_normalize(ax), az: simd_normalize(az), half: SIMD2<Float>(ext.width / 2, ext.height / 2))
                        }
                    } else { perches[a.id] = nil }
                }
            } else if let fy = floorY {
                if a.classification == .window { windows[a.id] = SIMD3<Float>(c.x, fy, c.z) }
                if a.classification == .door { doors[a.id] = SIMD3<Float>(c.x, fy, c.z) }
            }
        }
    }

    private func refreshFloor() {
        // 가장 넓은 바닥 면의 높이
        guard let best = floorPlanes.values.max(by: { $0.area < $1.area }) else { return }
        setFloor(best.y, plane: true)
    }

    private func setFloor(_ y: Float, plane: Bool) {
        if let f = floorY, abs(f - y) < 0.02, floorFromPlane || !plane { return }
        floorY = y
        floorFromPlane = plane
        floorSlab.position = SIMD3<Float>(nav.ox, y - 0.1, nav.oz)
        floorSlab.isEnabled = true
        let cx = nav.ox, cz = nav.oz
        nav.reset(x: cx, z: cz)
        epoch += 1
        // 모든 조각을 다시 계산 — 차례로, 화면 밖 줄에서 (0.9: 여기서 전부를 한 번에 계산해 몇 초씩 멈췄음)
        for id in meshCache.keys { enqueue(id) }
    }

    // MARK: 그물 → 길찾기 칸 (계산은 메인 밖에서 차례로)
    private var rasterQ: [UUID] = []
    private var rasterBusy = 0
    private var epoch = 0
    private var occAt: [UUID: Double] = [:]
    private var occLater: Set<UUID> = []

    private func enqueue(_ id: UUID) {
        if !rasterQ.contains(id) { rasterQ.append(id) }
        pump()
    }

    private func pump() {
        while rasterBusy < 2, !rasterQ.isEmpty {
            let id = rasterQ.removeFirst()
            guard let a = meshCache[id], let fy = floorY else { continue }
            let job = RasterJob(a, fy: fy, ox: nav.ox, oz: nav.oz, epoch: epoch)
            rasterBusy += 1
            Task.detached(priority: .utility) {
                let r = job.run()
                await self.finish(id, r, job.epoch)
            }
        }
    }

    private func finish(_ id: UUID, _ r: RasterOut, _ ep: Int) {
        rasterBusy -= 1
        defer { pump() }
        guard !ended else { return }
        if ep != epoch { enqueue(id); return }
        nav.update(id, floorCells: r.floor, blockCells: r.block)
        // 가림 그물은 1.5초에 한 번만 새로 (그물 만들기는 메인에서 해야 함) — 처음 스캔된 조각은 바로
        let now = CACurrentMediaTime()
        guard occluders[id] == nil || now - (occAt[id] ?? 0) > 1.5 else {
            // 건너뛴 마지막 모양이 묵지 않게 잠시 뒤 한 번 더 (0.10.3 까지는 3초 안에 온 마지막 모양을 버려 옛 가림이 남았음)
            if !occLater.contains(id) {
                occLater.insert(id)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_700_000_000)
                    self.occLater.remove(id)
                    if !self.ended { self.enqueue(id) }
                }
            }
            return
        }
        occAt[id] = now
        guard r.occIdx.count >= 3 else { occluders[id]?.isEnabled = false; return }
        var d = MeshDescriptor(name: "occ")
        d.positions = MeshBuffers.Positions(r.occPos)
        d.primitives = .triangles(r.occIdx)
        guard let mesh = try? MeshResource.generate(from: [d]) else { return }
        if let e = occluders[id] {
            e.model?.mesh = mesh
            e.isEnabled = occlusion
        } else {
            let e = ModelEntity(mesh: mesh, materials: [OcclusionMaterial()])
            e.isEnabled = occlusion
            occluders[id] = e
            root.addChild(e)
        }
    }

    // MARK: 스캔 그물
    private func watchScene(_ s: SceneReconstructionProvider) async {
        for await u in s.anchorUpdates {
            if ended { break }
            let a = u.anchor
            if case .removed = u.event {
                // 멀어져서 지워진 조각은 그대로 둠 (길·가림이 비지 않게) — 어나더 스페이스 교훈
                continue
            }
            meshCache[a.id] = a
            let now = CACurrentMediaTime()
            if now - (meshAt[a.id] ?? 0) > 1.2 {
                meshAt[a.id] = now
                enqueue(a.id)
            }
            if now - (shapeAt[a.id] ?? 0) > 2.5 {
                shapeAt[a.id] = now
                let id = a.id, t = a.originFromAnchorTransform
                Task {
                    guard let shape = try? await ShapeResource.generateStaticMesh(from: a) else { return }
                    let e = self.colliders[id] ?? Entity()
                    e.transform = Transform(matrix: t)
                    e.components.set(CollisionComponent(shapes: [shape], isStatic: true))
                    e.components.set(PhysicsBodyComponent(mode: .static))
                    if self.colliders[id] == nil { self.colliders[id] = e; self.root.addChild(e) }
                }
            }
        }
    }

    // MARK: 매 화면
    func tick(now: Double, dt: Float) {
        // 바닥을 아직 모르면: 3초 뒤 눈높이 - 1.5m 로 어림 (0 으로 두면 높이 판정이 틀어짐)
        if let h = head() {
            let p = simd_make_float3(h.columns.3)
            if nav.ox == 0 && nav.oz == 0 { nav.reset(x: p.x, z: p.z) }
            if floorY == nil && (now - startAt > 3 || !sensingOK) { setFloor(p.y - 1.5, plane: false) }
        } else if floorY == nil && now - startAt > 4 {
            setFloor(0, plane: false)
        }
        guard let hp = handsP, hp.state == .running else { return }
        let la = hp.handAnchors(at: now + 0.02)
        update(0, la.leftHand, now, dt)
        update(1, la.rightHand, now, dt)
    }

    private func update(_ i: Int, _ a: HandAnchor?, _ now: Double, _ dt: Float) {
        guard let a, a.isTracked, let sk = a.handSkeleton else {
            if now - hands[i].lastT > 0.3 { hands[i].seen = false; hands[i].pinch = false; hands[i].fist = false }
            return
        }
        let m = a.originFromAnchorTransform
        func p(_ j: HandSkeleton.JointName) -> SIMD3<Float> { simd_make_float3((m * sk.joint(j).anchorFromJointTransform).columns.3) }
        var h = hands[i]
        let wrist = p(.wrist), ik = p(.indexFingerKnuckle), lk = p(.littleFingerKnuckle), mk = p(.middleFingerKnuckle)
        let palm: SIMD3<Float> = (wrist + mk) * 0.5 + (mk - wrist) * 0.15
        var n = simd_cross(ik - wrist, lk - wrist)
        if simd_length(n) > 1e-6 { n = simd_normalize(n) }
        if a.chirality == .left { n = -n }
        if h.seen && dt > 0 {
            let v: SIMD3<Float> = (palm - h.palm) / dt
            h.vel += (v - h.vel) * min(1, dt * 12)
        } else { h.vel = .zero }
        h.right = a.chirality == .right
        h.wrist = wrist; h.palm = palm; h.palmN = n
        h.index = p(.indexFingerTip); h.thumb = p(.thumbTip); h.middle = p(.middleFingerTip)
        let fd = mk - wrist
        if simd_length(fd) > 1e-4 { h.fingers = simd_normalize(fd) }
        let pd = simd_distance(h.index, h.thumb)
        if pd < 0.02 { h.pinch = true } else if pd > 0.04 { h.pinch = false }
        let curl: Float = (simd_distance(h.index, palm) + simd_distance(h.middle, palm) + simd_distance(p(.ringFingerTip), palm) + simd_distance(p(.littleFingerTip), palm)) / 4
        if curl < 0.055 { h.fist = true } else if curl > 0.075 { h.fist = false }
        h.seen = true
        h.lastT = now
        hands[i] = h
    }
}

/// 그물 조각 하나를 길찾기 칸·가림 그물로 바꾸는 일 (메인에서 그물 값만 복사해 두고 계산은 밖에서)
struct RasterOut: Sendable {
    var floor: [Int32] = [], block: [Int32] = []
    var occPos: [SIMD3<Float>] = [], occIdx: [UInt32] = []
}

struct RasterJob: Sendable {
    let pos: [SIMD3<Float>], nrm: [SIMD3<Float>], idx: [UInt32]
    let fy: Float, ox: Float, oz: Float, epoch: Int

    @MainActor init(_ a: MeshAnchor, fy: Float, ox: Float, oz: Float, epoch: Int) {
        let g = a.geometry
        let vs = g.vertices, ns = g.normals, fs = g.faces
        let m = a.originFromAnchorTransform
        let rot = simd_float3x3(simd_make_float3(m.columns.0), simd_make_float3(m.columns.1), simd_make_float3(m.columns.2))
        let tr = simd_make_float3(m.columns.3)
        let vp = vs.buffer.contents().advanced(by: vs.offset)
        let np = ns.buffer.contents().advanced(by: ns.offset)
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = []
        p.reserveCapacity(vs.count); n.reserveCapacity(vs.count)
        for i in 0..<vs.count {
            let o = i * vs.stride
            p.append(rot * SIMD3<Float>(vp.loadUnaligned(fromByteOffset: o, as: Float.self), vp.loadUnaligned(fromByteOffset: o + 4, as: Float.self), vp.loadUnaligned(fromByteOffset: o + 8, as: Float.self)) + tr)
            if i < ns.count {
                let q = i * ns.stride
                n.append(rot * SIMD3<Float>(np.loadUnaligned(fromByteOffset: q, as: Float.self), np.loadUnaligned(fromByteOffset: q + 4, as: Float.self), np.loadUnaligned(fromByteOffset: q + 8, as: Float.self)))
            } else { n.append(SIMD3<Float>(0, 1, 0)) }
        }
        let fp = fs.buffer.contents()
        let bpi = fs.bytesPerIndex
        let nidx = fs.count * 3
        var ix: [UInt32] = []
        ix.reserveCapacity(nidx)
        for t in 0..<nidx {
            ix.append(bpi == 2 ? UInt32(fp.loadUnaligned(fromByteOffset: t * 2, as: UInt16.self)) : fp.loadUnaligned(fromByteOffset: t * 4, as: UInt32.self))
        }
        pos = p; nrm = n; idx = ix
        self.fy = fy; self.ox = ox; self.oz = oz; self.epoch = epoch
    }

    private func cellOf(_ x: Float, _ z: Float) -> Int? {
        let i = Int(((x - ox) / NavGrid.cell).rounded(.down)) + NavGrid.n / 2
        let j = Int(((z - oz) / NavGrid.cell).rounded(.down)) + NavGrid.n / 2
        guard i >= 0, j >= 0, i < NavGrid.n, j < NavGrid.n else { return nil }
        return j * NavGrid.n + i
    }

    func run() -> RasterOut {
        var out = RasterOut()
        var t = 0
        while t + 2 < idx.count {
            let i0 = Int(idx[t]), i1 = Int(idx[t + 1]), i2 = Int(idx[t + 2])
            t += 3
            guard i0 < pos.count, i1 < pos.count, i2 < pos.count else { continue }
            let a0 = pos[i0], a1 = pos[i1], a2 = pos[i2]
            var fn = simd_cross(a1 - a0, a2 - a0)
            let fl = simd_length(fn)
            if fl < 1e-9 { continue }
            fn /= fl
            let hmid: Float = (a0.y + a1.y + a2.y) / 3 - fy
            let isFloor = abs(hmid) < 0.07 && fn.y > 0.8
            if !isFloor { out.occIdx.append(UInt32(i0)); out.occIdx.append(UInt32(i1)); out.occIdx.append(UInt32(i2)) }
            // 삼각형 안을 6cm 간격으로 찍어 칸에 담음
            let edge = max(simd_distance(a0, a1), simd_distance(a1, a2), simd_distance(a2, a0))
            let n = min(8, max(1, Int(edge / 0.06)))
            for i in 0...n {
                for j in 0...(n - i) {
                    let u = Float(i) / Float(n), v = Float(j) / Float(n)
                    let p: SIMD3<Float> = a0 + (a1 - a0) * u + (a2 - a0) * v
                    guard let c = cellOf(p.x, p.z) else { continue }
                    let h = p.y - fy
                    if isFloor { out.floor.append(Int32(c)) }
                    else if h > 0.06 && h < 0.40 { out.block.append(Int32(c)) }
                }
            }
        }
        // 가림: 현실 가구 뒤의 개·물건을 가림. 바닥은 뺌.
        // 위를 향한 면(소파 앉는 면 등, 강아지가 딛는 곳)만 2.5cm 물려 발·털이 잘리지 않게 하고, 옆·아래를 향한 면은 0.8cm 만 물림
        // (0.10.3 까지: 모든 면을 2.5cm 물려 가구 둘레 2.5cm 띠로 뒤의 것이 비쳐 보였음)
        if out.occIdx.count >= 3 {
            var op = pos
            for i in 0..<op.count { op[i] -= nrm[i] * (nrm[i].y > 0.7 ? 0.025 : 0.008) }
            out.occPos = op
        }
        return out
    }
}
