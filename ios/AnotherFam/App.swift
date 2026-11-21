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
        // 팸과 함께하는 동안 메인 메뉴는 손 닿는 가까이(시스템이 사람 곁에 두는 자리), 아닐 땐 시선 정면(기본).
        // visionOS 는 앱이 창을 공간의 정한 점(예: 왼쪽)에 놓는 API 를 주지 않음 — 정면·곁(utilityPanel)·다른 창 옆만 고를 수 있음
        .defaultWindowPlacement { _, _ in AppModel.nearWindow ? WindowPlacement(.utilityPanel) : WindowPlacement(nil) }
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

    /// 우리 집 팸들과 가족 살림 (0.11.0). 함께하는 동안은 공간(PlaySession.fam)이 고치고 0.5초마다 여기로 알림
    var family: Family = Store.load()
    /// 메뉴에서 먼저 보여 줄 팸 (홈 카드 등) — 공간에는 모든 팸이 함께 나옴
    var pet: PetState? {
        get { family.current }
        set { if let p = newValue { family.put(p) } }
    }
    var playOpen = false
    var notice: String?
    var tab = 0                          // 메인 메뉴 탭 (4 보금자리, 0 홈, 1 보관함, 2 상점, 3 설정)
    @ObservationIgnored var mainOpen = false
    @ObservationIgnored var openMain: (@MainActor () -> Void)?
    @ObservationIgnored var closeMain: (@MainActor () -> Void)?
    @ObservationIgnored weak var session: PlaySession?
    @ObservationIgnored var openAction: (@MainActor () async -> Bool)?
    @ObservationIgnored var closeAction: (@MainActor () async -> Void)?
    @ObservationIgnored private var busy = false
    nonisolated(unsafe) static var nearWindow = false

    /// 가족 고치기: 공간이 열려 있으면 거기(한 곳)에서 고치고, 아니면 여기서 고치고 저장
    func mutate(_ f: (inout Family) -> Void) {
        if let s = session {
            f(&s.fam)
            family = s.fam
            s.shown = s.fam
        } else {
            var x = family
            f(&x)
            family = x
            Store.save(family: x)
        }
    }

    /// 한 팸 고치기
    func mutate(pet id: String, _ f: @escaping (inout PetState) -> Void) {
        mutate { fam in
            guard let i = fam.pets.firstIndex(where: { $0.id == id }) else { return }
            f(&fam.pets[i])
        }
    }

    /// 앱으로 돌아옴: 그동안 흐른 시간을 따라잡음 (공간이 열려 있으면 공간이 셈 — 함께 있다는 표시만 다시 올림)
    func wake() {
        if let s = session {
            if s.fam.pets.contains(where: { !$0.together }) {
                for i in s.fam.pets.indices { s.fam.pets[i].together = true }
                Store.save(family: s.fam, force: true)
            }
            return
        }
        guard !family.pets.isEmpty else { return }
        var f = family
        f.catchUp()
        for i in f.pets.indices { f.pets[i].together = false }
        family = f
        Store.save(family: f)
    }

    /// 앱이 뒤로 감(기기를 벗거나 다른 앱으로): 함께 있다는 표시를 내리고 바로 올림 → 아이폰이 그때부터 다시 알림을 맡음
    func sleep() {
        if let s = session {
            let now = Date().timeIntervalSince1970
            for i in s.fam.pets.indices { s.fam.pets[i].together = false; s.fam.pets[i].lastSim = now }
            Store.saveFinal(family: s.fam)
            family = s.fam
        } else if !family.pets.isEmpty {
            var f = family
            for i in f.pets.indices { f.pets[i].together = false }
            family = f
            Store.saveFinal(family: f)
        }
    }

    /// 보금자리에서 입양 (최대 Sim.maxPets): 가족 지갑에 1,500P, 이 팸 이름이 붙은 물그릇·담요.
    /// 함께하는 중이면 바로 공간에 나옴
    func adopt(_ breed: Breed, name: String, male: Bool) {
        guard !family.full else { notice = "팸은 \(Sim.maxPets)마리까지 함께 키울 수 있어요"; return }
        var p = PetState()
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.species = breed.id
        p.name = n.isEmpty ? "몽이" : String(n.prefix(12))
        p.male = male
        p.born = Date().timeIntervalSince1970
        p.lastSim = p.born
        p.rate = breed.rate
        p.together = session != nil
        mutate { f in
            f.adopt(p)
            if f.active.isEmpty { f.active = p.id }
        }
        session?.adopted(p.id)
        tab = 0
        notice = "\(p.name)\(Josa.wa(p.name)) 가족이 되었어요"
    }

    /// 메뉴에서 먼저 보여 줄 팸
    func select(_ id: String) {
        guard family.active != id, family.pet(id) != nil else { return }
        mutate { $0.active = id }
    }

    /// 잘못 배운 말 지우기 (설정 › 목소리)
    func forgetWord(_ w: String, pet id: String) { mutate(pet: id) { $0.words[w] = nil } }

    /// 팸 하나와 헤어짐 (설정 › 가족). 다른 팸들과 공용 살림은 그대로. 마지막 팸이면 집 자리도 지움
    func remove(_ id: String) {
        guard session == nil, family.pet(id) != nil else { return }
        mutate { $0.remove(id) }
        if family.pets.isEmpty { UserDefaults.standard.removeObject(forKey: "af.home"); tab = 4 }
    }

    // MARK: 상점·보관함 (가족 살림)
    /// 살 수 있는지: 따로 쓰는 물건은 그 팸이 아직 없을 때, 한 번 사면 계속 쓰는 공용 물건은 아직 없을 때
    func canBuy(_ it: Item, for pk: String? = nil) -> Bool {
        let h = family.home
        guard h.points >= it.price else { return false }
        if it.personal {
            guard let pk else { return false }
            return !h.has(Own.key(it.id, pk))
        }
        return !(it.permanent && h.has(it.id))
    }

    func buy(_ it: Item, for pk: String? = nil) {
        guard canBuy(it, for: pk) else { return }
        mutate { f in
            f.home.points -= it.price
            let k = it.personal ? Own.key(it.id, pk ?? "") : it.id
            f.home.inv[k] = f.home.count(k) + (it.permanent ? 1 : it.qty)
        }
    }

    /// 바로 쓰는 것 (접종·검진·영양제·물티슈 등): 공용 보관함에서 하나 쓰고 고른 팸에게
    func useNow(_ id: String, pet pid: String) {
        mutate { f in
            guard let i = f.pets.firstIndex(where: { $0.id == pid }), f.home.use(id) else { return }
            var p = f.pets[i]
            switch id {
            case "vaccine": p.vaccines += 1; p.health = min(1, p.health + 0.1)
            case "checkup": p.checkupAge = p.age(); p.health = min(1, p.health + 0.15)
            case "joint": p.jointUntil = Date().timeIntervalSince1970 + 30 / p.breed.rate * 86400; p.health = min(1, p.health + 0.05)
            case "wipes": p.clean = min(1, p.clean + 0.2)
            case "toothpaste": p.health = min(1, p.health + 0.02)
            case "heartworm": p.health = min(1, p.health + 0.05)
            case "probiotic": p.health = min(1, p.health + 0.03)
            default: break
            }
            f.pets[i] = p
        }
    }

    /// 꺼내기·넣기: 열쇠(공용 = 물건 이름, 개별 = 물건:팸)
    func takeOut(_ key: String) {
        guard let s = session else { notice = "먼저 '함께하기'를 눌러 주세요"; return }
        if let why = s.takeOut(key) { notice = why }
    }

    func putBack(_ key: String) { session?.putBack(key) }

    // MARK: 함께하는 공간
    func play() {
        guard !playOpen, !busy, !family.pets.isEmpty else { return }
        busy = true
        Task {
            let ok = await openAction?() ?? false
            playOpen = ok
            AppModel.nearWindow = ok
            busy = false
            if ok { closeMain?() }          // 강아지에게 집중: 메인 창은 닫아 둠 (강아지를 누르면 메뉴)
            if !ok { notice = "공간을 열지 못했어요. 다른 앱의 몰입 화면을 닫고 다시 해 주세요." }
        }
    }

    func rest() {
        Task {
            if playOpen, let closeAction { await closeAction() }
            playOpen = false
            AppModel.nearWindow = false
        }
    }

    func playClosed() { playOpen = false; AppModel.nearWindow = false }

    /// 메인 메뉴(하나뿐인 메뉴 — 창)를 그 탭으로 엶. 뜨면 팸 카드는 바로 닫힘.
    /// 0.11.1: 0.10.15 의 공간 안 메뉴판은 되돌림 — 0.5.1 에서 만들었다 0.6.0 에서 '새 메뉴 금지'로 없앤 것을 다시 만든 실수였음
    /// (홈 탭이 안 눌리고 가로로 길어 닫을 수도 없었음). 창 자리는 visionOS 가 정함(정면·곁(utilityPanel)·다른 창 옆만 고를 수 있음)
    func showMain(tab t: Int, note: String? = nil) {
        if let note { notice = note }
        tab = t
        session?.closeCard()
        if !mainOpen { openMain?() }
    }
}
