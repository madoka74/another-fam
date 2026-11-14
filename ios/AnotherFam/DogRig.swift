import Foundation
import simd

/// 말티즈 뼈대·그물·움직임 자료 (Model/dog.bin, dog_anim.bin — tools/dog_build.py, dog_anim.py 가 만듦).
/// 좌표: +Z 앞(코), +Y 위, +X 개의 왼쪽. 단위 m, 다 자란 개 크기 기준 — 나이에 따른 크기·비율은 Growth 가 뼈마다 배율로 줌.
/// 도구(tools/dogrig.py)와 같은 식이라 도구에서 그려 확인한 자세가 그대로 나옴. 식을 바꾸면 양쪽을 같이 바꿀 것

enum Q {
    static func rx(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3<Float>(1, 0, 0)) }
    static func ry(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3<Float>(0, 1, 0)) }
    static func rz(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3<Float>(0, 0, 1)) }
    static let id = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    static func ss(_ t: Float) -> Float { let c = min(1, max(0, t)); return c * c * (3 - 2 * c) }
    static func adiff(_ a: Float, _ b: Float) -> Float {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }
    /// 꺾은선 표 읽기 (xs 오름차순)
    static func interp(_ x: Float, _ xs: [Float], _ ys: [Float]) -> Float {
        if x <= xs[0] { return ys[0] }
        let n = xs.count
        if x >= xs[n - 1] { return ys[n - 1] }
        var i = 1
        while i < n - 1 && x > xs[i] { i += 1 }
        let t = (x - xs[i - 1]) / max(1e-6, xs[i] - xs[i - 1])
        return ys[i - 1] + (ys[i] - ys[i - 1]) * t
    }
    static func nlerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
        let d = simd_dot(a.vector, b.vector)
        let bv = d < 0 ? -b.vector : b.vector
        let v = a.vector + (bv - a.vector) * t
        let l = simd_length(v)
        return l > 1e-6 ? simd_quatf(vector: v / l) : a
    }
}

/// 뼈 번호 (tools/dogrig.py JOINTS 순서)
enum J {
    static let root = 0, spine = 1, chest = 2, neck = 3, head = 4, jaw = 5, earL = 6, earR = 7
    static let tail1 = 8, tail2 = 9, tail3 = 10, tail4 = 11
    static let FL0 = 12, FL2 = 14, FR0 = 15, FR2 = 17, HL0 = 18, HL2 = 20, HR0 = 21, HR2 = 23
    static let count = 24
    static let paws = [14, 17, 20, 23]
}

/// 나이(개 나이, 날)에 따른 크기·비율·털. 표는 tools/dogrig.py growth(), tools/preview.py coat() 와 같음
struct Growth: Sendable {
    var g: Float                        // 전체 크기 (성견 1)
    var scale: [SIMD3<Float>]           // 묶음(0 몸통 1 머리 2 주둥이 3 귀 4 꼬리 5 다리)마다 가로·세로·앞뒤
    var coatBody: Float, coatLong: Float
    var legY: Float { scale[5].y }

    /// 나이 듦 정도 (7살부터 서서히 0 → 13살 1): 자세·눈·털·움직임에 씀
    static func old(_ age: Float) -> Float { Q.interp(age, [2555, 3650, 4745], [0, 0.55, 1]) }

    static func at(_ age: Float) -> Growth {
        let a = max(0, age)
        let g = Q.interp(a, [0, 14, 28, 56, 90, 180, 300, 365], [0.30, 0.36, 0.42, 0.52, 0.64, 0.86, 0.97, 1.0])
        let head = Q.interp(a, [0, 28, 56, 120, 240, 365], [1.42, 1.36, 1.28, 1.17, 1.06, 1.0])
        let muz = Q.interp(a, [0, 28, 56, 120, 240, 365], [0.52, 0.62, 0.74, 0.88, 0.97, 1.0])
        let ear = Q.interp(a, [0, 14, 56, 180, 365], [0.42, 0.5, 0.78, 0.95, 1.0])
        let tail = Q.interp(a, [0, 56, 180, 365], [0.55, 0.8, 0.95, 1.0])
        let leg = Q.interp(a, [0, 21, 56, 120, 240, 365], [0.50, 0.58, 0.76, 0.90, 0.98, 1.0])
        let girth = Q.interp(a, [0, 28, 56, 120, 365, 2900, 3650, 4745], [1.12, 1.16, 1.12, 1.04, 1.0, 1.03, 0.97, 0.93])
        let legw = Q.interp(a, [0, 56, 180, 365], [1.25, 1.15, 1.03, 1.0])
        let sc: [SIMD3<Float>] = [SIMD3<Float>(girth, girth, 1), SIMD3<Float>(head, head, head), SIMD3<Float>(head * 0.96, head * 0.96, head * muz),
                                  SIMD3<Float>(repeating: ear * head), SIMD3<Float>(repeating: tail), SIMD3<Float>(legw, leg, legw)]
        let cb = Q.interp(a, [0, 14, 28, 56, 180, 365, 3650, 4745], [0.10, 0.16, 0.27, 0.46, 0.80, 1.0, 1.0, 0.92])
        let cl = Q.interp(a, [0, 28, 56, 180, 365, 540], [0.07, 0.14, 0.26, 0.60, 0.88, 1.0])
        return Growth(g: g, scale: sc, coatBody: cb, coatLong: cl)
    }
}

