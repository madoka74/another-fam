import Foundation
import UIKit
import RealityKit
import simd

/// 공간에 꺼내 놓는 물건 (그릇·잠자리·패드·장난감·손에 쥐는 도구·치울 것)
/// - 장난감·도구는 현실 가구·바닥(스캔 그물)에 부딪히고 구름 (RealityKit 물리)
/// - 손으로 직접 집어야 잡힘 (엄지·검지로 집거나 주먹 — 어나더 스페이스 0.5.68 방식). 놓으면 손 빠르기 그대로 날아감
struct PropTag: Component {
    var id: String = ""
}

struct DogTag: Component {}

enum PropKind {
    case fixed          // 바닥에 놓아 두는 것 (그릇·잠자리·패드·계단)
    case toy            // 굴러다니는 장난감
    case tool           // 손에 쥐고 쓰는 것 (젖병·빗·간식·샴푸)
    case mess           // 치울 것 (똥·오줌)
}

@MainActor
final class Prop {
    let id: String              // 물건 종류 (Catalog id) — 치울 것은 "poop"/"pee"
    let uid = UUID().uuidString
    let kind: PropKind
    let entity = Entity()
    private(set) var radius: Float = 0.06           // 잡히는 둘레
    var heldBy: Int?            // 쥔 손 (0 왼, 1 오른)
    var grabRel = Transform()   // 쥔 순간 손목 기준 자리
    var inMouth = false
    var thrownAt: Double = 0
    var fill: Float = 0 { didSet { if fill != oldValue { showFill() } } }
    private var content: ModelEntity?
    private var contentTop: Float = 0.03
    var restAt: Double = 0

