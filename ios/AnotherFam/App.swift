import SwiftUI
import RealityKit

/// 어나더 팸 (Another Fam): 메인 창(입양·상태·상점·보관함·설정) + 함께하는 공간(현실 위의 강아지)
@main
struct AnotherFamApp: App {
    init() {
        PropTag.registerComponent()
        DogTag.registerComponent()
    }

    @Environment(\.scenePhase) private var phase

    var body: some SwiftUI.Scene {
        WindowGroup(id: "main") {
            HomeView()
        }
        .defaultSize(width: 900, height: 660)
        // 메인 창은 손 닿는 가까이·낮게 (0.4.0: 시스템이 정한 먼 자리에 떠 현실 물건과 겹쳐 보였음)
        .defaultWindowPlacement { _, _ in WindowPlacement(.utilityPanel) }
        .onChange(of: phase) { _, p in
            if p == .active { AppModel.shared.wake() } else { AppModel.shared.sleep() }
        }

        // 현실이 그대로 보이는 섞인 공간 — 강아지가 현실 바닥·가구 사이를 다님
        ImmersiveSpace(id: "play") {
            PlayView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var pet: PetState? = Store.load()
    var playOpen = false
    var notice: String?
    var tab = 0                          // 메인 창 탭 (0 홈, 1 보관함, 2 상점, 3 설정)
    @ObservationIgnored var mainOpen = false
    @ObservationIgnored var openMain: (@MainActor () -> Void)?
    @ObservationIgnored var closeMain: (@MainActor () -> Void)?
    @ObservationIgnored weak var session: PlaySession?
    @ObservationIgnored var openAction: (@MainActor () async -> Bool)?
    @ObservationIgnored var closeAction: (@MainActor () async -> Void)?
    @ObservationIgnored private var busy = false

    /// 값 고치기: 공간이 열려 있으면 거기(한 곳)에서 고치고, 아니면 여기서 고치고 저장
    func mutate(_ f: (inout PetState) -> Void) {
        if let s = session {
            f(&s.pet)
            pet = s.pet
            s.shown = s.pet
        } else if var p = pet {
            f(&p)
            pet = p
            Store.save(p)
        }
    }

    /// 앱으로 돌아옴: 그동안 흐른 시간을 따라잡음
    func wake() {
        guard session == nil, var p = pet else { return }
        p.catchUp()
        pet = p
        Store.save(p)
    }

    func sleep() {
        if let s = session { Store.save(s.pet) } else if let p = pet { Store.save(p) }
    }

    func adopt(name: String, male: Bool) {
        var p = PetState()
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.name = n.isEmpty ? "몽이" : String(n.prefix(12))
        p.male = male
        p.born = Date().timeIntervalSince1970
        p.lastSim = p.born
        pet = p
        Store.save(p)
    }

    /// 시험: '함께한 날'을 정함 (입양한 때를 그만큼 앞당김). 그 뒤로는 그 나이에서 시간이 그대로 흐름
    func setTogetherDays(_ days: Double) {
        let d = min(Sim.maxAge / Sim.ageRate, max(0, days))
        mutate { p in
            let now = Date().timeIntervalSince1970
            p.born = now - d * 86400
            p.lastSim = now                  // 건너뛴 날 동안 배고파지지 않게 (나이만 바꿈)
            p.asleep = false
        }
        session?.dog?.ageChanged()
    }

    func reset() {
        guard session == nil else { return }
        Store.clear()
        UserDefaults.standard.removeObject(forKey: "af.home")
        pet = nil
    }

    // MARK: 상점·보관함
    func canBuy(_ it: Item) -> Bool {
        guard let p = pet else { return false }
        if it.permanent && p.has(it.id) { return false }
        return p.points >= it.price
    }

    func buy(_ it: Item) {
        guard canBuy(it) else { return }
        mutate { p in
            p.points -= it.price
            p.inv[it.id] = p.count(it.id) + (it.permanent ? 1 : it.qty)
        }
    }

    /// 바로 쓰는 것 (접종·검진·영양제)
    func useNow(_ id: String) {
        mutate { p in
            guard p.use(id) else { return }
            switch id {
            case "vaccine": p.vaccines += 1; p.health = min(1, p.health + 0.1)
            case "checkup": p.checkupAge = p.age(); p.health = min(1, p.health + 0.15)
            case "joint": p.jointUntil = Date().timeIntervalSince1970 + 30 / Sim.ageRate * 86400; p.health = min(1, p.health + 0.05)
            default: break
            }
        }
    }

    func takeOut(_ id: String) {
        guard let s = session else { notice = "먼저 '함께하기'를 눌러 주세요"; return }
        if let why = s.takeOut(id) { notice = why }
    }

    func putBack(_ id: String) { session?.putBack(id) }

    // MARK: 함께하는 공간
    func play() {
        guard !playOpen, !busy, pet != nil else { return }
        busy = true
        Task {
            let ok = await openAction?() ?? false
            playOpen = ok
            busy = false
            if ok { closeMain?() }          // 강아지에게 집중: 메인 창은 닫아 둠 (강아지를 누르면 메뉴)
            if !ok { notice = "공간을 열지 못했어요. 다른 앱의 몰입 화면을 닫고 다시 해 주세요." }
        }
    }

    func rest() {
        Task {
            if playOpen, let closeAction { await closeAction() }
            playOpen = false
        }
    }

    func playClosed() { playOpen = false }

    /// 메인 창을 그 탭으로 (닫혀 있으면 엶) — 함께하는 동안 메인 창은 필요할 때만 뜸
    func showMain(tab t: Int, note: String? = nil) {
        tab = t
        if let note { notice = note }
        if !mainOpen { openMain?() }
    }
}
