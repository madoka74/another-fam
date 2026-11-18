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
    var at: Double
    let text: String
    var n = 0
    var id: String { "\(kind)\(at)" }
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

    /// 비전에서 함께하는 중인지: 비전 앱이 올린 '함께 있음' 표시 + 그 소식이 너무 오래되지 않았을 때 (20분마다 다시 옴)
    var together: Bool {
        guard let p = pet else { return false }
        return p.together && Date().timeIntervalSince1970 - seenAt < 30 * 60
    }
    /// 화면을 새로 그리게 하는 시계 (열어 둔 동안 15초마다)
    var clock: Double = Date().timeIntervalSince1970

    /// 지금 하고 있는 일 (비전 앱이 켜져 있지 않은 동안은 흘러간 시간으로 미루어 봄)
    var doing: Doing {
        _ = clock
        guard let p = pet else { return .calm }
        if together { return .together }
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
        Forecast.noteDelivered()
        center.removeAllPendingNotificationRequests()
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
        if saved.together { now.together = true }
        pet = now
        clock = Date().timeIntervalSince1970
        // 비전에서 함께하는 동안은 폰 알림을 울리지 않음 (알릴 일은 비전 안에서). 비전 소식이 끊겨도 2시간 뒤부터는 다시 알림
        // 방금 비전에서 나왔으면 30분은 쉬었다가 (나오자마자 폰이 울리지 않게)
        let quiet = saved.together ? saved.lastSim + 2 * 3600 : (Date().timeIntervalSince1970 - saved.lastSim < 1800 ? saved.lastSim + 1800 : 0)
        let plan = Forecast.plan(from: now, night: night, quietUntil: quiet)
        upcoming = plan
        guard allowed == true else { return }
        let t0 = Date().timeIntervalSince1970
        for (i, a) in plan.enumerated() {
            let c = UNMutableNotificationContent()
            c.title = saved.name
            c.body = a.text
            c.sound = .default
            c.threadIdentifier = "pet"
            let trig = UNTimeIntervalNotificationTrigger(timeInterval: max(5, a.at - t0), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "af.\(a.kind).\(i)", content: c, trigger: trig))
        }
        Forecast.remember(plan)
    }
}

/// 알림 계획: 앞으로 하루(30시간)를 10분씩 흘려 보며, 무슨 일이 언제 생기고 그대로 두면 얼마나 이어지는지 미리 셈.
/// 처음 그렇게 될 때 알리고, 그대로 두면 몇 시간마다 다시(점점 간절하게) 알림 — 0.9 까지는 종류마다 처음 한 번만 울려,
/// 새벽에 밥을 준 뒤 오후까지 알림이 하나뿐이었음. 비전 앱이 새 상태를 올릴 때마다 처음부터 다시 셈
enum Forecast {
    static let kinds = ["food", "water", "fun", "love", "mess", "potty", "health"]
    /// 다시 알리는 간격 (시간)
    private static let again: [String: Double] = ["food": 3, "water": 3, "fun": 4, "love": 4, "mess": 3, "potty": 5, "health": 6]
    private static let maxAgain = 3

    private static func bad(_ k: String, _ p: PetState) -> Bool {
        let st = Stage.of(p.age())
        let grown = st.rawValue >= Stage.social.rawValue
        switch k {
        case "food": return p.food < 0.25
        case "water": return grown && p.water < 0.25
        case "fun": return grown && !p.asleep && p.fun < 0.2
        case "love": return !p.asleep && p.love < 0.2
        case "mess": return p.poops > 0
        case "potty": return p.placed.contains("pad") && p.padUses == 0
        default: return p.health < 0.5
        }
    }

    private static func text(_ k: String, _ p: PetState, _ n: Int) -> String {
        let nm = p.name + josa(p.name)
        let baby = Stage.of(p.age()).rawValue < Stage.social.rawValue
        // 같은 상황도 그때그때 다르게, 다시 알릴수록 더 간절하게
        let say: [String]
        switch k {
        case "food":
            say = baby ? (n == 0 ? ["젖을 찾아요", "낑낑대며 젖을 찾고 있어요", "배가 고픈지 꼬물거려요"] : ["아직도 젖을 찾아요", "배고파서 크게 울어요"])
                       : (n == 0 ? ["배고파해요", "밥그릇 앞을 서성이고 있어요", "빈 밥그릇을 코로 밀고 있어요"]
                                 : ["아직 배고파해요", "빈 밥그릇 옆에서 기다리고 있어요", "배고파서 낑낑대요"])
        case "water": say = n == 0 ? ["목말라해요", "빈 물그릇을 핥고 있어요", "물을 찾고 있어요"] : ["아직 목말라해요", "물그릇 앞에서 기다려요"]
        case "fun": say = n == 0 ? ["심심해해요", "놀자고 엉덩이를 들고 있어요", "혼자 장난감을 굴리다 멈췄어요"] : ["많이 심심해해요", "장난감을 물고 문 앞에서 기다려요"]
        case "love": say = n == 0 ? ["보고 싶어 해요", "문 쪽을 바라보며 기다려요", "작게 낑낑대며 기다리고 있어요"] : ["아직 기다리고 있어요", "많이 보고 싶어 해요"]
        case "mess": say = n == 0 ? ["실수를 했어요. 치워 주세요", "바닥에 실수를 했어요"] : ["치울 것이 남아 있어요"]
        case "potty": say = ["패드가 가득 찼어요. 갈아 주세요"]
        default: say = n == 0 ? ["기운이 없어 보여요", "축 처져 있어요"] : ["아직 기운이 없어요"]
        }
        return "\(nm) " + (say.randomElement() ?? say[0])
    }

