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
            if let m = attachments.entity(for: "menu") { s.attachMenu(m) }
            if let t = attachments.entity(for: "toast") { s.attachToast(t) }
            s.updateSub = content.subscribe(to: SceneEvents.Update.self) { e in s.tick(Float(e.deltaTime)) }
        } attachments: {
            Attachment(id: "card") { StatusCard(s: s) }
            Attachment(id: "menu") { MenuPanel(s: s) }
            Attachment(id: "toast") { ToastView(s: s) }
        }
        // 강아지를 바라보고 집으면 상태 카드
        // 탭 자리를 함께 넘김: 손가락이 직접 닿은 탭(쓰다듬기)만 거르고, 바라보고 집은 탭은 가까이 있어도 받음 (0.10.0)
        .gesture(SpatialTapGesture().targetedToEntity(where: .has(DogTag.self)).onEnded { v in s.tapDog(at: v.convert(v.location3D, from: .local, to: .scene)) })
        // 그릇·패드·치울 것: 바라보고 집으면 쓸 도구를 꺼내 주거나 하는 법을 알려 줌
        .simultaneousGesture(SpatialTapGesture().targetedToEntity(where: .has(PropTag.self)).onEnded { v in s.tapProp(v.entity, at: v.convert(v.location3D, from: .local, to: .scene)) })
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

/// 욕구 하나 (아이콘 + 채움 고리 + 이름).
/// 고리가 찬 만큼 넉넉함 — 초록 넉넉 / 주황 곧 필요 / 빨강 지금 필요. 빨강이면 고리 바탕도 붉게(0 이어도 비어 보이지 않게)
struct NeedRing: View {
    let label: String
    let icon: String
    let value: Float
    var size: CGFloat = 40
    var tappable = false

    var body: some View {
        let v = CGFloat(min(1, max(0, value)))
        let col: Color = value < 0.25 ? .red : (value < 0.5 ? .orange : .green)
        VStack(spacing: size * 0.1) {
            ZStack {
                Circle().stroke(value < 0.25 ? Color.red.opacity(0.35) : .white.opacity(0.15), lineWidth: size * 0.1)
                Circle().trim(from: 0, to: v).stroke(col, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: icon).font(.system(size: size * 0.38)).foregroundStyle(value < 0.25 ? Color.red : .primary)
            }
            .frame(width: size, height: size)
            .padding(tappable ? size * 0.08 : 0)
            // 바라보면 고리가 15% 커지고 둥글게 밝아짐 (0.10.13: 밝아지기만 해서 어느 고리를 보고 있는지 알 수 없었음)
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.highlight, isEnabled: tappable)
            .hoverEffect(isEnabled: tappable) { e, on, _ in e.scaleEffect(on ? 1.15 : 1) }
            Text(label).font(.system(size: max(11, size * 0.26), weight: .medium)).foregroundStyle(value < 0.25 ? Color.red : .secondary)
        }
    }
}

enum Needs {
    /// (이름, 아이콘, 값) — 젖먹이(3주 전)는 물·놀이가 없음
    static func list(_ p: PetState) -> [(String, String, Float)] {
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
}

struct CardButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.callout.weight(.medium))
            }
            .frame(width: 84, height: 66)
        }
        .buttonBorderShape(.roundedRectangle(radius: 18))
    }
}

/// 강아지를 바라보고 집으면 뜨는 작은 카드: 지금 상태 + 메뉴에 없는 바로 할 일(밥·물) + 메뉴 열기.
/// 보관함·상점·쉬기·설정은 모두 메인 메뉴 한 곳에 (0.5.x: 카드에 기능을 몰아넣고 공간 안 메뉴판까지 만들어 같은 메뉴가 셋이 됐음)
struct StatusCard: View {
    let s: PlaySession

    var body: some View {
        let p = s.shown
        VStack(spacing: 16) {
            if s.cardOn {
                HStack(spacing: 10) {
                    Text(p.name).font(.title2.weight(.bold))
                    Text(PetState.ageText(p.age())).font(.title3).foregroundStyle(.secondary)
                    if p.asleep { Image(systemName: "zzz").foregroundStyle(.secondary) }
                    Spacer(minLength: 12)
                    Button { s.closeCard() } label: { Image(systemName: "xmark") }.buttonBorderShape(.circle)
                }
                HStack(spacing: 14) {
                    let items = Needs.list(p)
                    ForEach(0..<items.count, id: \.self) { i in
                        // 고리를 보고 집으면 그 욕구의 지금과 앞으로 (아이폰·메인 메뉴와 같은 글)
                        Button { s.showRing(NeedInfo.key(items[i].0)) } label: { NeedRing(label: items[i].0, icon: items[i].1, value: items[i].2, size: 46, tappable: true) }
                            .buttonStyle(RingPress())
                    }
                }
                if let t = s.ringInfo { Text(t).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 560) }
                HStack(spacing: 12) {
                    CardButton(icon: "fork.knife", title: "밥") { s.feed() }
                    if p.age() >= 21 { CardButton(icon: "drop.fill", title: "물") { s.giveWater() } }
                    CardButton(icon: "square.grid.2x2.fill", title: "메뉴") { AppModel.shared.showMain(tab: AppModel.shared.tab) }
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 24).padding(.vertical, 20)
        .glassBackgroundEffect()
        .opacity(s.cardOn ? 1 : 0)
    }
}

/// 안내 (0.10.15): 카드와 따로, 보는 쪽 정면 조금 아래에 뜸 (PlaySession.showToast)
struct ToastView: View {
    let s: PlaySession

    var body: some View {
        VStack(spacing: 14) {
            if let t = s.toastText { Text(t).font(.title3.weight(.medium)).multilineTextAlignment(.center).frame(maxWidth: 620) }
            if s.loading {
                HStack(spacing: 12) {
                    if s.canRehome { Button { s.rehome() } label: { Label("여기에 새로 자리 잡기", systemImage: "mappin.and.ellipse") } }
                    Button { AppModel.shared.rest() } label: { Label("쉬기", systemImage: "house.fill") }
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 26).padding(.vertical, 16)
        .glassBackgroundEffect()
        .opacity(s.toastText != nil || (s.loading && s.canRehome) ? 1 : 0)
    }
}
