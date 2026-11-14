import SwiftUI
import UserNotifications
import BackgroundTasks

/// 어나더 팸 아이폰 짝 앱: 비전 프로의 강아지 소식을 보고, 배고픔·목마름·심심함 등을 알림으로 받음.
/// 비전 앱이 아이클라우드(키-값)에 올린 상태를 읽어, 앱을 안 켠 동안의 시간 흐름(Sim.swift 의 catchUp — 비전 앱과 같은 코드)으로
/// '언제 그렇게 될지'를 미리 계산해 그 시각에 로컬 알림을 예약함. 서버 없음
@main
struct FamPhoneApp: App {
    @Environment(\.scenePhase) private var phase

    var body: some SwiftUI.Scene {
        WindowGroup {
            PhoneView()
        }
        .onChange(of: phase) { _, p in
            if p == .active { PhoneModel.shared.refresh() }
            if p == .background { PhoneModel.scheduleRefresh() }
        }
        // 가끔 백그라운드에서 깨어나 새 소식으로 알림을 다시 맞춤 (언제 깨울지는 iOS 가 정함)
        .backgroundTask(.appRefresh(PhoneModel.refreshID)) {
            await PhoneModel.backgroundRefresh()
        }
    }
}

struct PlannedAlert: Identifiable {
    let kind: String
    let at: Double
    let text: String
    var id: String { kind }
}

@MainActor @Observable
final class PhoneModel {
    static let shared = PhoneModel()
    static let refreshID = "com.blankishworks.another-fam.refresh"

    var pet: PetState?                  // 지금 시각까지 따라잡은 상태
    var seenAt: Double = 0              // 비전 앱이 마지막으로 저장한 때
    var upcoming: [PlannedAlert] = []
    var allowed: Bool?
    var night: Bool = UserDefaults.standard.bool(forKey: "af.night") {
        didSet { UserDefaults.standard.set(night, forKey: "af.night"); refresh() }
    }
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                          object: NSUbiquitousKeyValueStore.default, queue: .main) { _ in
            Task { @MainActor in PhoneModel.shared.refresh() }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    func refresh() {
        Task { await update() }
    }

    func askPermission() {
        Task {
            let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            allowed = ok
            if !ok, let url = URL(string: UIApplication.openSettingsURLString) { _ = await UIApplication.shared.open(url) }
            await update()
        }
    }

    static func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: refreshID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(r)
    }

    static func backgroundRefresh() async {
        scheduleRefresh()
        await shared.update()
    }

    func update() async {
        NSUbiquitousKeyValueStore.default.synchronize()
        let center = UNUserNotificationCenter.current()
        var st = await center.notificationSettings()
        if st.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            st = await center.notificationSettings()
        }
        allowed = st.authorizationStatus == .authorized || st.authorizationStatus == .provisional
        center.removePendingNotificationRequests(withIdentifiers: Forecast.kinds.map { "af." + $0 })
        guard let saved = CloudPet.pull() else {
            pet = nil
            upcoming = []
            return
        }
        seenAt = saved.lastSim
        var now = saved
        now.catchUp()
        pet = now
        let plan = Forecast.plan(from: now, key: seenAt, night: night)
        upcoming = plan
        guard allowed == true else { return }
        var sched: [String: [Double]] = [:]
        let t0 = Date().timeIntervalSince1970
        for a in plan {
            let c = UNMutableNotificationContent()
            c.title = saved.name
            c.body = a.text
            c.sound = .default
            c.threadIdentifier = "pet"
            let trig = UNTimeIntervalNotificationTrigger(timeInterval: max(5, a.at - t0), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "af." + a.kind, content: c, trigger: trig))
            sched[a.kind] = [seenAt, a.at]
        }
        Forecast.remember(sched)
    }
}

/// 앞으로 48시간을 10분씩 흘려 보며 처음 그렇게 되는 때를 찾음
enum Forecast {
    static let kinds = ["food", "water", "fun", "love", "mess", "health"]

    private static func bad(_ k: String, _ p: PetState, poops0: Int) -> Bool {
        let st = Stage.of(p.age())
        let grown = st.rawValue >= Stage.social.rawValue
        switch k {
        case "food": return p.food < 0.25
        case "water": return grown && p.water < 0.25
        case "fun": return grown && !p.asleep && p.fun < 0.2
        case "love": return !p.asleep && p.love < 0.2
        case "mess": return p.poops > poops0
        default: return p.health < 0.5
        }
    }

    private static func text(_ k: String, _ p: PetState) -> String {
        let n = p.name + josa(p.name)
        let baby = Stage.of(p.age()).rawValue < Stage.social.rawValue
        switch k {
        case "food": return baby ? "\(n) 젖을 찾아요" : "\(n) 배고파해요"
        case "water": return "\(n) 목말라해요"
        case "fun": return "\(n) 심심해해요. 놀아 주세요"
        case "love": return "\(n) 보고 싶어 해요"
        case "mess": return "\(n) 실수를 했어요. 치워 주세요"
        default: return "\(n) 기운이 없어 보여요"
        }
    }

