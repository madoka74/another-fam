import SwiftUI
import RealityKit

/// 아이폰 화면: 지금의 팸(손가락으로 돌려 보는 3D) + 하고 있는 일 + 상태 + 다음 알림. 보기만 하는 화면
struct PhoneView: View {
    private var m: PhoneModel { PhoneModel.shared }
    @State private var stage = DogStage()
    @State private var info: (key: String, text: String)?

    private let ground = Color(red: 0.105, green: 0.110, blue: 0.120)
    private let card = Color.white.opacity(0.06)

    var body: some View {
        ZStack {
            ground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    if let p = m.pet {
                        if m.pets.count > 1 { petRow(p.id) }
                        stageCard(p)
                        needsCard(p)
                        alertsCard
                    } else {
                        emptyCard
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .refreshable { await m.update() }
        }
        .preferredColorScheme(.dark)
        .task {
            // 열어 둔 동안 1분마다 새로 (시간이 흐르면 상태도 바뀜)
            while !Task.isCancelled {
                await m.update()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .task {
            // '지금 함께 있어요' 같은 표시가 오래된 채 남지 않게 15초마다 다시 그림
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                m.clock = Date().timeIntervalSince1970
            }
        }
        .onChange(of: m.pet) { _, p in
            if let p { stage.show(p, m.doing) }
        }
    }

    // MARK: 우리 집 팸들 (0.10.15): 둘 이상이면 위에 이름 줄 — 누르면 그 팸을 봄 (알림은 모든 팸 것)
    private func petRow(_ sel: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(m.pets, id: \.id) { q in
                    let on = q.id == sel
                    Button {
                        m.sel = q.id
                        info = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Breeds.of(q.species).icon).font(.footnote)
                            Text(q.name).font(.subheadline.weight(.semibold))
                            if m.togetherNow(q) { Image(systemName: "visionpro").font(.caption2) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.white.opacity(on ? 0.22 : 0.07), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(on ? 0.5 : 0), lineWidth: 1.2))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: 지금 모습
    private func stageCard(_ p: PetState) -> some View {
        let doing = m.doing
        return ZStack {
            RealityView { content in
                content.camera = .virtual                       // 카메라 화면(AR)이 아니라 화면 안의 무대
                stage.setup()
                content.add(stage.root)
                stage.sub = content.subscribe(to: SceneEvents.Update.self) { e in stage.tick(Float(e.deltaTime)) }
                if let now = PhoneModel.shared.pet { stage.show(now, PhoneModel.shared.doing) }
            }
            .background(LinearGradient(colors: [Color(red: 0.30, green: 0.27, blue: 0.25), Color(red: 0.16, green: 0.15, blue: 0.15)],
                                       startPoint: .top, endPoint: .bottom))
            // 한 손가락으로 돌리고, 두 손가락으로 당겨 보기
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { stage.drag($0.translation.width, $0.translation.height) }
                .onEnded { _ in stage.dragEnd() })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { stage.pinch($0.magnification) }
                .onEnded { _ in stage.pinchEnd() })
            // 톡 건드리면 지금 상태에 맞게 작게 반응 (소리와 함께)
            .simultaneousGesture(SpatialTapGesture().onEnded { _ in stage.poke() })
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(p.name).font(.system(size: 32, weight: .bold))
                    Text(PetState.ageText(p.age())).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(p.stage.title).font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                Spacer()
                HStack {
                    Label(doing.text(baby: p.age() < 21), systemImage: doing.icon)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.35), in: Capsule())
                    Spacer()
                    Image(systemName: "rotate.3d").font(.footnote).foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(18)
            .allowsHitTesting(false)
        }
        .frame(height: 400)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    // MARK: 상태
    private func needsCard(_ p: PetState) -> some View {
        let items = needs(p)
        return VStack(spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                ForEach(0..<items.count, id: \.self) { i in
                    let k = NeedInfo.key(items[i].0)
                    Button {
                        // 고리를 누르면 그 욕구의 지금과 앞으로 (비전의 카드·메인 메뉴와 같은 글)
                        if info?.key == k { info = nil } else { info = (k, NeedInfo.text(p, k)) }
                    } label: {
                        VStack(spacing: 5) {
                            Ring(icon: items[i].1, value: items[i].2)
                                .overlay(Circle().stroke(.white.opacity(info?.key == k ? 0.5 : 0), lineWidth: 2).padding(-4))
                            Text(items[i].0).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let info {
                Text(info.text).font(.subheadline).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .padding(.horizontal, 6).transition(.opacity)
            }
        }
        .padding(.vertical, 18).padding(.horizontal, 12)
        .background(card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: info?.key)
    }

    private func needs(_ p: PetState) -> [(String, String, Float)] {
        var out: [(String, String, Float)] = [("밥", "fork.knife", p.food)]
        if p.age() >= 21 { out.append(("물", "drop.fill", p.water)) }
        out.append(("기운", "moon.zzz.fill", p.energy))
        out.append(("배변", "toilet.fill", p.potty))
        if p.age() >= 21 { out.append(("놀이", "tennisball.fill", p.fun)) }
        out.append(("사랑", "heart.fill", p.love))
        out.append(("청결", "sparkles", p.clean))
        out.append(("건강", "cross.case.fill", p.health))
        return out
    }

    // MARK: 알림 — 미리 정해진 목록은 보여 주지 않음 (사용자가 하기에 따라 달라지는 일이라 예정표처럼 보이면 어색함)
    private var alertsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("알림", systemImage: "bell.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if m.allowed == false {
                Button { m.askPermission() } label: {
                    Text("알림 허용하기").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
            Toggle("밤(23~7시)에도 알림", isOn: Binding(get: { m.night }, set: { m.night = $0 })).font(.subheadline)
        }
        .padding(18)
        .background(card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var emptyCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "dog.fill").font(.system(size: 52)).foregroundStyle(.secondary)
            Text("비전 프로에서 가족을 맞이하면\n여기서 만날 수 있어요").multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 70)
        .background(card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var footer: some View {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return VStack(spacing: 4) {
            if m.pet != nil { Text("비전 프로 소식 · \(ago(m.seenAt))") }
            Text("어나더 팸 \(v) (\(b))")
        }
        .font(.caption2).foregroundStyle(.tertiary)
        .padding(.top, 6)
    }

    private func ago(_ t: Double) -> String {
        let s = Date().timeIntervalSince1970 - t
        if s < 90 { return "방금" }
        if s < 3600 { return "\(Int(s / 60))분 전" }
        if s < 86400 { return "\(Int(s / 3600))시간 전" }
        return "\(Int(s / 86400))일 전"
    }

}

struct Ring: View {
    let icon: String
    let value: Float

    var body: some View {
        let v = CGFloat(min(1, max(0, value)))
        let col: Color = value < 0.25 ? .red : (value < 0.5 ? .orange : .green)
        ZStack {
            Circle().stroke(value < 0.25 ? Color.red.opacity(0.35) : .white.opacity(0.12), lineWidth: 5)
            Circle().trim(from: 0, to: v).stroke(col, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(value < 0.25 ? Color.red : .primary)
        }
        .frame(width: 54, height: 54)
    }
}
