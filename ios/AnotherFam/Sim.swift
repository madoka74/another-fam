import Foundation

/// 시간·나이·욕구·포인트 (화면·공간과 상관없는 계산만)
/// - 하루는 현실과 같은 24시간 (밥·물·잠·배변·놀이는 현실 시간으로 흐름)
/// - 나이는 현실 하루에 13일씩 먹음: 13년(4,745일) ÷ 13 = 365일 = 현실 1년 (현실 한 달 ≈ 강아지 1년).
///   0.10.7 까지 26배(6달)였음 — 초반에 너무 빨리 자라 1년으로 늘림 (PetState.rate 로 이미 키우던 팸의 나이는 그대로 이어 감)
///   13살이 되면 그 모습 그대로 머묾
enum Sim {
    /// 말티즈 기준 (종마다 다르면 Breed.rate·maxAge 를 씀 — 평균 수명이 현실 1년이 되게)
    static let ageRate: Double = 13
    static let maxAge: Double = 4745
    /// 입양할 때마다 가족 지갑에 들어오는 포인트
    static let startPoints = 1500
    /// 한 번에 키울 수 있는 팸 수 (성능 — 나중에 이 숫자만 바꾸면 됨)
    static let maxPets = 3
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

    /// 깨어 있을 때 시간당 줄어드는 기운: 하루 중 자는 비율(sleepShare)에 맞게 — 밤잠(8시간)을 뺀 낮 동안 그 비율만큼 낮잠을 잠.
    /// (0.9 까지는 모든 나이가 시간당 0.06 이라, 7주 강아지도 낮에 13시간을 깨어 있어 하루 대부분 멀쩡했음)
    var awakeDrain: Float {
        let day = max(0.08, min(0.8, (sleepShare * 24 - 8) / 16))
        return 0.22 * day / (1 - day)
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

// MARK: - 팸 종류 (0.10.15): 새 팸(강아지·고양이·다른 동물)은 여기 한 줄과 그 몸(모델·움직임)만 더하면 보금자리에 나와 바로 입양·함께하기가 됨
enum Kind: String, Codable {
    case dog                    // 몸·움직임·행동 = DogData/DogSkin/DogAnimator/Dog (말티즈 모델)
    var title: String {
        switch self {
        case .dog: return "강아지"
        }
    }
}

struct Breed: Identifiable {
    let id: String              // PetState.species 에 저장되는 값
    let name: String
    let kind: Kind
    let icon: String
    let note: String            // 한 줄 소개 (카드)
    let about: String           // 보금자리에서 고르면 보이는 설명
    let lifeYears: Double       // 평균 수명 — 이만큼이 현실 1년 (0.11.0)
    /// 나이 빠르기: 현실 하루에 먹는 나이(일)
    var rate: Double { lifeYears }
    var maxAge: Double { lifeYears * 365 }
}

enum Breeds {
    static let all: [Breed] = [
        Breed(id: "maltese", name: "말티즈", kind: .dog, icon: "dog.fill", note: "희고 작은 친구 · 다 자라면 3kg",
              about: "하얀 털이 보송한 작은 강아지예요. 사람을 좋아하고 애교가 많아 곁에 붙어 있기를 좋아해요. 갓 태어난 아기로 와서 13살까지 자라요",
              lifeYears: 13),
    ]
    static func of(_ id: String) -> Breed { all.first { $0.id == id } ?? all[0] }
}

/// 팸마다 따로 쓰는 물건의 열쇠: "bowl_food:ab12cd" (물건:팸 열쇠). 공용 물건은 물건 이름 그대로 (0.11.0)
enum Own {
    static func key(_ item: String, _ pk: String) -> String { item + ":" + pk }
    static func item(_ key: String) -> String { key.split(separator: ":", maxSplits: 1).first.map(String.init) ?? key }
    static func pet(_ key: String) -> String? {
        let parts = key.split(separator: ":", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }
}

/// 가족 살림 (0.11.0): 포인트·보관함·꺼내 둔 물건과 자리·바닥의 똥·패드 — 팸 모두가 함께 씀.
/// 팸마다 따로 쓰는 물건(그릇·잠자리·줄·젖병)은 열쇠에 팸 열쇠가 붙음 (Own)
struct Household: Codable, Equatable {
    var points = 0
    var pointFrac: Double = 0
    var usedSec: Double = 0
    var inv: [String: Int] = [:]
    var placed: [String] = []
    var layout: [String: [Float]] = [:]
    var poops = 0
    var padUses = 0

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func g<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        points = g(.points, 0); pointFrac = g(.pointFrac, 0); usedSec = g(.usedSec, 0)
        inv = g(.inv, [:]); placed = g(.placed, []); layout = g(.layout, [:]); poops = g(.poops, 0); padUses = g(.padUses, 0)
    }

    func has(_ k: String) -> Bool { (inv[k] ?? 0) > 0 }
    func count(_ k: String) -> Int { inv[k] ?? 0 }
    mutating func use(_ k: String, _ n: Int = 1) -> Bool {
        guard count(k) >= n else { return false }
        inv[k] = count(k) - n
        return true
    }
}

/// 이름 뒤 토씨: 받침 있는 이름은 부를 때 '이'를 붙임 (깨몽 → 깨몽이와, 몽이 → 몽이와)
enum Josa {
    static func batchim(_ name: String) -> Bool {
        guard let c = name.unicodeScalars.last, c.value >= 0xAC00, c.value <= 0xD7A3 else { return false }
        return (c.value - 0xAC00) % 28 != 0
    }
    static func wa(_ name: String) -> String { batchim(name) ? "이와" : "와" }
}

struct PetState: Codable, Equatable {
    var id = UUID().uuidString                                       // 팸마다 다른 이름표 (0.10.15 여러 팸)
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
    var together = false                                             // 비전에서 함께하는 중 (아이폰은 이 동안 알림을 멈춤)
    var rate: Double = Sim.ageRate                                   // born 을 셈한 나이 빠르기 (바뀌면 지금 나이를 그대로 두고 born 을 다시 셈)

    init() {}

    /// 팸 열쇠 (물건 열쇠·자리 열쇠에 붙는 짧은 이름표)
    var key: String { String(id.replacingOccurrences(of: "-", with: "").lowercased().prefix(6)) }
    var breed: Breed { Breeds.of(species) }
    var maxAge: Double { breed.maxAge }
    /// 이 팸 몫으로 보이는 살림: 공용 물건 + 이 팸 물건(열쇠를 떼고) — 화면·알림 셈(NeedInfo·Forecast·catchUp)이 예전처럼 has("bowl_food") 로 볼 수 있게
    func with(_ h: Household) -> PetState {
        var p = self
        var inv: [String: Int] = [:]
        for (k, v) in h.inv {
            if let pk = Own.pet(k) { if pk == key { inv[Own.item(k)] = v } } else { inv[k] = v }
        }
        p.inv = inv
        p.placed = h.placed.compactMap { k in
            if let pk = Own.pet(k) { return pk == key ? Own.item(k) : nil }
            return k
        }
        p.points = h.points
        p.poops = h.poops
        p.padUses = h.padUses
        return p
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func g<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        let z = PetState()
        id = g(.id, z.id)
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
        bottle = g(.bottle, z.bottle); together = g(.together, z.together)
        // 나이 빠르기가 바뀜(0.10.8: 26배 → 13배): 지금 나이는 그대로 두고 그 나이가 되는 born 으로 옮김
        // (그대로 두면 이미 키우던 팸의 나이가 절반으로 줄어 다시 젖병을 먹는 아기가 됨)
        let r = g(.rate, 26.0)
        let br = Breeds.of(species)
        if r != br.rate {
            let now = Date().timeIntervalSince1970
            let a = min(br.maxAge, max(0, (now - born) / 86400 * r))
            born = now - a / br.rate * 86400
        }
        rate = br.rate
    }

    // MARK: 나이 — 종마다 평균 수명이 현실 1년 (말티즈 13년 → 현실 하루에 13일)
    func age(_ now: Double = Date().timeIntervalSince1970) -> Double {
        let b = breed
        return min(b.maxAge, max(0, (now - born) / 86400 * b.rate))
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
            energy = PetState.clamp(energy + (sleeping ? 0.22 : -st.awakeDrain) * h)
            if !sleeping {
                fun = PetState.clamp(fun - d.fun * h)
                love = PetState.clamp(love - d.love * h)
            }
            clean = PetState.clamp(clean - 0.004 * h)
            // 그릇에 남은 밥·물: 배고프거나 목마르면 자다가도(밤에도) 일어나 먹고 마심. 필요한 만큼만 먹고 남김 (젖먹이는 혼자 못 먹음)
            // (0.9: 자는 동안엔 먹지 않아, 밤새 그릇이 가득한데 배고프다는 알림이 왔음 / 한 번 먹으면 그릇을 통째로 비웠음)
            if st.rawValue >= Stage.social.rawValue {
                if food < (sleeping ? 0.3 : 0.45), foodBowl > 0.05 {
                    let take = min(foodBowl, (1 - food) / st.meal)
                    food = PetState.clamp(food + st.meal * take); foodBowl = max(0, foodBowl - take); meals += 1; potty = PetState.clamp(potty - 0.2)
                }
                if water < (sleeping ? 0.3 : 0.5), waterBowl > 0.05 {
                    let take = min(waterBowl, 0.34)
                    water = PetState.clamp(water + 0.6 * take / 0.34); waterBowl = max(0, waterBowl - take)
                }
            }
            if potty < 0.12 {
                potty = 1
                if padUses > 0 { padUses -= 1; if padUses == 0, use("pad") { padUses = 3 } }
                else { poops = min(3, poops + 1); clean = PetState.clamp(clean - 0.05) }
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

/// 우리 집 팸들 (0.10.15 → 0.11.0): 입양한 팸(최대 Sim.maxPets)과 가족 살림(home).
/// 0.11.0 부터 '함께하기'를 누르면 모든 팸이 함께 나옴. active 는 메뉴에서 먼저 보여 줄 팸
struct Family: Codable, Equatable {
    var pets: [PetState] = []
    var active = ""
    var home = Household()
    var rel: [String: Float] = [:]          // 팸 둘 사이 사이 좋음 (−1 앙숙 ~ 1 단짝). 열쇠 = 두 팸 열쇠를 정렬해 '|'
    var v = 2                               // 2 = 가족 살림 (0.11.0)

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        pets = (try? c.decodeIfPresent([PetState].self, forKey: .pets)) ?? []
        active = (try? c.decodeIfPresent(String.self, forKey: .active)) ?? ""
        home = (try? c.decodeIfPresent(Household.self, forKey: .home)) ?? Household()
        rel = (try? c.decodeIfPresent([String: Float].self, forKey: .rel)) ?? [:]
        let ver = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 1
        if ver < 2 { migrate() }
        v = 2
    }

    var current: PetState? { pets.first { $0.id == active } ?? pets.first }
    func pet(_ id: String) -> PetState? { pets.first { $0.id == id } }
    func petByKey(_ k: String) -> PetState? { pets.first { $0.key == k } }
    /// 이 팸 몫으로 보이는 상태 (공용 살림 + 이 팸 물건)
    func view(_ p: PetState) -> PetState { p.with(home) }
    var full: Bool { pets.count >= Sim.maxPets }

    mutating func put(_ p: PetState) {
        if let i = pets.firstIndex(where: { $0.id == p.id }) { pets[i] = p } else { pets.append(p) }
    }

    static func pair(_ a: String, _ b: String) -> String { a < b ? a + "|" + b : b + "|" + a }
    func relation(_ a: String, _ b: String) -> Float { rel[Family.pair(a, b)] ?? 0.1 }

    /// 공간에 나와 있지 않은 동안 흐른 시간: 팸마다 셈하되 패드·똥·패드 재고는 함께 씀
    mutating func catchUp(_ now: Double = Date().timeIntervalSince1970, except: Set<String> = []) {
        for i in pets.indices where !except.contains(pets[i].id) {
            var v = pets[i].with(home)
            v.catchUp(now)
            home.padUses = v.padUses
            home.poops = v.poops
            home.inv["pad"] = v.inv["pad"]
            pets[i] = v
        }
    }

    /// 입양: 가족 지갑에 1,500P + 이 팸의 입양 키트(물그릇·담요, 이름 붙음)
    mutating func adopt(_ p: PetState) {
        pets.append(p)
        home.points += Sim.startPoints
        for it in ["bowl_water", "blanket"] {
            let k = Own.key(it, p.key)
            home.inv[k] = 1
            if !home.placed.contains(k) { home.placed.append(k) }
        }
    }

    /// 헤어짐: 그 팸과 그 팸 물건(이름 붙은 것)·자리를 지움. 공용 살림은 그대로
    mutating func remove(_ id: String) {
        guard let p = pet(id) else { return }
        pets.removeAll { $0.id == id }
        let mine = { (k: String) in Own.pet(k) == p.key }
        home.inv = home.inv.filter { !mine($0.key) }
        home.placed.removeAll(where: mine)
        home.layout = home.layout.filter { !mine($0.key) }
        rel = rel.filter { !$0.key.contains(p.id) }
        if active == id { active = pets.first?.id ?? "" }
    }

    /// 0.10.15 까지(팸마다 살림을 따로 가짐) → 가족 살림 하나로: 포인트는 모두 더하고, 따로 쓰는 물건은 팸 이름을 붙이고,
    /// 공용 물건은 개수를 더함. 꺼내 둔 물건·자리는 고른 팸(active) 것을 씀
    mutating func migrate() {
        guard !pets.isEmpty else { return }
        var h = Household()
        let main = current ?? pets[0]
        for p in pets {
            h.points += p.points
            h.usedSec += p.usedSec
            for (k, n) in p.inv where n > 0 {
                if Catalog.personal(k) { h.inv[Own.key(k, p.key)] = 1 } else { h.inv[k, default: 0] += n }
            }
        }
        let ren = { (k: String) -> String in
            if k == "_dog" { return "_dog:" + main.key }
            return Catalog.personal(k) ? Own.key(k, main.key) : k
        }
        h.placed = main.placed.map(ren)
        for (k, v) in main.layout { h.layout[ren(k)] = v }
        h.poops = main.poops
        h.padUses = main.padUses
        home = h
        // 물건 고정점 목록도 같은 열쇠로 (0.10.15 의 팸마다 목록, 그 전의 한 목록)
        let ud = UserDefaults.standard
        if ud.dictionary(forKey: "af.anchors.home") == nil,
           let pins = (ud.dictionary(forKey: "af.anchors." + main.id) ?? ud.dictionary(forKey: "af.anchors")) as? [String: String] {
            var m: [String: String] = [:]
            for (k, v) in pins { m[ren(k)] = v }
            ud.set(m, forKey: "af.anchors.home")
        }
    }

    /// 저장된 글 → 가족. 예전(0.10.14 까지) 한 마리 글이면 그 팸 하나뿐인 가족으로
    static func decode(_ d: Foundation.Data) -> Family? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if o["pets"] != nil { return try? JSONDecoder().decode(Family.self, from: d) }
        guard o["name"] != nil, let p = try? JSONDecoder().decode(PetState.self, from: d) else { return nil }
        var f = Family()
        f.pets = [p]
        f.active = p.id
        f.migrate()
        return f
    }
}

/// 아이클라우드 키-값 저장소의 가족 (0.3.0, 0.10.15 부터 여러 팸): 비전 앱이 저장할 때마다 올리고, 아이폰 앱이 읽어 알림을 계산함.
/// 두 앱이 같은 번들 ID 라 같은 저장소를 씀. 앱을 지웠다 다시 깔면 여기서 되살림
enum CloudPet {
    static let key = "family.v1"
    static let legacy = "pet.v1"

    static func push(_ d: Foundation.Data) {
        NSUbiquitousKeyValueStore.default.set(d, forKey: key)
    }

    static func pull() -> Family? {
        if let d = NSUbiquitousKeyValueStore.default.data(forKey: key), let f = Family.decode(d) { return f }
        if let d = NSUbiquitousKeyValueStore.default.data(forKey: legacy), let f = Family.decode(d) { return f }
        return nil
    }
}

/// 저장: 앱 지원 폴더의 family.json (업데이트해도 그대로 — 항목이 늘어도 예전 파일을 읽음) + 아이클라우드.
/// 0.10.14 까지의 pet.json(한 마리)은 처음 읽을 때 가족으로 옮김
enum Store {
    /// 마지막으로 읽거나 저장한 가족 (공간·메인 창이 저마다 고친 팸을 여기에 모아 저장)
    nonisolated(unsafe) static var family = Family()

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("anotherfam", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var file: URL { dir.appendingPathComponent("family.json") }

    static func load() -> Family {
        for name in ["family.json", "family.bak.json"] {
            if let d = try? Foundation.Data(contentsOf: dir.appendingPathComponent(name)), let f = Family.decode(d) { family = f; return f }
        }
        // 예전 한 마리 파일 → 가족으로 옮김 (지난 물건 고정점 목록도 그 팸 것으로)
        for name in ["pet.json", "pet.bak.json"] {
            if let d = try? Foundation.Data(contentsOf: dir.appendingPathComponent(name)), let f = Family.decode(d), f.current != nil {
                family = f
                write(f, force: false)
                return f
            }
        }
        // 기기에 없으면(다시 설치) 아이클라우드에서
        NSUbiquitousKeyValueStore.default.synchronize()
        if let f = CloudPet.pull() {
            family = f
            if let d = try? JSONEncoder().encode(f) { try? d.write(to: file, options: .atomic) }
            return f
        }
        return Family()
    }

    /// 한 팸을 고쳐 저장 (그 팸만 바꾸고 나머지는 그대로)
    static func save(_ p: PetState, force: Bool = false) {
        family.put(p)
        write(family, force: force)
    }

    /// 가족 전체 저장 (입양·고르기·헤어지기·시간 따라잡기). 같은 팸이 양쪽에 있으면 더 나중에 셈한 것(lastSim)을 씀
    static func save(family f: Family, force: Bool = false) {
        var m = f
        for i in m.pets.indices {
            if let mine = family.pet(m.pets[i].id), mine.lastSim > m.pets[i].lastSim { m.pets[i] = mine }
        }
        family = m
        write(m, force: force)
    }

    private static func write(_ f: Family, force: Bool) {
        guard let d = try? JSONEncoder().encode(f) else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("family.bak.json"))
            try? FileManager.default.copyItem(at: file, to: dir.appendingPathComponent("family.bak.json"))
        }
        try? d.write(to: file, options: .atomic)
        CloudPet.push(d)
        CloudSync.push(f, data: d, force: force)           // 아이폰 앱을 바로 깨워 알림을 다시 맞추게 (Cloud.swift)
    }

    /// 공간을 닫거나 앱이 뒤로 갈 때: 저장 + 아이클라우드에 바로 올림 (앱이 멈추기 전에 올라가도록 시간을 빌려서)
    static func saveFinal(_ p: PetState) {
        save(p, force: true)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    static func saveFinal(family f: Family) {
        save(family: f, force: true)
        NSUbiquitousKeyValueStore.default.synchronize()
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
    /// 팸마다 따로 쓰는 것 (이름표가 붙고, 살 때 어느 팸 것인지 고름) — 0.11.0
    var personal: Bool { Catalog.personal(id) }
    /// 쓸 수 있는 종류 (nil = 모두) · 품종 (nil = 그 종류 모두)
    var kinds: [Kind]? { Catalog.kindsOf[id] }
    var breeds: [String]? { Catalog.breedsOf[id] }
    func fits(_ p: PetState) -> Bool {
        if let k = kinds, !k.contains(p.breed.kind) { return false }
        if let b = breeds, !b.contains(p.species) { return false }
        return true
    }
    /// 쓰는 범위 이름 (메뉴 갈래 표시)
    var scopeText: String {
        if personal { return "개별" }
        if let b = breeds { return b.map { Breeds.of($0).name }.joined(separator: "·") + " 전용" }
        if let k = kinds { return k.map(\.title).joined(separator: "·") + " 전용" }
        return "공용"
    }
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
        Item(id: "food_salmon", name: "연어 어덜트 사료", cat: .food, price: 170, qty: 4, unit: "끼", icon: "fish.fill", note: "1~7살 · 이틀치 · 털 윤기", ageMin: 300, ageMax: 2700),
        Item(id: "treat", name: "간식", cat: .food, price: 120, qty: 10, unit: "개", icon: "star.fill", note: "손으로 주기 · 훈련", ageMin: 42),
        Item(id: "jerky", name: "닭가슴살 육포", cat: .food, price: 140, qty: 8, unit: "개", icon: "flame.fill", note: "손으로 주기 · 좋아하는 간식", ageMin: 70),
        Item(id: "cheese", name: "치즈 큐브", cat: .food, price: 100, qty: 12, unit: "개", icon: "square.grid.2x2.fill", note: "작은 한입 간식 · 훈련", ageMin: 56),
        Item(id: "dental", name: "덴탈 껌", cat: .food, price: 150, qty: 5, unit: "개", icon: "mouth.fill", note: "이갈이 · 치아 관리", ageMin: 90),
        Item(id: "pad", name: "배변 패드", cat: .care, price: 100, qty: 10, unit: "장", icon: "square.fill", note: "한 장에 세 번"),
        Item(id: "bag", name: "배변 봉투", cat: .care, price: 60, qty: 20, unit: "장", icon: "bag.fill", note: "치울 때 한 장"),
        Item(id: "shampoo", name: "거품 샴푸", cat: .care, price: 200, qty: 5, unit: "회", icon: "bubbles.and.sparkles.fill", note: "물 없이 씻기기", ageMin: 56),
        Item(id: "brush", name: "빗", cat: .care, price: 150, qty: 0, unit: "", icon: "comb.fill", note: "손에 쥐고 빗겨 주기"),
        Item(id: "wipes", name: "반려견 물티슈", cat: .care, price: 80, qty: 20, unit: "장", icon: "hand.raised.fill", note: "발·얼굴 닦기 · 청결 조금", ageMin: 21),
        Item(id: "toothpaste", name: "강아지 치약", cat: .care, price: 120, qty: 10, unit: "회", icon: "mouth", note: "양치 · 건강 조금", ageMin: 90),
        Item(id: "bottle", name: "젖병", cat: .living, price: 100, qty: 0, unit: "", icon: "waterbottle.fill", note: "분유 먹일 때", ageMax: 60),
        Item(id: "bowl_food", name: "밥그릇", cat: .living, price: 80, qty: 0, unit: "", icon: "circle.circle.fill", note: "사료를 담는 그릇"),
        Item(id: "bowl_water", name: "물그릇", cat: .living, price: 0, qty: 0, unit: "", icon: "drop.circle.fill", note: "입양 키트 · 물은 무료"),
        Item(id: "blanket", name: "담요", cat: .living, price: 0, qty: 0, unit: "", icon: "rectangle.fill", note: "입양 키트 · 첫 잠자리"),
        Item(id: "bed", name: "방석", cat: .living, price: 350, qty: 0, unit: "", icon: "bed.double.fill", note: "푹신한 잠자리"),
        Item(id: "cushion", name: "쿠션 매트", cat: .living, price: 280, qty: 0, unit: "", icon: "square.fill.on.square.fill", note: "도톰한 누빔 매트 · 잠자리"),
        Item(id: "leash", name: "하네스와 줄", cat: .living, price: 400, qty: 0, unit: "", icon: "figure.walk", note: "산책", ageMin: 70),
        Item(id: "steps", name: "강아지 계단", cat: .living, price: 450, qty: 0, unit: "", icon: "stairs", note: "소파 오르내리기 · 관절 보호", ageMin: 300),
        Item(id: "ball", name: "공", cat: .toy, price: 120, qty: 0, unit: "", icon: "tennisball.fill", note: "던지면 물어 옴", ageMin: 28),
        Item(id: "ball_mini", name: "작은 고무공", cat: .toy, price: 90, qty: 0, unit: "", icon: "circle.fill", note: "잘 튀는 빨간 공 · 굴리기", ageMin: 28),
        Item(id: "frisbee", name: "말랑 원반", cat: .toy, price: 180, qty: 0, unit: "", icon: "circle.dashed", note: "던지면 날아감 · 물어 옴", ageMin: 120),
        Item(id: "squeak_ball", name: "삑삑이 공", cat: .toy, price: 160, qty: 0, unit: "", icon: "speaker.wave.1.fill", note: "물면 삑 · 굴러감", ageMin: 28),
        Item(id: "rope", name: "터그 로프", cat: .toy, price: 150, qty: 0, unit: "", icon: "lasso", note: "당기기 놀이", ageMin: 42),
        Item(id: "rope_ring", name: "링 터그", cat: .toy, price: 170, qty: 0, unit: "", icon: "circle.circle", note: "둥근 고리 · 당기기 놀이", ageMin: 60),
        Item(id: "squeak", name: "삑삑이 뼈다귀", cat: .toy, price: 180, qty: 0, unit: "", icon: "speaker.wave.2.fill", note: "물면 소리가 남", ageMin: 28),
        Item(id: "chewbone", name: "씹는 뼈", cat: .toy, price: 200, qty: 0, unit: "", icon: "capsule.fill", note: "오래 씹기", ageMin: 60),
        Item(id: "antler", name: "사슴뿔 개껌", cat: .toy, price: 260, qty: 0, unit: "", icon: "leaf.fill", note: "단단해 오래 씹음", ageMin: 180),
        Item(id: "blanky", name: "블랭키씨 인형", cat: .toy, price: 300, qty: 0, unit: "", icon: "figure.stand", note: "물고 다니는 애착 인형", ageMin: 21),
        Item(id: "vaccine", name: "예방 접종", cat: .health, price: 250, qty: 1, unit: "회", icon: "syringe.fill", note: "6·9·12주, 그 뒤 해마다", ageMin: 42),
        Item(id: "checkup", name: "건강 검진", cat: .health, price: 200, qty: 1, unit: "회", icon: "stethoscope", note: "해마다 한 번", ageMin: 180),
        Item(id: "joint", name: "관절 영양제", cat: .health, price: 300, qty: 1, unit: "달", icon: "pills.fill", note: "7살부터 · 한 달", ageMin: 2400),
        Item(id: "heartworm", name: "심장사상충 예방약", cat: .health, price: 220, qty: 1, unit: "달", icon: "heart.text.square.fill", note: "한 달에 한 번", ageMin: 56),
        Item(id: "probiotic", name: "유산균", cat: .health, price: 180, qty: 10, unit: "회", icon: "leaf.circle.fill", note: "장 건강 · 건강 조금", ageMin: 42),
    ]
    static func item(_ id: String) -> Item? { let i = Own.item(id); return items.first { $0.id == i } }
    /// 팸마다 따로 쓰는 물건 (0.11.0): 그릇·잠자리·줄·젖병 — 이름표가 붙음
    static let personalIds: Set<String> = ["bowl_food", "bowl_water", "bed", "blanket", "cushion", "leash", "bottle"]
    static func personal(_ id: String) -> Bool { personalIds.contains(Own.item(id)) }
    /// 종류 전용 (그 밖은 모두 공용): 사료·분유·간식·개껌·강아지 줄
    static let kindsOf: [String: [Kind]] = {
        var m: [String: [Kind]] = [:]
        for id in ["formula", "food_puppy", "food_adult", "food_adult_l", "food_senior", "food_salmon", "treat", "jerky", "cheese", "dental",
                   "chewbone", "antler", "leash"] { m[id] = [.dog] }
        return m
    }()
    static let breedsOf: [String: [String]] = [:]
    /// 젖떼기: 이 나이(생후 5주)부터는 젖병을 먹지 않음 (분유는 4주까지, 3~5주는 젖병과 사료를 함께)
    static let weanAge: Double = 35
    /// 공간에 꺼내 놓는 것
    static let placeable: Set<String> = ["bowl_food", "bowl_water", "blanket", "bed", "pad", "ball", "rope", "squeak", "chewbone", "blanky", "steps",
                                         "cushion", "ball_mini", "frisbee", "squeak_ball", "rope_ring", "antler"]
    static let toys: [String] = ["ball", "rope", "squeak", "chewbone", "blanky", "ball_mini", "frisbee", "squeak_ball", "rope_ring", "antler"]
    /// 같은 방식으로 쓰는 물건의 바탕 종류 (0.10.7 새 물건): 생김새는 저마다, 강아지와 노는 방식은 바탕 물건과 같음
    static let baseOf: [String: String] = ["jerky": "treat", "cheese": "treat", "ball_mini": "ball", "frisbee": "ball", "squeak_ball": "squeak",
                                           "rope_ring": "rope", "antler": "chewbone", "cushion": "blanket"]
    static func base(_ id: String) -> String { let i = Own.item(id); return baseOf[i] ?? i }
    /// 손으로 주는 간식 (사료 봉지로 붓는 것이 아님)
    static func isTreat(_ id: String) -> Bool { let b = base(id); return b == "treat" || b == "dental" }
    static func foodFor(_ age: Double) -> [String] {
        if age < 21 { return ["formula"] }
        if age < 35 { return ["formula", "food_puppy"] }
        if age < 330 { return ["food_puppy"] }
        if age < 2555 { return ["food_adult", "food_salmon", "food_adult_l", "food_puppy"] }
        return ["food_senior", "food_adult", "food_salmon", "food_adult_l"]
    }
}

// MARK: - 욕구 고리 설명 (비전 카드·메인 메뉴·아이폰에서 고리를 누르면 같은 글)
enum NeedInfo {
    static func key(_ label: String) -> String {
        ["밥": "food", "물": "water", "기운": "energy", "배변": "potty", "놀이": "fun", "사랑": "love", "청결": "clean", "건강": "health"][label] ?? label
    }

    /// 앞으로 처음 그렇게 되는 때 (10분씩 흘려 봄, 최대 하루). 지금 이미 그러면 0
    static func first(_ p0: PetState, within h: Double = 24, _ f: (PetState) -> Bool) -> Double? {
        if f(p0) { return 0 }
        var p = p0
        let now = Date().timeIntervalSince1970
        var t = now
        while t < now + h * 3600 {
            t += 600
            p.catchUp(t)
            if f(p) { return t - now }
        }
        return nil
    }

    static func later(_ sec: Double) -> String {
        if sec < 50 * 60 { return "\(max(10, Int(sec / 600) * 10))분쯤 뒤" }
        let h = sec / 3600
        if h < 10 { return "\(Int(h.rounded()))시간쯤 뒤" }
        let d = Date(timeIntervalSince1970: Date().timeIntervalSince1970 + sec)
        let c = Calendar.current.dateComponents([.hour], from: d)
        let today = Calendar.current.isDateInToday(d)
        return (today ? "오늘 " : "내일 ") + "\(c.hour ?? 0)시쯤"
    }

    /// 다음 예방 접종 때 (생후 6·9·12주, 그 뒤 해마다)
    static func nextVaccine(_ n: Int) -> Double {
        let early: [Double] = [42, 63, 84]
        return n < 3 ? early[n] : 84 + 365 * Double(n - 2)
    }

    static func text(_ p: PetState, _ key: String) -> String {
        let age = p.age()
        let st = Stage.of(age)
        let grown = st.rawValue >= Stage.social.rawValue
        switch key {
        case "food":
            if age < 21 {
                if p.food < 0.3 { return "젖을 찾아요 · 젖병을 입에 대 주세요" }
                if let t = first(p, { $0.food < 0.3 }) { return "배불러요 · \(later(t)) 다시 젖을 찾아요" }
                return "배불러요"
            }
            let bowl = p.foodBowl
            let b = bowl > 0.7 ? "그릇에 사료가 넉넉해요" : (bowl > 0.05 ? "그릇에 사료가 조금 남았어요" : "밥그릇이 비었어요")
            if p.food < 0.25 { return bowl > 0.05 ? "배고파요 · 그릇에 사료가 있어 곧 먹을 거예요" : "배고파요 · 밥그릇에 사료를 부어 주세요" }
            if let t = first(p, { $0.food < 0.25 }) { return "\(b) · \(later(t)) 배고파해요" }
            return bowl > 0.05 ? "\(b) · 배고프면 알아서 먹어요" : "\(b) · 하루 안엔 괜찮아요"
        case "water":
            if !grown || age < 21 { return "아직 젖만 먹어요" }
            let bowl = p.waterBowl
            let b = bowl > 0.6 ? "물그릇에 물이 넉넉해요" : (bowl > 0.05 ? "물이 조금 남았어요" : "물그릇이 비었어요")
            if p.water < 0.25 { return bowl > 0.05 ? "목말라요 · 곧 마실 거예요" : "목말라요 · 물그릇에 물을 부어 주세요" }
            if let t = first(p, { $0.water < 0.25 }) { return "\(b) · \(later(t)) 목말라해요" }
            return "\(b) · 목마르면 알아서 마셔요"
        case "energy":
            if p.asleep {
                if let t = first(p, { !$0.asleep }) { return "자는 중이에요 · \(later(t)) 깨요" }
                return "자는 중이에요"
            }
            if let t = first(p, { $0.asleep }) { return "기운이 \(p.energy > 0.6 ? "넘쳐요" : "조금 빠졌어요") · \(later(t)) 자요" }
            return "깨어 있어요"
        case "potty":
            var a: [String] = []
            if p.placed.contains("pad") { a.append(p.padUses > 0 ? "패드가 깔려 있어요 (\(p.padUses)번 더)" : "패드가 가득 찼어요 · 새 패드로 갈아 주세요") }
            else { a.append("패드가 없어 바닥에 실수할 수 있어요") }
            if p.poops > 0 { a.append("치울 똥이 \(p.poops)개 있어요") }
            if p.potty < 0.3 { a.append("곧 볼일을 봐요") }
            a.append("패드에서 볼 때마다 배변 훈련 \(Int(p.train * 100))%")
            return a.joined(separator: " · ")
        case "fun":
            if !grown { return "아직 놀기엔 어려요" }
            if p.fun < 0.25 { return "심심해해요 · 장난감을 던지거나 놀아 주세요" }
            if let t = first(p, { $0.fun < 0.25 }) { return "신나요 · \(later(t)) 심심해해요" }
            return "신나요"
        case "love":
            if p.love < 0.25 { return "보고 싶어 해요 · 쓰다듬거나 안아 주세요" }
            if let t = first(p, { $0.love < 0.25 }) { return "사랑받고 있어요 · \(later(t)) 보고 싶어 해요" }
            return "사랑받고 있어요"
        case "clean":
            let lv = p.clean > 0.7 ? "깨끗해요" : (p.clean > 0.4 ? "조금 꼬질꼬질해요" : "많이 더러워요")
            return age < 56 ? lv : "\(lv) · 빗질·거품 샴푸로 깨끗해져요"
        default:
            var a: [String] = [p.health > 0.7 ? "건강해요" : (p.health > 0.4 ? "기운이 없어요" : "아파요 · 밥·물을 챙겨 주세요")]
            if age >= 35 {
                let due = nextVaccine(p.vaccines)
                if age >= due { a.append("예방 접종을 맞힐 때예요 (\(p.vaccines)번 맞음)") }
                else { a.append("다음 접종 \(PetState.ageText(due)) · \(later((due - age) / p.breed.rate * 86400))") }
            }
            if age >= 180 && (p.checkupAge < 0 || age - p.checkupAge >= 365) { a.append("건강 검진을 받을 때예요") }
            return a.joined(separator: " · ")
        }
    }
}
