import Foundation
import UIKit
import RealityKit
import simd
import Metal
import ImageIO

/// 말티즈 몸 그리기: 뼈를 따라 휜 몸 그물을 여러 겹(껍데기)으로 부풀려 털을 냄.
/// - 겹마다 털 높이 무늬(fur_h, 흰색 = 높음)를 '불투명도'로 쓰고 문턱을 올림 → 위로 갈수록 가닥이 가늘어짐 (오려 내기라 앞뒤가 정확하고 깊이도 씀)
/// - 털은 결(빗어 내린 방향) + 중력으로 처지고, 움직이면 뒤따라 출렁이며, 바닥·앉은 면 아래로는 내려가지 않음(눌림)
/// - 휘는 계산(점 4천 × 겹)은 메인 스레드 밖에서, 끝나면 몸·머리·턱 자리와 함께 한꺼번에 놓음 (따로 놓으면 눈·코가 털과 어긋남 — 어나더 스페이스 0.5.67 교훈)
struct DogVert {
    var p: SIMD3<Float>
    var n: SIMD3<Float>
    var uv: SIMD2<Float>
}

struct SkinJob: Sendable {
    var pose = Pose()
    var growth = Growth.at(400)
    var lift: Float = 0
    var gravity = SIMD3<Float>(0, -1, 0)           // 개 기준 아래 방향
    var floorN = SIMD3<Float>(0, 1, 0)             // 바닥(앉은 면) — 개 기준, 성견 단위
    var floorD: Float = 0
    var sway = SIMD3<Float>(0, 0, 0)               // 움직임에 뒤따르는 털 출렁임 (개 기준)
    var shells = 18
    var eyeOpen: Float = 1                         // 나이 (갓난 강아지는 감김)
}

private final class SkinResult: @unchecked Sendable {
    let verts: [DogVert]
    let ks: [Int]
    let R: [simd_float3x3], T: [SIMD3<Float>], S: [SIMD3<Float>]
    let job: SkinJob
    init(_ v: [DogVert], _ ks: [Int], _ R: [simd_float3x3], _ T: [SIMD3<Float>], _ S: [SIMD3<Float>], _ j: SkinJob) {
        verts = v; self.ks = ks; self.R = R; self.T = T; self.S = S; job = j
    }
}

/// 겹 수 (어느 스레드에서나 읽음)
enum SkinK {
    static let N = 18
}

private let skinQueue = DispatchQueue(label: "dog.skin", qos: .userInitiated)

@MainActor
final class DogSkin {
    static let N = SkinK.N
    let entity = Entity()
    private let D: DogData
    private var meshes: [LowLevelMesh] = []
    private var shells: [ModelEntity] = []
    private let headPivot = Entity(), jawPivot = Entity()
    private var eyes: [ModelEntity] = [], eyeRest: [SIMD3<Float>] = []
    private var tongue: ModelEntity?
    private var busy = false
    private var pending: SkinJob?
    private var first = true
    private var tone: Float = -1
    /// 마지막으로 놓은 뼈 자리 (개 기준, 성견 단위) — 머리·입 자리를 물을 때
    private(set) var T = [SIMD3<Float>](repeating: .zero, count: J.count)
    private(set) var R = [simd_float3x3](repeating: matrix_identity_float3x3, count: J.count)
    private(set) var S = [SIMD3<Float>](repeating: SIMD3<Float>(1, 1, 1), count: J.count)

