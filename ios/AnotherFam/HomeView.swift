import SwiftUI

/// 메인 창: 입양 → 홈(상태)·상점·보관함·설정
struct HomeView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private var model: AppModel { AppModel.shared }

    var body: some View {
        // 보금자리(입양소) · 홈 · 보관함 · 상점 · 설정 — 공간 안 메뉴판(MenuPanel)과 같은 탭 (0.10.15)
        TabView(selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
            ForEach(MenuTab.order) { t in
                t.view.tabItem { Label(t.title, systemImage: t.icon) }.tag(t.rawValue)
            }
        }
        // 팸과 함께하는 동안엔 메뉴를 닫아 팸에 집중 (닫아도 팸을 바라보고 집으면 카드의 '메뉴'로 다시 엶)
        .ornament(visibility: model.playOpen ? .visible : .hidden, attachmentAnchor: .scene(.topTrailing), contentAlignment: .bottomTrailing) {
            Button { dismissWindow(id: "main") } label: { Label("닫기", systemImage: "xmark") }
                .buttonBorderShape(.capsule)
                .padding(8)
                .glassBackgroundEffect()
        }
        .overlay(alignment: .bottom) {
            if let n = model.notice {
                HStack(spacing: 12) {
                    Text(n).font(.callout)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonBorderShape(.circle)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .glassBackgroundEffect()
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            let open = openImmersiveSpace, close = dismissImmersiveSpace
            model.openAction = {
                switch await open(id: "play") {
                case .opened: return true
                default: return false
                }
            }
            model.closeAction = { await close() }
            let ow = openWindow, dw = dismissWindow
            model.openMain = { ow(id: "main") }
            model.closeMain = { dw(id: "main") }
            model.mainOpen = true
            if model.family.pets.isEmpty { model.tab = MenuTab.adopt.rawValue }
            model.session?.closeCard()
            model.session?.closeMenu()                       // 메뉴는 늘 하나만 (창이 뜨면 공간 안 메뉴판은 닫음)
            model.wake()
        }
        .onDisappear { model.mainOpen = false }
        .task {
            // 공간을 열지 않은 동안에도 시간은 흐름
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                model.wake()
            }
        }
    }
}

// MARK: - 메뉴 탭 (창·공간 안 메뉴판이 함께 씀)
enum MenuTab: Int, Identifiable {
    case adopt = 4, home = 0, storage = 1, shop = 2, settings = 3
    static let order: [MenuTab] = [.adopt, .home, .storage, .shop, .settings]
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .adopt: return "보금자리"
        case .home: return "홈"
        case .storage: return "보관함"
        case .shop: return "상점"
        case .settings: return "설정"
        }
    }
    var icon: String {
        switch self {
        case .adopt: return "heart.circle.fill"
        case .home: return "pawprint.fill"
        case .storage: return "archivebox.fill"
        case .shop: return "cart.fill"
        case .settings: return "gearshape.fill"
        }
    }
    @MainActor var view: AnyView {
        if self != .adopt && AppModel.shared.family.pets.isEmpty { return AnyView(NoPetView()) }
        switch self {
        case .adopt: return AnyView(AdoptTab())
        case .home: return AnyView(HomeTab())
        case .storage: return AnyView(StorageTab())
        case .shop: return AnyView(ShopTab())
        case .settings: return AnyView(SettingsTab())
        }
    }
}

/// 아직 팸이 없을 때 (보금자리 말고 다른 탭)
struct NoPetView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "heart.circle").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("보금자리에서 가족을 맞이해 주세요").font(.title3).foregroundStyle(.secondary)
            Button("보금자리로") { AppModel.shared.tab = MenuTab.adopt.rawValue }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 공간 안 메인 메뉴판 (0.10.15): 함께하는 동안 메뉴를 창(시스템이 곁에 낮고 기울여 둠) 대신 팸 카드가 뜨던 자리에 같은 방식으로.
