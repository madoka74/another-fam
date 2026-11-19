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

/// 손에 든 도구로 하는 일의 이어지는 값 (붓기·닦기)
struct ToolWork {
    var credit: Float = 0          // 이미 뜯은 사료 한 끼 중 아직 안 부은 양
    var soundAt: Double = 0
    var fullTold = false
    var wipeT: Float = 0
}

@MainActor
final class Prop {
    let id: String              // 물건 종류 (Catalog id) — 치울 것은 "poop"/"pee", 손 도구는 "foodbag"(사료 봉지)·"jug"(물병)·"padsheet"(새 패드 한 장)·"bag"(배변 봉투)
    let uid = UUID().uuidString
    let kind: PropKind
    let entity = Entity()
    private(set) var radius: Float = 0.06           // 잡히는 둘레
    var heldBy: Int?            // 쥔 손 (0 왼, 1 오른)
    var grabRel = Transform()   // 쥔 순간 손목 기준 자리
    var inMouth = false
    var thrownAt: Double = 0
    var fill: Float = 0 { didSet { if fill != oldValue { showFill() } } }
    var foodId = "" { didSet { if foodId != oldValue { paintBag() } } }
    var used = false { didSet { if used != oldValue { showUsed() } } }
    /// 붓는 입구 (물건 기준)
    private(set) var spout = SIMD3<Float>(0, 0.1, 0)
    private var content: ModelEntity?
    private var kib: [Entity] = []                  // 사료 알갱이 층 (밥그릇)
    private var padStains: [ModelEntity] = []       // 패드: 쓸 때마다 하나씩 생기는 얼룩
    private var padDots: [ModelEntity] = []         // 패드: 흡수 표시 점 3개
    /// 패드를 쓴 횟수 (0~3)
    var padUsed: Int { Int((min(1, max(0, fill)) * 3).rounded()) }
    static func padDotMat(_ wet: Bool) -> RealityKit.Material {
        wet ? Geo.mat(SIMD3<Float>(0.93, 0.74, 0.22), rough: 0.6) : Geo.mat(SIMD3<Float>(0.95, 0.96, 0.97), rough: 0.6)
    }
    private var waterLine: ModelEntity?             // 물그릇 벽에 닿은 물 높이 선
    private var waterBuilt: Float = -1              // 물 덩어리를 마지막으로 만든 양

