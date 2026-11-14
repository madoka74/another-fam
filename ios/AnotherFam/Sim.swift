import Foundation

/// 시간·나이·욕구·포인트 (화면·공간과 상관없는 계산만)
/// - 하루는 현실과 같은 24시간 (밥·물·잠·배변·놀이는 현실 시간으로 흐름)
/// - 나이는 현실 하루에 26일씩 먹음: 13년(4,745일) ÷ 26 = 182.5일 ≈ 6달. 13살이 되면 그 모습 그대로 머묾
enum Sim {
    static let ageRate: Double = 26
    static let maxAge: Double = 4745
    static let startPoints = 1500
    /// 포인트: 쓴 시간 6초에 1 (1분 10P, 15분 150P = 성견 이틀치 밥)
    static let secPerPoint: Double = 6
}

enum Stage: Int, CaseIterable {
    case neonatal, transitional, social, juvenile, adolescent, adult, mature, senior

    static func of(_ age: Double) -> Stage {
        if age < 14 { return .neonatal }
        if age < 21 { return .transitional }
        if age < 56 { return .social }
        if age < 180 { return .juvenile }
        if age < 365 { return .adolescent }
        if age < 2555 { return .adult }
        if age < 3650 { return .mature }
        return .senior
    }

    var title: String {
        switch self {
        case .neonatal: return "신생아기"
        case .transitional: return "눈 뜨는 시기"
        case .social: return "아기 강아지"
        case .juvenile: return "어린 강아지"
        case .adolescent: return "청소년기"
        case .adult: return "성견"
        case .mature: return "중년"
        case .senior: return "노견"
        }
    }

    /// 하루 중 자는 비율 (갓난 강아지는 거의 하루 종일)
    var sleepShare: Float {
        switch self {
        case .neonatal: return 0.9
        case .transitional: return 0.85
        case .social: return 0.75
        case .juvenile: return 0.65
        case .adolescent: return 0.55
        case .adult: return 0.5
        case .mature: return 0.58
        case .senior: return 0.68
        }
    }

    /// 시간당 줄어드는 양 (밥, 물, 배변 참기, 놀이, 사랑)
    var decay: (food: Float, water: Float, potty: Float, fun: Float, love: Float) {
        switch self {
        case .neonatal: return (0.30, 0, 0.5, 0, 0.10)                 // 2~3시간마다 젖, 물은 안 마심
        case .transitional: return (0.25, 0, 0.45, 0.02, 0.10)
        case .social: return (0.16, 0.10, 0.40, 0.10, 0.09)            // 하루 4끼
        case .juvenile: return (0.12, 0.12, 0.30, 0.14, 0.08)          // 하루 3~4끼
        case .adolescent: return (0.085, 0.12, 0.22, 0.13, 0.07)
        case .adult: return (0.0625, 0.11, 0.17, 0.09, 0.06)           // 하루 2끼
        case .mature: return (0.0625, 0.11, 0.19, 0.07, 0.06)
        case .senior: return (0.0625, 0.10, 0.24, 0.05, 0.06)
        }
    }

    /// 한 끼에 차는 양
    var meal: Float {
        switch self {
        case .neonatal, .transitional: return 0.7
        case .social: return 0.6
        case .juvenile: return 0.5
        default: return 0.75
        }
    }
}