    init(_ id: String) {
        self.id = id
        switch id {
        case "ball", "rope", "squeak", "chewbone", "blanky": kind = .toy
        case "bottle", "brush", "treat", "shampoo", "dental": kind = .tool
        case "poop", "pee": kind = .mess
        default: kind = .fixed
        }
        var r: Float = 0.06
        var shape: ShapeResource = .generateSphere(radius: 0.03)
        var mass: Float = 0.05
        var bounce: Float = 0.3
        switch id {
        case "bowl_food", "bowl_water":
            let water = id == "bowl_water"
            add(Geo.lathe([(0.062, 0), (0.078, 0.004), (0.074, 0.042), (0.068, 0.044), (0.064, 0.012), (0, 0.010)], seg: 28),
                Geo.mat(water ? SIMD3<Float>(0.80, 0.86, 0.90) : SIMD3<Float>(0.92, 0.80, 0.72), rough: 0.3))
            let c = ModelEntity(mesh: Geo.lathe([(0, 0), (0.063, 0), (0.063, 0.002), (0, 0.003)], seg: 24) ?? .generateBox(size: 0.001),
                                materials: [Geo.mat(water ? SIMD3<Float>(0.55, 0.75, 0.88) : SIMD3<Float>(0.50, 0.33, 0.20), rough: water ? 0.05 : 0.95)])
            entity.addChild(c)
            content = c
            r = 0.09
            shape = ShapeResource.generateBox(size: SIMD3<Float>(0.16, 0.05, 0.16)).offsetBy(translation: SIMD3<Float>(0, 0.025, 0))
        case "blanket":
            add(.generateBox(width: 0.52, height: 0.014, depth: 0.42, cornerRadius: 0.007), Geo.mat(SIMD3<Float>(0.78, 0.70, 0.60), rough: 1), at: SIMD3<Float>(0, 0.007, 0))
            add(.generateBox(width: 0.50, height: 0.004, depth: 0.10, cornerRadius: 0.002), Geo.mat(SIMD3<Float>(0.64, 0.50, 0.42), rough: 1), at: SIMD3<Float>(0, 0.0155, 0.12))
            r = 0.26
            shape = ShapeResource.generateBox(size: SIMD3<Float>(0.52, 0.02, 0.42)).offsetBy(translation: SIMD3<Float>(0, 0.01, 0))
        case "bed":
            add(Geo.lathe([(0, 0), (0.25, 0), (0.27, 0.03), (0.265, 0.085), (0.235, 0.10), (0.205, 0.085), (0.19, 0.04), (0, 0.035)], seg: 32),
                Geo.mat(SIMD3<Float>(0.62, 0.66, 0.72), rough: 1))
            add(Geo.lathe([(0, 0.035), (0.19, 0.04), (0.17, 0.05), (0, 0.055)], seg: 28), Geo.mat(SIMD3<Float>(0.93, 0.91, 0.86), rough: 1))
            r = 0.27
            shape = ShapeResource.generateBox(size: SIMD3<Float>(0.5, 0.05, 0.5)).offsetBy(translation: SIMD3<Float>(0, 0.025, 0))
        case "pad":
            add(.generateBox(width: 0.46, height: 0.005, depth: 0.34, cornerRadius: 0.002), Geo.mat(SIMD3<Float>(0.55, 0.72, 0.88), rough: 1), at: SIMD3<Float>(0, 0.0025, 0))
            add(.generateBox(width: 0.40, height: 0.003, depth: 0.28), Geo.mat(SIMD3<Float>(0.97, 0.97, 0.96), rough: 1), at: SIMD3<Float>(0, 0.0058, 0))
            let c = ModelEntity(mesh: Geo.lathe([(0, 0), (0.06, 0), (0, 0.0012)], seg: 20) ?? .generateBox(size: 0.001), materials: [Geo.mat(SIMD3<Float>(0.93, 0.86, 0.45), rough: 1)])
            c.position = SIMD3<Float>(0.03, 0.0075, -0.02)
            entity.addChild(c)
            content = c
            r = 0.24
            shape = ShapeResource.generateBox(size: SIMD3<Float>(0.46, 0.012, 0.34)).offsetBy(translation: SIMD3<Float>(0, 0.006, 0))
        case "steps":
            let m = Geo.mat(SIMD3<Float>(0.80, 0.76, 0.70), rough: 1)
            add(.generateBox(width: 0.36, height: 0.14, depth: 0.50, cornerRadius: 0.01), m, at: SIMD3<Float>(0, 0.07, 0))
            add(.generateBox(width: 0.36, height: 0.14, depth: 0.25, cornerRadius: 0.01), m, at: SIMD3<Float>(0, 0.21, -0.125))
            r = 0.3
            shape = ShapeResource.generateBox(size: SIMD3<Float>(0.36, 0.28, 0.5)).offsetBy(translation: SIMD3<Float>(0, 0.14, 0))
        case "ball":
            add(.generateSphere(radius: 0.027), Geo.mat(SIMD3<Float>(0.80, 0.86, 0.25), rough: 0.95))
            r = 0.027; shape = .generateSphere(radius: 0.027); mass = 0.03; bounce = 0.62
        case "rope":
            let m = Geo.mat(SIMD3<Float>(0.86, 0.80, 0.66), rough: 1), k = Geo.mat(SIMD3<Float>(0.75, 0.30, 0.28), rough: 1)
            add(Geo.lathe([(0, -0.09), (0.011, -0.088), (0.011, 0.088), (0, 0.09)], seg: 12), m, rot: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
            add(.generateSphere(radius: 0.02), k, at: SIMD3<Float>(0.085, 0, 0))
            add(.generateSphere(radius: 0.02), k, at: SIMD3<Float>(-0.085, 0, 0))
            r = 0.1; shape = .generateBox(size: SIMD3<Float>(0.21, 0.036, 0.036)); mass = 0.06; bounce = 0.15
        case "squeak", "chewbone":
            let col = id == "squeak" ? SIMD3<Float>(0.35, 0.70, 0.86) : SIMD3<Float>(0.90, 0.84, 0.70)
            let m = Geo.mat(col, rough: id == "squeak" ? 0.45 : 0.8)
            add(Geo.lathe([(0, -0.045), (0.009, -0.044), (0.009, 0.044), (0, 0.045)], seg: 12), m, rot: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
            for sx: Float in [-1, 1] {
                for sz: Float in [-1, 1] { add(.generateSphere(radius: 0.013), m, at: SIMD3<Float>(sx * 0.047, 0, sz * 0.009)) }
            }
            r = 0.062; shape = .generateBox(size: SIMD3<Float>(0.12, 0.026, 0.044)); mass = 0.04; bounce = 0.3
        case "blanky":
            buildBlanky()
            r = 0.11; shape = .generateBox(size: SIMD3<Float>(0.07, 0.20, 0.05)); mass = 0.05; bounce = 0.1
        case "bottle":
            add(Geo.lathe([(0, 0), (0.019, 0), (0.020, 0.07), (0.013, 0.082), (0.013, 0.09), (0.006, 0.10), (0.004, 0.112), (0, 0.114)], seg: 20),
                Geo.mat(SIMD3<Float>(0.96, 0.95, 0.90), rough: 0.25), at: SIMD3<Float>(0, -0.05, 0))
            add(Geo.lathe([(0, 0.082), (0.0145, 0.082), (0.0145, 0.092), (0, 0.092)], seg: 20), Geo.mat(SIMD3<Float>(0.45, 0.70, 0.85), rough: 0.5), at: SIMD3<Float>(0, -0.05, 0))
            r = 0.06; shape = .generateBox(size: SIMD3<Float>(0.04, 0.115, 0.04)); mass = 0.08; bounce = 0.1
        case "brush":
            add(.generateBox(width: 0.045, height: 0.014, depth: 0.085, cornerRadius: 0.005), Geo.mat(SIMD3<Float>(0.62, 0.45, 0.30), rough: 0.6))
            add(.generateBox(width: 0.038, height: 0.012, depth: 0.075), Geo.mat(SIMD3<Float>(0.12, 0.12, 0.12), rough: 1), at: SIMD3<Float>(0, -0.012, 0))
            add(.generateBox(width: 0.02, height: 0.012, depth: 0.09, cornerRadius: 0.005), Geo.mat(SIMD3<Float>(0.62, 0.45, 0.30), rough: 0.6), at: SIMD3<Float>(0, 0, -0.085))
            r = 0.07; shape = .generateBox(size: SIMD3<Float>(0.045, 0.028, 0.17)); mass = 0.06; bounce = 0.1
        case "treat", "dental":
            let c = id == "treat" ? SIMD3<Float>(0.62, 0.38, 0.22) : SIMD3<Float>(0.55, 0.78, 0.50)
            add(.generateBox(width: id == "treat" ? 0.03 : 0.075, height: 0.01, depth: 0.014, cornerRadius: 0.004), Geo.mat(c, rough: 0.9))
            r = 0.04; shape = .generateBox(size: SIMD3<Float>(0.03, 0.012, 0.016)); mass = 0.01; bounce = 0.1
        case "shampoo":
            add(Geo.lathe([(0, 0), (0.024, 0), (0.024, 0.09), (0.010, 0.10), (0.010, 0.118), (0, 0.118)], seg: 20), Geo.mat(SIMD3<Float>(0.80, 0.90, 0.96), rough: 0.3), at: SIMD3<Float>(0, -0.055, 0))
            r = 0.06; shape = .generateBox(size: SIMD3<Float>(0.048, 0.12, 0.048)); mass = 0.1; bounce = 0.1
        case "poop":
            let m = Geo.mat(SIMD3<Float>(0.30, 0.19, 0.10), rough: 0.9)
            add(.generateSphere(radius: 0.011), m, at: SIMD3<Float>(0, 0.009, 0))
            add(.generateSphere(radius: 0.009), m, at: SIMD3<Float>(0.014, 0.007, 0.006))
            add(.generateSphere(radius: 0.008), m, at: SIMD3<Float>(-0.004, 0.006, 0.015))
            r = 0.05; shape = ShapeResource.generateBox(size: SIMD3<Float>(0.09, 0.05, 0.09)).offsetBy(translation: SIMD3<Float>(0, 0.02, 0))
        default: // pee
            add(Geo.lathe([(0, 0), (0.07, 0), (0, 0.001)], seg: 22), Geo.mat(SIMD3<Float>(0.90, 0.84, 0.40), rough: 0.08), at: SIMD3<Float>(0, 0.002, 0))
            r = 0.08; shape = ShapeResource.generateBox(size: SIMD3<Float>(0.16, 0.03, 0.16)).offsetBy(translation: SIMD3<Float>(0, 0.015, 0))
        }
        radius = r
        entity.components.set(PropTag(id: uid))
        entity.components.set(CollisionComponent(shapes: [shape]))
        entity.components.set(InputTargetComponent())
        if kind == .toy || kind == .tool {
            entity.components.set(PhysicsBodyComponent(massProperties: PhysicsMassProperties(mass: mass),
                                                       material: PhysicsMaterialResource.generate(friction: 0.7, restitution: bounce), mode: .dynamic))
            entity.components.set(PhysicsMotionComponent())
        }
        showFill()
    }

    private func add(_ mesh: MeshResource?, _ m: RealityKit.Material, at p: SIMD3<Float> = .zero, rot: simd_quatf? = nil) {
        guard let mesh else { return }
        let e = ModelEntity(mesh: mesh, materials: [m])
        e.position = p
        if let rot { e.orientation = rot }
        entity.addChild(e)
    }

    /// 블랭키씨 인형: 어나더 스페이스의 블랭키씨 모델을 20cm 봉제 인형으로 (Model/blanky_toy.bin — tools/blanky_toy.py)
    private func buildBlanky() {
        let H: Float = 0.20
        let holder = Entity()
        holder.position = SIMD3<Float>(0, -H / 2, 0)
        entity.addChild(holder)
        guard let url = Bundle.main.url(forResource: "blanky_toy", withExtension: "bin", subdirectory: "Model"),
              let d = try? Foundation.Data(contentsOf: url), d.count > 12 else {
            let e = ModelEntity(mesh: .generateBox(width: 0.06, height: H, depth: 0.04, cornerRadius: 0.02), materials: [Geo.mat(SIMD3<Float>(0.10, 0.09, 0.09), rough: 1)])
            entity.addChild(e)
            return
        }
        var pos: [SIMD3<Float>] = [], nrm: [SIMD3<Float>] = [], idx: [UInt32] = [], parts: [Float] = []
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            func u(_ o: Int) -> Int { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
            func f(_ o: Int) -> Float { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
            let nv = u(4), nt = u(8)
            guard raw.count >= 12 + nv * 24 + nt * 12 + 96 else { return }
            for v in 0..<nv {
                let o = 12 + v * 24
                pos.append(SIMD3<Float>(f(o), f(o + 4), f(o + 8)) * H)
                nrm.append(SIMD3<Float>(f(o + 12), f(o + 16), f(o + 20)))
            }
            let o = 12 + nv * 24
            for i in 0..<(nt * 3) { idx.append(UInt32(u(o + i * 4))) }
            let q = o + nt * 12
            for i in 0..<24 { parts.append(f(q + i * 4)) }
        }
        guard !idx.isEmpty, parts.count == 24 else { return }
        var md = MeshDescriptor(name: "blankyToy")
        md.positions = MeshBuffers.Positions(pos)
        md.normals = MeshBuffers.Normals(nrm)
        md.primitives = .triangles(idx)
        // 봉제 인형: 매트한 딥 다크 차콜 천
        var body = PhysicallyBasedMaterial()
        body.baseColor = .init(tint: UIColor(red: 0.086, green: 0.078, blue: 0.075, alpha: 1))
        body.roughness = .init(floatLiteral: 1)
        body.faceCulling = .none
        if let mesh = try? MeshResource.generate(from: [md]) { holder.addChild(ModelEntity(mesh: mesh, materials: [body])) }
        func box(_ i: Int) -> (c: SIMD3<Float>, h: SIMD3<Float>) {
            (SIMD3<Float>(parts[i * 6], parts[i * 6 + 1], parts[i * 6 + 2]) * H, SIMD3<Float>(parts[i * 6 + 3], parts[i * 6 + 4], parts[i * 6 + 5]) * H)
        }
        let dark = Geo.mat(SIMD3<Float>(0.012, 0.012, 0.012), rough: 0.4)
        for i in 0..<3 {
            let b = box(i)
            let e = ModelEntity(mesh: .generateSphere(radius: 1), materials: [dark])
            e.position = b.c
            e.scale = simd_max(b.h, SIMD3<Float>(repeating: 0.0006))
            holder.addChild(e)
        }
        // 배 구멍 속 빛 구슬 하나 (은은한 하늘빛)
        let ob = box(3)
        var glow = UnlitMaterial(color: UIColor(red: 0.45, green: 0.85, blue: 0.95, alpha: 1))
        glow.blending = .opaque
        let orb = ModelEntity(mesh: .generateSphere(radius: 1), materials: [glow])
        orb.position = ob.c
        orb.scale = SIMD3<Float>(repeating: max(0.002, ob.h.x * 0.8))
        holder.addChild(orb)
    }

    /// 그릇에 담긴 양·패드 얼룩
    private func showFill() {
        guard let c = content else { return }
        if id == "pad" {
            c.isEnabled = fill > 0.01
            c.scale = SIMD3<Float>(repeating: 0.6 + 0.5 * fill)
            return
        }
        c.isEnabled = fill > 0.02
        c.position = SIMD3<Float>(0, 0.012 + 0.024 * min(1, fill), 0)
        let s: Float = 0.92 + 0.12 * min(1, fill)
        c.scale = SIMD3<Float>(s, 1, s)
    }

    var pos: SIMD3<Float> { entity.position(relativeTo: nil) }

    func setMode(_ m: PhysicsBodyMode) {
        guard var b = entity.components[PhysicsBodyComponent.self] else { return }
        if b.mode != m { b.mode = m; entity.components.set(b) }
    }

    func setVelocity(_ v: SIMD3<Float>, spin: SIMD3<Float> = .zero) {
        entity.components.set(PhysicsMotionComponent(linearVelocity: v, angularVelocity: spin))
    }

    var velocity: SIMD3<Float> { entity.components[PhysicsMotionComponent.self]?.linearVelocity ?? .zero }
}

/// 간단한 그물·재질
@MainActor
enum Geo {
    static func mat(_ c: SIMD3<Float>, rough: Float, metal: Float = 0) -> RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1))
        m.roughness = .init(floatLiteral: rough)
        m.metallic = .init(floatLiteral: metal)
        return m
    }