/// 카드와 메뉴판은 한 번에 하나만 (PlaySession.openMenu)
struct MenuPanel: View {
    let s: PlaySession
    private var model: AppModel { AppModel.shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(MenuTab.order) { t in
                    let on = model.tab == t.rawValue
                    Button { model.tab = t.rawValue } label: {
                        Label(t.title, systemImage: t.icon)
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(.white.opacity(on ? 0.26 : 0), in: Capsule())
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                            // 고리·재주 단추와 같은 바라보기 효과 (캡슐 그대로 밝아지고 조금 커짐)
                            .contentShape(.hoverEffect, Capsule())
                            .hoverEffect(.highlight)
                            .hoverEffect(isEnabled: true) { e, on, _ in e.scaleEffect(on ? 1.06 : 1) }
                    }
                    .buttonStyle(RingPress())
                }
                Spacer()
                Button { s.closeMenu() } label: { Image(systemName: "xmark") }.buttonBorderShape(.circle)
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 6)
            (MenuTab(rawValue: model.tab) ?? .home).view
                .frame(width: 860, height: 600)
        }
        .overlay(alignment: .bottom) {
            if let n = model.notice {
                HStack(spacing: 12) {
                    Text(n).font(.callout)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonBorderShape(.circle)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .glassBackgroundEffect()
                .padding(.bottom, 20)
            }
        }
        .glassBackgroundEffect()
        .opacity(s.menuOn ? 1 : 0)
    }
}

// MARK: - 보금자리 (입양소)
/// 입양할 수 있는 팸들을 모아 보여 줌. 같은 종류도 여러 번 입양할 수 있음 (이름·성별·나이가 다른 새 팸)
struct AdoptTab: View {
    @State private var name = ""
    @State private var male = false
    @State private var pick = Breeds.all[0].id
    private var model: AppModel { AppModel.shared }

    var body: some View {
        let b = Breeds.of(pick)
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("보금자리").font(.extraLargeTitle)
                    Text(model.family.pets.isEmpty ? "가족을 기다리는 팸들이에요"
                         : (model.family.full ? "우리 집 팸 \(model.family.pets.count) · 지금은 \(Sim.maxPets)마리까지 함께 키울 수 있어요"
                            : "우리 집 팸 \(model.family.pets.count) · 새 가족을 더 맞이할 수 있어요 (\(Sim.maxPets)마리까지)"))
                        .font(.title3).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                    ForEach(Breeds.all) { x in
                        Button { pick = x.id } label: {
                            VStack(spacing: 10) {
                                Image(systemName: x.icon).font(.system(size: 54))
                                Text(x.name).font(.title3.weight(.semibold))
                                Text(x.note).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 230, height: 170)
                            .background(.white.opacity(pick == x.id ? 0.22 : 0.08), in: RoundedRectangle(cornerRadius: 24))
                            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(pick == x.id ? 0.55 : 0), lineWidth: 1.5))
                            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 24))
                            .hoverEffect(.highlight)
                            .hoverEffect(isEnabled: true) { e, on, _ in e.scaleEffect(on ? 1.04 : 1) }      // 고리·재주 단추와 같은 바라보기 효과
                        }
                        .buttonStyle(RingPress())
                    }
                }
                .frame(maxWidth: 760)
                Text(b.about).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 620)
                HStack(spacing: 16) {
                    TextField("이름", text: $name).textFieldStyle(.roundedBorder).frame(width: 240)
                    Picker("", selection: $male) {
                        Text("여자아이").tag(false)
                        Text("남자아이").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 240)
                }
                Button {
                    model.adopt(b, name: name, male: male)
                    name = ""
                } label: {
                    Text("\(b.name) 입양하기").font(.title3.weight(.semibold)).padding(.horizontal, 36).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.family.full)
                Text("입양할 때마다 가족 지갑에 \(Sim.startPoints)P와 이 팸 이름이 붙은 물그릇·담요가 들어와요").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 홈
/// 우리 집 팸들의 상태 카드를 한 번에 (0.11.0). '함께하기'를 누르면 모든 팸이 함께 나옴. 산책은 팸마다
struct HomeTab: View {
    private var model: AppModel { AppModel.shared }
    @State private var info: (pid: String, key: String, text: String)?

