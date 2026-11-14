import SwiftUI
import RealityKit

/// 함께하는 공간 화면
struct PlayView: View {
    @State private var s = PlaySession()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        RealityView { content, attachments in
            content.add(s.root)
            if let c = attachments.entity(for: "card") { s.attachCard(c) }
            s.updateSub = content.subscribe(to: SceneEvents.Update.self) { e in s.tick(Float(e.deltaTime)) }
        } attachments: {
            Attachment(id: "card") { StatusCard(s: s) }
        }
        // 강아지를 바라보고 집으면 상태 카드
        .gesture(SpatialTapGesture().targetedToEntity(where: .has(DogTag.self)).onEnded { _ in s.tapDog() })
        // 그릇·패드·치울 것: 바라보고 집으면 채우기·갈기·치우기
        .simultaneousGesture(SpatialTapGesture().targetedToEntity(where: .has(PropTag.self)).onEnded { v in s.tapProp(v.entity) })
        // 안고 있는 동안은 진짜 손이 강아지 위에 겹쳐 그려지지 않게 (손에 가려 강아지가 흐릿했음)
        .upperLimbVisibility(s.holding ? .hidden : .automatic)
        .task {
            let ow = openWindow, close = dismissImmersiveSpace
            AppModel.shared.openMain = { ow(id: "main") }
            AppModel.shared.closeAction = { await close() }
            await s.start()
        }
        .onDisappear {
            s.stop()
            if !AppModel.shared.mainOpen { openWindow(id: "main") }      // 쉬러 가면 메인 창으로
        }
    }
}

/// 욕구 하나 (아이콘 + 채움 고리)
struct NeedRing: View {
    let icon: String
    let value: Float
    var size: CGFloat = 40

    var body: some View {
        let v = CGFloat(min(1, max(0, value)))
        let col: Color = value < 0.25 ? .red : (value < 0.5 ? .orange : .green)
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: size * 0.1)
            Circle().trim(from: 0, to: v).stroke(col, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round)).rotationEffect(.degrees(-90))
            Image(systemName: icon).font(.system(size: size * 0.38))
        }
        .frame(width: size, height: size)
    }
}

enum Needs {
    static func list(_ p: PetState) -> [(String, Float)] {
        var out: [(String, Float)] = [("fork.knife", p.food)]
        if p.age() >= 21 { out.append(("drop.fill", p.water)) }
        out.append(("moon.zzz.fill", p.energy))
        out.append(("toilet.fill", p.potty))
        if p.age() >= 21 { out.append(("tennisball.fill", p.fun)) }
        out.append(("heart.fill", p.love))
        out.append(("sparkles", p.clean))
        out.append(("cross.case.fill", p.health))
        return out
    }
}

struct CardButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(width: 58, height: 46)
        }
        .buttonBorderShape(.roundedRectangle(radius: 14))
    }
}

/// 강아지 메뉴 카드 (강아지를 바라보고 집으면 뜸): 상태 + 할 일 + 짧은 알림
struct StatusCard: View {
    let s: PlaySession

    var body: some View {
        let p = s.shown
        VStack(spacing: 10) {
            if s.cardOn {
                HStack(spacing: 8) {
                    Text(p.name).font(.headline)
                    Text(PetState.ageText(p.age())).font(.subheadline).foregroundStyle(.secondary)
                    if p.asleep { Image(systemName: "zzz").foregroundStyle(.secondary) }
                    Spacer(minLength: 12)
                    Label("\(p.points)", systemImage: "p.circle.fill").font(.subheadline)
                    Button { s.closeCard() } label: { Image(systemName: "xmark") }.buttonBorderShape(.circle).controlSize(.small)
                }
                HStack(spacing: 8) {
                    let items = Needs.list(p)
                    ForEach(0..<items.count, id: \.self) { i in NeedRing(icon: items[i].0, value: items[i].1, size: 34) }
                }
                // 할 일: 밥·물은 바로, 나머지는 필요할 때만 메인 창을 띄움
                HStack(spacing: 10) {
                    CardButton(icon: "fork.knife", title: "밥") { s.feed() }
                    CardButton(icon: "drop.fill", title: "물") { s.giveWater() }
                    CardButton(icon: "archivebox.fill", title: "보관함") { AppModel.shared.showMain(tab: 2) }
                    CardButton(icon: "cart.fill", title: "상점") { AppModel.shared.showMain(tab: 1) }
                    CardButton(icon: "house.fill", title: "쉬기") { AppModel.shared.rest() }
                }
            }
            if let t = s.toastText { Text(t).font(.callout) }
            if s.loading { Button { AppModel.shared.rest() } label: { Label("쉬기", systemImage: "house.fill") }.controlSize(.small) }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassBackgroundEffect()
        .opacity(s.cardOn || s.toastText != nil ? 1 : 0)
    }
}