struct PetState: Codable, Equatable {
    var species = "maltese"
    var name = "몽이"
    var male = false
    var born: Double = Date().timeIntervalSince1970
    // 욕구 (1 = 충분, 0 = 바닥)
    var food: Float = 0.6, water: Float = 0.8, energy: Float = 0.7, potty: Float = 0.8, fun: Float = 0.6, love: Float = 0.7, clean: Float = 1
    var health: Float = 1, bond: Float = 0.1, train: Float = 0
    var tricks: [String: Float] = [:]
    var words: [String: [String: Float]] = [:]                          // 들은 낱말 → 재주 → 익힘 (0~1). 사람마다 다른 말도 각각 배움
    var lastSim: Double = Date().timeIntervalSince1970
    var points = Sim.startPoints
    var pointFrac: Double = 0
    var usedSec: Double = 0
    var inv: [String: Int] = ["bowl_water": 1, "blanket": 1]         // 입양 키트
    var placed: [String] = []                                        // 공간에 꺼내 둔 것
    var layout: [String: [Float]] = [:]                              // 꺼내 둔 자리 (집 기준 x, y, z, 방향)
    var foodBowl: Float = 0, waterBowl: Float = 0
    var foodKind = ""
    var poops = 0
    var padUses = 0
    var vaccines = 0
    var checkupAge: Double = -1
    var jointUntil: Double = 0
    var asleep = false
    var walkM: Float = 0                                             // 오늘 산책한 거리
    var walkDay = ""
    var meals = 0
    var bottle: Float = 0                                            // 젖병에 타 둔 분유 (1회분 = 1)

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func g<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        let z = PetState()
        species = g(.species, z.species); name = g(.name, z.name); male = g(.male, z.male); born = g(.born, z.born)
        food = g(.food, z.food); water = g(.water, z.water); energy = g(.energy, z.energy); potty = g(.potty, z.potty)
        fun = g(.fun, z.fun); love = g(.love, z.love); clean = g(.clean, z.clean)
        health = g(.health, z.health); bond = g(.bond, z.bond); train = g(.train, z.train); tricks = g(.tricks, z.tricks); words = g(.words, z.words)
        lastSim = g(.lastSim, z.lastSim); points = g(.points, z.points); pointFrac = g(.pointFrac, z.pointFrac); usedSec = g(.usedSec, z.usedSec)
        inv = g(.inv, z.inv); placed = g(.placed, z.placed); layout = g(.layout, z.layout)
        foodBowl = g(.foodBowl, z.foodBowl); waterBowl = g(.waterBowl, z.waterBowl); foodKind = g(.foodKind, z.foodKind)
        poops = g(.poops, z.poops); padUses = g(.padUses, z.padUses); vaccines = g(.vaccines, z.vaccines)
        checkupAge = g(.checkupAge, z.checkupAge); jointUntil = g(.jointUntil, z.jointUntil); asleep = g(.asleep, z.asleep)
        walkM = g(.walkM, z.walkM); walkDay = g(.walkDay, z.walkDay); meals = g(.meals, z.meals)
        bottle = g(.bottle, z.bottle)
    }

    // MARK: 나이
    func age(_ now: Double = Date().timeIntervalSince1970) -> Double {
        min(Sim.maxAge, max(0, (now - born) / 86400 * Sim.ageRate))
    }
    var stage: Stage { Stage.of(age()) }

    static func ageText(_ a: Double) -> String {
        if a < 14 { return "생후 \(Int(a))일" }
        if a < 84 { return "생후 \(Int(a / 7))주" }
        if a < 365 { return "\(Int(a / 30.4))개월" }
        let y = Int(a / 365), m = Int((a - Double(y) * 365) / 30.4)
        return m > 0 ? "\(y)살 \(m)개월" : "\(y)살"
    }

    func has(_ id: String) -> Bool { (inv[id] ?? 0) > 0 }
    func count(_ id: String) -> Int { inv[id] ?? 0 }
    mutating func use(_ id: String, _ n: Int = 1) -> Bool {
        guard count(id) >= n else { return false }
        inv[id] = count(id) - n
        return true
    }

    private static func clamp(_ v: Float) -> Float { min(1, max(0, v)) }

    /// 지금이 잘 시간인지 (현실 시각 + 나이). 밤 23~7시는 누구나 자고, 낮잠은 나이에 따라
    static func sleepy(hour: Double, stage: Stage, energy: Float) -> Bool {
        let night = hour >= 23 || hour < 7
        if night { return true }
        if stage == .neonatal { return true }
        return energy < 0.22
    }

    /// 앱을 안 켠 동안 흐른 시간을 따라잡음 (밥그릇·물그릇·패드가 있으면 알아서 먹고 싸고, 없으면 배고프고 실수함)
    mutating func catchUp(_ now: Double = Date().timeIntervalSince1970) {
        var left = min(now - lastSim, 14 * 86400)
        lastSim = now
        guard left > 1 else { return }
        var t = now - left
        while left > 0 {
            let dt = min(left, 900)
            let h = Float(dt / 3600)
            let st = Stage.of(age(t))
            let d = st.decay
            let cal = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t))
            let hour = Double(cal.hour ?? 12) + Double(cal.minute ?? 0) / 60
            let sleeping = PetState.sleepy(hour: hour, stage: st, energy: energy) || (energy < 0.9 && asleep)
            asleep = sleeping
            let k: Float = sleeping ? 0.45 : 1
            food = PetState.clamp(food - d.food * h * k)
            water = PetState.clamp(water - d.water * h * k)
            potty = PetState.clamp(potty - d.potty * h * k)
            energy = PetState.clamp(energy + (sleeping ? 0.22 : -0.06) * h)
            if !sleeping {
                fun = PetState.clamp(fun - d.fun * h)
                love = PetState.clamp(love - d.love * h)
            }
            clean = PetState.clamp(clean - 0.004 * h)
            if !sleeping {
                // 그릇에 남은 밥·물 (젖먹이는 혼자 못 먹음)
                if st.rawValue >= Stage.social.rawValue {
                    if food < 0.45, foodBowl > 0.05 { food = PetState.clamp(food + st.meal * foodBowl); foodBowl = 0; meals += 1; potty = PetState.clamp(potty - 0.2) }
                    if water < 0.5, waterBowl > 0.05 { water = PetState.clamp(water + 0.6); waterBowl = max(0, waterBowl - 0.34) }
                }
                if potty < 0.12 {
                    potty = 1
                    if padUses > 0 { padUses -= 1; if padUses == 0, use("pad") { padUses = 3 } }
                    else { poops = min(3, poops + 1); clean = PetState.clamp(clean - 0.05) }
                }
            }
            if food < 0.08 || (water < 0.08 && d.water > 0) { health = max(0.25, health - 0.02 * h) }
            else { health = min(1, health + 0.012 * h) }
            if love < 0.15 { bond = max(0, bond - 0.004 * h) }
            left -= dt
            t += dt
        }
        let day = PetState.dayKey(now)
        if walkDay != day { walkDay = day; walkM = 0 }
    }

    static func dayKey(_ t: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// 기분 (0~1): 욕구가 고루 찼을수록
    var mood: Float {
        let v = [food, water, energy, potty, fun, love].min() ?? 0.5
        let avg = (food + water + energy + fun + love + clean) / 6
        return PetState.clamp(0.45 * v + 0.55 * avg) * (0.6 + 0.4 * health)
    }
}