    var body: some View {
        let fam = model.family
        ScrollView {
            VStack(spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("우리 집").font(.extraLargeTitle)
                    Text("팸 \(fam.pets.count)").font(.title2).foregroundStyle(.secondary)
                    Spacer()
                    Label("\(fam.home.points)", systemImage: "p.circle.fill").font(.title2.weight(.semibold))
                }
                HStack(spacing: 16) {
                    Button { model.playOpen ? model.rest() : model.play() } label: {
                        Label(model.playOpen ? "팸들 쉬기" : "팸들과 함께하기", systemImage: model.playOpen ? "house.fill" : "pawprint.fill")
                            .font(.title3.weight(.semibold)).frame(minWidth: 240, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    if !fam.full {
                        Button { model.tab = MenuTab.adopt.rawValue } label: { Label("보금자리", systemImage: "plus").frame(minHeight: 44) }
                    }
                    Spacer()
                }
                ForEach(fam.pets, id: \.id) { p in petCard(fam.view(p)) }
            }
            .padding(32)
        }
    }

    /// 팸 하나: 이름·나이·시기, 고리 8개(누르면 그 욕구 안내), 산책
    private func petCard(_ p: PetState) -> some View {
        let age = p.age()
        let days = ((Date().timeIntervalSince1970 - p.born) / 86400).formatted(.number.precision(.fractionLength(0...1)))
        let items = Needs.list(p)
        let walkingMe = model.session?.walkPid == p.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: p.breed.icon).font(.title2)
                Text(p.name).font(.title.weight(.bold))
                Text(PetState.ageText(age)).font(.title3).foregroundStyle(.secondary)
                Text(p.breed.name + " · " + p.stage.title).font(.callout).padding(.horizontal, 10).padding(.vertical, 3).background(.white.opacity(0.12), in: Capsule())
                if p.asleep { Label("자는 중", systemImage: "zzz").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Text("함께한 지 \(days)일").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, age / p.maxAge))
            HStack(spacing: 18) {
                ForEach(0..<items.count, id: \.self) { i in
                    let k = NeedInfo.key(items[i].0)
                    Button {
                        if info?.pid == p.id && info?.key == k { info = nil } else { info = (p.id, k, NeedInfo.text(p, k)) }
                    } label: {
                        NeedRing(label: items[i].0, icon: items[i].1, value: items[i].2, size: 52, tappable: true)
                    }
                    .buttonStyle(RingPress())
                }
                Spacer(minLength: 0)
                if p.has("leash") && age >= 70 {
                    VStack(spacing: 4) {
                        Button {
                            guard let s = model.session else { model.notice = "먼저 '팸들과 함께하기'를 눌러 주세요"; return }
                            s.setWalking(p.id, !walkingMe)
                        } label: {
                            Label(walkingMe ? "산책 끝" : "산책", systemImage: "figure.walk").frame(minWidth: 110, minHeight: 40)
                        }
                        Text("오늘 \(Int(p.walkM))m").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let info, info.pid == p.id { Text(info.text).font(.callout).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(20)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
    }
}

// MARK: - 상점
/// 가족 지갑으로 삼. 물건마다 쓰는 범위 표시(개별·종류 전용·공용). 개별 물건은 어느 팸 것인지 골라 삼 (이름이 붙음)
struct ShopTab: View {
    @State private var cat: ItemCat = .food
    private var model: AppModel { AppModel.shared }

    var body: some View {
        let fam = model.family
        VStack(spacing: 16) {
            HStack {
                Picker("", selection: $cat) {
                    ForEach(ItemCat.allCases, id: \.self) { c in Text(c.rawValue).tag(c) }
                }
                .pickerStyle(.segmented)
                Label("\(fam.home.points)", systemImage: "p.circle.fill").font(.title3.weight(.semibold)).frame(width: 130, alignment: .trailing)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Catalog.items.filter { $0.cat == cat && $0.price > 0 }) { it in
                        let who = fam.pets.filter { it.fits($0) }
                        let fits = who.contains { $0.age() >= it.ageMin - 14 && $0.age() <= it.ageMax }
                        HStack(spacing: 14) {
                            Image(systemName: it.icon).font(.title2).frame(width: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(it.name + (it.permanent ? "" : " \(it.qty)\(it.unit)")).font(.headline)
                                    ScopeBadge(it)
                                }
                                Text(it.note).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if it.personal {
                                // 팸마다: 이미 있으면 '있음', 없으면 그 팸 이름으로 사기
                                ForEach(who, id: \.id) { p in
                                    let have = fam.home.has(Own.key(it.id, p.key))
                                    Button { model.buy(it, for: p.key) } label: { Text(have ? "\(p.name) 있음" : "\(p.name) \(it.price)").frame(minWidth: 84) }
                                        .disabled(!model.canBuy(it, for: p.key))
                                }
                            } else {
                                if fam.home.count(it.id) > 0 {
                                    Text(it.permanent ? "있음" : "\(fam.home.count(it.id))\(it.unit)").font(.callout).foregroundStyle(.secondary)
                                }
                                Button { model.buy(it) } label: { Text("\(it.price)").frame(width: 70) }
                                    .disabled(!model.canBuy(it) || who.isEmpty)
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                        .opacity(fits ? 1 : 0.45)
                    }
                }
            }
        }
        .padding(32)
    }
}

/// 쓰는 범위 표시: 개별(이름표) · ○○ 전용 · 공용
struct ScopeBadge: View {
    let it: Item
    init(_ it: Item) { self.it = it }
    var body: some View {
        Text(it.scopeText)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background((it.personal ? Color.orange : (it.kinds != nil || it.breeds != nil ? Color.blue : Color.gray)).opacity(0.3), in: Capsule())
    }
}

// MARK: - 보관함
/// 위: 공용 살림(상점과 같은 갈래). 아래: 팸마다 따로 쓰는 물건(이름 붙은 그릇·잠자리·줄·젖병) — 0.11.0
struct StorageTab: View {
    private var model: AppModel { AppModel.shared }
    private static let instant: Set<String> = ["vaccine", "checkup", "joint", "wipes", "toothpaste", "heartworm", "probiotic"]
    private static let handy: Set<String> = ["bottle", "brush", "treat", "dental", "shampoo"]

    // 상점과 같은 갈래로 나눠 보여 줌 (0.10.7: 한 줄로 이어져 사료는 위·물병은 맨 아래라 오가기 번거로웠음)
    @State private var cat: ItemCat = .food

    var body: some View {
        let fam = model.family
        let h = fam.home
        let shared = Catalog.items.filter { !$0.personal && (h.count($0.id) > 0 || model.session?.isOut($0.id) == true) }
        let own = shared.filter { $0.cat == cat }
        let grown = fam.pets.contains { $0.age() >= 21 }
        let jug = cat == .food && model.session != nil && grown
        VStack(spacing: 16) {
            Picker("", selection: $cat) {
                ForEach(ItemCat.allCases, id: \.self) { c in
                    let n = shared.filter { $0.cat == c }.count + (c == .food && model.session != nil && grown ? 1 : 0)
                    Text(n > 0 ? "\(c.rawValue) \(n)" : c.rawValue).tag(c)
                }
            }
            .pickerStyle(.segmented)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(own) { it in
                        let (a, b) = buttons(it.id, it)
                        row(it.icon, it.name, it.permanent ? "" : "\(h.count(it.id))\(it.unit)", it, a, b)
                    }
                    // 물병: 물은 공짜라 보관함 물건이 아니지만 꺼내고 넣을 수 있어야 함 — 사료 바로 아래
                    if jug {
                        let out = model.session?.isOut("jug") == true
                        row("waterbottle.fill", "물병", "", nil, out ? nil : take("jug", true), out ? put("jug") : nil)
                    }
                    if own.isEmpty && !jug { Text("이 갈래엔 아직 공용 물건이 없어요").foregroundStyle(.secondary).padding(24) }
                    // 팸마다 따로 쓰는 물건
                    ForEach(fam.pets, id: \.id) { p in
                        let mine = Catalog.items.filter { $0.personal && (h.has(Own.key($0.id, p.key)) || model.session?.isOut(Own.key($0.id, p.key)) == true) }
                        if !mine.isEmpty {
                            HStack {
                                Label("\(p.name) 것", systemImage: p.breed.icon).font(.headline).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.top, 10)
                            ForEach(mine) { it in
                                let k = Own.key(it.id, p.key)
                                let (a, b) = buttons(k, it)
                                row(it.icon, "\(p.name) " + it.name, "", it, a, b)
                            }
                        }
                    }
                }
            }
        }
        .padding(32)
    }
}

extension StorageTab {
    struct Act { let title: String; let on: Bool; let run: () -> Void }

