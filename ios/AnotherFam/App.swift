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

    /// 우리 집 팸들 (0.10.15). pet = 지금 고른(공간에 나와 함께하는) 팸 — 보관함·상점·설정은 이 팸 것
    var family: Family = Store.load()
    var pet: PetState? {
        get { family.current }
        set { if let p = newValue { family.put(p) } }
    }
    var playOpen = false
    var notice: String?
    var tab = 0                          // 메인 메뉴 탭 (4 보금자리, 0 홈, 1 보관함, 2 상점, 3 설정)
    var menuSel: String?                 // 홈에서 살펴보는 팸 (함께하는 중에 다른 팸을 골랐을 때)
    @ObservationIgnored var mainOpen = false
    @ObservationIgnored var openMain: (@MainActor () -> Void)?
    @ObservationIgnored var closeMain: (@MainActor () -> Void)?
    @ObservationIgnored weak var session: PlaySession?
    @ObservationIgnored var openAction: (@MainActor () async -> Bool)?
    @ObservationIgnored var closeAction: (@MainActor () async -> Void)?
    @ObservationIgnored private var busy = false
    nonisolated(unsafe) static var nearWindow = false

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

    /// 앱으로 돌아옴: 그동안 흐른 시간을 따라잡음 — 공간에 나와 있지 않은 팸들 모두 (공간의 팸은 공간이 셈)
    func wake() {
        if let s = session, !s.pet.together {
            // 다시 앞으로: 함께 있다는 표시를 다시 올림
            s.pet.together = true
            Store.save(s.pet, force: true)
        }
        guard !family.pets.isEmpty else { return }
        var f = family
        for i in f.pets.indices where f.pets[i].id != session?.pet.id {
            f.pets[i].catchUp()
            f.pets[i].together = false
        }
        family = f
        Store.save(family: f)
        if let s = session { family.put(s.pet) }
    }

    /// 앱이 뒤로 감(기기를 벗거나 다른 앱으로): 함께 있다는 표시를 내리고 바로 올림 → 아이폰이 그때부터 다시 알림을 맡음
    func sleep() {
        if let s = session { s.pet.together = false; s.pet.lastSim = Date().timeIntervalSince1970; Store.saveFinal(s.pet); family.put(s.pet) }
        else if !family.pets.isEmpty {
            var f = family
            for i in f.pets.indices { f.pets[i].together = false }
            family = f
            Store.saveFinal(family: f)
        }
    }

    /// 보금자리에서 입양. 함께하는 팸이 없으면 새 팸을 바로 고름 (있으면 홈에서 바꿔 함께할 수 있음)
    func adopt(_ breed: Breed, name: String, male: Bool) {
        var p = PetState()
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.species = breed.id
        p.name = n.isEmpty ? "몽이" : String(n.prefix(12))
        p.male = male
        p.born = Date().timeIntervalSince1970
        p.lastSim = p.born
        var f = family
        f.put(p)
        if session == nil || f.active.isEmpty { f.active = p.id }
        family = f
        Store.save(family: f)
        menuSel = p.id
        tab = 0
        notice = session == nil ? "\(p.name)\(Josa.wa(p.name)) 가족이 되었어요" : "\(p.name)\(Josa.wa(p.name)) 가족이 되었어요 · 홈에서 골라 함께할 수 있어요"
    }

    /// 홈에서 함께할 팸을 고름 (공간이 닫혀 있을 때)
    func select(_ id: String) {
        menuSel = id
        guard session == nil, !playOpen, family.active != id, family.pet(id) != nil else { return }
        var f = family
        f.active = id
        family = f
        Store.save(family: f)
    }

    /// 함께하는 중에 다른 팸으로: 지금 팸은 쉬러 가고(공간을 닫음) 고른 팸과 다시 함께함
    func switchPlay(to id: String) {
        guard family.pet(id) != nil, !busy else { return }
        Task {
            if playOpen, let closeAction { await closeAction() }
            playOpen = false
            AppModel.nearWindow = false
            var f = family
            f.active = id
            family = f
            Store.save(family: f)
            menuSel = id
            try? await Task.sleep(nanoseconds: 1_000_000_000)        // 공간이 다 닫히고 메인 창이 다시 뜬 뒤에 엶
            play()
        }
    }

    /// 시험: '함께한 날'을 정함 (입양한 때를 그만큼 앞당김). 그 뒤로는 그 나이에서 시간이 그대로 흐름
    /// 잘못 배운 말 지우기 (설정 › 목소리)
    func forgetWord(_ w: String) { mutate { $0.words[w] = nil } }

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

    /// 지금 고른 팸과 헤어짐 (설정 › 가족). 다른 팸들은 그대로. 마지막 팸이면 집 자리도 지움
    func reset() {
        guard session == nil, let p = pet else { return }
        var f = family
        f.pets.removeAll { $0.id == p.id }
        f.active = f.pets.first?.id ?? ""
        family = f
        Store.save(family: f)
        UserDefaults.standard.removeObject(forKey: "af.anchors." + p.id)
        if f.pets.isEmpty { UserDefaults.standard.removeObject(forKey: "af.home"); tab = 4 }
        menuSel = nil
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
            case "wipes": p.clean = min(1, p.clean + 0.2)
            case "toothpaste": p.health = min(1, p.health + 0.02)
            case "heartworm": p.health = min(1, p.health + 0.05)
            case "probiotic": p.health = min(1, p.health + 0.03)
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
        if let id = menuSel, id != family.active, family.pet(id) != nil { select(id) }
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

    /// 메인 메뉴(하나뿐인 메뉴)를 그 탭으로 엶. 뜨면 팸 카드는 바로 닫힘.
    /// 0.10.15: 함께하는 동안은 창(시스템이 곁에 낮고 기울게 둠) 대신 공간 안 메뉴판 — 팸 카드가 뜨던 자리에 같은 방식으로
    func showMain(tab t: Int, note: String? = nil) {
        if let note { notice = note }
        tab = t
        if let s = session, !mainOpen { s.openMenu(); return }
        session?.closeCard()
        if !mainOpen { openMain?() }
    }
}