/// 아이클라우드 키-값 저장소의 강아지 (0.3.0): 비전 앱이 저장할 때마다 올리고, 아이폰 앱이 읽어 알림을 계산함.
/// 두 앱이 같은 번들 ID 라 같은 저장소를 씀. 앱을 지웠다 다시 깔면 여기서 되살림
enum CloudPet {
    static let key = "pet.v1"

    static func push(_ d: Foundation.Data) {
        NSUbiquitousKeyValueStore.default.set(d, forKey: key)
    }

    static func pull() -> PetState? {
        guard let d = NSUbiquitousKeyValueStore.default.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PetState.self, from: d)
    }

    static func remove() {
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
    }
}

/// 저장: 앱 지원 폴더의 pet.json (업데이트해도 그대로 — 항목이 늘어도 예전 파일을 읽음) + 아이클라우드
enum Store {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("anotherfam", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var file: URL { dir.appendingPathComponent("pet.json") }

    static func load() -> PetState? {
        for name in ["pet.json", "pet.bak.json"] {
            if let d = try? Foundation.Data(contentsOf: dir.appendingPathComponent(name)), let p = try? JSONDecoder().decode(PetState.self, from: d) { return p }
        }
        // 기기에 없으면(다시 설치) 아이클라우드에서
        NSUbiquitousKeyValueStore.default.synchronize()
        if let p = CloudPet.pull() {
            if let d = try? JSONEncoder().encode(p) { try? d.write(to: file, options: .atomic) }
            return p
        }
        return nil
    }

    static func save(_ p: PetState) {
        guard let d = try? JSONEncoder().encode(p) else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("pet.bak.json"))
            try? FileManager.default.copyItem(at: file, to: dir.appendingPathComponent("pet.bak.json"))
        }
        try? d.write(to: file, options: .atomic)
        CloudPet.push(d)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("pet.bak.json"))
        CloudPet.remove()
    }
}

