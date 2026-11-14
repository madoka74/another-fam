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
                    ShopTab().tabItem { Label("상점", systemImage: "cart.fill") }.tag(1)
                    StorageTab().tabItem { Label("보관함", systemImage: "archivebox.fill") }.tag(2)
                    SettingsTab().tabItem { Label("설정", systemImage: "gearshape.fill") }.tag(3)
                }
            } else {
                AdoptView()
            }
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
                    }
                    .buttonStyle(.plain)
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

    var body: some View {
        if let p = model.pet {
            let age = p.age()
            let days = Int((Date().timeIntervalSince1970 - p.born) / 86400) + 1
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
                    ForEach(0..<items.count, id: \.self) { i in NeedRing(icon: items[i].0, value: items[i].1, size: 64) }
                }
                .padding(.vertical, 8)
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
    private static let instant: Set<String> = ["vaccine", "checkup", "joint"]
    private static let handy: Set<String> = ["bottle", "brush", "treat", "dental", "shampoo"]

    var body: some View {
        if let p = model.pet {
            let own = Catalog.items.filter { p.count($0.id) > 0 || model.session?.isOut($0.id) == true }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(own) { it in
                        HStack(spacing: 14) {
                            Image(systemName: it.icon).font(.title2).frame(width: 44)
                            Text(it.name).font(.headline)
                            Text(it.permanent ? "" : "\(p.count(it.id))\(it.unit)").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            if StorageTab.instant.contains(it.id) {
                                Button("쓰기") { model.useNow(it.id) }.frame(width: 110)
                            } else if it.id == "leash" {
                                EmptyView()
                            } else if Catalog.placeable.contains(it.id) || StorageTab.handy.contains(it.id) {
                                let out = model.session?.isOut(it.id) == true
                                Button(out ? "넣기" : "꺼내기") { out ? model.putBack(it.id) : model.takeOut(it.id) }.frame(width: 110)
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                    }
                    if own.isEmpty { Text("비어 있어요").foregroundStyle(.secondary).padding(40) }
                }
            }
            .padding(32)
        }
    }
}

// MARK: - 설정
struct SettingsTab: View {
    @State private var volume: Double = UserDefaults.standard.object(forKey: "af.volume") as? Double ?? 0
    @State private var askReset = false
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
            Section("가족") {
                Button("처음부터 다시", role: .destructive) { askReset = true }
                    .disabled(model.playOpen)
            }
            Section("정보") {
                LabeledContent("버전", value: "\(v) (\(b))")
                LabeledContent("만든 곳", value: "Blankish works")
            }
        }
        .onAppear { SoundBank.shared.master = volume }
        .confirmationDialog("지금 가족과 헤어지고 처음부터 다시 시작할까요?", isPresented: $askReset, titleVisibility: .visible) {
            Button("헤어지기", role: .destructive) { model.reset() }
            Button("취소", role: .cancel) {}
        }
        .padding(24)
    }
}