/// 한 순간의 자세
struct Pose: Sendable {
    var root = SIMD3<Float>(0, 0, 0)                      // 쉬는 자리에서 옮긴 만큼 (성견 크기)
    var q = [simd_quatf](repeating: Q.id, count: J.count)
    var lid: Float = 0, tongue: Float = 0, wag: Float = 0.3, sq: Float = 0

    static func mix(_ a: Pose, _ b: Pose, _ t: Float) -> Pose {
        if t <= 0 { return a }
        if t >= 1 { return b }
        var o = a
        o.root = a.root + (b.root - a.root) * t
        for i in 0..<J.count { o.q[i] = Q.nlerp(a.q[i], b.q[i], t) }
        o.lid = a.lid + (b.lid - a.lid) * t
        o.tongue = a.tongue + (b.tongue - a.tongue) * t
        o.wag = a.wag + (b.wag - a.wag) * t
        o.sq = a.sq + (b.sq - a.sq) * t
        return o
    }
}

struct Clip: Sendable {
    var name: String
    var n: Int
    var loop: Bool
    var speed: Float
    var events: [(t: Float, name: String)]
    var mask: Bool
    var tag: String
    var off: Int
    var dur: Float { Float(loop ? n : max(1, n - 1)) / DogData.fps }
}

/// 읽기 전용 자료 (다른 스레드에서도 씀)
final class DogData: @unchecked Sendable {
    static let fps: Float = 30
    let nv: Int, nt: Int
    let pos: [SIMD3<Float>], nrm: [SIMD3<Float>], comb: [SIMD3<Float>]
    let uv: [SIMD2<Float>]
    let fur: [Float], lng: [Float]
    let bi: [Int32]                    // 점마다 뼈 4
    let bw: [Float]                    // 점마다 무게 4
    let idx: [UInt32]
    let parent: [Int], rest: [SIMD3<Float>], group: [Int]
    let eye: SIMD3<Float>, eyeR: Float, nose: SIMD3<Float>, noseS: SIMD3<Float>
    let pawFront: SIMD3<Float>, pawHind: SIMD3<Float>, hipY: Float
    let stride: Int
    let frames: [Int16]
    let clips: [String: Clip]

    static let shared: DogData? = load()

    private init(nv: Int, nt: Int, pos: [SIMD3<Float>], nrm: [SIMD3<Float>], comb: [SIMD3<Float>], uv: [SIMD2<Float>], fur: [Float], lng: [Float],
                 bi: [Int32], bw: [Float], idx: [UInt32], parent: [Int], rest: [SIMD3<Float>], group: [Int], eye: SIMD3<Float>, eyeR: Float,
                 nose: SIMD3<Float>, noseS: SIMD3<Float>, pawFront: SIMD3<Float>, pawHind: SIMD3<Float>, hipY: Float, stride: Int, frames: [Int16], clips: [String: Clip]) {
        self.nv = nv; self.nt = nt; self.pos = pos; self.nrm = nrm; self.comb = comb; self.uv = uv; self.fur = fur; self.lng = lng
        self.bi = bi; self.bw = bw; self.idx = idx; self.parent = parent; self.rest = rest; self.group = group
        self.eye = eye; self.eyeR = eyeR; self.nose = nose; self.noseS = noseS; self.pawFront = pawFront; self.pawHind = pawHind; self.hipY = hipY
        self.stride = stride; self.frames = frames; self.clips = clips
    }