// MARK: - 상점
enum ItemCat: String, CaseIterable {
    case food = "먹을 것", care = "돌봄", toy = "장난감", living = "살림", health = "건강"
    var icon: String {
        switch self {
        case .food: return "fork.knife"
        case .care: return "sparkles"
        case .toy: return "tennisball"
        case .living: return "house"
        case .health: return "cross.case"
        }
    }
}

struct Item: Identifiable {
    let id: String
    let name: String
    let cat: ItemCat
    let price: Int
    let qty: Int                 // 살 때 들어오는 수 (0 = 한 번 사면 계속 쓰는 것)
    let unit: String
    let icon: String
    let note: String
    var ageMin: Double = 0
    var ageMax: Double = 99999
    var permanent: Bool { qty == 0 }
}

/// 값 기준 (1분 = 10P): 하루 15분(150P)이면 성견 이틀치 밥. 물은 무료(물그릇은 입양 키트).
/// 처음 1,500P 로 젖병·분유·밥그릇·패드·봉투·방석·공·빗·이유식을 갖출 수 있음
enum Catalog {
    static let items: [Item] = [
        Item(id: "formula", name: "강아지 분유", cat: .food, price: 80, qty: 8, unit: "회", icon: "drop.fill", note: "생후 4주까지 · 하루치", ageMax: 35),
        Item(id: "food_puppy", name: "퍼피 사료", cat: .food, price: 150, qty: 8, unit: "끼", icon: "takeoutbag.and.cup.and.straw.fill", note: "3주~1살 · 이틀치", ageMin: 21, ageMax: 400),
        Item(id: "food_adult", name: "어덜트 사료", cat: .food, price: 150, qty: 4, unit: "끼", icon: "takeoutbag.and.cup.and.straw.fill", note: "1~7살 · 이틀치", ageMin: 300, ageMax: 2700),
        Item(id: "food_adult_l", name: "어덜트 사료 대용량", cat: .food, price: 700, qty: 20, unit: "끼", icon: "shippingbox.fill", note: "1~7살 · 열흘치", ageMin: 300, ageMax: 2700),
        Item(id: "food_senior", name: "시니어 사료", cat: .food, price: 160, qty: 4, unit: "끼", icon: "takeoutbag.and.cup.and.straw.fill", note: "7살부터 · 이틀치", ageMin: 2400),
        Item(id: "treat", name: "간식", cat: .food, price: 120, qty: 10, unit: "개", icon: "star.fill", note: "손으로 주기 · 훈련", ageMin: 42),
        Item(id: "dental", name: "덴탈 껌", cat: .food, price: 150, qty: 5, unit: "개", icon: "mouth.fill", note: "이갈이 · 치아 관리", ageMin: 90),
        Item(id: "pad", name: "배변 패드", cat: .care, price: 100, qty: 10, unit: "장", icon: "square.fill", note: "한 장에 세 번"),
        Item(id: "bag", name: "배변 봉투", cat: .care, price: 60, qty: 20, unit: "장", icon: "bag.fill", note: "치울 때 한 장"),
        Item(id: "shampoo", name: "거품 샴푸", cat: .care, price: 200, qty: 5, unit: "회", icon: "bubbles.and.sparkles.fill", note: "물 없이 씻기기", ageMin: 56),
        Item(id: "brush", name: "빗", cat: .care, price: 150, qty: 0, unit: "", icon: "comb.fill", note: "손에 쥐고 빗겨 주기"),
        Item(id: "bottle", name: "젖병", cat: .living, price: 100, qty: 0, unit: "", icon: "waterbottle.fill", note: "분유 먹일 때", ageMax: 60),
        Item(id: "bowl_food", name: "밥그릇", cat: .living, price: 80, qty: 0, unit: "", icon: "circle.circle.fill", note: "사료를 담는 그릇"),
        Item(id: "bowl_water", name: "물그릇", cat: .living, price: 0, qty: 0, unit: "", icon: "drop.circle.fill", note: "입양 키트 · 물은 무료"),
        Item(id: "blanket", name: "담요", cat: .living, price: 0, qty: 0, unit: "", icon: "rectangle.fill", note: "입양 키트 · 첫 잠자리"),
        Item(id: "bed", name: "방석", cat: .living, price: 350, qty: 0, unit: "", icon: "bed.double.fill", note: "푹신한 잠자리"),
        Item(id: "leash", name: "하네스와 줄", cat: .living, price: 400, qty: 0, unit: "", icon: "figure.walk", note: "산책", ageMin: 70),
        Item(id: "steps", name: "강아지 계단", cat: .living, price: 450, qty: 0, unit: "", icon: "stairs", note: "소파 오르내리기 · 관절 보호", ageMin: 300),
        Item(id: "ball", name: "공", cat: .toy, price: 120, qty: 0, unit: "", icon: "tennisball.fill", note: "던지면 물어 옴", ageMin: 28),
        Item(id: "rope", name: "터그 로프", cat: .toy, price: 150, qty: 0, unit: "", icon: "lasso", note: "당기기 놀이", ageMin: 42),
        Item(id: "squeak", name: "삑삑이 뼈다귀", cat: .toy, price: 180, qty: 0, unit: "", icon: "speaker.wave.2.fill", note: "물면 소리가 남", ageMin: 28),
        Item(id: "chewbone", name: "씹는 뼈", cat: .toy, price: 200, qty: 0, unit: "", icon: "capsule.fill", note: "오래 씹기", ageMin: 60),
        Item(id: "blanky", name: "블랭키씨 인형", cat: .toy, price: 300, qty: 0, unit: "", icon: "figure.stand", note: "물고 다니는 애착 인형", ageMin: 21),
        Item(id: "vaccine", name: "예방 접종", cat: .health, price: 250, qty: 1, unit: "회", icon: "syringe.fill", note: "6·9·12주, 그 뒤 해마다", ageMin: 42),
        Item(id: "checkup", name: "건강 검진", cat: .health, price: 200, qty: 1, unit: "회", icon: "stethoscope", note: "해마다 한 번", ageMin: 180),
        Item(id: "joint", name: "관절 영양제", cat: .health, price: 300, qty: 1, unit: "달", icon: "pills.fill", note: "7살부터 · 한 달", ageMin: 2400),
    ]
    static func item(_ id: String) -> Item? { items.first { $0.id == id } }
    /// 공간에 꺼내 놓는 것
    static let placeable: Set<String> = ["bowl_food", "bowl_water", "blanket", "bed", "pad", "ball", "rope", "squeak", "chewbone", "blanky", "steps"]
    static let toys: [String] = ["ball", "rope", "squeak", "chewbone", "blanky"]
    static func foodFor(_ age: Double) -> [String] {
        if age < 21 { return ["formula"] }
        if age < 35 { return ["formula", "food_puppy"] }
        if age < 330 { return ["food_puppy"] }
        if age < 2555 { return ["food_adult", "food_adult_l", "food_puppy"] }
        return ["food_senior", "food_adult", "food_adult_l"]
    }
}