    /// 물 재질: 양이 많을수록 더 푸르고 진함 (실제 물도 깊을수록 그릇 바닥이 덜 보이고 푸르게 보임)
    static func waterMat(_ f: Float, line: Bool) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        let a = SIMD3<Float>(0.66, 0.84, 0.93), b = SIMD3<Float>(0.18, 0.47, 0.72)
        let c = line ? b * 0.85 : a + (b - a) * f
        m.baseColor = .init(tint: UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1))
        m.roughness = .init(floatLiteral: 0.03)
        m.clearcoat = .init(scale: 1)
        m.clearcoatRoughness = .init(scale: 0.02)
        m.blending = .transparent(opacity: .init(floatLiteral: line ? 0.8 : 0.32 + 0.4 * f))
        return m
    }
    private var label: ModelEntity?
    private var streamE: ModelEntity?
    private var drops: [ModelEntity] = []
    private var dropPh: Float = 0
    var restAt: Double = 0

    /// 그릇 안쪽 반지름 (높이 y 에서) — 바닥 r 0.060(높이 0.008) → 입구 r 0.077(높이 0.044)
    static func bowlR(_ y: Float) -> Float { 0.060 + max(0, min(1, (y - 0.008) / 0.036)) * 0.017 }

    init(_ id: String) {
        self.id = id
        switch id {
        case "ball", "rope", "squeak", "chewbone", "blanky": kind = .toy
        case "bottle", "brush", "treat", "shampoo", "dental", "foodbag", "jug", "padsheet", "bag": kind = .tool
        case "poop", "pee": kind = .mess
        default: kind = .fixed
        }
        var r: Float = 0.06
        var shape: ShapeResource = .generateSphere(radius: 0.03)
        var shapes: [ShapeResource]?
        var mass: Float = 0.05
        var bounce: Float = 0.3
        switch id {
        case "bowl_food", "bowl_water":
            let water = id == "bowl_water"
            // 밥그릇 = 스테인리스(금속 광택), 물그릇 = 유약 바른 도자기. 둘 다 말린 입구 테두리 + 고무 받침
            let wall: [(Float, Float)] = [(0.066, 0.002), (0.069, 0.004), (0.079, 0.040), (0.084, 0.043), (0.085, 0.0465), (0.082, 0.049), (0.078, 0.047),
                                          (0.077, 0.044), (0.060, 0.008), (0, 0.006)]
            add(Geo.lathe(wall, seg: 40), water ? Geo.mat(SIMD3<Float>(0.86, 0.90, 0.93), rough: 0.12, coat: 1) : Geo.mat(SIMD3<Float>(0.80, 0.81, 0.82), rough: 0.2, metal: 1))
            add(Geo.lathe([(0, 0), (0.066, 0), (0.068, 0.002), (0.066, 0.0035), (0, 0.003)], seg: 32), Geo.mat(SIMD3<Float>(0.08, 0.08, 0.09), rough: 0.9))
            if water {
                // 물: 비치는 물 면 (그릇 바닥이 보임) — 0.9 는 색만 다른 불투명 원판이라 사료와 구별이 안 됐음
                // 0.10.2: 물 덩어리(바닥~물 높이)로 — 얇은 물 면 하나는 흰 도자기에서 얼마나 찼는지 구분이 어려웠음
                let c = ModelEntity(mesh: .generateBox(size: 0.001), materials: [Prop.waterMat(0.5, line: false)])
                entity.addChild(c)
                content = c
                let line = ModelEntity(mesh: .generateBox(size: 0.001), materials: [Prop.waterMat(0.5, line: true)])
                c.addChild(line)
                waterLine = line
            } else {
                // 사료: 그릇 모양대로 쌓인 더미 + 맨 위 알갱이 두 겹(두 가지 색) + 바닥에 남은 몇 알
                let pile = ModelEntity(mesh: Geo.lathe([(0, 0), (1, 0), (0.97, 0.004), (0.7, 0.007), (0, 0.009)], seg: 32) ?? .generateBox(size: 0.001),
                                       materials: [Geo.mat(SIMD3<Float>(0.30, 0.18, 0.09), rough: 0.95)])
                entity.addChild(pile)
                content = pile
                for (k, col) in [SIMD3<Float>(0.50, 0.31, 0.16), SIMD3<Float>(0.40, 0.24, 0.12), SIMD3<Float>(0.46, 0.28, 0.14)].enumerated() {
                    let e = ModelEntity(mesh: Geo.kibble(k), materials: [Geo.mat(col, rough: 0.85)])
                    entity.addChild(e)
                    kib.append(e)
                }
            }
            r = 0.09
            shape = ShapeResource.generateBox(size: SIMD3<Float>(0.17, 0.05, 0.17)).offsetBy(translation: SIMD3<Float>(0, 0.025, 0))
            // 부딪힘은 바닥 + 둘레 벽 (속이 꽉 찬 상자면 장난감이 그릇 위에 떠서 얹힘)
            var cs: [ShapeResource] = [ShapeResource.generateBox(size: SIMD3<Float>(0.13, 0.010, 0.13)).offsetBy(translation: SIMD3<Float>(0, 0.005, 0))]
            for i in 0..<12 {
                let a = Float(i) / 12 * 2 * .pi
                cs.append(ShapeResource.generateBox(size: SIMD3<Float>(0.012, 0.047, 0.046))
                    .offsetBy(rotation: simd_quatf(angle: a, axis: SIMD3<Float>(0, 1, 0)), translation: SIMD3<Float>(sin(a) * 0.076, 0.0235, cos(a) * 0.076)))
            }
            shapes = cs
        case "blanket":
            // 보들보들한 극세사 담요: 잔결 무늬 + 둥근 모서리 + 한쪽 끝 띠
            add(.generateBox(width: 0.54, height: 0.016, depth: 0.44, cornerRadius: 0.008), Geo.fabric("fleece", SIMD3<Float>(0.80, 0.72, 0.62)), at: SIMD3<Float>(0, 0.008, 0))
            add(.generateBox(width: 0.54, height: 0.004, depth: 0.09, cornerRadius: 0.002), Geo.fabric("fleece", SIMD3<Float>(0.62, 0.48, 0.40)), at: SIMD3<Float>(0, 0.0165, 0.155))
            r = 0.27
            shape = ShapeResource.generateBox(size: SIMD3<Float>(0.54, 0.016, 0.44)).offsetBy(translation: SIMD3<Float>(0, 0.008, 0))
        case "bed":
            // 둥근 방석: 바닥 + 통통한 둘레 쿠션(도넛) + 가운데 푹신한 방석
            let fab = Geo.fabric("weave", SIMD3<Float>(0.58, 0.55, 0.53))
            add(Geo.lathe([(0, 0), (0.27, 0), (0.275, 0.012), (0, 0.012)], seg: 40), fab)
            var ring: [(Float, Float)] = []
            for i in 0...18 {
                let t = Float(i) / 18 * 2 * .pi
                ring.append((0.22 + 0.052 * cos(t), 0.052 + 0.048 * sin(t)))
            }
            add(Geo.lathe(ring, seg: 40), fab)
            add(Geo.lathe([(0, 0.03), (0.175, 0.03), (0.18, 0.04), (0.17, 0.048), (0.1, 0.053), (0, 0.054)], seg: 36), Geo.fabric("plush", SIMD3<Float>(0.93, 0.90, 0.85)))
            r = 0.28
            shape = ShapeResource.generateBox(size: SIMD3<Float>(0.54, 0.05, 0.54)).offsetBy(translation: SIMD3<Float>(0, 0.025, 0))
            // 부딪힘도 실제 모양대로: 바닥판 + 가운데 방석 + 둘레 쿠션(16조각). 0.10.0 은 높이 5cm 납작한 상자라
            // 공이 그 위에 올라가 둘레 쿠션(10cm)을 뚫고 굴러다녔음
            var cs: [ShapeResource] = [ShapeResource.generateBox(size: SIMD3<Float>(0.54, 0.012, 0.54)).offsetBy(translation: SIMD3<Float>(0, 0.006, 0)),
                                       ShapeResource.generateBox(size: SIMD3<Float>(0.32, 0.05, 0.32)).offsetBy(translation: SIMD3<Float>(0, 0.027, 0))]
            for i in 0..<16 {
                let a = Float(i) / 16 * 2 * .pi
                cs.append(ShapeResource.generateBox(size: SIMD3<Float>(0.10, 0.10, 0.092))
                    .offsetBy(rotation: simd_quatf(angle: a, axis: SIMD3<Float>(0, 1, 0)), translation: SIMD3<Float>(sin(a) * 0.22, 0.05, cos(a) * 0.22)))
            }
            shapes = cs
        case "pad", "padsheet":
            // 배변 패드: 파란 방수 테두리 + 누빔 무늬 흡수면
            add(.generateBox(width: 0.46, height: 0.004, depth: 0.34, cornerRadius: 0.002), Geo.mat(SIMD3<Float>(0.50, 0.70, 0.88), rough: 0.6), at: SIMD3<Float>(0, 0.002, 0))
            add(.generateBox(width: 0.41, height: 0.003, depth: 0.29), Geo.fabric("quilt", SIMD3<Float>(0.97, 0.97, 0.96)), at: SIMD3<Float>(0, 0.0052, 0))
            // 쓸 때마다 자기 자리에 얼룩 하나씩 (3번 쓰면 3개) + 테두리 모서리의 흡수 표시 점 3개(쓸 때마다 하나씩 노랗게)
            // — 실제 패드의 '젖으면 색이 바뀌는 표시선'처럼. 몇 번 썼고 몇 번 남았는지 패드만 봐도 알 수 있게 (0.10.3)
            var sm = PhysicallyBasedMaterial()
            sm.baseColor = .init(tint: UIColor(red: 0.90, green: 0.80, blue: 0.40, alpha: 1))
            sm.roughness = .init(floatLiteral: 0.7)
            sm.blending = .transparent(opacity: .init(floatLiteral: 0.7))
            for (k, (at, r)) in [(SIMD3<Float>(0.03, 0.0072, -0.02), Float(0.06)), (SIMD3<Float>(-0.09, 0.0073, 0.05), 0.052), (SIMD3<Float>(0.10, 0.0074, 0.06), 0.048)].enumerated() {
                let c = ModelEntity(mesh: Geo.puddle(r, seed: 3 + 5 * k) ?? .generateBox(size: 0.001), materials: [sm])
                c.position = at
                c.isEnabled = false
                entity.addChild(c)
                padStains.append(c)
            }
            content = padStains.first
            for k in 0..<3 {
                let d = ModelEntity(mesh: .generateCylinder(height: 0.0008, radius: 0.0065), materials: [Prop.padDotMat(false)])
                d.position = SIMD3<Float>(0.185 - 0.02 * Float(k), 0.0044, 0.1575)
                entity.addChild(d)
                padDots.append(d)
            }
            r = 0.24
            mass = 0.03; bounce = 0
            shape = ShapeResource.generateBox(size: SIMD3<Float>(0.46, 0.012, 0.34)).offsetBy(translation: SIMD3<Float>(0, 0.006, 0))
        case "steps":
            let m = Geo.fabric("weave", SIMD3<Float>(0.80, 0.76, 0.70))
            add(.generateBox(width: 0.36, height: 0.14, depth: 0.50, cornerRadius: 0.012), m, at: SIMD3<Float>(0, 0.07, 0))
            add(.generateBox(width: 0.36, height: 0.14, depth: 0.25, cornerRadius: 0.012), m, at: SIMD3<Float>(0, 0.21, -0.125))
            r = 0.3
            shape = ShapeResource.generateBox(size: SIMD3<Float>(0.36, 0.28, 0.5)).offsetBy(translation: SIMD3<Float>(0, 0.14, 0))
        case "ball":
            // 테니스공: 연둣빛 펠트 + 흰 곡선 솔기
            add(.generateSphere(radius: 0.027), Geo.fabric("tennis", SIMD3<Float>(0.84, 0.90, 0.28)))
            r = 0.027; shape = .generateSphere(radius: 0.027); mass = 0.03; bounce = 0.62
        case "rope":
            let m = Geo.fabric("rope", SIMD3<Float>(0.88, 0.82, 0.68)), k = Geo.fabric("rope", SIMD3<Float>(0.78, 0.32, 0.30))
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
            r = 0.11; shape = .generateBox(size: SIMD3<Float>(0.075, 0.20, 0.05)); mass = 0.06; bounce = 0.05
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
        case "treat":
            // 뼈다귀 모양 비스킷
            let m = Geo.mat(SIMD3<Float>(0.72, 0.48, 0.27), rough: 0.9)
            add(.generateBox(width: 0.024, height: 0.008, depth: 0.009, cornerRadius: 0.003), m)
            for sx: Float in [-1, 1] { for sz: Float in [-1, 1] { add(.generateSphere(radius: 0.0055), m, at: SIMD3<Float>(sx * 0.013, 0, sz * 0.0045)) } }
            r = 0.04; mass = 0.01; bounce = 0.1
        case "dental":
            let m = Geo.mat(SIMD3<Float>(0.55, 0.78, 0.50), rough: 0.8)
            add(Geo.lathe([(0, -0.037), (0.006, -0.035), (0.0065, 0.035), (0, 0.037)], seg: 6), m, rot: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
            r = 0.04; mass = 0.015; bounce = 0.1
        case "shampoo":
            add(Geo.lathe([(0, 0), (0.024, 0), (0.024, 0.09), (0.010, 0.10), (0.010, 0.118), (0, 0.118)], seg: 20), Geo.mat(SIMD3<Float>(0.80, 0.90, 0.96), rough: 0.3), at: SIMD3<Float>(0, -0.055, 0))
            r = 0.06; shape = .generateBox(size: SIMD3<Float>(0.048, 0.12, 0.048)); mass = 0.1; bounce = 0.1
        case "foodbag":
            // 지퍼 달린 사료 봉지 (세워 두는 봉지): 사료 종류에 따라 띠 색, 위 오른쪽 모서리를 뜯어 입구
            add(.generateBox(width: 0.12, height: 0.17, depth: 0.05, cornerRadius: 0.012), Geo.mat(SIMD3<Float>(0.93, 0.91, 0.86), rough: 0.55), at: SIMD3<Float>(0, 0, 0))
            add(.generateBox(width: 0.12, height: 0.012, depth: 0.012, cornerRadius: 0.003), Geo.mat(SIMD3<Float>(0.75, 0.73, 0.70), rough: 0.5), at: SIMD3<Float>(0, 0.088, 0))
            let l = ModelEntity(mesh: .generateBox(width: 0.10, height: 0.07, depth: 0.052, cornerRadius: 0.006), materials: [Geo.mat(SIMD3<Float>(0.85, 0.50, 0.20), rough: 0.6)])
            l.position = SIMD3<Float>(0, -0.02, 0)
            entity.addChild(l)
            label = l
            add(.generateSphere(radius: 0.012), Geo.mat(SIMD3<Float>(0.32, 0.20, 0.10), rough: 0.9), at: SIMD3<Float>(0.044, 0.08, 0))
            spout = SIMD3<Float>(0.05, 0.088, 0)
            r = 0.1; mass = 0.35; bounce = 0.05
        case "jug":
            // 물병: 비치는 파란 플라스틱 + 안의 물 + 손잡이 + 주둥이
            var pm = PhysicallyBasedMaterial()
            pm.baseColor = .init(tint: UIColor(red: 0.70, green: 0.84, blue: 0.95, alpha: 1))
            pm.roughness = .init(floatLiteral: 0.1)
            pm.blending = .transparent(opacity: .init(floatLiteral: 0.55))
            add(Geo.lathe([(0, -0.09), (0.038, -0.09), (0.04, -0.085), (0.04, 0.05), (0.03, 0.075), (0.014, 0.085), (0.014, 0.105), (0, 0.105)], seg: 28), pm)
            var wm = PhysicallyBasedMaterial()
            wm.baseColor = .init(tint: UIColor(red: 0.50, green: 0.70, blue: 0.86, alpha: 1))
            wm.roughness = .init(floatLiteral: 0.05)
            wm.blending = .transparent(opacity: .init(floatLiteral: 0.45))
            add(Geo.lathe([(0, -0.086), (0.035, -0.086), (0.035, 0.03), (0, 0.03)], seg: 24), wm)
            add(Geo.lathe([(0, 0.098), (0.016, 0.098), (0.016, 0.112), (0, 0.112)], seg: 20), Geo.mat(SIMD3<Float>(0.25, 0.50, 0.85), rough: 0.4))
            spout = SIMD3<Float>(0, 0.112, 0)
            r = 0.1; mass = 0.5; bounce = 0.05
        case "bag":
            // 배변 봉투 한 장 (초록 비닐, 손잡이 두 개)
            add(Geo.lathe([(0, -0.045), (0.02, -0.044), (0.032, -0.02), (0.034, 0.02), (0.028, 0.04), (0, 0.042)], seg: 14), Geo.mat(SIMD3<Float>(0.35, 0.62, 0.38), rough: 0.35))
            for sx: Float in [-1, 1] { add(.generateBox(width: 0.008, height: 0.03, depth: 0.004, cornerRadius: 0.002), Geo.mat(SIMD3<Float>(0.35, 0.62, 0.38), rough: 0.35), at: SIMD3<Float>(sx * 0.018, 0.055, 0)) }
            r = 0.06; mass = 0.01; bounce = 0
        case "poop":
            // 굽은 통나무 모양 세 마디 (윤기 있는 짙은 갈색)
            let m = Geo.mat(SIMD3<Float>(0.27, 0.17, 0.09), rough: 0.45)
            let segs: [(SIMD3<Float>, SIMD3<Float>, Float)] = [(SIMD3<Float>(0, 0.008, -0.014), SIMD3<Float>(0.0085, 0.0075, 0.012), 0.3),
                                                               (SIMD3<Float>(0.004, 0.0085, 0.004), SIMD3<Float>(0.009, 0.008, 0.013), -0.2),
                                                               (SIMD3<Float>(-0.002, 0.0075, 0.02), SIMD3<Float>(0.0075, 0.0068, 0.010), -0.7)]
            for (c, sc, yw) in segs {
                let e = ModelEntity(mesh: .generateSphere(radius: 1), materials: [m])
                e.position = c; e.scale = sc; e.orientation = Q.ry(yw)
                entity.addChild(e)
            }
            r = 0.05; shape = ShapeResource.generateBox(size: SIMD3<Float>(0.09, 0.05, 0.09)).offsetBy(translation: SIMD3<Float>(0, 0.02, 0))
        default: // pee: 고르지 않은 테두리의 비치는 웅덩이
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: UIColor(red: 0.93, green: 0.84, blue: 0.42, alpha: 1))
            m.roughness = .init(floatLiteral: 0.03)
            m.clearcoat = .init(scale: 1)
            m.blending = .transparent(opacity: .init(floatLiteral: 0.5))
            let c = ModelEntity(mesh: Geo.puddle(0.075, seed: Int.random(in: 0...99)) ?? .generateBox(size: 0.001), materials: [m])
            c.position = SIMD3<Float>(0, 0.0015, 0)
            entity.addChild(c)
            content = c
            r = 0.08; shape = ShapeResource.generateBox(size: SIMD3<Float>(0.16, 0.03, 0.16)).offsetBy(translation: SIMD3<Float>(0, 0.015, 0))
        }
        radius = r
        // 손에 쥐는 것·장난감은 부딪힘 모양을 실제 그린 모양의 상자에 맞춤 (0.5.x: 어림한 상자가 모양보다 커서 블랭키씨 등이 바닥·담요 위에 떠 있었음)
        if kind == .toy || kind == .tool {
            let vb = entity.visualBounds(relativeTo: entity)
            let e = vb.extents
            if e.x > 0.003 && e.y > 0.003 && e.z > 0.003 && e.x < 1 && e.y < 1 && e.z < 1 {
                if id == "ball" {
                    shape = ShapeResource.generateSphere(radius: max(e.x, e.y, e.z) / 2).offsetBy(translation: vb.center)
                } else {
                    shape = ShapeResource.generateBox(size: e).offsetBy(translation: vb.center)
                }
                halfV = e / 2
                centerV = vb.center
            }
        }
        entity.components.set(PropTag(id: uid))
        entity.components.set(CollisionComponent(shapes: shapes ?? [shape]))
        entity.components.set(InputTargetComponent())
        if kind == .toy || kind == .tool {
            // 무게·도는 무게(관성)를 실제 모양으로 계산 — 0.4.0 은 무게만 주어 관성이 기본값(수십 g 물건에 너무 큼)이라
            // 부딪혀도 잘 돌지 않고 풍선처럼 둥둥 떠다니듯 움직였음
            var b = PhysicsBodyComponent(massProperties: PhysicsMassProperties(shape: shape, mass: mass),
                                         material: PhysicsMaterialResource.generate(friction: id == "blanky" || id == "padsheet" || id == "bag" ? 0.95 : 0.7, restitution: bounce), mode: .dynamic)
            b.linearDamping = id == "padsheet" ? 0.9 : 0.05             // 패드는 종이처럼 천천히 내려앉음
            b.isContinuousCollisionDetectionEnabled = true        // 빨리 던져도 소파·벽(얇은 스캔 면)을 뚫고 지나가지 않게
            b.angularDamping = id == "ball" ? 0.15 : 0.6
            entity.components.set(b)
            entity.components.set(PhysicsMotionComponent())
        } else if kind == .fixed {
            // 바닥에 놓아 두는 것도 부딪힘 몸을 가짐 (0.4.0: 부딪힘 모양만 있고 물리 몸이 없어 장난감이 담요·그릇을 뚫고 바닥까지 묻혔음)
            // 손으로 옮기므로 '움직이게 놓는 몸'(kinematic) — 중력·밀림은 받지 않음
            entity.components.set(PhysicsBodyComponent(massProperties: .default,
                                                       material: PhysicsMaterialResource.generate(friction: 0.9, restitution: 0.05), mode: .kinematic))
        }
        if id == "pee" { fill = 1 }
        showFill()
    }

    private var halfV: SIMD3<Float>?
    private var centerV = SIMD3<Float>(0, 0, 0)
    /// 작아서 손이 조금 빗나가도 잡혀야 하는 것
    var small: Bool { ["treat", "dental", "ball", "bag"].contains(id) }

    private func add(_ mesh: MeshResource?, _ m: RealityKit.Material, at p: SIMD3<Float> = .zero, rot: simd_quatf? = nil) {
        guard let mesh else { return }
        let e = ModelEntity(mesh: mesh, materials: [m])
        e.position = p
        if let rot { e.orientation = rot }
        entity.addChild(e)
    }

    /// 사료 봉지 띠 색: 퍼피 주황, 어덜트 초록, 시니어 파랑
    private func paintBag() {
        guard let l = label else { return }
        let c: SIMD3<Float> = foodId.contains("senior") ? SIMD3<Float>(0.30, 0.50, 0.80) : (foodId.contains("adult") ? SIMD3<Float>(0.35, 0.62, 0.35) : SIMD3<Float>(0.88, 0.52, 0.20))
        l.model?.materials = [Geo.mat(c, rough: 0.6)]
    }

    /// 닦은 패드는 누렇게, 똥을 담은 봉투는 불룩하게
    private func showUsed() {
        guard used else { return }
        if id == "padsheet" {
            let c = ModelEntity(mesh: Geo.puddle(0.07, seed: 7) ?? .generateBox(size: 0.001), materials: [Geo.mat(SIMD3<Float>(0.86, 0.76, 0.40), rough: 0.8)])
            c.position = SIMD3<Float>(0, 0.0072, 0)
            entity.addChild(c)
        } else if id == "bag" {
            entity.children.first?.scale = SIMD3<Float>(1.1, 0.95, 1.25)
        }
    }

    /// 붓는 줄기: 물은 가는 물줄기, 사료는 떨어지는 알갱이 (from 이 nil 이면 숨김)
    func showStream(_ from: SIMD3<Float>?, _ to: SIMD3<Float>?, water: Bool) {
        guard let a = from, let b = to else {
            streamE?.isEnabled = false
            for d in drops where d.isEnabled { d.isEnabled = false }
            return
        }
        let v = b - a
        let l = max(0.01, simd_length(v))
        if water {
            if streamE == nil {
                var m = PhysicallyBasedMaterial()
                m.baseColor = .init(tint: UIColor(red: 0.70, green: 0.84, blue: 0.95, alpha: 1))
                m.roughness = .init(floatLiteral: 0.02)
                m.blending = .transparent(opacity: .init(floatLiteral: 0.5))
                let e = ModelEntity(mesh: Geo.lathe([(0.0035, 0), (0.0035, 1), (0, 1)], seg: 10) ?? .generateBox(size: 0.001), materials: [m])
                entity.addChild(e)
                streamE = e
            }
            guard let e = streamE else { return }
            e.isEnabled = true
            dropPh += 0.37
            e.setPosition(a, relativeTo: nil)
            e.setOrientation(simd_quatf(from: SIMD3<Float>(0, 1, 0), to: v / l), relativeTo: nil)
            e.setScale(SIMD3<Float>(1 + 0.15 * sin(dropPh), l, 1 + 0.15 * cos(dropPh * 1.3)), relativeTo: nil)
        } else {
            if drops.isEmpty {
                let m = Geo.mat(SIMD3<Float>(0.47, 0.29, 0.15), rough: 0.85)
                for _ in 0..<9 {
                    let e = ModelEntity(mesh: .generateSphere(radius: 1), materials: [m])
                    e.scale = SIMD3<Float>(0.0045, 0.0032, 0.0045)
                    entity.addChild(e)
                    drops.append(e)
                }
            }
            dropPh += 0.06
            for (i, d) in drops.enumerated() {
                d.isEnabled = true
                let t = (dropPh + Float(i) / Float(drops.count)).truncatingRemainder(dividingBy: 1)
                let j = SIMD3<Float>(sin(Float(i) * 2.3) * 0.006, 0, cos(Float(i) * 1.7) * 0.006) * t
                d.setPosition(a + v * (t * t) + j, relativeTo: nil)       // 떨어질수록 빨라짐
                d.setScale(SIMD3<Float>(0.0045, 0.0032, 0.0045), relativeTo: nil)
            }
        }
    }

    /// 그릇 속 내용물 윗면 높이 (그릇 밑면 기준)
    var contentY: Float { 0.008 + 0.034 * min(1, fill) }
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
        // 배 구멍 속 빛 하나: 블랭키씨 기준(어나더 스페이스·비전 드럼)과 같이 7색 중 무작위 — 꺼낼 때마다·앱을 열 때마다 새로 고름
        // 숨 쉬듯 2.2초에 커졌다 작아짐 + 빛무리(반투명, 깊이 안 씀)
        let ob = box(3)
        let cols: [SIMD3<Float>] = [[0.2, 0.78, 0.86], [0.84, 0.58, 0.16], [1.0, 0.36, 0.72], [0.62, 1.0, 0.38], [1.0, 0.88, 0.35], [0.45, 0.6, 1.0], [0.75, 0.5, 1.0]]
        let c = cols.randomElement() ?? cols[0]
        let col = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        let r = max(0.002, ob.h.x * 0.8)
        let sph = MeshResource.generateSphere(radius: 1)
        let core = ModelEntity(mesh: sph, materials: [UnlitMaterial(color: col)])
        core.position = ob.c
        core.scale = SIMD3<Float>(repeating: r)
        holder.addChild(core)
        var hm = UnlitMaterial(color: col)
        hm.blending = .transparent(opacity: .init(scale: 0.3))
        hm.writesDepth = false
        let halo = ModelEntity(mesh: sph, materials: [hm])
        halo.position = ob.c
        halo.scale = SIMD3<Float>(repeating: r * 1.5)
        holder.addChild(halo)
        glow = (core, halo, ob.c, r)
    }

    private var glow: (core: Entity, halo: Entity, c: SIMD3<Float>, r: Float)?

    /// 공간에 놓인 뒤 한 번: 빛 숨쉬기를 RealityKit 되풀이 움직임으로 맡김
    func started() {
        guard let g = glow else { return }
        let id = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        func loop(_ e: Entity, _ a: Float, _ b: Float) {
            let anim = FromToByAnimation<Transform>(from: Transform(scale: SIMD3<Float>(repeating: a), rotation: id, translation: g.c),
                                                    to: Transform(scale: SIMD3<Float>(repeating: b), rotation: id, translation: g.c),
                                                    duration: 2.2, timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse)
            if let r = try? AnimationResource.generate(with: anim) { e.playAnimation(r) }
        }
        loop(g.core, g.r * 0.9, g.r * 1.06)
        loop(g.halo, g.r * 1.15, g.r * 2.0)
    }

    /// 그릇에 담긴 양·패드 얼룩·닦이는 오줌
    private func showFill() {
        guard let c = content else { return }
        switch id {
        case "pad", "padsheet":
            // 새 패드는 깨끗하게 (0.10.0: 꺼낸 패드에 쓰던 패드의 얼룩이 그대로 보였음). 쓴 횟수 = fill·3
            _ = c
            let n = padUsed
            for (k, e) in padStains.enumerated() { e.isEnabled = n > k }
            for (k, e) in padDots.enumerated() { e.model?.materials = [Prop.padDotMat(k < n)] }
        case "pee":
            c.isEnabled = fill > 0.02
            c.scale = SIMD3<Float>(0.35 + 0.65 * fill, 1, 0.35 + 0.65 * fill)
        case "bowl_water":
            // 물 = 그릇 바닥부터 물 높이까지 찬 덩어리: 많을수록 진하고 푸르게, 벽에 닿은 물 높이에 진한 물 선
            // (0.10.1 까지: 비치는 얇은 물 면 하나(불투명도 0.42)라 흰 그릇에서 반쯤인지 가득인지 구분이 어려웠음)
            c.isEnabled = fill > 0.02
            guard c.isEnabled else { waterBuilt = -1; return }
            guard waterBuilt < 0 || abs(fill - waterBuilt) > 0.012 else { return }
            waterBuilt = fill
            let f = min(1, fill)
            let y = contentY, r = Prop.bowlR(y) - 0.0008
            let y0: Float = 0.0065, r0: Float = 0.0595
            c.position = .zero
            c.scale = SIMD3<Float>(repeating: 1)
            if let m = Geo.lathe([(0, y0), (r0, y0), (r, y), (0, y)], seg: 40) { c.model?.mesh = m }
            c.model?.materials = [Prop.waterMat(f, line: false)]
            if let l = waterLine {
                if let m = Geo.lathe([(r - 0.0004, y - 0.0022), (r + 0.0002, y + 0.0004)], seg: 48) { l.model?.mesh = m }
                l.model?.materials = [Prop.waterMat(f, line: true)]
            }
        case "bowl_food":
            // 사료: 가득일수록 더미가 높고 넓음. 아주 적으면 바닥에 몇 알만
            let y = contentY
            let r = Prop.bowlR(y) - 0.003
            c.isEnabled = fill > 0.12
            c.position = SIMD3<Float>(0, 0.006, 0)
            c.scale = SIMD3<Float>(r, max(0.2, (y - 0.010) / 0.009), r)
            for (k, e) in kib.enumerated() {
                if k == 2 {
                    e.isEnabled = fill > 0.005 && fill <= 0.12
                    e.position = SIMD3<Float>(0, 0.009, 0)
                    e.scale = SIMD3<Float>(repeating: 1)
                } else {
                    e.isEnabled = fill > 0.12
                    e.position = SIMD3<Float>(0, y - 0.003, 0)
                    let k2 = r / 0.074
                    e.scale = SIMD3<Float>(k2, 1, k2)
                }
            }
        default: break
        }
    }

    var pos: SIMD3<Float> { entity.position(relativeTo: nil) }

    /// 물건의 대략적인 상자 (절반 크기). 바닥에 놓는 것은 밑면이 원점
    private var half: SIMD3<Float> {
        switch id {
        case "bowl_food", "bowl_water": return SIMD3<Float>(0.078, 0.022, 0.078)
        case "blanket": return SIMD3<Float>(0.27, 0.008, 0.22)
        case "bed": return SIMD3<Float>(0.275, 0.05, 0.275)
        case "pad", "padsheet": return SIMD3<Float>(0.23, 0.003, 0.17)
        case "steps": return SIMD3<Float>(0.18, 0.14, 0.25)
        case "ball": return SIMD3<Float>(0.027, 0.027, 0.027)
        case "rope": return SIMD3<Float>(0.105, 0.02, 0.02)
        case "squeak", "chewbone": return SIMD3<Float>(0.06, 0.013, 0.022)
        case "blanky": return SIMD3<Float>(0.035, 0.10, 0.025)
        case "bottle": return SIMD3<Float>(0.02, 0.057, 0.02)
        case "brush": return SIMD3<Float>(0.023, 0.014, 0.085)
        case "shampoo": return SIMD3<Float>(0.024, 0.06, 0.024)
        case "poop": return SIMD3<Float>(0.012, 0.009, 0.03)
        case "pee": return SIMD3<Float>(0.07, 0.002, 0.07)
        default: return halfV ?? SIMD3<Float>(0.03, 0.008, 0.01)
        }
    }

    /// 세계의 한 점에서 물건 겉까지 거리 (집을 때 — 둘레 원이 아니라 실제 모양 기준)
    func grabDist(_ w: SIMD3<Float>) -> Float {
        var l = entity.convert(position: w, from: nil)
        let h = half
        if kind == .fixed || kind == .mess { l.y -= h.y }
        else if halfV != nil { l -= centerV }
        let d: SIMD3<Float> = simd_max(simd_abs(l) - h, SIMD3<Float>(repeating: 0))
        return simd_length(d)
    }

    /// 이 물건 위에 올라선 자리의 높이 (물건 밑면에서). 올라서는 물건(담요·방석·패드)이 아니거나 밖이면 nil
    func top(at w: SIMD3<Float>) -> Float? {
        let l = entity.convert(position: w, from: nil)
        switch id {
        case "blanket": return abs(l.x) < 0.27 && abs(l.z) < 0.22 ? 0.012 : nil       // 살짝 눌림
        case "pad": return abs(l.x) < 0.23 && abs(l.z) < 0.17 ? 0.005 : nil
        case "bed":
            // 실제 모양대로: 가운데 방석 5.4cm, 둘레 도넛 쿠션은 가장 높은 곳 10cm (0.9 는 둘레를 7.5cm 로 봐 강아지 몸이 쿠션에 반쯤 묻혀 지나갔음)
            let r = (l.x * l.x + l.z * l.z).squareRoot()
            if r < 0.17 { return 0.052 }
            if r < 0.272 { let d = (r - 0.22) / 0.052; return max(0.052, 0.052 + 0.048 * max(0, 1 - d * d).squareRoot()) - 0.006 }
            return r < 0.28 ? 0.012 : nil
        default: return nil
        }
    }

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
    static func mat(_ c: SIMD3<Float>, rough: Float, metal: Float = 0, coat: Float = 0) -> RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1))
        m.roughness = .init(floatLiteral: rough)
        m.metallic = .init(floatLiteral: metal)
        if coat > 0 {
            m.clearcoat = .init(scale: coat)
            m.clearcoatRoughness = .init(scale: 0.05)
        }
        return m
    }

    private static var texCache: [String: TextureResource] = [:]

    /// 천·표면 무늬 (그려서 만든 무늬를 색에 곱함): fleece 극세사 잔결, weave 짠 천, plush 보들한 방석, quilt 패드 누빔, tennis 테니스공, rope 꼰 줄
    static func fabric(_ kind: String, _ c: SIMD3<Float>) -> RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1))
        m.roughness = .init(floatLiteral: kind == "tennis" ? 0.95 : 1)
        if let t = pattern(kind) {
            var p = MaterialParameters.Texture(t)
            p.sampler = DogSkin.repeatSampler
            m.baseColor = .init(tint: UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1), texture: p)
        }
        return m
    }

    private static func pattern(_ kind: String) -> TextureResource? {
        if let t = texCache[kind] { return t }
        let n = 256
        var px = [UInt8](repeating: 255, count: n * n * 4)
        var seed: UInt32 = 12345
        func rnd() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) }
        for y in 0..<n {
            for x in 0..<n {
                let u = Float(x) / Float(n), v = Float(y) / Float(n)
                var k: Float = 1
                switch kind {
                case "fleece": k = 0.90 + 0.10 * rnd() + 0.03 * sin(u * 80 + sin(v * 30) * 2)
                case "weave": k = 0.84 + 0.10 * (0.5 + 0.5 * sin(u * 2 * .pi * 48)) * (0.5 + 0.5 * sin(v * 2 * .pi * 48 + .pi / 2)) + 0.06 * rnd()
                case "plush": k = 0.92 + 0.08 * rnd()
                case "quilt":
                    // 마름모 누빔 줄 (흡수면이 눌린 선)
                    let a = abs(sin((u + v) * .pi * 9)), b = abs(sin((u - v) * .pi * 9))
                    k = (min(a, b) < 0.08 ? 0.86 : 1) - 0.03 * rnd()
                case "tennis":
                    // 펠트 + 공을 감는 흰 솔기 두 줄
                    let s1 = abs(v - 0.5 - 0.22 * sin(u * 4 * .pi))
                    k = s1 < 0.012 ? 2.0 : 0.88 + 0.12 * rnd()
                case "rope": k = 0.80 + 0.2 * (0.5 + 0.5 * sin((u * 3 + v) * 2 * .pi * 6)) + 0.05 * rnd()
                default: break
                }
                let i = (y * n + x) * 4
                if kind == "tennis" && k > 1.5 {
                    px[i] = 255; px[i + 1] = 255; px[i + 2] = 255          // 솔기는 색을 곱해도 하얗게 보이도록 (연두색에 곱해 연한 연두가 됨)
                } else {
                    let g = UInt8(max(0, min(255, k * 255)))
                    px[i] = g; px[i + 1] = g; px[i + 2] = g
                }
                px[i + 3] = 255
            }
        }
        guard let prov = CGDataProvider(data: Foundation.Data(px) as CFData),
              let img = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let t = try? TextureResource.generate(from: img, options: .init(semantic: .color)) else { return nil }
        texCache[kind] = t
        return t
    }

    private static var kibCache: [Int: MeshResource] = [:]

    /// 사료 알갱이 한 겹 (둥근 납작 알갱이 여러 개를 한 그물로). k: 0·1 = 그릇을 덮는 위층 두 겹(더미 모양), 2 = 바닥에 남은 몇 알
    static func kibble(_ k: Int) -> MeshResource {
        if let m = kibCache[k] { return m }
        var seed: UInt32 = UInt32(77 + k * 31)
        func rnd() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) }
        var items: [(c: SIMD3<Float>, r: SIMD3<Float>, q: simd_quatf)] = []
        let count = k == 2 ? 14 : 150
        let R: Float = k == 2 ? 0.05 : 0.072
        for _ in 0..<count {
            let a = rnd() * 2 * .pi, d = (rnd()).squareRoot() * R
            var y: Float = (k == 2 ? 0.002 : 0.004 * (1 - (d / R) * (d / R))) + rnd() * 0.002     // 가운데가 조금 봉긋
            if k == 1 { y -= 0.0015 }
            let c = SIMD3<Float>(cos(a) * d, y, sin(a) * d)
            let r = SIMD3<Float>(0.0042, 0.0029, 0.0042) * (0.85 + 0.3 * rnd())
            let q = simd_quatf(angle: rnd() * 1.2, axis: simd_normalize(SIMD3<Float>(rnd() - 0.5, 0.2, rnd() - 0.5)))
            items.append((c, r, q))
        }
        let m = blobs(items) ?? .generateBox(size: 0.001)
        kibCache[k] = m
        return m
    }

    /// 작은 타원 덩어리 여러 개를 한 그물로
    static func blobs(_ items: [(c: SIMD3<Float>, r: SIMD3<Float>, q: simd_quatf)], seg: Int = 7, rings: Int = 4) -> MeshResource? {
        var pos: [SIMD3<Float>] = [], nrm: [SIMD3<Float>] = [], idx: [UInt32] = []
        for it in items {
            let base = UInt32(pos.count)
            for i in 0...rings {
                let v = Float(i) / Float(rings) * .pi
                for j in 0...seg {
                    let u = Float(j) / Float(seg) * 2 * .pi
                    let n = SIMD3<Float>(sin(v) * cos(u), cos(v), sin(v) * sin(u))
                    pos.append(it.q.act(n * it.r) + it.c)
                    nrm.append(simd_normalize(it.q.act(n / it.r)))
                }
            }
            for i in 0..<rings {
                for j in 0..<seg {
                    let a = base + UInt32(i * (seg + 1) + j), b = a + UInt32(seg + 1)
                    idx.append(contentsOf: [a, a + 1, b, a + 1, b + 1, b])
                }
            }
        }
        var d = MeshDescriptor(name: "blobs")
        d.positions = MeshBuffers.Positions(pos)
        d.normals = MeshBuffers.Normals(nrm)
        d.primitives = .triangles(idx)
        return try? MeshResource.generate(from: [d])
    }

    /// 고르지 않은 테두리의 납작한 웅덩이 (오줌·얼룩)
    static func puddle(_ r: Float, seed s: Int) -> MeshResource? {
        let n = 36
        let p1 = Float(s % 7), p2 = Float(s % 11) * 0.7
        var pos: [SIMD3<Float>] = [SIMD3<Float>(0, 0.0006, 0)], nrm: [SIMD3<Float>] = [SIMD3<Float>(0, 1, 0)], idx: [UInt32] = []
        for i in 0...n {
            let t = Float(i) / Float(n) * 2 * .pi
            let k: Float = 1 + 0.22 * sin(3 * t + p1) + 0.12 * sin(5 * t + p2) + 0.06 * sin(9 * t)
            pos.append(SIMD3<Float>(cos(t) * r * k, 0, sin(t) * r * k * 0.85))
            nrm.append(SIMD3<Float>(0, 1, 0))
        }
        for i in 1...n { idx.append(contentsOf: [0, UInt32(i + 1), UInt32(i)]) }
        var d = MeshDescriptor(name: "puddle")
        d.positions = MeshBuffers.Positions(pos)
        d.normals = MeshBuffers.Normals(nrm)
        d.primitives = .triangles(idx)
        return try? MeshResource.generate(from: [d])
    }

    /// 돌림체: (반지름, 높이) 꺾은선을 y축 둘레로 돌림. 꺾이는 곳마다 점을 따로 두어 모서리가 또렷함
    static func lathe(_ prof: [(Float, Float)], seg: Int) -> MeshResource? {
        var pos: [SIMD3<Float>] = [], nrm: [SIMD3<Float>] = [], idx: [UInt32] = [], uv: [SIMD2<Float>] = []
        var run: Float = 0
        for k in 0..<(prof.count - 1) {
            let a = prof[k], b = prof[k + 1]
            let dr = b.0 - a.0, dy = b.1 - a.1
            let l = max(1e-6, (dr * dr + dy * dy).squareRoot())
            let nr = dy / l, ny = -dr / l
            let base = UInt32(pos.count)
            for j in 0...seg {
                let t = 2 * Float.pi * Float(j) / Float(seg)
                let c = cos(t), s = sin(t)
                let u = Float(j) / Float(seg) * 6
                pos.append(SIMD3<Float>(a.0 * c, a.1, a.0 * s)); nrm.append(SIMD3<Float>(nr * c, ny, nr * s)); uv.append(SIMD2<Float>(u, run * 8))
                pos.append(SIMD3<Float>(b.0 * c, b.1, b.0 * s)); nrm.append(SIMD3<Float>(nr * c, ny, nr * s)); uv.append(SIMD2<Float>(u, (run + l) * 8))
            }
            run += l
            for j in 0..<seg {
                let i0 = base + UInt32(j * 2), i1 = i0 + 1, i2 = i0 + 2, i3 = i0 + 3
                idx.append(contentsOf: [i0, i1, i2, i2, i1, i3])
            }
        }
        var d = MeshDescriptor(name: "lathe")
        d.positions = MeshBuffers.Positions(pos)
        d.normals = MeshBuffers.Normals(nrm)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uv)
        d.primitives = .triangles(idx)
        return try? MeshResource.generate(from: [d])
    }
}