    /// 이름 끝 글자에 받침이 있으면 '이가'(깨몽이가), 없으면 '가'(몽이가) — 받침 있는 이름은 부를 때 '이'를 붙임
    static func josa(_ name: String) -> String {
        guard let c = name.unicodeScalars.last, c.value >= 0xAC00, c.value <= 0xD7A3 else { return "가" }
        return (c.value - 0xAC00) % 28 == 0 ? "가" : "이가"
    }

    static func plan(from cur: PetState, key: Double, night: Bool) -> [PlannedAlert] {
        let now = Date().timeIntervalSince1970
        let prev = UserDefaults.standard.dictionary(forKey: "af.sched") as? [String: [Double]] ?? [:]
        var at: [String: Double] = [:]
        var label: [String: String] = [:]
        // 지금 이미 그런 것: 같은 소식(비전 앱의 같은 저장)으로 이미 알렸으면 다시 안 함
        for k in kinds where bad(k, cur, poops0: cur.poops) || (k == "mess" && cur.poops > 0) {
            if let s = prev[k], s.count == 2, s[0] == key, s[1] <= now { continue }
            at[k] = now + 5
            label[k] = text(k, cur)
        }
        let already = Set(kinds.filter { bad($0, cur, poops0: cur.poops) || ($0 == "mess" && cur.poops > 0) })
        var p = cur
        var t = now
        var poops = cur.poops
        while t < now + 48 * 3600 {
            t += 600
            p.catchUp(t)
            for k in kinds where at[k] == nil && !already.contains(k) && bad(k, p, poops0: poops) {
                at[k] = t
                label[k] = text(k, p)
            }
            poops = p.poops
            if at.count + already.subtracting(at.keys).count >= kinds.count { break }
        }
        var out: [PlannedAlert] = []
        for (k, t) in at {
            out.append(PlannedAlert(kind: k, at: night ? t : daytime(t), text: label[k] ?? ""))
        }
        return out.sorted { $0.at < $1.at }
    }

    /// 밤 23시~7시면 아침 7시로 미룸
    private static func daytime(_ t: Double) -> Double {
        let cal = Calendar.current
        let d = Date(timeIntervalSince1970: t)
        let h = cal.component(.hour, from: d)
        guard h >= 23 || h < 7 else { return t }
        var day = cal.startOfDay(for: d)
        if h >= 23 { day = cal.date(byAdding: .day, value: 1, to: day) ?? day }
        return (cal.date(bySettingHour: 7, minute: 0, second: 0, of: day) ?? d).timeIntervalSince1970
    }

    static func remember(_ s: [String: [Double]]) {
        var all = UserDefaults.standard.dictionary(forKey: "af.sched") as? [String: [Double]] ?? [:]
        for (k, v) in s { all[k] = v }
        UserDefaults.standard.set(all, forKey: "af.sched")
    }
}

// MARK: - 화면
struct PhoneView: View {
    private var m: PhoneModel { PhoneModel.shared }

    var body: some View {
        NavigationStack {
            List {
                if let p = m.pet {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p.name).font(.largeTitle.bold())
                            HStack(spacing: 8) {
                                Text(PetState.ageText(p.age()))
                                Text(p.stage.title).padding(.horizontal, 8).padding(.vertical, 2).background(.quaternary, in: Capsule())
                                if p.asleep { Label("자는 중", systemImage: "zzz") }
                            }
                            .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        let items = needs(p)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                            ForEach(0..<items.count, id: \.self) { i in
                                VStack(spacing: 4) {
                                    Ring(icon: items[i].1, value: items[i].2)
                                    Text(items[i].0).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        LabeledContent("비전 프로 소식", value: ago(m.seenAt))
                    }
                    Section("다음 알림") {
                        if m.allowed == false {
                            Button("알림 허용하기") { m.askPermission() }
                        }
                        if m.upcoming.isEmpty {
                            Text("당분간 없어요").foregroundStyle(.secondary)
                        }
                        ForEach(m.upcoming) { a in
                            LabeledContent(a.text, value: when(a.at))
                        }
                        Toggle("밤(23~7시)에도 알림", isOn: Binding(get: { m.night }, set: { m.night = $0 }))
                    }
                } else {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "dog.fill").font(.system(size: 48)).foregroundStyle(.secondary)
                            Text("비전 프로에서 가족을 맞이하면\n여기서 소식을 받아요").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                }
                Section {
                    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    LabeledContent("버전", value: "\(v) (\(b))")
                }
            }
            .navigationTitle("어나더 팸")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await m.update() }
        }
        .task { await m.update() }
    }

    private func needs(_ p: PetState) -> [(String, String, Float)] {
        var out: [(String, String, Float)] = [("밥", "fork.knife", p.food)]
        if p.age() >= 21 { out.append(("물", "drop.fill", p.water)) }
        out.append(("잠", "moon.zzz.fill", p.energy))
        out.append(("배변", "toilet.fill", p.potty))
        if p.age() >= 21 { out.append(("놀이", "tennisball.fill", p.fun)) }
        out.append(("사랑", "heart.fill", p.love))
        out.append(("청결", "sparkles", p.clean))
        out.append(("건강", "cross.case.fill", p.health))
        return out
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
            Circle().stroke(.quaternary, lineWidth: 5)
            Circle().trim(from: 0, to: v).stroke(col, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
            Image(systemName: icon).font(.system(size: 17))
        }
        .frame(width: 50, height: 50)
    }
}