    /// 단추 두 칸: 왼쪽 칸은 늘 '꺼내기'·'쓰기', 오른쪽 칸은 늘 '넣기' — 같은 글자는 같은 자리, 단추 크기는 모두 같게 (0.10.1).
    /// key = 보관함 열쇠 (공용 = 물건 이름, 개별 = 물건:팸)
    func buttons(_ key: String, _ it: Item) -> (Act?, Act?) {
        let s = model.session
        let h = model.family.home
        if StorageTab.instant.contains(it.id) { return (nil, nil) }          // 바로 쓰는 것은 줄 아래 팸 이름 단추로
        if it.id == "leash" || it.id == "formula" { return (nil, nil) }
        if it.cat == .food && !Catalog.isTreat(it.id) {
            // 사료: 사료 봉지를 손 앞에 꺼냄 / 꺼낸 봉지를 넣음
            let out = s?.isOut("foodbag") == true
            return (out ? nil : take(key, h.count(key) > 0), out ? put(key) : nil)
        }
        if it.id == "pad" {
            // 패드: 새 한 장을 손 앞에 꺼냄 / 깔린 패드(와 손에 든 패드)를 걷어 넣음
            let held = s?.isOut("padsheet") == true
            let out = s?.isOut("pad") == true || held
            return (take("pad", h.count("pad") > 0 && !held), out ? put("pad") : nil)
        }
        if it.id == "bag" {
            let out = s?.isOut("bag") == true
            return (out ? nil : take("bag", h.count("bag") > 0), out ? put("bag") : nil)
        }
        if Catalog.placeable.contains(it.id) || StorageTab.handy.contains(Catalog.base(it.id)) {
            let out = s?.isOut(key) == true
            return (out ? nil : take(key, true), out ? put(key) : nil)
        }
        return (nil, nil)
    }