    /// 이름 끝 글자에 받침이 있으면 '이가'(깨몽이가), 없으면 '가'(몽이가) — 받침 있는 이름은 부를 때 '이'를 붙임
    static func josa(_ name: String) -> String {
        guard let c = name.unicodeScalars.last, c.value >= 0xAC00, c.value <= 0xD7A3 else { return "가" }
        return (c.value - 0xAC00) % 28 == 0 ? "가" : "이가"
    }

    /// 이미 울린 알림 (종류 → 마지막으로 울린 때·몇 번째) — 계획을 다시 세워도 방금 울린 것을 또 울리지 않게
    private static var sent: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: "af.sent") as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "af.sent") }
    }

    /// 지난번 계획 중 이미 지난 것 = 울린 것으로 기록
    static func noteDelivered() {
        let now = Date().timeIntervalSince1970
        guard let list = UserDefaults.standard.array(forKey: "af.plan") as? [[String: Any]] else { return }
        var s = sent
        for e in list {
            guard let k = e["k"] as? String, let at = e["t"] as? Double, let n = e["n"] as? Double, at <= now else { continue }
            if (s[k]?[0] ?? 0) < at { s[k] = [at, n] }
        }
        sent = s
    }

    static func remember(_ plan: [PlannedAlert]) {
        UserDefaults.standard.set(plan.map { ["k": $0.kind, "t": $0.at, "n": Double($0.n)] as [String: Any] }, forKey: "af.plan")
    }

    static func plan(from cur: PetState, night: Bool, quietUntil: Double) -> [PlannedAlert] {
        let now = Date().timeIntervalSince1970
        let prev = sent
        var out: [PlannedAlert] = []
        var state: [String: (on: Bool, last: Double, n: Int)] = [:]
        for k in kinds {
            // 지금 이미 그런데 조금 전에 알렸으면 그 다음 차례부터
            if bad(k, cur), let s = prev[k], s.count == 2, now - s[0] < (again[k] ?? 3) * 3600 {
                state[k] = (true, s[0], Int(s[1]) + 1)
            } else { state[k] = (false, 0, 0) }
        }
        var p = cur
        var t = now
        var poops = cur.poops
        let end = now + 30 * 3600
        while t < end {
            let isNow = t == now
            for k in kinds {
                guard var st = state[k] else { continue }
                var isBad = bad(k, p)
                if k == "mess" { isBad = p.poops > poops || (isNow && p.poops > 0) }
                if !isBad && k != "mess" { st.on = false; st.n = 0; state[k] = st; continue }
                if !isBad { continue }
                let gap = (again[k] ?? 3) * 3600
                if !st.on || (st.n <= maxAgain && t - st.last >= gap) {
                    if st.on && st.n > maxAgain { continue }
                    let n = st.on ? st.n : 0
                    var at = isNow ? now + 5 : t + Double.random(in: -600...600)
                    at = max(at, now + 5, quietUntil)
                    if !night { at = daytime(at) }
                    out.append(PlannedAlert(kind: k, at: at, text: text(k, p, n), n: n))
                    st = (true, t, n + 1)
                    state[k] = st
                }
            }
            poops = p.poops
            t += 600
            p.catchUp(t)
        }
        // 같은 때 몰리지 않게 (20분 간격) + 밤에 미뤄진 같은 종류는 하나만 + iOS 예약 한도(64) 안
        out.sort { $0.at < $1.at }
        var res: [PlannedAlert] = []
        var lastAt = -1e9
        var seen = Set<String>()
        for var a in out {
            let key = "\(a.kind)@\(Int(a.at / 1800))"
            if seen.contains(key) { continue }
            seen.insert(key)
            if a.at - lastAt < 20 * 60 { a.at = lastAt + 20 * 60 }
            lastAt = a.at
            res.append(a)
            if res.count >= 48 { break }
        }
        return res
    }

    /// 밤 23시~7시면 아침 7시로 미룸
    private static func daytime(_ t: Double) -> Double {
        let cal = Calendar.current
        let d = Date(timeIntervalSince1970: t)
        let h = cal.component(.hour, from: d)
        guard h >= 23 || h < 7 else { return t }
        var day = cal.startOfDay(for: d)
        if h >= 23 { day = cal.date(byAdding: .day, value: 1, to: day) ?? day }
        return (cal.date(bySettingHour: 7, minute: Int.random(in: 0...20), second: 0, of: day) ?? d).timeIntervalSince1970
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
