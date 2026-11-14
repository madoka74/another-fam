import SwiftUI
import RealityKit
import simd

/// 폰에서 보는 지금의 팸: 비전 앱과 같은 그물·털·움직임 코드(DogSkin·DogAnimator)로 그려, 손가락으로 돌려 봄.
/// 무엇을 하고 있는지(Doing)에 맞는 자세·작은 동작을 되풀이함. 보기만 하는 화면 — 여기서 상태를 바꾸지 않음
@MainActor
final class DogStage {
    let root = Entity()
    private let dog = Entity()
    private let cam = PerspectiveCamera()
    private var anim: DogAnimator?
    private var skin: DogSkin?
    var sub: EventSubscription?
    private(set) var ready = false

    // 보는 방향 (손가락으로 바꿈)
    private var yaw: Float = 0.55
    private var pitch: Float = 0.28
    private var zoom: Float = 1
    private var yaw0: Float = 0.55, pitch0: Float = 0.28, zoom0: Float = 1
    private var camPos = SIMD3<Float>(0, 0.3, 1)

    private var pet = PetState()
    private var doing: Doing = .calm
    private var started = false
    private var holdNext: String?
    private var nextAt: Float = 2
    private var t: Float = 0

    func setup() {
        guard !ready, let d = DogData.shared, let sk = DogSkin() else { return }
        ready = true
        anim = DogAnimator(d)
        skin = sk
        dog.addChild(sk.entity)
        root.addChild(dog)
        // 깔개 (그림자가 떨어질 바닥)
        var mm = PhysicallyBasedMaterial()
        mm.baseColor = .init(tint: UIColor(red: 0.50, green: 0.43, blue: 0.37, alpha: 1))
        mm.roughness = .init(floatLiteral: 1)
        let mat = ModelEntity(mesh: .generateBox(width: 0.62, height: 0.012, depth: 0.62, cornerRadius: 0.006), materials: [mm])
        mat.position = SIMD3<Float>(0, -0.006, 0)
        root.addChild(mat)
        // 빛: 앞 왼쪽 위에서 (그림자 있음) — 둘레 빛은 RealityView 기본값
        let sun = DirectionalLight()
        sun.light.intensity = 1400
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 3, depthBias: 2)
        sun.look(at: SIMD3<Float>(0, 0, 0), from: SIMD3<Float>(0.7, 1.6, 0.9), relativeTo: nil)
        root.addChild(sun)
        cam.camera.fieldOfViewInDegrees = 34
        root.addChild(cam)
        placeCamera()
    }

    func show(_ p: PetState, _ d: Doing) {
        pet = p
        if d != doing || !started {
            doing = d
            started = true
            begin()
        }
    }

    // MARK: 손가락
    func drag(_ dx: CGFloat, _ dy: CGFloat) {
        yaw = yaw0 - Float(dx) * 0.011
        pitch = min(1.25, max(0.03, pitch0 + Float(dy) * 0.008))
    }
    func dragEnd() { yaw0 = yaw; pitch0 = pitch }
    func pinch(_ m: CGFloat) { zoom = min(2.2, max(0.6, zoom0 / Float(m))) }
    func pinchEnd() { zoom0 = zoom }

    private func placeCamera() {
        let g = anim?.growth.g ?? 1
        let size: Float = 0.30 + 0.70 * g                      // 강아지가 작으면 가까이
        let dist: Float = 1.05 * size * zoom
        let target = SIMD3<Float>(0, 0.13 * g, 0)
        let p = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * dist + target
        camPos = p
        cam.look(at: target, from: p, relativeTo: nil)
    }

    // MARK: 하고 있는 일에 맞는 자세
    private var baby: Bool { pet.age() < 21 }

    private func begin() {
        guard let a = anim else { return }
        a.age = pet.age()
        a.overlay(nil)
        a.stop()
        holdNext = nil
        nextAt = t + 2.5
        if baby {
            a.setPosture("newborn")
            if doing == .sleeping { holdNext = "nb_sleep" }
            return
        }
        switch doing {
        case .sleeping:
            let senior = Stage.of(pet.age()) == .senior
            a.setPosture(senior ? "side" : "curl")
            holdNext = senior ? "sleep_side" : "sleep_curl"
        case .bored: a.setPosture("rest")
        case .potty, .together, .happy: a.setPosture("stand")
        default: a.setPosture("sit")
        }
    }

    /// 몇 초마다 그 상태다운 작은 동작 하나
    private func fidget() {
        guard let a = anim, !a.busy else { return }
        if baby {
            if doing == .sleeping { return }
            a.play(doing == .hungry || Bool.random() ? "nb_root" : "nb_squirm", then: "newborn")
            return
        }
        let r = Int.random(in: 0..<6)
        switch doing {
        case .sleeping: break
        case .hungry:
            if r < 2 { a.overlay("whine") } else if r < 4, a.posture == "sit" { a.play("paw_at", then: "sit") } else { a.overlay("lick_lips") }
        case .thirsty:
            if r < 3 { a.overlay("lick_lips") } else { a.overlay("pant", hold: true) }
        case .potty:
            if r < 3 { a.play("sniff_ground", then: "stand") } else { a.play(Bool.random() ? "spin_l" : "spin_r", then: "stand") }
        case .lonely:
            if r < 2 { a.overlay("whine") } else if r < 4 { a.overlay("look_up") } else { a.overlay(Bool.random() ? "tilt_l" : "tilt_r") }
        case .bored:
            if r < 2 { a.overlay("yawn") } else if r < 4 { a.overlay("blink_slow") } else { a.overlay(Bool.random() ? "look_l" : "look_r") }
        case .happy, .together:
            switch r {
            case 0: a.setPosture(a.posture == "stand" ? "sit" : "stand")
            case 1: if a.posture == "stand" { a.play("shake") } else { a.overlay("tilt_lr") }
            case 2: if a.posture == "stand" { a.play("stretch_front") } else { a.overlay("ear_perk") }
            case 3: a.overlay("tilt_lr")
            case 4: a.overlay("pant", hold: true)
            default: a.overlay("ear_perk")
            }
        case .calm:
            switch r {
            case 0: a.setPosture(["sit", "down", "rest", "sploot"].randomElement() ?? "sit")
            case 1: a.overlay("yawn")
            case 2: a.overlay(Bool.random() ? "look_l" : "look_r")
            case 3: if a.posture == "sit" { a.play(Bool.random() ? "scratch_l" : "scratch_r", then: "sit") } else { a.overlay("blink_slow") }
            case 4: a.overlay("ear_perk")
            default: a.overlay(Bool.random() ? "tilt_l" : "tilt_r")
            }
        }
    }

    func tick(_ dt0: Float) {
        guard let a = anim, let sk = skin else { return }
        let dt = min(0.1, dt0)
        t += dt
        a.age = pet.age()
        let g = a.growth.g
        if let h = holdNext, a.settled { a.hold(h); holdNext = nil }
        if t > nextAt {
            nextAt = t + Float.random(in: 4...9)
            fidget()
        }
        let sleeping = doing == .sleeping
        a.asleep = sleeping && holdNext == nil
        a.wagBoost = sleeping ? 0 : (0.3 + 1.1 * pet.mood + (doing == .together ? 0.7 : 0))
        a.breathRate = 0.38
        // 깨어 있으면 가끔 나(카메라)를 봄
        a.look = (sleeping || baby) ? nil : camPos / max(0.2, g)
        a.lookOn = sleeping ? 0 : 1
        let job = a.tick(dt)
        sk.update(job)
        sk.setTone(clean: pet.clean, thin: Stage.of(pet.age()) == .senior ? 1 : 0)
        dog.scale = SIMD3<Float>(repeating: g)
        placeCamera()
    }
}