    private static func v3(_ a: Any?) -> SIMD3<Float> {
        guard let l = a as? [Any], l.count >= 3 else { return .zero }
        func f(_ x: Any) -> Float { Float((x as? NSNumber)?.doubleValue ?? 0) }
        return SIMD3<Float>(f(l[0]), f(l[1]), f(l[2]))
    }

    private static func chunk(_ name: String, _ magic: String) -> (json: [String: Any], body: Foundation.Data)? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "bin", subdirectory: "Model"),
              let d = try? Foundation.Data(contentsOf: url), d.count > 8,
              String(data: d.subdata(in: 0..<4), encoding: .ascii) == magic else { return nil }
        let len = d.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))) }
        guard d.count >= 8 + len, let js = try? JSONSerialization.jsonObject(with: d.subdata(in: 8..<(8 + len))) as? [String: Any] else { return nil }
        return (js, d.subdata(in: (8 + len)..<d.count))
    }

    private static func load() -> DogData? {
        guard let c1 = chunk("dog", "AFD1"), let c2 = chunk("dog_anim", "AFA1") else { return nil }
        let m = c1.json, body = c1.body, am = c2.json, ab = c2.body
        let nv = (m["nv"] as? NSNumber)?.intValue ?? 0, nt = (m["nt"] as? NSNumber)?.intValue ?? 0
        guard nv > 0, nt > 0, body.count >= nv * 84 + nt * 12, let js = m["joints"] as? [[String: Any]], js.count == J.count else { return nil }
        var pos: [SIMD3<Float>] = [], nrm: [SIMD3<Float>] = [], comb: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = []
        var fur: [Float] = [], lng: [Float] = [], bi: [Int32] = [], bw: [Float] = [], idx: [UInt32] = []
        pos.reserveCapacity(nv); nrm.reserveCapacity(nv); comb.reserveCapacity(nv); uv.reserveCapacity(nv)
        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            func f(_ o: Int) -> Float { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
            for v in 0..<nv {
                let o = v * 84
                pos.append(SIMD3<Float>(f(o), f(o + 4), f(o + 8)))
                nrm.append(SIMD3<Float>(f(o + 12), f(o + 16), f(o + 20)))
                uv.append(SIMD2<Float>(f(o + 24), f(o + 28)))
                comb.append(SIMD3<Float>(f(o + 32), f(o + 36), f(o + 40)))
                fur.append(f(o + 44)); lng.append(f(o + 48))
                for k in 0..<4 { bi.append(Int32(f(o + 52 + k * 4).rounded())) }
                for k in 0..<4 { bw.append(f(o + 68 + k * 4)) }
            }
            let o = nv * 84
            idx.reserveCapacity(nt * 3)
            for i in 0..<(nt * 3) { idx.append(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + i * 4, as: UInt32.self))) }
        }
        var parent: [Int] = [], rest: [SIMD3<Float>] = [], group: [Int] = []
        for j in js {
            parent.append((j["p"] as? NSNumber)?.intValue ?? -1)
            rest.append(v3(j["r"]))
            group.append((j["g"] as? NSNumber)?.intValue ?? 0)
        }
        let stride = (am["stride"] as? NSNumber)?.intValue ?? 103
        var frames: [Int16] = []
        let nfr = ab.count / 2
        frames.reserveCapacity(nfr)
        ab.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<nfr { frames.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) }
        }
        var clips: [String: Clip] = [:]
        for c in (am["clips"] as? [[String: Any]]) ?? [] {
            guard let name = c["name"] as? String else { continue }
            var ev: [(t: Float, name: String)] = []
            for e in (c["events"] as? [[Any]]) ?? [] where e.count == 2 {
                ev.append((Float((e[0] as? NSNumber)?.doubleValue ?? 0), (e[1] as? String) ?? ""))
            }
            let cl = Clip(name: name, n: (c["n"] as? NSNumber)?.intValue ?? 1, loop: (c["loop"] as? NSNumber)?.boolValue ?? false,
                          speed: Float((c["speed"] as? NSNumber)?.doubleValue ?? 0), events: ev, mask: ((c["mask"] as? String) ?? "") == "head",
                          tag: (c["tag"] as? String) ?? "", off: (c["off"] as? NSNumber)?.intValue ?? 0)
            guard cl.off / 2 + cl.n * stride <= frames.count else { continue }
            clips[name] = cl
        }
        return DogData(nv: nv, nt: nt, pos: pos, nrm: nrm, comb: comb, uv: uv, fur: fur, lng: lng, bi: bi, bw: bw, idx: idx,
                       parent: parent, rest: rest, group: group, eye: v3(m["eye"]), eyeR: Float((m["eyeR"] as? NSNumber)?.doubleValue ?? 0.01),
                       nose: v3(m["nose"]), noseS: v3(m["noseS"]), pawFront: v3(m["pawFront"]), pawHind: v3(m["pawHind"]),
                       hipY: Float((m["hipY"] as? NSNumber)?.doubleValue ?? 0.137), stride: stride, frames: frames, clips: clips)
    }

    private func read(_ c: Clip, _ f: Int, _ p: inout Pose) {
        let o = c.off / 2 + f * stride
        p.root = SIMD3<Float>(Float(frames[o]), Float(frames[o + 1]), Float(frames[o + 2])) / 20000
        for j in 0..<J.count {
            let k = o + 3 + j * 4
            let w = Float(frames[k]) / 32767, x = Float(frames[k + 1]) / 32767, y = Float(frames[k + 2]) / 32767, z = Float(frames[k + 3]) / 32767
            p.q[j] = simd_quatf(ix: x, iy: y, iz: z, r: w)
        }
        let e = o + 3 + J.count * 4
        p.lid = Float(frames[e]) / 8000; p.tongue = Float(frames[e + 1]) / 8000; p.wag = Float(frames[e + 2]) / 8000; p.sq = Float(frames[e + 3]) / 8000
    }

    /// 동작의 t 초 자세 (장 사이는 이어 줌). 되풀이 동작은 끝과 처음을 이음
    func sample(_ c: Clip, _ t: Float) -> Pose {
        var a = Pose(), b = Pose()
        let x = max(0, t) * DogData.fps
        var f0 = Int(x)
        let u = x - Float(f0)
        var f1 = f0 + 1
        if c.loop { f0 %= c.n; f1 %= c.n } else { f0 = min(f0, c.n - 1); f1 = min(f1, c.n - 1) }
        read(c, f0, &a)
        if f1 == f0 || u < 0.001 { return a }
        read(c, f1, &b)
        return Pose.mix(a, b, u)
    }

    /// 뼈 세계 행렬 (개 기준, 성견 단위 × 나이 비율). R 돌림, T 자리, S 배율
    func fk(_ p: Pose, _ gr: Growth, lift: Float = 0) -> (R: [simd_float3x3], T: [SIMD3<Float>], S: [SIMD3<Float>]) {
        var R = [simd_float3x3](repeating: matrix_identity_float3x3, count: J.count)
        var T = [SIMD3<Float>](repeating: .zero, count: J.count)
        var S = [SIMD3<Float>](repeating: SIMD3<Float>(1, 1, 1), count: J.count)
        let ly = gr.legY
        for i in 0..<J.count {
            S[i] = gr.scale[group[i]]
            let m = simd_matrix3x3(p.q[i])
            let pa = parent[i]
            if pa < 0 {
                R[i] = m
                let y0: Float = (rest[i].y - hipY) * S[i].y + hipY * ly
                T[i] = SIMD3<Float>(p.root.x, y0 + p.root.y * ly + lift, rest[i].z + p.root.z)
            } else {
                R[i] = R[pa] * m
                let d: SIMD3<Float> = (rest[i] - rest[pa]) * S[pa]
                T[i] = T[pa] + R[pa] * d
            }
        }
        return (R, T, S)
    }

    /// 가장 낮은 곳 (발바닥 넷 + 몸통 아랫면 셋) — 땅에 맞출 때
    func lowest(_ R: [simd_float3x3], _ T: [SIMD3<Float>], _ S: [SIMD3<Float>]) -> Float {
        var lo: Float = 9
        for (k, i) in J.paws.enumerated() {
            let pw: SIMD3<Float> = (k < 2 ? pawFront : pawHind) * S[i]
            lo = min(lo, (T[i] + R[i] * pw).y)
        }
        let belly: Float = 0.05 * S[J.root].y
        lo = min(lo, T[J.root].y - belly, T[J.spine].y - belly, T[J.chest].y - belly * 1.08)
        return lo
    }
}