    func take(_ key: String, _ on: Bool) -> Act? { Act(title: "꺼내기", on: on, run: { model.takeOut(key) }) }
    func put(_ key: String) -> Act? { Act(title: "넣기", on: true, run: { model.putBack(key) }) }

    func row(_ icon: String, _ name: String, _ count: String, _ it: Item?, _ a: Act?, _ b: Act?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).frame(width: 44)
                Text(name).font(.headline)
                if let it { ScopeBadge(it) }
                Text(count).font(.callout).foregroundStyle(.secondary)
                Spacer()
                slot(a)
                slot(b)
            }
            // 바로 쓰는 것(접종·영양제·물티슈 등): 누구에게 쓸지 팸 이름 단추
            if let it, StorageTab.instant.contains(it.id) {
                HStack(spacing: 8) {
                    Text("쓰기").font(.callout).foregroundStyle(.secondary).frame(width: 44)
                    ForEach(model.family.pets.filter { it.fits($0) }, id: \.id) { p in
                        Button(p.name) { model.useNow(it.id, pet: p.id) }.disabled(model.family.home.count(it.id) == 0)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder func slot(_ x: Act?) -> some View {
        Group {
            if let x { Button(action: x.run) { Text(x.title).frame(width: 84) }.disabled(!x.on) }
            else { Color.clear.frame(width: 84, height: 1) }
        }
        .frame(width: 124)
    }
}

/// 고리 단추: 시스템의 네모난 포커스 대신 고리 둘레만 은은하게 밝아짐 (0.10.1)
struct RingPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 설정
/// 재주 목록 (0.10.13): 단추 모양 이름표로 한눈에 — 나이가 되어 가르칠 수 있는 재주는 밝게, 아직이면 흐리게.
/// 누르면 아래에 언제부터·어떻게 가르치는지 한두 줄. 익힌 만큼 % 표시
struct TrickChips: View {
    let pet: PetState
    @State private var sel: String?

    struct Info { let key: String; let title: String; let from: Double; let how: String }
    static let all: [Info] = [
        Info(key: "sit", title: "앉아", from: 42, how: "간식을 서 있는 팸 머리보다 조금 위로 → 앉아서 1초 있으면 간식"),
        Info(key: "down", title: "엎드려", from: 42, how: "간식을 바닥 가까이 → 엎드려서 1초 있으면 간식"),
        Info(key: "roll", title: "굴러", from: 42, how: "엎드린 팸 머리 옆에서 간식을 어깨 쪽으로 → 구르면 간식 (엎드려를 25% 익힌 뒤)"),
        Info(key: "paw", title: "손", from: 56, how: "간식은 한 손에 들고, 앉은 팸 가슴 앞에 다른 빈 손바닥을 낮게 → 앞발을 올리면 간식"),
        Info(key: "touch", title: "코", from: 42, how: "간식은 한 손에 들고, 서 있는 팸 코앞에 다른 빈 손바닥을 → 코를 대면 간식"),
        Info(key: "speak", title: "짖어", from: 56, how: "간식을 내 얼굴 높이 이상으로 들고 기다림 → 짖으면 내려서 간식"),
        Info(key: "spin", title: "돌아", from: 90, how: "서 있는 팸 머리 높이에서 간식으로 몸 둘레에 크게 원 → 한 바퀴 돌면 간식"),
        Info(key: "beg", title: "애교", from: 120, how: "앉은 팸 머리 위로 간식을 조금 더 높게 → 앞발을 들고 1초 있으면 간식"),
        Info(key: "hind", title: "일어서", from: 150, how: "팸 바로 위, 머리보다 훨씬 높게 → 뒷발로 서면 간식 (노견은 안 함)"),
    ]

    static func ageText(_ d: Double) -> String { d < 60 ? "생후 \(Int(d / 7))주" : "생후 \(Int((d / 30.4).rounded()))개월" }

    var body: some View {
        let age = pet.age()
        VStack(alignment: .leading, spacing: 10) {
            Text("재주").font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(TrickChips.all, id: \.key) { t in
                    let open = age >= t.from && !(t.key == "hind" && Stage.of(age) == .senior)
                    let skill = pet.tricks[t.key] ?? 0
                    Button { sel = sel == t.key ? nil : t.key } label: {
                        Text(skill > 0 ? "\(t.title) \(Int(skill * 100))%" : t.title)
                            .font(.callout.weight(.medium))
                            .frame(minWidth: 72)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(open ? Color.white.opacity(sel == t.key ? 0.32 : 0.16) : Color.white.opacity(0.05), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(sel == t.key ? 0.6 : 0), lineWidth: 1.5))
                            .foregroundStyle(open ? Color.primary : Color.secondary.opacity(0.6))
                            // 바라보면 고리와 똑같이: 단추 모양(캡슐) 그대로 밝아지고 조금 커짐 (0.10.14)
                            // 0.10.13 은 .borderless 단추에 효과를 걸어 시스템이 단추 둘레를 둥근 네모로 부풀려 보였음 — 고리에서 고쳤던 것과 같은 실수
                            .contentShape(.hoverEffect, Capsule())
                            .hoverEffect(.highlight)
                            .hoverEffect(isEnabled: true) { e, on, _ in e.scaleEffect(on ? 1.1 : 1) }
                    }
                    .buttonStyle(RingPress())                      // 시스템 단추 모양 없이 (한 줄 안 단추마다 따로 눌림)
                }
            }
            if let k = sel, let t = TrickChips.all.first(where: { $0.key == k }) {
                let open = age >= t.from && !(t.key == "hind" && Stage.of(age) == .senior)
                Text((open ? "" : "\(TrickChips.ageText(t.from))부터 · ") + t.how + " · 할 때 말을 하고 15초 안에 간식을 주면 그 말도 배워요")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsTab: View {
    @State private var volume: Double = UserDefaults.standard.object(forKey: "af.volume") as? Double ?? 0
    @State private var askRemove: PetState?
    @State private var voice = VoiceEar.enabled
    private var model: AppModel { AppModel.shared }

    var body: some View {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let fam = model.family
        Form {
            Section("소리") {
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: $volume, in: -24...6)
                    Image(systemName: "speaker.wave.3.fill")
                }
                .onChange(of: volume) { _, x in
                    SoundBank.shared.master = x
                    UserDefaults.standard.set(x, forKey: "af.volume")
                }
            }
            // 말로 부르기·시키기: 간식으로 재주를 가르치며 말하면 그 말을 배움 (팸마다·사람마다 다른 말도 각각).
            // 이름을 부르고 말하면 그 팸만, 이름 없이 말하면 모두가 들음 (0.11.0)
            Section("목소리") {
                Toggle("말 알아듣기", isOn: Binding(get: { voice }, set: { voice = $0; VoiceEar.enabled = $0 }))
                LabeledContent("최근 들은 말", value: VoiceEar.recent.isEmpty ? "없음" : VoiceEar.recent.prefix(5).joined(separator: " · "))
                Text("이름을 부른 뒤 말하면 그 팸만, 이름 없이 말하면 모두가 들어요").font(.footnote).foregroundStyle(.secondary)
            }
            // 팸마다 재주·배운 말 (한 화면에 모두)
            ForEach(fam.pets, id: \.id) { p in
                Section("\(p.name) · 재주와 배운 말") {
                    TrickChips(pet: p)
                    let list = p.words.compactMap { w, m -> (String, String, Float)? in
                        guard let b = m.max(by: { $0.value < $1.value }), b.value >= 0.2 else { return nil }
                        return (w, Dog.trickTitle(b.key), b.value)
                    }.sorted { $0.2 > $1.2 }
                    if list.isEmpty { LabeledContent("배운 말", value: "아직 없음") }
                    ForEach(list.prefix(20), id: \.0) { it in
                        // 잘못 배운 말은 지울 수 있게 (0.10.10) — 한 줄에 단추가 있으니 .borderless (줄 전체가 눌리지 않게)
                        HStack {
                            LabeledContent("'\(it.0)' → \(it.1)", value: "\(Int(it.2 * 100))%")
                            Button(role: .destructive) { model.forgetWord(it.0, pet: p.id) } label: { Label("지우기", systemImage: "trash").labelStyle(.iconOnly) }
                                .buttonStyle(.borderless)
                                .padding(.leading, 12)
                        }
                    }
                }
            }
            Section("가족") {
                ForEach(fam.pets, id: \.id) { p in
                    // 팸마다 따로 헤어질 수 있음 (그 팸 이름이 붙은 물건도 함께 정리). 함께하는 동안은 안 됨
                    Button("\(p.name)\(Josa.wa(p.name)) 헤어지기", role: .destructive) { askRemove = p }
                        .disabled(model.playOpen)
                }
                if fam.pets.isEmpty { Text("아직 가족이 없어요").foregroundStyle(.secondary) }
            }
            Section("정보") {
                LabeledContent("버전", value: "\(v) (\(b))")
                LabeledContent("만든 곳", value: "Blankish works")
            }
        }
        .onAppear { SoundBank.shared.master = volume }
        .confirmationDialog(askRemove.map { "\($0.name)\(Josa.wa($0.name)) 헤어질까요? \($0.name) 이름이 붙은 물건도 함께 정리돼요. 다른 팸들은 그대로예요." } ?? "",
                            isPresented: Binding(get: { askRemove != nil }, set: { if !$0 { askRemove = nil } }), titleVisibility: .visible) {
            Button("헤어지기", role: .destructive) { if let p = askRemove { model.remove(p.id) }; askRemove = nil }
            Button("취소", role: .cancel) { askRemove = nil }
        }
        .padding(24)
    }
}
