import SwiftUI
import UserNotifications
import BackgroundTasks

/// 어나더 팸 아이폰 짝 앱: 비전 프로의 강아지 소식을 보고, 배고픔·목마름·심심함 등을 알림으로 받음.
/// 비전 앱이 아이클라우드(키-값)에 올린 상태를 읽어, 앱을 안 켠 동안의 시간 흐름(Sim.swift 의 catchUp — 비전 앱과 같은 코드)으로
/// '언제 그렇게 될지'를 미리 계산해 그 시각에 로컬 알림을 예약함. 서버 없음
@main
struct FamPhoneApp: App {
    @Environment(\.scenePhase) private var phase
    @UIApplicationDelegateAdaptor(PhoneDelegate.self) private var delegate

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

/// 클라우드킷 조용한 푸시: 비전 앱이 상태를 올리면 iOS 가 이 앱을 백그라운드에서 깨움 → 새 상태로 알림을 다시 맞춤 (0.8.0)
final class PhoneDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        Task { await CloudSync.subscribe() }
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let d = await CloudSync.pull() else { return .failed }
        await MainActor.run { PhoneModel.cloudData = d }
        await PhoneModel.shared.update()
        return .newData
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
    /// 클라우드킷으로 받은 마지막 상태 (키-값 저장소보다 먼저 도착할 수 있음 — 둘 중 더 새것을 씀)
    static var cloudData: Foundation.Data? {
        get { UserDefaults.standard.data(forKey: "af.ckpet") }
        set { UserDefaults.standard.set(newValue, forKey: "af.ckpet") }
    }

    var pet: PetState?                  // 지금 시각까지 따라잡은 상태
    var seenAt: Double = 0              // 비전 앱이 마지막으로 저장한 때
    var upcoming: [PlannedAlert] = []
    var allowed: Bool?
    var night: Bool = UserDefaults.standard.bool(forKey: "af.night") {
        didSet { UserDefaults.standard.set(night, forKey: "af.night"); refresh() }
    }
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// 지금 하고 있는 일 (비전 앱이 켜져 있지 않은 동안은 흘러간 시간으로 미루어 봄)
    var doing: Doing {
        guard let p = pet else { return .calm }
        if Date().timeIntervalSince1970 - seenAt < 45 { return .together }
        if p.asleep { return .sleeping }
        let grown = p.age() >= 21
        if p.food < 0.25 { return .hungry }
        if grown && p.water < 0.25 { return .thirsty }
        if p.potty < 0.2 { return .potty }
        if p.love < 0.25 { return .lonely }
        if grown && p.fun < 0.25 { return .bored }
        return p.mood > 0.7 ? .happy : .calm
    }

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
        if let d = await CloudSync.pull() { PhoneModel.cloudData = d }      // 켤 때·깨어날 때 클라우드킷에서도 한 번
        let kv = CloudPet.pull()
        let ck = PhoneModel.cloudData.flatMap { try? JSONDecoder().decode(PetState.self, from: $0) }
        let fresh = [kv, ck].compactMap { $0 }.max { $0.lastSim < $1.lastSim }
        guard let saved = fresh else {
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
        // 같은 상황도 그때그때 다르게 (늘 같은 문장이면 정해진 대로 울리는 기계처럼 느껴짐)
        let say: [String]
        switch k {
        case "food": say = baby ? ["젖을 찾아요", "낑낑대며 젖을 찾고 있어요", "배가 고픈지 꼬물거려요"]
                                : ["배고파해요", "밥그릇 앞을 서성이고 있어요", "밥 달라고 기다리고 있어요"]
        case "water": say = ["목말라해요", "빈 물그릇을 핥고 있어요", "물을 찾고 있어요"]
        case "fun": say = ["심심해해요", "놀자고 엉덩이를 들고 있어요", "혼자 장난감을 굴리다 멈췄어요"]
        case "love": say = ["보고 싶어 해요", "문 쪽을 바라보며 기다려요", "작게 낑낑대며 기다리고 있어요"]
        case "mess": say = ["실수를 했어요. 치워 주세요", "바닥에 실수를 했어요"]
        default: say = ["기운이 없어 보여요", "축 처져 있어요"]
        }
        return "\(n) " + (say.randomElement() ?? say[0])
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
        for (k, t0) in at {
            // 그때의 기분·몸 상태에 따라 조금 이르거나 늦게 (지금 이미 그런 것은 그대로)
            let t = t0 > now + 60 ? max(now + 120, t0 + Double.random(in: -900...900)) : t0
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

enum Doing: Equatable {
    case together, sleeping, hungry, thirsty, potty, lonely, bored, happy, calm

    func text(baby: Bool) -> String {
        switch self {
        case .together: return "지금 함께 있어요"
        case .sleeping: return "자는 중"
        case .hungry: return baby ? "젖을 찾아요" : "배고파해요"
        case .thirsty: return "목말라해요"
        case .potty: return "화장실이 급해요"
        case .lonely: return "보고 싶어 해요"
        case .bored: return "심심해해요"
        case .happy: return "기분이 좋아요"
        case .calm: return "편히 쉬고 있어요"
        }
    }

    var icon: String {
        switch self {
        case .together: return "visionpro"
        case .sleeping: return "zzz"
        case .hungry: return "fork.knife"
        case .thirsty: return "drop.fill"
        case .potty: return "toilet.fill"
        case .lonely: return "heart.fill"
        case .bored: return "tennisball.fill"
        case .happy: return "face.smiling"
        case .calm: return "leaf.fill"
        }
    }
}
