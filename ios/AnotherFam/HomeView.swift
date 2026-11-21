import SwiftUI

/// 메인 창: 입양 → 홈(상태)·상점·보관함·설정
struct HomeView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private var model: AppModel { AppModel.shared }

    var body: some View {
        Group {
            if model.pet != nil {
                TabView(selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                    HomeTab().tabItem { Label("홈", systemImage: "pawprint.fill") }.tag(0)
                    StorageTab().tabItem { Label("보관함", systemImage: "archivebox.fill") }.tag(1)
                    ShopTab().tabItem { Label("상점", systemImage: "cart.fill") }.tag(2)
                    SettingsTab().tabItem { Label("설정", systemImage: "gearshape.fill") }.tag(3)
                }
            } else {
                AdoptView()
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
            model.session?.closeCard()
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

// MARK: - 입양
struct AdoptView: View {
    @State private var name = ""
    @State private var male = false
    private let breeds: [(id: String, name: String, note: String)] = [("maltese", "말티즈", "희고 작은 친구 · 다 자라면 3kg")]
    @State private var pick = "maltese"

    var body: some View {
        VStack(spacing: 26) {
            Text("어나더 팸").font(.extraLargeTitle)
            Text("가족을 맞이해요").font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach(breeds, id: \.id) { b in
                    Button { pick = b.id } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "dog.fill").font(.system(size: 54))
                            Text(b.name).font(.title3.weight(.semibold))
                            Text(b.note).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 240, height: 180)
                        .background(.white.opacity(pick == b.id ? 0.22 : 0.08), in: RoundedRectangle(cornerRadius: 24))
                        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 24))
                        .hoverEffect(.highlight)
                        .hoverEffect(isEnabled: true) { e, on, _ in e.scaleEffect(on ? 1.04 : 1) }      // 고리·재주 단추와 같은 바라보기 효과
                    }
                    .buttonStyle(RingPress())
                }
            }
            HStack(spacing: 16) {
                TextField("이름", text: $name).textFieldStyle(.roundedBorder).frame(width: 240)
                Picker("", selection: $male) {
                    Text("여자아이").tag(false)
                    Text("남자아이").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 240)
            }
            Button { AppModel.shared.adopt(name: name, male: male) } label: {
                Text("입양하기").font(.title3.weight(.semibold)).padding(.horizontal, 36).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

// MARK: - 홈
struct HomeTab: View {
    private var model: AppModel { AppModel.shared }
    @State private var info: (key: String, text: String)?

    var body: some View {
        if let p = model.pet {
            let age = p.age()
            // 설정의 '함께한 날'과 같은 셈 (지난 날수, 소수 한 자리) — 0.7.0 은 '+1일째'로 세어 1일이 2일로 보였음
            let days = ((Date().timeIntervalSince1970 - p.born) / 86400).formatted(.number.precision(.fractionLength(0...1)))
            VStack(spacing: 24) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(p.name).font(.extraLargeTitle)
                    Text(PetState.ageText(age)).font(.title2).foregroundStyle(.secondary)
                    Text(p.stage.title).font(.callout).padding(.horizontal, 12).padding(.vertical, 4).background(.white.opacity(0.12), in: Capsule())
                    Spacer()
                    Label("\(p.points)", systemImage: "p.circle.fill").font(.title2.weight(.semibold))
                }
                ProgressView(value: min(1, age / Sim.maxAge)) { Text("함께한 지 \(days)일").font(.caption).foregroundStyle(.secondary) }
                let items = Needs.list(p)
                HStack(spacing: 22) {
                    ForEach(0..<items.count, id: \.self) { i in
                        let k = NeedInfo.key(items[i].0)
                        Button { if info?.key == k { info = nil } else { info = (k, NeedInfo.text(p, k)) } } label: {
                            NeedRing(label: items[i].0, icon: items[i].1, value: items[i].2, size: 64, tappable: true)
                        }
                        .buttonStyle(RingPress())
                    }
                }
                .padding(.vertical, 8)
                if let info { Text(info.text).font(.title3).multilineTextAlignment(.center) }
                HStack(spacing: 16) {
                    Button { model.playOpen ? model.rest() : model.play() } label: {
                        Label(model.playOpen ? "쉬기" : "함께하기", systemImage: model.playOpen ? "house.fill" : "pawprint.fill")
                            .font(.title3.weight(.semibold)).frame(width: 220, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    if p.has("leash") && age >= 70 {
                        Button {
                            guard let s = model.session else { model.notice = "먼저 '함께하기'를 눌러 주세요"; return }
                            s.setWalking(!s.walking)
                        } label: {
                            Label(model.session?.walking == true ? "산책 끝" : "산책", systemImage: "figure.walk").font(.title3).frame(width: 160, height: 44)
                        }
                        Text("오늘 \(Int(p.walkM))m").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if p.asleep { Label("자는 중", systemImage: "zzz").foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            .padding(40)
        }
    }
}

// MARK: - 상점
struct ShopTab: View {
    @State private var cat: ItemCat = .food
    private var model: AppModel { AppModel.shared }

    var body: some View {
        if let p = model.pet {
            let age = p.age()
            VStack(spacing: 16) {
                HStack {
                    Picker("", selection: $cat) {
                        ForEach(ItemCat.allCases, id: \.self) { c in Text(c.rawValue).tag(c) }
                    }
                    .pickerStyle(.segmented)
                    Label("\(p.points)", systemImage: "p.circle.fill").font(.title3.weight(.semibold)).frame(width: 130, alignment: .trailing)
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Catalog.items.filter { $0.cat == cat && $0.price > 0 }) { it in
                            let fits = age >= it.ageMin - 14 && age <= it.ageMax
                            HStack(spacing: 14) {
                                Image(systemName: it.icon).font(.title2).frame(width: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(it.name + (it.permanent ? "" : " \(it.qty)\(it.unit)")).font(.headline)
                                    Text(it.note).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if p.count(it.id) > 0 {
                                    Text(it.permanent ? "있음" : "\(p.count(it.id))\(it.unit)").font(.callout).foregroundStyle(.secondary)
                                }
                                Button { model.buy(it) } label: { Text("\(it.price)").frame(width: 70) }
                                    .disabled(!model.canBuy(it))
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
}

// MARK: - 보관함
struct StorageTab: View {
    private var model: AppModel { AppModel.shared }
    private static let instant: Set<String> = ["vaccine", "checkup", "joint", "wipes", "toothpaste", "heartworm", "probiotic"]
    private static let handy: Set<String> = ["bottle", "brush", "treat", "dental", "shampoo"]

    // 상점과 같은 갈래로 나눠 보여 줌 (0.10.7: 한 줄로 이어져 사료는 위·물병은 맨 아래라 오가기 번거로웠음)
    @State private var cat: ItemCat = .food

    var body: some View {
        if let p = model.pet {
            let all = Catalog.items.filter { p.count($0.id) > 0 || model.session?.isOut($0.id) == true }
            let own = all.filter { $0.cat == cat }
            let jug = cat == .food && model.session != nil && p.age() >= 21
            VStack(spacing: 16) {
                Picker("", selection: $cat) {
                    ForEach(ItemCat.allCases, id: \.self) { c in
                        let n = all.filter { $0.cat == c }.count + (c == .food && model.session != nil && p.age() >= 21 ? 1 : 0)
                        Text(n > 0 ? "\(c.rawValue) \(n)" : c.rawValue).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(own) { it in
                            let (a, b) = buttons(it, p)
                            row(it.icon, it.name, it.permanent ? "" : "\(p.count(it.id))\(it.unit)", a, b)
                        }
                        // 물병: 물은 공짜라 보관함 물건이 아니지만 꺼내고 넣을 수 있어야 함 — 사료 바로 아래
                        if jug {
                            let out = model.session?.isOut("jug") == true
                            row("waterbottle.fill", "물병", "", out ? nil : take("jug", true), out ? put("jug") : nil)
                        }
                        if own.isEmpty && !jug { Text("이 갈래엔 아직 없어요").foregroundStyle(.secondary).padding(40) }
                    }
                }
            }
            .padding(32)
        }
    }
}

extension StorageTab {
    struct Act { let title: String; let on: Bool; let run: () -> Void }

    /// 단추 두 칸: 왼쪽 칸은 늘 '꺼내기'·'쓰기', 오른쪽 칸은 늘 '넣기' — 같은 글자는 같은 자리, 단추 크기는 모두 같게 (0.10.1)
    func buttons(_ it: Item, _ p: PetState) -> (Act?, Act?) {
        let s = model.session
        if StorageTab.instant.contains(it.id) { return (Act(title: "쓰기", on: true, run: { model.useNow(it.id) }), nil) }
        if it.id == "leash" || it.id == "formula" { return (nil, nil) }
        if it.cat == .food && !Catalog.isTreat(it.id) {
            // 사료: 사료 봉지를 손 앞에 꺼냄 / 꺼낸 봉지를 넣음
            let out = s?.isOut("foodbag") == true
            return (out ? nil : take(it.id, p.count(it.id) > 0), out ? put(it.id) : nil)
        }
        if it.id == "pad" {
            // 패드: 새 한 장을 손 앞에 꺼냄 / 깔린 패드(와 손에 든 패드)를 걷어 넣음
            let held = s?.isOut("padsheet") == true
            let out = s?.isOut("pad") == true || held
            return (take("pad", p.count("pad") > 0 && !held), out ? put("pad") : nil)
        }
        if it.id == "bag" {
            let out = s?.isOut("bag") == true
            return (out ? nil : take("bag", p.count("bag") > 0), out ? put("bag") : nil)
        }
        if Catalog.placeable.contains(it.id) || StorageTab.handy.contains(Catalog.base(it.id)) {
            let out = s?.isOut(it.id) == true
            return (out ? nil : take(it.id, true), out ? put(it.id) : nil)
        }
        return (nil, nil)
    }

    func take(_ id: String, _ on: Bool) -> Act? { Act(title: "꺼내기", on: on, run: { model.takeOut(id) }) }
    func put(_ id: String) -> Act? { Act(title: "넣기", on: true, run: { model.putBack(id) }) }

    func row(_ icon: String, _ name: String, _ count: String, _ a: Act?, _ b: Act?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 44)
            Text(name).font(.headline)
            Text(count).font(.callout).foregroundStyle(.secondary)
            Spacer()
            slot(a)
            slot(b)
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
    @State private var askReset = false
    @State private var entry = ""
    @State private var voice = VoiceEar.enabled
    private var model: AppModel { AppModel.shared }

    var body: some View {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
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
            // 함께한 날: 화면 안 숫자판으로 바로 입력 (0.4.0 숫자 칸은 정확히 눌러야 했고, 0.5.0 슬라이더는 맞추기 어려웠고
            // 단추는 폼 한 줄 안에 여럿이라 눌리지 않았음 — 한 줄에 단추가 여럿이면 모두 .bordered 로 따로 눌리게)
            Section("시험 · 함께한 날") {
                let val = min(Sim.maxAge / Sim.ageRate, Double(entry) ?? 0)
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text((entry.isEmpty ? "0" : entry) + "일").font(.system(size: 44, weight: .semibold)).monospacedDigit()
                        Text("강아지 나이 " + PetState.ageText(val * Sim.ageRate)).foregroundStyle(.secondary)
                        Button("적용") { model.setTogetherDays(val); entry = val.formatted(.number.precision(.fractionLength(0...1))) }
                            .buttonStyle(.borderedProminent).padding(.top, 6)
                    }
                    Spacer()
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [".", "0", "⌫"]], id: \.self) { row in
                            GridRow {
                                ForEach(row, id: \.self) { k in
                                    Button { key(k) } label: {
                                        Group { if k == "⌫" { Image(systemName: "delete.left") } else { Text(k) } }
                                            .font(.title2.weight(.medium)).frame(width: 64, height: 44)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            // 말로 부르기·시키기: 간식으로 재주를 가르치며 말하면 그 말을 배움 (사람마다 다른 말도 각각)
            Section("목소리") {
                Toggle("말 알아듣기", isOn: Binding(get: { voice }, set: { voice = $0; VoiceEar.enabled = $0 }))
                if let p = model.pet { TrickChips(pet: p) }
                LabeledContent("최근 들은 말", value: VoiceEar.recent.isEmpty ? "없음" : VoiceEar.recent.prefix(5).joined(separator: " · "))
                if let p = model.pet, p.words.values.allSatisfy({ ($0.values.max() ?? 0) < 0.2 }) {
                    LabeledContent("배운 말", value: "아직 없음")
                }
                if let p = model.pet, !p.words.isEmpty {
                    let list = p.words.compactMap { w, m -> (String, String, Float)? in
                        guard let b = m.max(by: { $0.value < $1.value }), b.value >= 0.2 else { return nil }
                        return (w, Dog.trickTitle(b.key), b.value)
                    }.sorted { $0.2 > $1.2 }
                    ForEach(list.prefix(20), id: \.0) { it in
                        // 잘못 배운 말은 지울 수 있게 (0.10.10) — 한 줄에 단추가 있으니 .borderless (줄 전체가 눌리지 않게)
                        HStack {
                            LabeledContent("'\(it.0)' → \(it.1)", value: "\(Int(it.2 * 100))%")
                            Button(role: .destructive) { model.forgetWord(it.0) } label: { Label("지우기", systemImage: "trash").labelStyle(.iconOnly) }
                                .buttonStyle(.borderless)
                                .padding(.leading, 12)
                        }
                    }
                }
            }
            Section("가족") {
                Button("처음부터 다시", role: .destructive) { askReset = true }
                    .disabled(model.playOpen)
            }
            Section("정보") {
                LabeledContent("버전", value: "\(v) (\(b))")
                LabeledContent("만든 곳", value: "Blankish works")
            }
        }
        .onAppear {
            SoundBank.shared.master = volume
            if let p = model.pet { entry = ((Date().timeIntervalSince1970 - p.born) / 86400).formatted(.number.precision(.fractionLength(0...1)).grouping(.never)) }
        }
        .confirmationDialog("지금 가족과 헤어지고 처음부터 다시 시작할까요?", isPresented: $askReset, titleVisibility: .visible) {
            Button("헤어지기", role: .destructive) { model.reset() }
            Button("취소", role: .cancel) {}
        }
        .padding(24)
    }

    /// 숫자판 한 칸 (소수 한 자리까지, 최대 365일)
    private func key(_ k: String) {
        switch k {
        case "⌫": if !entry.isEmpty { entry.removeLast() }
        case ".": if !entry.contains(".") { entry = (entry.isEmpty ? "0" : entry) + "." }
        default:
            if let dot = entry.firstIndex(of: "."), entry.distance(from: dot, to: entry.endIndex) > 1 { return }
            let next = entry == "0" ? k : entry + k
            if (Double(next) ?? 0) <= Sim.maxAge / Sim.ageRate { entry = next }
        }
    }
}