    static func texture(_ name: String, raw: Bool) -> TextureResource? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Model"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return try? TextureResource.generate(from: cg, options: .init(semantic: raw ? .raw : .color))
    }

    static let repeatSampler: MaterialParameters.Texture.Sampler = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear
        d.magFilter = .linear
        d.mipFilter = .linear
        d.sAddressMode = .repeat
        d.tAddressMode = .repeat
        d.maxAnisotropy = 4
        return MaterialParameters.Texture.Sampler(d)
    }()

    private static var texC: TextureResource?
    private static var texH: TextureResource?

    static func color(_ c: SIMD3<Float>) -> UIColor {
        UIColor(red: CGFloat(min(1, max(0, c.x))), green: CGFloat(min(1, max(0, c.y))), blue: CGFloat(min(1, max(0, c.z))), alpha: 1)
    }

    /// 겹 k 의 재질. clean(0~1)이 낮으면 누렇게, thin(노견)이면 털이 성김
    private static func shellMat(_ k: Int, clean: Float, thin: Float) -> RealityKit.Material {
        let t = Float(k) / Float(N - 1)
        let dirt = SIMD3<Float>(0.80, 0.74, 0.62)
        let base = SIMD3<Float>(0.80 + 0.20 * t, 0.75 + 0.24 * t, 0.70 + 0.27 * t)
        let mixv: SIMD3<Float> = dirt + (SIMD3<Float>(1, 1, 1) - dirt) * clean
        let c: SIMD3<Float> = base * mixv
        var m = PhysicallyBasedMaterial()
        m.roughness = .init(floatLiteral: 0.92)
        m.metallic = .init(floatLiteral: 0)
        if k == 0 {
            m.baseColor = .init(tint: color(SIMD3<Float>(0.90, 0.86, 0.82) * mixv))
            return m
        }
        if let tc = texC, let th = texH {
            var pc = MaterialParameters.Texture(tc)
            pc.sampler = repeatSampler
            var ph = MaterialParameters.Texture(th)
            ph.sampler = repeatSampler
            m.baseColor = .init(tint: color(c), texture: pc)
            m.blending = .transparent(opacity: .init(scale: 1, texture: ph))
            // 문턱: 안쪽 겹은 낮게(속털이 빽빽해 속이 비치지 않게), 바깥 겹만 가늘게 (0.4.0: 0.14 + 0.84t 는 속이 비쳐 보였음)
            m.opacityThreshold = min(0.95, 0.05 + 0.88 * t * t + thin * 0.06 * t)
        } else {
            m.baseColor = .init(tint: color(c))
        }
        return m
    }

    init?() {
        guard let d = DogData.shared else { return nil }
        D = d
        if DogSkin.texC == nil { DogSkin.texC = DogSkin.texture("fur_c", raw: false) }
        if DogSkin.texH == nil { DogSkin.texH = DogSkin.texture("fur_h", raw: true) }
        let attrs = [LowLevelMesh.Attribute(semantic: .position, format: .float3, offset: MemoryLayout<DogVert>.offset(of: \DogVert.p) ?? 0),
                     LowLevelMesh.Attribute(semantic: .normal, format: .float3, offset: MemoryLayout<DogVert>.offset(of: \DogVert.n) ?? 16),
                     LowLevelMesh.Attribute(semantic: .uv0, format: .float2, offset: MemoryLayout<DogVert>.offset(of: \DogVert.uv) ?? 32)]
        let desc = LowLevelMesh.Descriptor(vertexCapacity: d.nv, vertexAttributes: attrs,
                                           vertexLayouts: [LowLevelMesh.Layout(bufferIndex: 0, bufferStride: MemoryLayout<DogVert>.stride)],
                                           indexCapacity: d.idx.count)
        let ids = d.idx
        for k in 0..<DogSkin.N {
            guard let m = try? LowLevelMesh(descriptor: desc) else { return nil }
            m.withUnsafeMutableIndices { raw in
                ids.withUnsafeBytes { src in raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<min(src.count, raw.count)])) }
            }
            m.parts.replaceAll([LowLevelMesh.Part(indexCount: ids.count, topology: .triangle,
                                                  bounds: BoundingBox(min: SIMD3<Float>(repeating: -0.7), max: SIMD3<Float>(repeating: 0.7)))])
            guard let res = try? MeshResource(from: m) else { return nil }
            let e = ModelEntity(mesh: res, materials: [DogSkin.shellMat(k, clean: 1, thin: 0)])
            if k == 10 { e.components.set(GroundingShadowComponent(castsShadow: true)) }
            meshes.append(m); shells.append(e)
            entity.addChild(e)
        }
        entity.addChild(headPivot)
        entity.addChild(jawPivot)
        buildFace()
    }

    /// 털 빛깔 (깨끗함·노견 성김)이 눈에 띄게 달라졌을 때만 재질을 다시 만듦
    func setTone(clean: Float, thin: Float) {
        let key = (clean * 10).rounded() + (thin * 4).rounded() * 100
        guard key != tone else { return }
        tone = key
        for k in 0..<DogSkin.N { shells[k].model?.materials = [DogSkin.shellMat(k, clean: clean, thin: thin)] }
    }

    // MARK: 얼굴 (눈·눈꺼풀·코·입 안·혀)
    private func buildFace() {
        let hr = D.rest[J.head], jr = D.rest[J.jaw]
        var em = PhysicallyBasedMaterial()
        em.baseColor = .init(tint: DogSkin.color(SIMD3<Float>(0.035, 0.022, 0.016)))
        em.roughness = .init(floatLiteral: 0.06)
        em.clearcoat = .init(scale: 1)
        em.clearcoatRoughness = .init(scale: 0.03)
        for s: Float in [1, -1] {
            let c = SIMD3<Float>(s * D.eye.x, D.eye.y, D.eye.z) - hr
            let e = ModelEntity(mesh: .generateSphere(radius: D.eyeR), materials: [em])
            e.position = c
            headPivot.addChild(e)
            eyes.append(e)
            eyeRest.append(c)
        }
        var nm = PhysicallyBasedMaterial()
        nm.baseColor = .init(tint: DogSkin.color(SIMD3<Float>(0.02, 0.018, 0.018)))
        nm.roughness = .init(floatLiteral: 0.32)
        let nose = ModelEntity(mesh: .generateSphere(radius: 1), materials: [nm])
        nose.position = D.nose - hr
        nose.scale = D.noseS
        headPivot.addChild(nose)
        var mm = PhysicallyBasedMaterial()
        mm.baseColor = .init(tint: DogSkin.color(SIMD3<Float>(0.16, 0.05, 0.06)))
        mm.roughness = .init(floatLiteral: 0.6)
        let mouth = ModelEntity(mesh: .generateSphere(radius: 1), materials: [mm])
        mouth.position = SIMD3<Float>(0, 0.2165, 0.176) - hr
        mouth.scale = SIMD3<Float>(0.0135, 0.0055, 0.017)
        headPivot.addChild(mouth)
        var tm = PhysicallyBasedMaterial()
        tm.baseColor = .init(tint: DogSkin.color(SIMD3<Float>(0.92, 0.50, 0.55)))
        tm.roughness = .init(floatLiteral: 0.35)
        let tg = ModelEntity(mesh: .generateSphere(radius: 1), materials: [tm])
        tg.position = SIMD3<Float>(0, 0.2215, 0.176) - jr
        tg.scale = SIMD3<Float>(0.0078, 0.0028, 0.014)
        jawPivot.addChild(tg)
        tongue = tg
    }

    // MARK: 자세 놓기
    func update(_ job: SkinJob) {
        if first {
            first = false
            apply(Self.compute(D, job))
            return
        }
        if busy { pending = job; return }
        busy = true
        let d = D
        skinQueue.async { [weak self] in
            let r = Self.compute(d, job)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apply(r)
                    self.busy = false
                    if let p = self.pending {
                        self.pending = nil
                        self.update(p)
                    }
                }
            }
        }
    }

    private static func xform(_ R: simd_float3x3, _ S: SIMD3<Float>, _ T: SIMD3<Float>) -> Transform {
        var t = Transform()
        t.rotation = simd_quatf(R)
        t.scale = S
        t.translation = T
        return t
    }

    private func apply(_ r: SkinResult) {
        T = r.T; R = r.R; S = r.S
        let nv = D.nv, stride = MemoryLayout<DogVert>.stride
        let a = r.verts
        var on = [Bool](repeating: false, count: DogSkin.N)
        for (i, k) in r.ks.enumerated() {
            on[k] = true
            let lo = i * nv * stride, hi = (i + 1) * nv * stride
            let m = meshes[k]
            m.withUnsafeMutableBytes(bufferIndex: 0) { raw in
                a.withUnsafeBytes { src in
                    guard hi <= src.count else { return }
                    raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[lo..<min(hi, lo + raw.count)]))
                }
            }
        }
        for k in 0..<DogSkin.N where shells[k].isEnabled != on[k] { shells[k].isEnabled = on[k] }
        headPivot.transform = DogSkin.xform(r.R[J.head], r.S[J.head], r.T[J.head])
        jawPivot.transform = DogSkin.xform(r.R[J.jaw], r.S[J.jaw], r.T[J.jaw])
        // 눈 감기: 검은 눈을 위아래로 눌러 가는 선으로 (말티즈 눈가는 검은 테라 감으면 검은 선으로 보임)
        // 0.4.0 까지는 밝은 살색 눈꺼풀 뚜껑(눈보다 큼)이 덮어, 감거나 반쯤 감으면 흰 눈알처럼 보여 무서웠음
        let lidv = min(1, max(r.job.pose.lid, 1 - r.job.eyeOpen))
        let open: Float = 1 - lidv
        let h: Float = 0.14 + 0.86 * open
        for (i, e) in eyes.enumerated() {
            e.scale = SIMD3<Float>(1, h, 1)
            e.position = eyeRest[i] - SIMD3<Float>(0, D.eyeR * 0.35 * (1 - h), 0)
        }
        if let tg = tongue {
            let tv = min(1, max(0, r.job.pose.tongue))
            let jr = D.rest[J.jaw]
            tg.position = SIMD3<Float>(0, 0.2215, 0.176 + 0.013 * tv) - jr
            tg.scale = SIMD3<Float>(0.0078, 0.0028, 0.014 * (1 + 0.85 * tv))
            tg.orientation = Q.rx(0.4 * tv)
        }
    }

    private nonisolated static func compute(_ D: DogData, _ job: SkinJob) -> SkinResult {
        let (R, T, S) = D.fk(job.pose, job.growth, lift: job.lift)
        var A = [simd_float3x3](repeating: matrix_identity_float3x3, count: J.count)
        var B = [SIMD3<Float>](repeating: .zero, count: J.count)
        for i in 0..<J.count {
            let sc = simd_float3x3(diagonal: S[i])
            A[i] = R[i] * sc
            B[i] = T[i] - A[i] * D.rest[i]
        }
        let n = D.nv
        let M = max(4, min(SkinK.N, job.shells))
        var ks: [Int] = []
        for i in 0..<M {
            let k = Int((Float(i) * Float(SkinK.N - 1) / Float(M - 1)).rounded())
            if ks.last != k { ks.append(k) }
        }
        var out = [DogVert](repeating: DogVert(p: .zero, n: .zero, uv: .zero), count: n * ks.count)
        let cb = job.growth.coatBody, cl = job.growth.coatLong, g = max(0.2, job.growth.g)
        let fn = job.floorN, fd = job.floorD
        for v in 0..<n {
            var p = SIMD3<Float>(0, 0, 0), nn = SIMD3<Float>(0, 0, 0), cc = SIMD3<Float>(0, 0, 0)
            let rp = D.pos[v], rn = D.nrm[v], rc = D.comb[v]
            for k in 0..<4 {
                let w = D.bw[v * 4 + k]
                if w <= 0 { continue }
                let b = Int(D.bi[v * 4 + k])
                let pp: SIMD3<Float> = A[b] * rp + B[b]
                p += pp * w
                nn += (R[b] * rn) * w
                cc += (R[b] * rc) * w
            }
            let nl = simd_length(nn)
            if nl > 1e-6 { nn /= nl }
            var d: SIMD3<Float> = nn + cc
            let dl = simd_length(d)
            if dl > 1e-6 { d /= dl }
            let lg = D.lng[v]
            let L: Float = D.fur[v] * (cb + (cl - cb) * lg) / g
            let droop: SIMD3<Float> = job.gravity * (0.20 + 0.12 * lg) + job.sway * (0.25 + 0.75 * lg)
            let uv = D.uv[v]
            for (i, k) in ks.enumerated() {
                let t = Float(k) / Float(SkinK.N - 1)
                var q: SIMD3<Float> = p + (d * t + droop * (t * t)) * L
                let h: Float = simd_dot(q, fn) - fd - 0.0015 * t
                if h < 0 { q -= fn * h }
                out[i * n + v] = DogVert(p: q, n: nn, uv: uv)
            }
        }
        return SkinResult(out, ks, R, T, S, job)
    }
}