    /// 돌림체: (반지름, 높이) 꺾은선을 y축 둘레로 돌림. 꺾이는 곳마다 점을 따로 두어 모서리가 또렷함
    static func lathe(_ prof: [(Float, Float)], seg: Int) -> MeshResource? {
        var pos: [SIMD3<Float>] = [], nrm: [SIMD3<Float>] = [], idx: [UInt32] = []
        for k in 0..<(prof.count - 1) {
            let a = prof[k], b = prof[k + 1]
            let dr = b.0 - a.0, dy = b.1 - a.1
            let l = max(1e-6, (dr * dr + dy * dy).squareRoot())
            let nr = dy / l, ny = -dr / l
            let base = UInt32(pos.count)
            for j in 0...seg {
                let t = 2 * Float.pi * Float(j) / Float(seg)
                let c = cos(t), s = sin(t)
                pos.append(SIMD3<Float>(a.0 * c, a.1, a.0 * s)); nrm.append(SIMD3<Float>(nr * c, ny, nr * s))
                pos.append(SIMD3<Float>(b.0 * c, b.1, b.0 * s)); nrm.append(SIMD3<Float>(nr * c, ny, nr * s))
            }
            for j in 0..<seg {
                let i0 = base + UInt32(j * 2), i1 = i0 + 1, i2 = i0 + 2, i3 = i0 + 3
                idx.append(contentsOf: [i0, i1, i2, i2, i1, i3])
            }
        }
        var d = MeshDescriptor(name: "lathe")
        d.positions = MeshBuffers.Positions(pos)
        d.normals = MeshBuffers.Normals(nrm)
        d.primitives = .triangles(idx)
        return try? MeshResource.generate(from: [d])
    }
}
