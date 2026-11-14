import SwiftUI
import RealityKit

/// 아이폰 화면: 지금의 팸(손가락으로 돌려 보는 3D) + 하고 있는 일 + 상태 + 다음 알림. 보기만 하는 화면
struct PhoneView: View {
    private var m: PhoneModel { PhoneModel.shared }
    @State private var stage = DogStage()

    private let ground = Color(red: 0.105, green: 0.110, blue: 0.120)
    private let card = Color.white.opacity(0.06)

    var body: some View {
        ZStack {
            ground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    if let p = m.pet {
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
        .onChange(of: m.pet) { _, p in
            if let p { stage.show(p, m.doing) }
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
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
            ForEach(0..<items.count, id: \.self) { i in
                VStack(spacing: 5) {
                    Ring(icon: items[i].1, value: items[i].2)
                    Text(items[i].0).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 18).padding(.horizontal, 12)
        .background(card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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

    // MARK: 알림
    private var alertsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("다음 알림", systemImage: "bell.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if m.allowed == false {
                Button { m.askPermission() } label: {
                    Text("알림 허용하기").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
            if m.upcoming.isEmpty {
                Text("당분간 없어요").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(m.upcoming) { a in
                HStack {
                    Text(a.text).font(.subheadline)
                    Spacer()
                    Text(when(a.at)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Divider().overlay(.white.opacity(0.1))
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

    private func when(_ t: Double) -> String {
        let d = Date(timeIntervalSince1970: t)
        if t - Date().timeIntervalSince1970 < 60 { return "곧" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "a h:mm" : "M/d a h:mm"
        return f.string(from: d)
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
