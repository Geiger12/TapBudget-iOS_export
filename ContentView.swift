// ContentView.swift
// TapBudget for iPhone, written in SwiftUI against the iOS 26+ APIs that Xcode 27 (iOS 27 SDK) ships.
// Set the target's minimum deployment to iOS 26.0: .glassEffect(), .buttonStyle(.glass) and the
// floating Liquid Glass tab bar need it.
//
// The data model uses the same JSON as the web app's backup file, so a backup saved from the web
// version can be pasted into Settings > Back up > Import and it just works.

import SwiftUI
import Charts
import Observation
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Dates (plain calendar math, so there are no time zone surprises)

private func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
    let y = m <= 2 ? y0 - 1 : y0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

private func civilFromDays(_ z0: Int) -> (y: Int, m: Int, d: Int) {
    let z = z0 + 719468
    let era = (z >= 0 ? z : z - 146096) / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
}

func daysIn(_ y: Int, _ m: Int) -> Int {
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
}

func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

/// A calendar day. `m` is 1...12.
struct YMD: Hashable, Comparable {
    var y: Int
    var m: Int
    var d: Int

    init(y: Int, m: Int, d: Int) { self.y = y; self.m = m; self.d = d }

    init?(iso: String) {
        let p = iso.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]), (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(y: y, m: m, d: d)
    }

    init(dayNumber n: Int) {
        let c = civilFromDays(n)
        self.init(y: c.y, m: c.m, d: c.d)
    }

    init(date: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        self.init(y: c.year ?? 2026, m: c.month ?? 1, d: c.day ?? 1)
    }

    static func < (a: YMD, b: YMD) -> Bool { (a.y, a.m, a.d) < (b.y, b.m, b.d) }
    static var today: YMD { YMD(date: Date()) }

    var iso: String { String(format: "%04ld-%02ld-%02ld", y, m, d) }
    var dayNumber: Int { daysFromCivil(y, m, d) }
    var ym: YM { YM(y: y, m: m) }
    var date: Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }
    func adding(days n: Int) -> YMD { YMD(dayNumber: dayNumber + n) }
    var nice: String { date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
    var short: String { date.formatted(.dateTime.month(.abbreviated).day()) }
}

/// A calendar month. `m` is 1...12.
struct YM: Hashable, Comparable {
    var y: Int
    var m: Int

    init(y: Int, m: Int) { self.y = y; self.m = m }
    init(index: Int) { self.y = index / 12; self.m = index % 12 + 1 }

    var index: Int { y * 12 + (m - 1) }
    static func < (a: YM, b: YM) -> Bool { a.index < b.index }
    static var current: YM { YMD.today.ym }
    func adding(_ n: Int) -> YM { YM(index: index + n) }
    var days: Int { daysIn(y, m) }
    var key: String { String(format: "%04ld-%02ld", y, m) }
    var title: String { "\(Calendar.current.monthSymbols[m - 1]) \(y)" }
    func day(_ d: Int) -> YMD { YMD(y: y, m: m, d: min(max(1, d), days)) }
}

// MARK: - Money formatting

func money(_ v: Double, whole: Bool = false) -> String {
    let code = Locale.current.currency?.identifier ?? "USD"
    let r = round2(v)
    let digits = (whole || r == r.rounded()) ? 0 : 2
    return r.formatted(.currency(code: code).precision(.fractionLength(digits)))
}

func kfmt(_ v: Double) -> String {
    let a = abs(v)
    let body: String
    if a >= 1000 {
        let k = a / 1000
        body = (k >= 10 || k == k.rounded()) ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
    } else {
        body = String(format: "%.0f", a)
    }
    return (v < 0 ? "−" : "") + "$" + body
}

// MARK: - Data model (same JSON as the web app's backup)

enum ItemType: String, Codable, CaseIterable, Identifiable {
    case bill, income, variable
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bill: return "Bill"
        case .income: return "Money in"
        case .variable: return "Everyday spending"
        }
    }
    var hint: String {
        switch self {
        case .bill: return "A payment with a due date. Tick it when you pay it."
        case .income: return "Money coming in, like a paycheck. Tick it when it arrives."
        case .variable: return "A monthly budget you spend from, like groceries. Type what you have spent as you go. If it also has a date, add the day and the cash flow shows it on that date. Without a day, it is spread through the month."
        }
    }
}

struct Item: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var type: ItemType
    var amount: Double
    var account: String = ""
    var biweekly: Bool = false
    var day: Int? = nil
    var anchor: String? = nil
    var automatic: Bool = false
    var autoSince: String? = nil
    var order: Int = 0

    enum CodingKeys: String, CodingKey { case id, name, type, amount, account, freq, day, anchor, recurring, autoSince, order }

    init(id: String = UUID().uuidString, name: String, type: ItemType, amount: Double, account: String = "", biweekly: Bool = false,
         day: Int? = nil, anchor: String? = nil, automatic: Bool = false, autoSince: String? = nil, order: Int = 0) {
        self.id = id; self.name = name; self.type = type; self.amount = amount; self.account = account
        self.biweekly = biweekly; self.day = day; self.anchor = anchor; self.automatic = automatic; self.autoSince = autoSince; self.order = order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        type = try c.decode(ItemType.self, forKey: .type)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
        biweekly = (try c.decodeIfPresent(String.self, forKey: .freq)) == "biweekly"
        day = try c.decodeIfPresent(Int.self, forKey: .day)
        anchor = try c.decodeIfPresent(String.self, forKey: .anchor)
        automatic = try c.decodeIfPresent(Bool.self, forKey: .recurring) ?? false
        autoSince = try c.decodeIfPresent(String.self, forKey: .autoSince)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(amount, forKey: .amount)
        try c.encode(account, forKey: .account)
        try c.encode(biweekly ? "biweekly" : "monthly", forKey: .freq)
        try c.encodeIfPresent(day, forKey: .day)
        try c.encodeIfPresent(anchor, forKey: .anchor)
        if automatic { try c.encode(true, forKey: .recurring) }
        try c.encodeIfPresent(autoSince, forKey: .autoSince)
        try c.encode(order, forKey: .order)
    }
}

/// A payment (or, for everyday spending, the amount spent so far this month).
struct Pay: Codable, Hashable {
    var item: String
    var due: String?
    var on: String?
    var amt: Double?
}

struct Loan: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var isCard: Bool
    var total: Double
    var balance: Double
    var payment: Double = 0
    var payBill: String? = nil
    var accounts: [String] = []
    var apr: Double? = nil
    var asOf: String? = nil
    var seen: [String] = []

    enum CodingKeys: String, CodingKey { case id, name, kind, total, balance, payment, payBill, accounts, apr, asOf, seen }

    init(id: String = UUID().uuidString, name: String, isCard: Bool, total: Double, balance: Double, payment: Double = 0,
         payBill: String? = nil, accounts: [String] = [], apr: Double? = nil, asOf: String? = nil, seen: [String] = []) {
        self.id = id; self.name = name; self.isCard = isCard; self.total = total; self.balance = balance; self.payment = payment
        self.payBill = payBill; self.accounts = accounts; self.apr = apr; self.asOf = asOf; self.seen = seen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Loan"
        isCard = (try c.decodeIfPresent(String.self, forKey: .kind)) == "card"
        total = try c.decodeIfPresent(Double.self, forKey: .total) ?? 0
        balance = try c.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        payment = try c.decodeIfPresent(Double.self, forKey: .payment) ?? 0
        payBill = try c.decodeIfPresent(String.self, forKey: .payBill)
        accounts = try c.decodeIfPresent([String].self, forKey: .accounts) ?? []
        apr = try c.decodeIfPresent(Double.self, forKey: .apr)
        asOf = try c.decodeIfPresent(String.self, forKey: .asOf)
        seen = try c.decodeIfPresent([String].self, forKey: .seen) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isCard ? "card" : "loan", forKey: .kind)
        try c.encode(total, forKey: .total)
        try c.encode(balance, forKey: .balance)
        try c.encode(payment, forKey: .payment)
        try c.encodeIfPresent(payBill, forKey: .payBill)
        if !accounts.isEmpty { try c.encode(accounts, forKey: .accounts) }
        try c.encodeIfPresent(apr, forKey: .apr)
        try c.encodeIfPresent(asOf, forKey: .asOf)
        if !seen.isEmpty { try c.encode(seen, forKey: .seen) }
    }
}

/// A chequing balance you typed in on a given day (the "Now" marker on the charts).
struct Actual: Codable, Hashable { var d: String; var v: Double }

struct Cash: Codable, Hashable {
    var starts: [String: Double] = [:]      // "2026-11" -> balance on the 1st
    var warn: Double = 500                  // the low balance line
    var carry: Bool = true                  // each month starts where the last one ended
    var follow: Bool = true                 // the forecast starts again from your real balance
    var spend: Bool = true                  // include everyday spending
    var actuals: [Actual] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        starts = try c.decodeIfPresent([String: Double].self, forKey: .starts) ?? [:]
        warn = try c.decodeIfPresent(Double.self, forKey: .warn) ?? 500
        carry = try c.decodeIfPresent(Bool.self, forKey: .carry) ?? true
        follow = try c.decodeIfPresent(Bool.self, forKey: .follow) ?? true
        spend = try c.decodeIfPresent(Bool.self, forKey: .spend) ?? true
        actuals = (try c.decodeIfPresent([Actual].self, forKey: .actuals) ?? []).filter { YMD(iso: $0.d) != nil }.sorted { $0.d < $1.d }
    }

    var followOff: Cash { var c = self; c.follow = false; return c }
}

// MARK: - Appearance: saved with each budget, and not part of the backup file

enum LookKind: String, Codable { case flat, glass }

enum SwitchKind: String, Codable, CaseIterable, Identifiable {
    case classic, check, orb, sun, soft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Classic"
        case .check: return "Check and X"
        case .orb: return "Glow"
        case .sun: return "Sun and ring"
        case .soft: return "Soft ring"
        }
    }
    var detail: String {
        switch self {
        case .classic: return "The standard switch"
        case .check: return "Green with a check, red with an X"
        case .orb: return "A glowing green light, a dim red one"
        case .sun: return "A bright sun when on, a ring when off"
        case .soft: return "A solid dot when on, a ring when off"
        }
    }
}

struct ThemeColors: Codable, Hashable {
    var preset: String = "cyan"            // "custom" once you pick your own
    var brand: String = "#2ebfd9"          // bills, headings, the tint
    var primary: String = "#0e7c91"        // bars, charts, spending
    var accent: String = "#fdcb2f"         // money in

    init() {}
    init(preset: String, brand: String, primary: String, accent: String) {
        self.preset = preset; self.brand = brand; self.primary = primary; self.accent = accent
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = (try? c.decodeIfPresent(String.self, forKey: .preset)) ?? "cyan"
        brand = (try? c.decodeIfPresent(String.self, forKey: .brand)) ?? "#2ebfd9"
        primary = (try? c.decodeIfPresent(String.self, forKey: .primary)) ?? "#0e7c91"
        accent = (try? c.decodeIfPresent(String.self, forKey: .accent)) ?? "#fdcb2f"
    }

    struct Preset: Identifiable {
        let id: String
        let name: String
        let brand: String
        let primary: String
        let accent: String
    }

    static let presets: [Preset] = [
        Preset(id: "cyan", name: "Cyan", brand: "#2ebfd9", primary: "#0e7c91", accent: "#fdcb2f"),
        Preset(id: "ocean", name: "Ocean", brand: "#5ba8f5", primary: "#1d5fae", accent: "#ffb547"),
        Preset(id: "forest", name: "Forest", brand: "#6fcf97", primary: "#1f7a4d", accent: "#f2c94c"),
        Preset(id: "sunset", name: "Sunset", brand: "#ff9f6b", primary: "#b8431c", accent: "#ffd166"),
        Preset(id: "berry", name: "Berry", brand: "#e58bc0", primary: "#9b2c6f", accent: "#ffd84d"),
        Preset(id: "graphite", name: "Graphite", brand: "#a8b3bd", primary: "#374151", accent: "#facc15")
    ]
}

struct WallpaperSettings: Codable, Hashable {
    var fileName: String? = nil            // the picture lives in Application Support/wallpapers
    var dim: Double = 0.3
    var blur: Double = 0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try? c.decodeIfPresent(String.self, forKey: .fileName)
        dim = min(max((try? c.decodeIfPresent(Double.self, forKey: .dim)) ?? 0.3, 0), 0.8)
        blur = min(max((try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? 0, 0), 30)
    }
}

/// The look of the three gauges at the top of Overview.
enum GaugeStyle: String, Codable, CaseIterable, Identifiable {
    case rings, thin, arc, bars, capsules
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rings: return "Rings"
        case .thin: return "Thin rings"
        case .arc: return "Arcs"
        case .bars: return "Bars"
        case .capsules: return "Meters"
        }
    }
    var detail: String {
        switch self {
        case .rings: return "Round gauges with a soft glow"
        case .thin: return "Light and airy, with big numbers"
        case .arc: return "Open gauges, like a dial"
        case .bars: return "One compact card with three bars"
        case .capsules: return "Tall meters that fill up"
        }
    }
}

struct Theme: Codable, Hashable {
    var colors = ThemeColors()
    var look: LookKind = .glass
    var switchKind: SwitchKind = .classic
    var wallpaper = WallpaperSettings()
    var gauge: GaugeStyle = .rings
    var gaugeAmounts = true                 // a plain-words line under each gauge, such as "$735 to pay"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // forgiving on purpose: a value this version does not know must never stop the budget from opening
        colors = (try? c.decodeIfPresent(ThemeColors.self, forKey: .colors)) ?? ThemeColors()
        look = (try? c.decodeIfPresent(LookKind.self, forKey: .look)) ?? .glass
        switchKind = (try? c.decodeIfPresent(SwitchKind.self, forKey: .switchKind)) ?? .classic
        wallpaper = (try? c.decodeIfPresent(WallpaperSettings.self, forKey: .wallpaper)) ?? WallpaperSettings()
        gauge = (try? c.decodeIfPresent(GaugeStyle.self, forKey: .gauge)) ?? .rings
        gaugeAmounts = (try? c.decodeIfPresent(Bool.self, forKey: .gaugeAmounts)) ?? true
    }
}

struct Budget: Identifiable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var items: [Item] = []
    var paid: [String: Pay] = [:]
    var loans: [Loan] = []
    var cash = Cash()
    var isSample = false
    var theme = Theme()

    enum CodingKeys: String, CodingKey { case id, name, items, paid = "pay", loans, cash, isSample = "sample", theme }

    init(id: String = UUID().uuidString, name: String) { self.id = id; self.name = name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "My budget"
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        paid = try c.decodeIfPresent([String: Pay].self, forKey: .paid) ?? [:]
        loans = try c.decodeIfPresent([Loan].self, forKey: .loans) ?? []
        cash = try c.decodeIfPresent(Cash.self, forKey: .cash) ?? Cash()
        isSample = try c.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? Theme()
    }
}

struct Library: Codable {
    var budgets: [Budget]
    var activeID: String
}

// MARK: - Calculations (a direct port of the web app's logic)

struct Occurrence { var key: String; var due: YMD? }

/// One bill or paycheck on one day of a month.
struct BillRow: Identifiable {
    var key: String
    var item: Item
    var due: YMD
    var pay: Pay?
    var id: String { key }
    var isPaid: Bool { pay != nil }
    var shownAmount: Double { pay?.amt ?? item.amount }
}

struct Step { var due: YMD; var name: String; var amt: Double; var income: Bool; var spend: Bool }

struct MonthStats {
    var billsTotal = 0
    var billsPaid = 0
    var billsLeft = 0.0
    var inExpected = 0.0
    var inReceived = 0.0
    var spent = 0.0
    var planned = 0.0
}

enum Health {
    case green, amber, red
    var title: String { self == .green ? "Green" : self == .amber ? "Amber" : "Red" }
    var color: Color { self == .green ? .green : self == .amber ? .orange : .red }
    var icon: String { self == .green ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
}

extension Budget {
    // MARK: Occurrences and rows

    func occurrences(of it: Item, in ym: YM) -> [Occurrence] {
        if it.type == .variable { return [Occurrence(key: "\(it.id)_\(ym.key)", due: nil)] }
        if it.biweekly, let a = it.anchor.flatMap({ YMD(iso: $0) }) {
            let first = ym.day(1).dayNumber, last = ym.day(ym.days).dayNumber, aN = a.dayNumber
            let n = Int((Double(first - aN) / 14).rounded(.up))
            var out: [Occurrence] = []
            var d = aN + n * 14
            while d <= last {
                let due = YMD(dayNumber: d)
                out.append(Occurrence(key: "\(it.id)_\(due.iso)", due: due))
                d += 14
            }
            return out
        }
        let due = ym.day(it.day ?? 1)
        return [Occurrence(key: "\(it.id)_\(due.iso)", due: due)]
    }

    func rows(in ym: YM) -> [BillRow] {
        var out: [BillRow] = []
        for it in items where it.type != .variable {
            for o in occurrences(of: it, in: ym) {
                guard let due = o.due else { continue }
                out.append(BillRow(key: o.key, item: it, due: due, pay: paid[o.key]))
            }
        }
        return out.sorted { a, b in
            if a.due != b.due { return a.due < b.due }
            return a.item.name < b.item.name
        }
    }

    func row(forKey key: String) -> BillRow? {
        guard let cut = key.lastIndex(of: "_"), let due = YMD(iso: String(key[key.index(after: cut)...])) else { return nil }
        return rows(in: due.ym).first { $0.key == key }
    }

    func spent(_ it: Item, in ym: YM) -> Double { max(0, paid["\(it.id)_\(ym.key)"]?.amt ?? 0) }

    func stats(in ym: YM) -> MonthStats {
        var s = MonthStats()
        for r in rows(in: ym) {
            if r.item.type == .income {
                s.inExpected += r.shownAmount
                if r.isPaid { s.inReceived += r.shownAmount }
            } else {
                s.billsTotal += 1
                if r.isPaid { s.billsPaid += 1 } else { s.billsLeft += r.item.amount }
            }
        }
        for it in items where it.type == .variable {
            s.planned += it.amount
            s.spent += spent(it, in: ym)
        }
        return s
    }

    // MARK: Everyday spending becomes steps: a dated item sits on its day, the rest one step a week

    private func spendSteps(in ym: YM, items vars: [Item]) -> [Step] {
        let today = YMD.today
        let nowIdx = today.ym.index, idx = ym.index
        var out: [Step] = []
        var pool: [Item] = []
        for it in vars {
            guard let day = it.day else { pool.append(it); continue }
            let sp = spent(it, in: ym)
            let passed = idx < nowIdx || (idx == nowIdx && day <= today.d)
            let amt = passed ? (sp > 0 ? sp : it.amount) : max(it.amount, sp)
            if amt > 0 { out.append(Step(due: ym.day(day), name: it.name, amt: -round2(amt), income: false, spend: true)) }
        }
        var planned = 0.0, spentTotal = 0.0
        for it in pool {
            let sp = spent(it, in: ym)
            spentTotal += sp
            planned += idx < nowIdx ? (sp > 0 ? sp : it.amount) : max(it.amount, sp)
        }
        if planned <= 0 { return out }
        let days = [7, 14, 21, 28].filter { $0 <= ym.days }
        func make(_ d: Int, _ amt: Double) -> Step {
            Step(due: ym.day(d), name: "Everyday spending", amt: -round2(amt), income: false, spend: true)
        }
        func spread(_ list: [Int], _ total: Double) -> [Step] {
            guard !list.isEmpty, total > 0 else { return [] }
            let raw = total / Double(list.count)
            let share = (raw * 100).rounded(.down) / 100
            let rest = round2(total - share * Double(list.count))
            return list.enumerated().map { make($0.element, share + ($0.offset == list.count - 1 ? rest : 0)) }
        }
        if idx != nowIdx { return out + spread(days, planned) }
        let w = planned / Double(days.count)
        let future = days.filter { $0 > today.d }
        var past = days.filter { $0 <= today.d }
        let pastTotal = max(spentTotal, w * Double(past.count))      // weeks that have passed: the plan, or what you spent if that is more
        if past.isEmpty && pastTotal > 0 { past = [today.d] }
        return out + spread(past, pastTotal) + spread(future, max(0, planned - pastTotal))
    }

    func steps(in ym: YM, cash c: Cash) -> [Step] {
        var rows: [Step] = []
        var vars: [Item] = []
        for it in items {
            if it.type == .variable { vars.append(it); continue }
            for o in occurrences(of: it, in: ym) {
                guard let due = o.due else { continue }
                let amt = paid[o.key]?.amt ?? it.amount
                rows.append(Step(due: due, name: it.name, amt: it.type == .income ? amt : -amt, income: it.type == .income, spend: false))
            }
        }
        if c.spend && !vars.isEmpty { rows += spendSteps(in: ym, items: vars) }
        return rows.sorted { a, b in
            if a.due != b.due { return a.due < b.due }
            if a.income != b.income { return a.income }
            return a.name < b.name
        }
    }

    // MARK: Cash flow

    enum StartKind { case set, carried, implied, unset }

    func actuals(in ym: YM, cash c: Cash, followOnly: Bool) -> [Actual] {
        if followOnly && !c.follow { return [] }
        return c.actuals.filter { $0.d.hasPrefix(ym.key) }.sorted { $0.d < $1.d }
    }

    /// A month's ending balance, given where it started and any chequing balances typed during it.
    func endFrom(_ v: Double, _ ym: YM, _ c: Cash) -> Double {
        let acts = actuals(in: ym, cash: c, followOnly: true)
        var run = v, ai = 0
        for r in steps(in: ym, cash: c) {
            while ai < acts.count && acts[ai].d < r.due.iso { run = acts[ai].v; ai += 1 }
            run += r.amt
        }
        while ai < acts.count { run = acts[ai].v; ai += 1 }
        return run
    }

    /// Typed for the month; else carried forward; else worked out from a chequing balance typed this month.
    func cashStart(_ ym: YM, _ c: Cash) -> (v: Double, kind: StartKind) {
        if let v = c.starts[ym.key] { return (v, .set) }
        func base(_ t: YM) -> Double? {
            if let v = c.starts[t.key] { return v }
            guard let last = actuals(in: t, cash: c, followOnly: true).last else { return nil }
            let before = steps(in: t, cash: c).filter { $0.due.iso <= last.d }.reduce(0.0) { $0 + $1.amt }
            return round2(last.v - before)
        }
        if c.carry {
            for back in 1...36 {
                let t = ym.adding(-back)
                guard var v = base(t) else { continue }
                var u = t
                while u < ym { v = endFrom(v, u, c); u = u.adding(1) }
                return (round2(v), .carried)
            }
        }
        if let b0 = base(ym) { return (b0, .implied) }
        return (0, .unset)
    }

    struct Col: Identifiable {
        enum Kind { case total, inc, dec, actual }
        var id: Int
        var kind: Kind
        var label: String
        var from: Double
        var to: Double
        var amt: Double
        var name: String
        var due: YMD?
        var spend: Bool
    }

    struct ActualMark { var d: YMD; var v: Double; var plan: Double; var diff: Double }

    struct CashModel {
        var startKind: StartKind
        var start: Double
        var cols: [Col]
        var marks: [ActualMark]
        var end: Double
        var low: Double
        var lowIndex: Int
        var warn: Double
        var real: Bool { startKind != .unset }
        var under: Bool { real && low < warn }
        var below0: Bool { real && low < 0 }
        /// The first step that dips under the low balance line, and the first one after it that climbs back over.
        var dip: (start: Col, back: Col?)? {
            guard under, let i = cols.dropLast().firstIndex(where: { $0.to < warn }) else { return nil }
            let back = cols[(i + 1)...].dropLast().first { $0.to >= warn }
            return (cols[i], back)
        }
    }

    func cashModel(_ ym: YM, cash override: Cash? = nil) -> CashModel {
        let c = override ?? cash
        let st = cashStart(ym, c)
        let rows = steps(in: ym, cash: c)
        let acts = actuals(in: ym, cash: c, followOnly: false)
        var cols: [Col] = [Col(id: 0, kind: .total, label: "Start", from: 0, to: st.v, amt: st.v, name: "Start", due: nil, spend: false)]
        var marks: [ActualMark] = []
        var run = st.v, low = st.v, lowAt = 0, ai = 0

        func take(before: String?) {          // chequing balances typed on a day: a marker and, if following, the forecast starts again from them
            while ai < acts.count {
                if let b = before, !(acts[ai].d < b) { break }
                let a = acts[ai]
                ai += 1
                let day = YMD(iso: a.d) ?? ym.day(1)
                let diff = round2(a.v - run)
                marks.append(ActualMark(d: day, v: a.v, plan: run, diff: diff))
                if c.follow {
                    cols.append(Col(id: cols.count, kind: .actual, label: "Now", from: run, to: a.v, amt: diff, name: "My balance", due: day, spend: false))
                    run = a.v
                    if run < low { low = run; lowAt = cols.count - 1 }
                }
            }
        }

        for r in rows {
            take(before: r.due.iso)
            let from = run
            run = round2(run + r.amt)
            cols.append(Col(id: cols.count, kind: r.amt > 0 ? .inc : .dec, label: String(r.due.d), from: from, to: run, amt: r.amt, name: r.name, due: r.due, spend: r.spend))
            if run < low { low = run; lowAt = cols.count - 1 }
        }
        take(before: nil)
        cols.append(Col(id: cols.count, kind: .total, label: "End", from: 0, to: run, amt: run, name: "End", due: nil, spend: false))
        return CashModel(startKind: st.kind, start: st.v, cols: cols, marks: marks, end: run, low: low, lowIndex: lowAt, warn: c.warn)
    }

    func cashNote(_ m: CashModel) -> (pill: String, text: String, health: Health) {
        guard m.real else { return ("Set starting balance", "Add your balance on the 1st, or your balance right now, to see where you land.", .amber) }
        var vs = ""
        if let last = m.marks.last, abs(last.diff) >= 1 { vs = " You are \(money(abs(last.diff))) \(last.diff > 0 ? "ahead of" : "behind") plan." }
        let lowCol = m.cols[m.lowIndex]
        let lowTxt = "\(money(m.low)) on \(lowCol.due?.short ?? "day 1")"
        if !m.under { return ("On track", "Ends at \(money(m.end)). Lowest is \(lowTxt).\(vs)", .green) }
        var until = " for the rest of the month"
        if let b = m.dip?.back, let d = b.due { until = " until \(b.name) on \(d.short)" }
        return (m.below0 ? "Below $0" : "Low balance", (m.below0 ? "Goes below $0: " : "Dips to ") + lowTxt + until + "." + vs, m.below0 ? .red : .amber)
    }

    func health(_ ym: YM) -> Health {
        let t = YMD.today
        let r = rows(in: ym)
        let overdue = r.filter { !$0.isPaid && $0.item.type == .bill && $0.due < t }.count
        let soon = r.filter { !$0.isPaid && $0.item.type == .bill && $0.due >= t && $0.due.dayNumber - t.dayNumber <= 3 }.count
        let m = cashModel(ym)
        let notPast = ym >= t.ym
        if overdue > 0 || (notPast && m.below0) { return .red }
        if soon > 0 || (notPast && m.under) { return .amber }
        return .green
    }

    // MARK: The explorer's day-by-day series

    struct SeriesPoint: Identifiable { var id: Int; var date: Date; var value: Double }
    struct SeriesStep: Identifiable {
        var id: Int
        var date: Date
        var before: Double
        var after: Double
        var name: String
        var amt: Double
        var spend: Bool
        var isActual: Bool
        var due: YMD
    }
    struct Series { var points: [SeriesPoint]; var steps: [SeriesStep]; var first: Date; var last: Date }

    func series(cash override: Cash? = nil) -> Series? {
        let c = override ?? cash
        let now = YM.current
        var first: YM? = nil
        for back in stride(from: 18, through: 0, by: -1) {
            let t = now.adding(-back)
            if cashModel(t, cash: c).startKind != .unset { first = t; break }
        }
        guard let f = first else { return nil }
        var pts: [SeriesPoint] = []
        var stp: [SeriesStep] = []
        func add(_ d: YMD, _ v: Double) {                   // one point per day: the last value of that day wins
            if let l = pts.last, l.date == d.date { pts[pts.count - 1].value = v } else { pts.append(SeriesPoint(id: pts.count, date: d.date, value: v)) }
        }
        var t = f
        while t <= now.adding(12) {
            let m = cashModel(t, cash: c)
            if m.startKind != .unset {
                add(t.day(1), m.start)
                for col in m.cols where col.kind != .total {
                    guard let due = col.due else { continue }
                    add(due, col.to)
                    stp.append(SeriesStep(id: stp.count, date: due.date, before: col.from, after: col.to, name: col.name, amt: round2(col.to - col.from), spend: col.spend, isActual: col.kind == .actual, due: due))
                }
                add(t.day(t.days), m.end)
            }
            t = t.adding(1)
        }
        guard let a = pts.first, let b = pts.last else { return nil }
        return Series(points: pts, steps: stp, first: a.date, last: b.date)
    }

    // MARK: Loans and cards that follow the bills you tick

    struct Linked { var key: String; var item: Item; var charge: Bool; var amt: Double; var date: String; var seen: Bool }
    struct LedgerStep { var before: Double; var after: Double }

    static func isLinked(_ l: Loan) -> Bool { l.payBill != nil || !l.accounts.isEmpty }
    private static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }

    func linkedRecords(_ l: Loan) -> [Linked] {
        let accs: Set<String> = l.isCard ? Set(l.accounts.map { Budget.norm($0) }.filter { !$0.isEmpty }) : []
        let seen = Set(l.seen)
        var out: [Linked] = []
        for (key, p) in paid {
            guard let it = items.first(where: { $0.id == p.item }), it.type == .bill else { continue }
            let isPay = l.payBill == it.id
            let isCharge = !isPay && !Budget.norm(it.account).isEmpty && accs.contains(Budget.norm(it.account))
            guard isPay || isCharge else { continue }
            out.append(Linked(key: key, item: it, charge: isCharge, amt: p.amt ?? it.amount, date: p.on ?? p.due ?? "", seen: seen.contains(key)))
        }
        return out.sorted { $0.date == $1.date ? $0.key < $1.key : $0.date < $1.date }
    }

    func ledger(_ l: Loan) -> (now: Double, steps: [String: LedgerStep]) {
        var bal = l.balance
        var steps: [String: LedgerStep] = [:]
        for r in linkedRecords(l) where !r.seen {
            let before = bal
            if r.charge { bal += r.amt }
            else if l.isCard { bal = max(0, bal - r.amt) }
            else {
                let rate = l.apr ?? 0
                let interest = rate > 0 ? round2(bal * rate / 1200) : 0
                bal = max(0, bal - (r.amt - interest))
            }
            bal = round2(bal)
            steps[r.key] = LedgerStep(before: before, after: bal)
        }
        return (bal, steps)
    }

    /// Loans with their balance worked out from the bills ticked since it was last checked.
    var liveLoans: [Loan] {
        loans.map { l in
            var x = l
            x.balance = ledger(l).now
            if let pb = l.payBill, let it = items.first(where: { $0.id == pb }) { x.payment = it.amount }
            return x
        }
    }

    /// "This is the balance as of today": bills already paid are treated as inside it.
    func rebased(_ l: Loan, balance: Double) -> Loan {
        var x = l
        x.balance = round2(balance)
        if Budget.isLinked(x) {
            var probe = x
            probe.seen = []
            x.asOf = YMD.today.iso
            x.seen = linkedRecords(probe).map { $0.key }
        }
        return x
    }

    /// The small line under a bill that says what it does to a loan or card.
    func effect(for it: Item, key: String, isPaid: Bool) -> String? {
        guard it.type == .bill else { return nil }
        for l in loans where Budget.isLinked(l) {
            let pays = l.payBill == it.id
            let charges = l.isCard && !Budget.norm(it.account).isEmpty && l.accounts.contains { Budget.norm($0) == Budget.norm(it.account) }
            guard pays || charges else { continue }
            if isPaid {
                guard let st = ledger(l).steps[key] else { continue }
                return "\(l.name): \(money(st.before)) → \(money(st.after))"
            }
            return "When paid: \(l.name) goes \(pays ? "down" : "up") by \(money(it.amount))"
        }
        return nil
    }

    /// How far ahead of or behind the plan a chequing balance entry was.
    func diff(for a: Actual) -> Double? {
        guard let d = YMD(iso: a.d) else { return nil }
        let m = cashModel(d.ym)
        guard m.startKind != .unset, let mk = m.marks.first(where: { $0.d == d }), abs(mk.diff) >= 1 else { return nil }
        return mk.diff
    }

    func billItems() -> [Item] { items.filter { $0.type == .bill }.sorted { $0.name < $1.name } }

    func accountLabels() -> [String] {
        var seen = Set<String>(), out: [String] = []
        for it in items where it.type == .bill {
            let a = it.account.trimmingCharacters(in: .whitespaces)
            if !a.isEmpty && !seen.contains(a.lowercased()) { seen.insert(a.lowercased()); out.append(a) }
        }
        return out.sorted()
    }
}

// MARK: - Easy mode helpers (the same plain words as the web app)

/// "Due Fri, Nov 27", "Due tomorrow", "Late. It was due Sun, Nov 1" ...
func easyWhen(_ due: YMD, income: Bool) -> (text: String, late: Bool, soon: Bool) {
    let d = due.dayNumber - YMD.today.dayNumber
    if income {
        if d < 0 { return ("Not received yet. It was expected \(due.nice)", false, true) }
        if d == 0 { return ("Expected today", false, true) }
        if d == 1 { return ("Expected tomorrow", false, false) }
        return ("Expected \(due.nice)", false, false)
    }
    if d < -1 { return ("Late. It was due \(due.nice)", true, false) }
    if d == -1 { return ("Late. It was due yesterday", true, false) }
    if d == 0 { return ("Due today", false, true) }
    if d == 1 { return ("Due tomorrow", false, true) }
    return ("Due \(due.nice)", false, d <= 3)
}

extension Budget {
    /// The bill to do next: the oldest late one, else the next unpaid one that does not pay itself.
    func easyNext(in ym: YM) -> (late: [BillRow], next: BillRow?) {
        let t = YMD.today
        let needs = rows(in: ym).filter { !$0.isPaid && $0.item.type == .bill && !$0.item.automatic }
        let late = needs.filter { $0.due < t }
        return (late, late.first ?? needs.first { $0.due >= t })
    }

    /// How the account looks, in plain words. Nil when no balance is set yet.
    func easyAccount(_ m: CashModel) -> (headline: String, detail: String, health: Health)? {
        guard m.real else { return nil }
        let lowCol = m.cols[m.lowIndex]
        let when = lowCol.due.map { "on \($0.short)" } ?? "early in the month"
        var until = ""
        if let b = m.dip?.back, let d = b.due { until = " until \(b.name) on \(d.short)" }
        if m.below0 { return ("You may run short", "Your balance could go below $0 (\(money(m.low))) \(when)\(until).", .red) }
        if m.under { return ("Watch your balance", "It gets low, about \(money(m.low)), \(when)\(until).", .amber) }
        return ("You should be fine", "About \(money(m.end)) should be left at the end of the month.", .green)
    }
}

extension Budget {
    /// Easy mode: "Paying this lowers your Car loan." for a bill that moves a loan or card.
    func linkWords(for it: Item) -> String? {
        guard it.type == .bill else { return nil }
        for l in loans where Budget.isLinked(l) {
            if l.payBill == it.id { return "Paying this lowers your \(l.name)." }
            let acct = it.account.trimmingCharacters(in: .whitespaces).lowercased()
            if l.isCard && !acct.isEmpty && l.accounts.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == acct }) { return "This is charged to your \(l.name)." }
        }
        return nil
    }
}

// MARK: - The cash flow chart's vertical scale

/// A tidy vertical scale: even steps (1, 2, 2.5 or 5 times a power of ten), with the first and last tick as the chart's edges.
struct ChartAxis: Equatable {
    var lo: Double
    var hi: Double
    var step: Double
    var ticks: [Double] {
        let n = max(1, Int(((hi - lo) / step).rounded()))
        return (0...n).map { lo + Double($0) * step }
    }
}

func niceStep(_ raw: Double) -> Double {
    guard raw > 0, raw.isFinite else { return 100 }
    let mag = pow(10, floor(log10(raw)))
    for m in [1.0, 2.0, 2.5, 5.0, 10.0] where m * mag >= raw - 1e-9 { return m * mag }
    return 10 * mag
}

/// The vertical scale for the part of the chart that is on screen.
/// - values: every balance that is on screen (the line, the old plan, the balances you typed, the bars)
/// - warn: the low balance line; it is kept in view when it is close to the balance, and left out when it is far away
/// - fixedSpan: 0 fits what you see; otherwise the chart is exactly that many dollars tall, centred on what you see
func chartAxis(values: [Double], warn: Double, fixedSpan: Double = 0) -> ChartAxis {
    let vmin = values.min(), vmax = values.max()
    if fixedSpan > 0 {
        let mid = (vmin != nil && vmax != nil) ? (vmin! + vmax!) / 2 : fixedSpan / 2 - fixedSpan / 10
        let step = fixedSpan / 5
        let lo = ((mid - fixedSpan / 2) / step).rounded(.down) * step
        return ChartAxis(lo: lo, hi: lo + fixedSpan, step: step)
    }
    var lo = vmin ?? 0
    var hi = vmax ?? 2000
    let slack = max(hi - lo, 500)
    if warn >= lo - slack && warn <= hi + slack { lo = min(lo, warn); hi = max(hi, warn) }       // keep the low-balance line in view when it is near
    if lo > 0 && lo < (hi - lo) * 0.5 { lo = 0 }                                                   // show the $0 line when the balance is near it
    let atZero = lo == 0
    if hi - lo < 500 { let mid = (hi + lo) / 2; lo = mid - 250; hi = mid + 250 }                    // a flat line does not zoom in absurdly far
    let pad = (hi - lo) * 0.06
    if !atZero { lo -= pad }
    hi += pad
    let step = niceStep((hi - lo) / 5)
    lo = (lo / step).rounded(.down) * step
    hi = (hi / step).rounded(.up) * step
    return ChartAxis(lo: lo, hi: hi, step: step)
}

// MARK: - The three gauges on Overview

enum GaugeKind { case bills, moneyIn, spending }

struct GaugeFigure: Identifiable {
    var kind: GaugeKind
    var title: String
    var fraction: Double                // 0 to 1, and above 1 when spending is over the plan
    var center: String                  // what is written inside: "11/13", "100%"
    var detail: String                  // a plain-words line: "$735 to pay", "All received", "$220 left"
    var over = false
    var empty = false                   // nothing to measure yet
    var id: String { title }
    var spoken: String { "\(title): \(center). \(detail)" }
}

func gaugeFigures(_ s: MonthStats) -> [GaugeFigure] {
    func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
    let billsFrac = s.billsTotal == 0 ? 0.0 : Double(s.billsPaid) / Double(s.billsTotal)
    let inFrac = s.inExpected == 0 ? 0.0 : s.inReceived / s.inExpected
    let spendFrac = s.planned == 0 ? 0.0 : s.spent / s.planned
    let toCome = s.inExpected - s.inReceived
    return [
        GaugeFigure(kind: .bills, title: "Bills", fraction: billsFrac,
                    center: s.billsTotal == 0 ? "–" : "\(s.billsPaid)/\(s.billsTotal)",
                    detail: s.billsTotal == 0 ? "No bills" : (s.billsLeft >= 0.5 ? "\(money(s.billsLeft, whole: true)) to pay" : "All paid"),
                    empty: s.billsTotal == 0),
        GaugeFigure(kind: .moneyIn, title: "Money in", fraction: inFrac,
                    center: s.inExpected == 0 ? "–" : percent(inFrac),
                    detail: s.inExpected == 0 ? "No money in" : (toCome >= 0.5 ? "\(money(toCome, whole: true)) to come" : "All received"),
                    empty: s.inExpected == 0),
        GaugeFigure(kind: .spending, title: "Spending", fraction: spendFrac,
                    center: s.planned == 0 ? "–" : percent(spendFrac),
                    detail: s.planned == 0 ? "No budget" : (s.spent > s.planned + 0.5 ? "\(money(s.spent - s.planned, whole: true)) over" : "\(money(max(0, s.planned - s.spent), whole: true)) left"),
                    over: s.planned > 0 && s.spent > s.planned + 0.5,
                    empty: s.planned == 0)
    ]
}

// MARK: - The store: saving, automatic payments, and every change the screens make

enum SheetKind: Identifiable {
    case item(Item?)            // nil = a new item
    case startBalance
    case loan(Loan?)            // nil = a new loan or card
    case importBackup
    case theme                  // Wallpaper and colors
    case manageBudgets
    case allItems               // Edit items
    case about
    case restore                // asks how to restore a backup file

    var id: String {
        switch self {
        case .item(let i): return "item-\(i?.id ?? "new")"
        case .startBalance: return "start"
        case .loan(let l): return "loan-\(l?.id ?? "new")"
        case .importBackup: return "import"
        case .theme: return "theme"
        case .manageBudgets: return "budgets"
        case .allItems: return "items"
        case .about: return "about"
        case .restore: return "restore"
        }
    }
}

enum AppInfo {
    /// "2.0 (12)": the version, and the build number Xcode Cloud gave this build.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "2.0"
        guard let b = info?["CFBundleVersion"] as? String else { return v }
        return "\(v) (\(b))"
    }
}

@MainActor
@Observable
final class BudgetStore {
    var library: Library
    var viewing: YM = .current
    var sheet: SheetKind?
    var toast: String?
    var revision = 0                                  // goes up on every change, so the charts know to redraw
    var pendingRestore: PendingRestore?               // a backup that was read and is waiting for the person to say how to restore it
    var showRestorePicker = false                     // asks the app to show the file picker
    var menuOpen = false                              // the slide-out menu on the left
    var detailDepth = 0                               // how many screens are pushed, so the menu's edge swipe stays out of the way

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL

    init() {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "tapbudget.json")
        fileURL = url
        if let data = try? Data(contentsOf: url), let lib = try? JSONDecoder().decode(Library.self, from: data), !lib.budgets.isEmpty {
            library = lib
        } else {
            if FileManager.default.fileExists(atPath: url.path) {      // a file that cannot be read is kept, never silently overwritten
                let keep = dir.appending(path: "tapbudget-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: url, to: keep)
            }
            let b = Budget.example()
            library = Library(budgets: [b], activeID: b.id)
        }
        applyAutoPay()
    }

    // MARK: Active budget

    private var activeIndex: Int { library.budgets.firstIndex { $0.id == library.activeID } ?? 0 }

    var budget: Budget {
        get { library.budgets[activeIndex] }
        set { library.budgets[activeIndex] = newValue }
    }

    func update(_ change: (inout Budget) -> Void) {
        var b = budget
        change(&b)
        budget = b
        save()
    }

    func save() {
        revision += 1
        if let data = try? JSONEncoder().encode(library) { try? data.write(to: fileURL, options: .atomic) }
    }

    func say(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Budgets

    func switchBudget(_ id: String) { library.activeID = id; save() }

    func addBudget(named name: String) {
        var b = Budget(name: name.isEmpty ? "New budget" : name)
        b.theme = budget.theme                         // a new budget starts with the look that was showing
        b.theme.wallpaper = WallpaperSettings()
        library.budgets.append(b)
        library.activeID = b.id
        save()
    }

    func addExample() {
        let b = Budget.example()
        library.budgets.append(b)
        library.activeID = b.id
        save()
    }

    func renameBudget(_ name: String) { update { $0.name = name.isEmpty ? $0.name : name } }

    func deleteBudget() { deleteBudget(id: library.activeID) }

    func deleteBudget(id: String) {
        guard library.budgets.count > 1 else { return }
        library.budgets.removeAll { $0.id == id }
        if !library.budgets.contains(where: { $0.id == library.activeID }) { library.activeID = library.budgets[0].id }
        save()
    }

    func setTheme(_ change: (inout Theme) -> Void) { update { change(&$0.theme) } }


    // MARK: Items and payments

    func upsert(_ item: Item) {
        update { b in
            if let i = b.items.firstIndex(where: { $0.id == item.id }) { b.items[i] = item }
            else { var n = item; n.order = (b.items.map { $0.order }.max() ?? 0) + 1; b.items.append(n) }
        }
    }

    func delete(_ item: Item) {
        update { b in
            // loans that followed this bill keep their balance where it was
            let keep = b.loans.filter { Budget.isLinked($0) }.map { ($0.id, b.ledger($0).now) }
            b.items.removeAll { $0.id == item.id }
            b.paid = b.paid.filter { $0.value.item != item.id }
            b.loans = b.loans.map { l in
                var x = l
                if x.payBill == item.id { x.payBill = nil }
                if let k = keep.first(where: { $0.0 == l.id }) { return b.rebased(x, balance: k.1) }
                return x
            }
        }
    }

    func setPaid(_ row: BillRow, _ on: Bool) {
        update { b in
            if on { b.paid[row.key] = Pay(item: row.item.id, due: row.due.iso, on: YMD.today.iso, amt: row.item.amount) }
            else { b.paid[row.key] = nil }
        }
        if on, let line = budget.effect(for: row.item, key: row.key, isPaid: true) { say(line) }
    }

    func setPayDate(_ key: String, _ day: YMD) {
        update { b in if var p = b.paid[key] { p.on = day.iso; b.paid[key] = p } }
    }

    func setPayAmount(_ key: String, _ amount: Double) {
        update { b in if var p = b.paid[key] { p.amt = max(0, amount); b.paid[key] = p } }
    }

    func setSpent(_ item: Item, _ amount: Double) {
        let key = "\(item.id)_\(viewing.key)"
        update { b in
            if amount <= 0 { b.paid[key] = nil }
            else { b.paid[key] = Pay(item: item.id, due: nil, on: b.paid[key]?.on ?? YMD.today.iso, amt: amount) }
        }
    }

    /// Automatic bills mark themselves paid on their due day, from the day they were switched on.
    func applyAutoPay() {
        let today = YMD.today
        var b = budget
        var changed = false
        for it in b.items where it.automatic && it.type != .variable {
            guard let since = it.autoSince.flatMap({ YMD(iso: $0) }) else { continue }
            var t = YM(index: max(since.ym.index, today.ym.index - 60))
            while t <= today.ym {
                for o in b.occurrences(of: it, in: t) {
                    guard let due = o.due, due >= since, due <= today, b.paid[o.key] == nil else { continue }
                    b.paid[o.key] = Pay(item: it.id, due: due.iso, on: due.iso, amt: it.amount)
                    changed = true
                }
                t = t.adding(1)
            }
        }
        if changed { budget = b; save() }
    }

    // MARK: Cash flow settings

    func addActual(_ value: Double, on day: YMD) {
        update { b in
            b.cash.actuals.removeAll { $0.d == day.iso }
            b.cash.actuals.append(Actual(d: day.iso, v: round2(value)))
            b.cash.actuals.sort { $0.d < $1.d }
            if b.cash.actuals.count > 90 { b.cash.actuals.removeFirst(b.cash.actuals.count - 90) }
            b.isSample = false
        }
    }

    func removeActual(_ a: Actual) { update { $0.cash.actuals.removeAll { $0.d == a.d } } }

    // MARK: Loans and cards

    func upsert(_ loan: Loan) {
        update { b in
            if let i = b.loans.firstIndex(where: { $0.id == loan.id }) { b.loans[i] = loan } else { b.loans.append(loan) }
        }
    }

    func delete(_ loan: Loan) { update { $0.loans.removeAll { $0.id == loan.id } } }

    func checkIn(_ loan: Loan, balance: Double) {
        update { b in
            guard let i = b.loans.firstIndex(where: { $0.id == loan.id }) else { return }
            b.loans[i] = b.rebased(b.loans[i], balance: balance)
        }
        say("\(loan.name) is now \(money(balance)).")
    }

    // MARK: Backup (the web app's JSON)

    private struct Backup: Decodable {
        var name: String?
        var items: [Item]?
        var pay: [String: Pay]?
        var loans: [Loan]?
        var cash: Cash?
        var budgets: [Backup]?            // only in an "all budgets" file
    }

    func exportJSON() -> String {
        struct Out: Encodable { var app = "budget-tracker"; var version = 2; var name: String; var items: [Item]; var pay: [String: Pay]; var loans: [Loan]; var cash: Cash }
        let b = budget
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(Out(name: b.name, items: b.items, pay: b.paid, loans: b.loans, cash: b.cash)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Everything in every budget, in one file. Each budget is in the same shape as a normal backup.
    func exportAllJSON() -> String {
        struct One: Encodable { var name: String; var items: [Item]; var pay: [String: Pay]; var loans: [Loan]; var cash: Cash }
        struct Out: Encodable { var app = "budget-tracker"; var version = 2; var kind = "all-budgets"; var budgets: [One] }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let all = library.budgets.map { One(name: $0.name, items: $0.items, pay: $0.paid, loans: $0.loans, cash: $0.cash) }
        guard let data = try? e.encode(Out(budgets: all)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A backup file in the temporary folder, ready to share. Named like the web app's: budget-name-2026-11-24.json
    func backupFileURL(all: Bool = false) -> URL? {
        let name = all ? "tapbudget-all-budgets" : "budget-\(Budget.slug(budget.name))"
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(YMD.today.iso).json")
        do { try (all ? exportAllJSON() : exportJSON()).write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    // MARK: Restore

    /// Reads a backup: one budget, or an "all budgets" file. Nil if it is not a backup.
    func readBackup(_ text: String, fileName: String) -> PendingRestore? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let file = try? JSONDecoder().decode(Backup.self, from: data) else { return nil }
        var parts: [PendingRestore.Part] = []
        for (n, p) in (file.budgets ?? [file]).enumerated() {
            let items = p.items ?? []
            let loans = p.loans ?? []
            if items.isEmpty && loans.isEmpty { continue }
            let clean = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var b = Budget(name: clean.isEmpty ? Budget.nameFromFile(fileName, number: n + 1) : String(clean.prefix(60)))
            b.items = items
            b.paid = p.pay ?? [:]
            b.loans = loans
            b.cash = p.cash ?? Cash()
            parts.append(PendingRestore.Part(budget: b, hasLoans: p.loans != nil, hasCash: p.cash != nil))
        }
        return parts.isEmpty ? nil : PendingRestore(parts: parts, fileName: fileName)
    }

    /// Reads a backup and asks how to restore it. Returns an error message, or nil if the question is showing.
    func stageRestore(_ text: String, fileName: String) -> String? {
        guard let p = readBackup(text, fileName: fileName) else { return "That does not look like a TapBudget backup." }
        pendingRestore = p
        sheet = .restore
        return nil
    }

    /// Adds a backup as a new budget straight away. Returns an error message, or nil if it worked.
    func importBackup(_ text: String) -> String? {
        guard let p = readBackup(text, fileName: "") else { return "That does not look like a TapBudget backup." }
        applyRestore(p, mode: .addNew)
        return nil
    }

    func uniqueName(_ wanted: String, among taken: [String]) -> String {
        let lower = taken.map { $0.lowercased() }
        let base = wanted.trimmingCharacters(in: .whitespaces).isEmpty ? "Imported budget" : wanted.trimmingCharacters(in: .whitespaces)
        if !lower.contains(base.lowercased()) { return base }
        var n = 2
        while lower.contains("\(base) (\(n))".lowercased()) { n += 1 }
        return "\(base) (\(n))"
    }

    /// Does what the person chose. Returns a sentence saying what happened.
    @discardableResult
    func applyRestore(_ p: PendingRestore, mode: RestoreMode, into targetID: String? = nil, newName: String? = nil) -> String {
        defer { pendingRestore = nil }
        if mode != .addNew, let i = library.budgets.firstIndex(where: { $0.id == targetID }), let part = p.parts.first {
            var b = library.budgets[i]
            let incoming = part.budget
            if mode == .replace {
                b.items = incoming.items
                b.paid = incoming.paid
                if part.hasLoans { b.loans = incoming.loans }
                if part.hasCash { b.cash = incoming.cash }
            } else {
                // merge: add and update, keep the rest. The backup wins where both have the same id or date.
                var items = b.items
                for it in incoming.items {
                    if let k = items.firstIndex(where: { $0.id == it.id }) { items[k] = it } else { items.append(it) }
                }
                b.items = items
                b.paid.merge(incoming.paid) { _, new in new }
                if part.hasLoans {
                    var loans = b.loans
                    for l in incoming.loans {
                        if let k = loans.firstIndex(where: { $0.id == l.id }) { loans[k] = l } else { loans.append(l) }
                    }
                    b.loans = loans
                }
                if part.hasCash {
                    var cash = incoming.cash
                    cash.starts = b.cash.starts.merging(incoming.cash.starts) { _, new in new }
                    var byDay: [String: Actual] = [:]
                    for a in b.cash.actuals { byDay[a.d] = a }
                    for a in incoming.cash.actuals { byDay[a.d] = a }
                    cash.actuals = Array(byDay.values.sorted { $0.d < $1.d }.suffix(90))
                    b.cash = cash
                }
            }
            b.isSample = false
            library.budgets[i] = b
            library.activeID = b.id
            save()
            return "Restored into “\(b.name)” (\(b.items.count) items)."
        }
        // add as new budgets
        let look = budget.theme                                      // a new budget starts with the look that was showing
        let loneExample = library.budgets.count == 1 && library.budgets[0].isSample ? library.budgets[0].id : nil
        var firstID: String?
        var added: [String] = []
        for (n, part) in p.parts.enumerated() {
            var b = part.budget
            let wanted = n == 0 ? (newName ?? "").trimmingCharacters(in: .whitespaces) : ""
            b.name = uniqueName(wanted.isEmpty ? b.name : wanted, among: library.budgets.map(\.name))
            b.theme = look
            b.theme.wallpaper = WallpaperSettings()
            library.budgets.append(b)
            firstID = firstID ?? b.id
            added.append(b.name)
        }
        if let loneExample { library.budgets.removeAll { $0.id == loneExample } }
        if let firstID { library.activeID = firstID }
        save()
        return added.count == 1 ? "Added “\(added[0])”." : "Added \(added.count) budgets."
    }
}

// MARK: - The example budget

extension Budget {
    static func example() -> Budget {
        let today = YMD.today
        var b = Budget(name: "Example budget")
        b.isSample = true
        let weekday = Calendar.current.component(.weekday, from: Date())      // 1 = Sunday
        let backToFriday = (weekday + 1) % 7
        let anchor = today.adding(days: -backToFriday)
        let since = YM.current.adding(-2).day(1).iso
        func bill(_ n: Int, _ id: String, _ name: String, _ amount: Double, _ day: Int, _ account: String, auto: Bool = false) -> Item {
            Item(id: "sample-\(id)", name: name, type: .bill, amount: amount, account: account, day: day, automatic: auto, autoSince: auto ? since : nil, order: n)
        }
        func spend(_ n: Int, _ id: String, _ name: String, _ amount: Double) -> Item {
            Item(id: "sample-\(id)", name: name, type: .variable, amount: amount, account: "Chequing", order: n)
        }
        b.items = [
            Item(id: "sample-pay", name: "Paycheck", type: .income, amount: 2150, account: "Chequing", biweekly: true, anchor: anchor.iso, order: 1),
            bill(2, "rent", "Rent", 1350, 1, "E-transfer"),
            bill(3, "streaming", "Streaming", 18, 5, "Credit card"),
            bill(4, "power", "Electricity", 95, 8, "Auto-pay", auto: true),
            bill(5, "gym", "Gym", 30, 10, "Credit card"),
            bill(6, "internet", "Internet", 65, 12, "Credit card"),
            bill(7, "phone", "Phone", 55, 15, "Credit card"),
            bill(8, "car", "Car insurance", 140, 20, "Auto-pay", auto: true),
            bill(9, "savings", "Savings transfer", 150, 21, "Chequing"),
            bill(10, "card", "Credit card payment", 200, 25, "Chequing"),
            bill(15, "carloan", "Car loan payment", 385, 27, "Chequing"),
            bill(16, "studentloan", "Student loan payment", 150, 26, "Chequing"),
            spend(11, "groceries", "Groceries", 450),
            spend(12, "gas", "Gas", 120),
            spend(13, "dining", "Dining out", 150),
            spend(14, "fun", "Fun money", 80)
        ]
        // two months of history: everything due before today is paid, and everyday spending is mostly spent
        for back in stride(from: 2, through: 0, by: -1) {
            let ym = YM.current.adding(-back)
            for it in b.items {
                for o in b.occurrences(of: it, in: ym) {
                    if it.type == .variable {
                        let fraction = back == 0 ? 0.9 * Double(today.d) / Double(ym.days) : 0.88
                        b.paid[o.key] = Pay(item: it.id, due: nil, on: today.iso, amt: round2(it.amount * fraction))
                    } else if let due = o.due, due < today {
                        b.paid[o.key] = Pay(item: it.id, due: due.iso, on: due.iso, amt: it.amount)
                    }
                }
            }
        }
        b.cash.starts[YM.current.key] = 1700
        b.loans = [
            Loan(id: "sample-loan-car", name: "Car loan", isCard: false, total: 18000, balance: 11250, payment: 385, payBill: "sample-carloan"),
            Loan(id: "sample-loan-school", name: "Student loan", isCard: false, total: 9000, balance: 3900, payment: 150, payBill: "sample-studentloan"),
            Loan(id: "sample-card-visa", name: "Rewards Visa", isCard: true, total: 6000, balance: 1850, payment: 200, payBill: "sample-card", accounts: ["Credit card"]),
            Loan(id: "sample-card-store", name: "Store card", isCard: true, total: 2500, balance: 2050, payment: 50)
        ]
        b.loans = b.loans.map { b.rebased($0, balance: $0.balance) }       // the history above is already inside these balances
        return b
    }
}

// MARK: - Backup and restore: types

/// A backup that has been read but not applied yet. The app shows what is in it and asks how to restore it.
struct PendingRestore: Identifiable {
    struct Part {
        var budget: Budget
        var hasLoans: Bool          // the file had a loans list, so it may replace the loans
        var hasCash: Bool           // the file had balances, so it may replace the balances
    }
    let id = UUID()
    var parts: [Part]
    var fileName: String
    var budgets: [Budget] { parts.map(\.budget) }
}

enum RestoreMode { case addNew, replace, merge }

extension Budget {
    /// "Rent and bills" -> "rent-and-bills" (the web app's file names)
    static func slug(_ name: String) -> String {
        var out = ""
        var lastDash = true
        for ch in name.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "budget" : String(out.prefix(40))
    }

    /// "budget-family-2026-11-24.json" -> "Family" (when a backup has no name inside it)
    static func nameFromFile(_ file: String, number: Int = 1) -> String {
        var t = file
        if t.lowercased().hasSuffix(".json") { t.removeLast(5) }
        if t.lowercased().hasPrefix("budget-") { t.removeFirst(7) }
        t = t.replacingOccurrences(of: "-[0-9]{4}-[0-9]{2}-[0-9]{2}$", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return number > 1 ? "Imported budget \(number)" : "Imported budget" }
        return t.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: - Shared look: Liquid Glass on the controls that float, plain cards for the content

struct Backdrop: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.palette) private var palette

    var body: some View {
        let w = store.budget.theme.wallpaper
        ZStack {
            LinearGradient(colors: [palette.brand.opacity(0.30), palette.brand.opacity(0.10), Color(uiColor: .systemBackground)],
                           startPoint: .top, endPoint: .center)
            if let name = w.fileName, let img = WallpaperFiles.image(name) {
                Color.clear
                    .overlay(Image(uiImage: img).resizable().scaledToFill().blur(radius: w.blur))
                    .clipped()
                    .overlay(Color.black.opacity(w.dim))
            }
        }
        .ignoresSafeArea()
    }
}

struct CardSurface: ViewModifier {
    let glass: Bool
    @Environment(\.palette) private var palette
    @ViewBuilder func body(content: Content) -> some View {
        if glass {
            content.surface(RoundedRectangle(cornerRadius: 26))
        } else {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var glass: Bool
    let content: Content

    init(title: String? = nil, glass: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.glass = glass
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardSurface(glass: glass))
    }
}

struct HealthPill: View {
    @Environment(BudgetStore.self) private var store
    var body: some View {
        let h = store.budget.health(store.viewing)
        Label(h.title, systemImage: h.icon)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .surface(Capsule(), tint: h.color.opacity(0.35))
    }
}

struct MonthBar: View {
    @Environment(BudgetStore.self) private var store
    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    Button { store.viewing = store.viewing.adding(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Previous month")
                    Text(store.viewing.title)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(minWidth: 100)
                    Button { store.viewing = store.viewing.adding(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Next month")
                }
                .buttonStyle(.plain)
                .padding(4)
                .surface(Capsule())
                Button("Today") { store.viewing = .current }
                    .themedButton()
                HealthPill()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background {
            // frosted, fading out below, so what scrolls underneath never shows through the pills.
            // It is as wide as the screen and stays inside the bar's own space, so it never covers the title above it.
            Rectangle()
                .fill(.regularMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .padding(.bottom, -14)
                .allowsHitTesting(false)
        }
    }
}

struct BudgetChrome: ViewModifier {
    let title: String
    var showsMonth = true
    @Environment(BudgetStore.self) private var store

    @ViewBuilder func body(content: Content) -> some View {
        let screen = content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { store.menuOpen = true } label: { Label("Menu", systemImage: "line.3.horizontal") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.sheet = .item(nil) } label: { Label("Add an item", systemImage: "plus") }
                }
            }
        if showsMonth {
            screen.safeAreaInset(edge: .top, spacing: 0) { MonthBar() }
        } else {
            screen
        }
    }
}

extension View {
    func budgetChrome(_ title: String, month: Bool = true) -> some View { modifier(BudgetChrome(title: title, showsMonth: month)) }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .surface(Capsule())
            .padding(.bottom, 96)
            .padding(.horizontal, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Root: the full app (five tabs, always all visible, because the iOS 27 SDK crashes if a TabView selection points at a hidden tab)
// or Easy mode (four big buttons). The slide-out menu sits on top of the full app.

enum AppTab: Hashable { case overview, bills, spending, insights, settings }

enum SchemeChoice: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

struct ContentView: View {
    @Environment(BudgetStore.self) private var store
    @AppStorage("schemeChoice") private var schemeChoice: SchemeChoice = .auto
    @AppStorage("easyMode") private var easyMode = false

    var body: some View {
        @Bindable var store = store
        let palette = Palette(store.budget.theme)
        ZStack {
            if easyMode { EasyRoot() } else { FullTabs() }
        }
        .overlay { if !easyMode { MenuOverlay() } }
        .overlay(alignment: .bottom) {
            if let text = store.toast { ToastView(text: text) }
        }
        .animation(.snappy, value: store.toast)
        .themed(palette)
        .preferredColorScheme(schemeChoice.scheme)
        .sheet(item: $store.sheet) { kind in
            SheetRouter(kind: kind)
                .themed(palette)
                .preferredColorScheme(schemeChoice.scheme)
        }
        .fileImporter(isPresented: $store.showRestorePicker, allowedContentTypes: [.json, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                store.say("Could not read that file.")
                return
            }
            let fileName = url.lastPathComponent
            Task {
                try? await Task.sleep(for: .milliseconds(450))          // let the picker finish closing before the question opens
                if let e = store.stageRestore(text, fileName: fileName) { store.say(e) }
            }
        }
    }
}

struct FullTabs: View {
    @Environment(BudgetStore.self) private var store
    @State private var tab: AppTab = .overview

    var body: some View {
        TabView(selection: $tab) {
            Tab("Overview", systemImage: "gauge.with.dots.needle.50percent", value: AppTab.overview) {
                OverviewTab(go: { tab = $0 })
            }
            Tab("Bills", systemImage: "list.bullet.rectangle", value: AppTab.bills) {
                BillsTab()
            }
            Tab("Spending", systemImage: "creditcard", value: AppTab.spending) {
                SpendingTab()
            }
            Tab("Insights", systemImage: "chart.xyaxis.line", value: AppTab.insights) {
                InsightsTab()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsTab()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .leading) { edgeStrip }
    }

    /// A thin strip on the left edge: swipe right from it to open the menu (not while a detail screen is open, where the same swipe means "back").
    @ViewBuilder private var edgeStrip: some View {
        if store.detailDepth == 0 && !store.menuOpen {
            Color.clear
                .frame(width: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 12).onEnded { v in
                    if v.translation.width > 40 { store.menuOpen = true }
                })
        }
    }
}

struct SheetRouter: View {
    let kind: SheetKind
    var body: some View {
        switch kind {
        case .item(let item): ItemForm(editing: item)
        case .startBalance: StartBalanceSheet()
        case .loan(let loan): LoanForm(editing: loan)
        case .importBackup: ImportSheet()
        case .theme: ThemeSheet()
        case .manageBudgets: ManageBudgetsSheet()
        case .allItems: ItemsListSheet()
        case .about: AboutSheet()
        case .restore: RestoreSheet()
        }
    }
}

// MARK: - Overview

struct OverviewTab: View {
    var go: (AppTab) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GaugeStrip()
                    CashFlowCard { go(.insights) }
                    MonthSummaryCard()
                    LoansCard()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background { Backdrop() }
            .budgetChrome("Overview")
        }
    }
}

struct WaterfallChart: View {
    let model: Budget.CashModel
    @Environment(\.palette) private var palette

    private func color(_ c: Budget.Col) -> Color {
        switch c.kind {
        case .total: return palette.brand
        case .actual: return .primary
        case .inc: return .green
        case .dec: return c.spend ? .orange : .purple
        }
    }

    var body: some View {
        let count = model.cols.count
        let step = max(1, count / 9)
        let labelIDs = model.cols.filter { $0.kind == .total || $0.kind == .actual || $0.id % step == 0 }.map { $0.id }
        let barWidth = max(5, min(14, 300 / CGFloat(max(1, count))))
        Chart {
            ForEach(model.cols) { c in
                BarMark(x: .value("Step", c.id), yStart: .value("From", c.from), yEnd: .value("To", c.to), width: .fixed(barWidth))
                    .foregroundStyle(color(c))
                    .opacity(model.real ? 1 : 0.45)
            }
            RuleMark(y: .value("Low balance line", model.warn))
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartXScale(domain: -1...count)
        .chartXAxis {
            AxisMarks(values: labelIDs) { v in
                AxisValueLabel {
                    if let i = v.as(Int.self), i >= 0, i < model.cols.count { Text(model.cols[i].label).font(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(kfmt(d)).font(.caption2) }
                }
            }
        }
        .accessibilityLabel("Cash flow waterfall for the month")
    }
}

struct CashFlowCard: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.palette) private var palette
    let onExplore: () -> Void

    var body: some View {
        let b = store.budget
        let model = b.cashModel(store.viewing)
        let note = b.cashNote(model)
        let startText = model.real ? (model.startKind == .set ? "Start " : "Starts ") + money(model.start) : "Set up"
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(note.pill, systemImage: note.health.icon)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .surface(Capsule(), tint: note.health.color.opacity(0.3))
                Spacer()
                Button { store.sheet = .startBalance } label: { Label(startText, systemImage: "pencil").font(.subheadline) }
                    .themedButton()
            }
            WaterfallChart(model: model).frame(height: 190)
            Text("Cash flow").font(.title3.bold())
            Text(note.text).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(legendItems(model), id: \.0) { item in
                    HStack(spacing: 5) { Circle().fill(item.1).frame(width: 8, height: 8); Text(item.0).font(.caption2) }
                }
            }
            Button(action: onExplore) {
                Label("Explore the cash flow", systemImage: "arrow.right").frame(maxWidth: .infinity)
            }
            .themedButton(prominent: true)
            .controlSize(.large)
        }
        .padding(16)
        .surface(RoundedRectangle(cornerRadius: 28))
    }

    private func legendItems(_ m: Budget.CashModel) -> [(String, Color)] {
        var out: [(String, Color)] = [("Money in", .green), ("Bills", .purple), ("Total", palette.brand)]
        if m.cols.contains(where: { $0.spend }) { out.append(("Spending", .orange)) }
        if !m.marks.isEmpty { out.append(("My balance", .primary)) }
        return out
    }
}

struct MonthSummaryCard: View {
    @Environment(BudgetStore.self) private var store
    var body: some View {
        let s = store.budget.stats(in: store.viewing)
        Card(title: "Month summary") {
            Label("\(s.billsPaid) of \(s.billsTotal) bills paid. \(money(s.billsLeft)) still to pay.", systemImage: "checkmark.circle")
            Label("Money in: \(money(s.inReceived)) of \(money(s.inExpected)).", systemImage: "arrow.down.circle")
            Label("Everyday spending: \(money(s.spent)) of \(money(s.planned)).", systemImage: "cart")
        }
        .font(.subheadline)
    }
}

struct LoansCard: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.palette) private var palette
    var body: some View {
        let loans = store.budget.liveLoans
        if !loans.isEmpty {
            Card(title: "Loans and cards") {
                ForEach(loans) { l in
                    let used = l.total > 0 ? min(1, max(0, l.isCard ? l.balance / l.total : 1 - l.balance / l.total)) : 0.0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(l.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(l.isCard ? "\(money(l.balance)) used of \(money(l.total))" : "\(money(l.balance)) left of \(money(l.total))")
                                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ProgressView(value: used)
                            .tint(l.isCard ? Color.orange : palette.primary)
                    }
                }
            }
        }
    }
}

// MARK: - Bills

enum BillFilter: String, CaseIterable, Identifiable {
    case all, unpaid, paid, overdue
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct BillsTab: View {
    @Environment(BudgetStore.self) private var store
    @State private var filter: BillFilter = .all
    @State private var search = ""
    @State private var path: [String] = []

    private func matches(_ r: BillRow) -> Bool {
        switch filter {
        case .all: break
        case .unpaid: if r.isPaid { return false }
        case .paid: if !r.isPaid { return false }
        case .overdue: if r.isPaid || r.item.type != .bill || r.due >= YMD.today { return false }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || r.item.name.localizedCaseInsensitiveContains(q) || r.item.account.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        let rows = store.budget.rows(in: store.viewing).filter { matches($0) }
        let income = rows.filter { $0.item.type == .income }
        let bills = rows.filter { $0.item.type == .bill }
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(BillFilter.allCases) { f in Text(f.title).tag(f) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                if rows.isEmpty {
                    ContentUnavailableView("Nothing here", systemImage: "tray",
                                           description: Text("No matching bills in \(store.viewing.title)."))
                }
                if !income.isEmpty {
                    Section("Money in") { ForEach(income) { BillRowView(row: $0) } }
                }
                if !bills.isEmpty {
                    Section("Bills") { ForEach(bills) { BillRowView(row: $0) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background { Backdrop() }
            .searchable(text: $search, prompt: "Search bills")
            .navigationDestination(for: String.self) { key in BillDetail(key: key) }
            .budgetChrome("Bills")
        }
        .onChange(of: path) { _, new in store.detailDepth = new.count }
        .onDisappear { store.detailDepth = 0 }
    }
}

struct BillRowView: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.palette) private var palette
    let row: BillRow

    var body: some View {
        let late = !row.isPaid && row.item.type == .bill && row.due < YMD.today
        let isIncome = row.item.type == .income
        let effect = store.budget.effect(for: row.item, key: row.key, isPaid: row.isPaid)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(get: { row.isPaid }, set: { store.setPaid(row, $0) }))
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(isIncome ? "Received" : "Paid")
                NavigationLink(value: row.key) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.item.name)
                                .font(.body.weight(.semibold))
                                .strikethrough(row.isPaid)
                                .foregroundStyle(row.isPaid ? Color.secondary : Color.primary)
                            HStack(spacing: 6) {
                                Text(row.due.nice)
                                if !row.item.account.isEmpty { Text("· \(row.item.account)") }
                                if row.item.automatic { Image(systemName: "lock.fill") }
                                if late { Text("Late").bold().foregroundStyle(Color.red) }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text((isIncome ? "+" : "") + money(row.shownAmount))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(isIncome ? Color.green : Color.primary)
                    }
                }
            }
            if let effect {
                Text(effect)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(palette.primary.opacity(0.16), in: Capsule())
            }
        }
        .swipeActions(edge: .leading) {
            Button { store.setPaid(row, !row.isPaid) } label: { Label(row.isPaid ? "Undo" : "Paid", systemImage: "checkmark") }
                .tint(row.isPaid ? Color.gray : Color.green)
        }
    }
}

struct BillDetail: View {
    @Environment(BudgetStore.self) private var store
    let key: String

    var body: some View {
        if let row = store.budget.row(forKey: key) {
            let isIncome = row.item.type == .income
            Form {
                Section {
                    LabeledContent("Due", value: row.due.nice)
                    LabeledContent("Planned", value: money(row.item.amount))
                    if !row.item.account.isEmpty { LabeledContent("Account", value: row.item.account) }
                    Toggle(isIncome ? "Received" : "Paid", isOn: Binding(get: { row.isPaid }, set: { store.setPaid(row, $0) }))
                }
                if let pay = row.pay {
                    Section(isIncome ? "Received" : "Paid") {
                        DatePicker("Date", selection: Binding(get: { YMD(iso: pay.on ?? row.due.iso)?.date ?? Date() },
                                                              set: { store.setPayDate(key, YMD(date: $0)) }),
                                   displayedComponents: .date)
                        HStack {
                            Text("Amount")
                            Spacer()
                            TextField("0", value: Binding(get: { pay.amt ?? row.item.amount }, set: { store.setPayAmount(key, $0) }), format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                if let line = store.budget.effect(for: row.item, key: key, isPaid: row.isPaid) {
                    Section("What it does to your loans and cards") { Text(line) }
                }
                Section { Button("Edit this item") { store.sheet = .item(row.item) } }
            }
            .navigationTitle(row.item.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("This bill is gone", systemImage: "questionmark.folder")
        }
    }
}

// MARK: - Spending

struct SpendingTab: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        let items = store.budget.items.filter { $0.type == .variable }
        let s = store.budget.stats(in: store.viewing)
        let frac = s.planned > 0 ? min(1, s.spent / s.planned) : 0.0
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Spent this month").font(.subheadline)
                            Spacer()
                            Text("\(money(s.spent)) of \(money(s.planned))").font(.headline).monospacedDigit()
                        }
                        ProgressView(value: frac).tint(s.spent > s.planned ? Color.red : Color.orange)
                    }
                }
                if items.isEmpty {
                    ContentUnavailableView("No everyday spending yet", systemImage: "cart",
                                           description: Text("Tap + and choose Everyday spending to add a monthly budget, like groceries."))
                }
                ForEach(items) { SpendRow(item: $0) }
            }
            .scrollContentBackground(.hidden)
            .background { Backdrop() }
            .budgetChrome("Spending")
        }
    }
}

struct SpendRow: View {
    @Environment(BudgetStore.self) private var store
    let item: Item
    @State private var text = ""

    private func format(_ v: Double) -> String { v <= 0 ? "" : (v == v.rounded() ? String(Int(v)) : String(v)) }

    var body: some View {
        let spent = store.budget.spent(item, in: store.viewing)
        let over = spent > item.amount
        let frac = item.amount > 0 ? min(1, spent / item.amount) : 0.0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.body.weight(.semibold))
                    Text("Budget \(money(item.amount))" + (item.day.map { " · on the \($0)" } ?? "") + (over ? "" : " · \(money(item.amount - spent)) left"))
                        .font(.footnote).foregroundStyle(.secondary)
                    if over { Text("\(money(spent - item.amount)) over").font(.caption.bold()).foregroundStyle(Color.red) }
                }
                Spacer()
                Text("Spent $").font(.footnote).foregroundStyle(.secondary)
                TextField("0", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: text) { _, new in
                        store.setSpent(item, Double(new.replacingOccurrences(of: ",", with: ".")) ?? 0)
                    }
            }
            ProgressView(value: frac).tint(over ? Color.red : Color.orange)
        }
        .task(id: store.viewing) { text = format(store.budget.spent(item, in: store.viewing)) }
    }
}

// MARK: - Insights

struct StatTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(RoundedRectangle(cornerRadius: 20))
    }
}

struct InsightsTab: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        let s = store.budget.stats(in: store.viewing)
        let net = s.inExpected - s.billsLeft - s.planned
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            StatTile(title: "Expected income", value: money(s.inExpected, whole: true))
                            StatTile(title: "Planned spending", value: money(s.planned, whole: true))
                            StatTile(title: "Expected net", value: money(net, whole: true))
                        }
                    }
                    CashExplorer()
                    WhereMoneyGoes()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background { Backdrop() }
            .budgetChrome("Insights")
        }
    }
}

struct WhereMoneyGoes: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.palette) private var palette

    /// The biggest planned amounts this month, with the rest lumped together.
    private func shownRows() -> [(name: String, amount: Double)] {
        let b = store.budget
        var totals: [(name: String, amount: Double)] = []
        for it in b.items where it.type != .income {
            let times = it.type == .variable ? 1 : max(1, b.occurrences(of: it, in: store.viewing).count)
            totals.append((name: it.name, amount: it.amount * Double(times)))
        }
        let sorted = totals.sorted { $0.amount > $1.amount }
        var shown = Array(sorted.prefix(7))
        let rest = sorted.dropFirst(7).reduce(0.0) { $0 + $1.amount }
        if rest > 0 { shown.append((name: "Other (\(sorted.count - 7))", amount: rest)) }
        return shown
    }

    var body: some View {
        let shown = shownRows()
        Card(title: "Where the money goes") {
            if shown.isEmpty {
                Text("Add some bills and this fills in.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, r in
                        BarMark(x: .value("Amount", r.amount), y: .value("Item", r.name))
                            .foregroundStyle(palette.primary.gradient)
                            .annotation(position: .trailing) { Text(money(r.amount, whole: true)).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(shown.count) * 34 + 10)
            }
        }
    }
}

/// The cash flow explorer: drag to move through time, pinch (or use + and −) to zoom, tap a bar for details.
struct CashExplorer: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.palette) private var palette
    @State private var series: Budget.Series?
    @State private var plan: Budget.Series?
    @State private var visibleDays = 60.0
    @State private var baseDays = 60.0
    @State private var scrollDate = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
    @State private var selected: Date?
    @State private var nowText = ""
    @State private var nowDay = Date()
    @State private var formError: String?
    @AppStorage("explorerYSpan") private var ySpan = 0.0           // 0 = fit what is on screen, otherwise the chart's height in dollars

    /// Every balance that is on screen right now, so the vertical scale can fit it.
    private func onScreenValues(_ s: Budget.Series, _ b: Budget) -> [Double] {
        let start = scrollDate
        let end = scrollDate.addingTimeInterval(visibleDays * 86400)
        func inView(_ pts: [Budget.SeriesPoint]) -> [Double] {
            var v = pts.filter { $0.date >= start && $0.date <= end }.map(\.value)
            if let before = pts.last(where: { $0.date < start }) { v.append(before.value) }      // a step that began before the left edge is still on screen
            return v
        }
        var values = inView(s.points)
        if let plan { values += inView(plan.points) }
        for a in b.cash.actuals {
            if let d = YMD(iso: a.d)?.date, d >= start, d <= end { values.append(a.v) }
        }
        if visibleDays <= 80 {
            for st in s.steps where !st.isActual && st.date >= start && st.date <= end { values.append(st.before); values.append(st.after) }
        }
        return values
    }

    private func axisLabel(_ d: Double) -> String { abs(d) >= 10_000 ? kfmt(d) : money(d, whole: true) }

    private var maxDays: Double {
        guard let s = series else { return 365 }
        return max(14, min(400, s.last.timeIntervalSince(s.first) / 86400))
    }

    var body: some View {
        Card(title: "Cash flow") {
            if let s = series { explorer(s) } else { emptyState }
        }
        .task(id: store.revision) { reload() }
    }

    private func reload() {
        let b = store.budget
        series = b.series()
        plan = (!b.cash.actuals.isEmpty && b.cash.follow) ? b.series(cash: b.cash.followOff) : nil
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set your starting balance, or type your chequing balance, and your cash flow shows up here.").foregroundStyle(.secondary)
            Button("Set it up") { store.sheet = .startBalance }.themedButton()
        }
    }

    private func setDays(_ d: Double) { visibleDays = min(max(d, 7), maxDays); baseDays = visibleDays }
    private func zoom(_ f: Double) { setDays(visibleDays * f) }
    private func pan(_ frac: Double) { scrollDate = scrollDate.addingTimeInterval(visibleDays * 86400 * frac) }
    private func goToday() { scrollDate = YMD.today.adding(days: -Int(visibleDays * 0.3)).date }

    private func nearestStep(_ s: Budget.Series) -> Budget.SeriesStep? {
        guard let sel = selected, let st = s.steps.min(by: { abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel)) }),
              abs(st.date.timeIntervalSince(sel)) < 1.5 * 86400 else { return nil }
        return st
    }

    @ViewBuilder
    private func explorer(_ s: Budget.Series) -> some View {
        let b = store.budget
        let todayD = YMD.today.date
        let todayValue = s.points.last { $0.date <= todayD }?.value ?? s.points.first?.value ?? 0
        let ahead = s.points.filter { $0.date >= todayD }
        let lowest = ahead.min { $0.value < $1.value }
        let lastActual = b.cash.actuals.last
        let sel = nearestStep(s)
        let presets: [(String, Double)] = [("1 month", 31), ("3 months", 92), ("6 months", 183), ("1 year", 365)]
        let axis = chartAxis(values: onScreenValues(s, b), warn: b.cash.warn, fixedSpan: ySpan)

        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                StatTile(title: "Plan for today", value: money(todayValue, whole: true))
                StatTile(title: "My balance", value: lastActual.map { money($0.v, whole: true) } ?? "–")
                StatTile(title: "Lowest ahead", value: lowest.map { money($0.value, whole: true) } ?? "–")
            }
        }

        if let a = lastActual, let d = b.diff(for: a) {
            Label("You are \(money(abs(d))) \(d > 0 ? "ahead of" : "behind") plan as of \(YMD(iso: a.d)?.nice ?? a.d).",
                  systemImage: d > 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(d > 0 ? Color.green : Color.orange)
        }

        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button { zoom(1.5) } label: { Image(systemName: "minus").frame(width: 22) }.accessibilityLabel("Zoom out")
                Button { zoom(1 / 1.5) } label: { Image(systemName: "plus").frame(width: 22) }.accessibilityLabel("Zoom in")
                Button { pan(-0.3) } label: { Image(systemName: "chevron.left").frame(width: 22) }.accessibilityLabel("Back in time")
                Button { pan(0.3) } label: { Image(systemName: "chevron.right").frame(width: 22) }.accessibilityLabel("Forward in time")
                Button("Today") { goToday() }
            }
            .themedButton()
        }

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.0) { p in
                    Button(p.0) { setDays(p.1); goToday() }
                        .themedButton()
                        .tint(abs(visibleDays - p.1) < p.1 * 0.12 ? palette.primary : nil)
                }
                Menu {
                    Picker("Chart height", selection: $ySpan) {
                        Text("Auto: fit what I see").tag(0.0)
                        ForEach([2_500.0, 5_000, 10_000, 20_000, 50_000], id: \.self) { v in Text("\(money(v, whole: true)) tall").tag(v) }
                    }
                } label: {
                    Label(ySpan == 0 ? "Scale: auto" : "Scale: \(money(ySpan, whole: true))", systemImage: "arrow.up.and.down")
                }
                .menuStyle(.button)
                .themedButton()
            }
        }

        Chart {
            ForEach(s.points) { p in
                AreaMark(x: .value("Date", p.date), y: .value("Balance", p.value))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(palette.primary.opacity(0.16))
                LineMark(x: .value("Date", p.date), y: .value("Balance", p.value), series: .value("Line", "Balance"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(palette.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineJoin: .round))
            }
            if let plan {
                ForEach(plan.points) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Balance", p.value), series: .value("Line", "Plan before my balance"))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            RuleMark(y: .value("Low balance line", b.cash.warn))
                .foregroundStyle(Color.red.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(x: .value("Today", todayD))
                .foregroundStyle(Color.primary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if visibleDays <= 80 {
                ForEach(s.steps.filter { !$0.isActual }) { st in
                    BarMark(x: .value("Date", st.date), yStart: .value("Before", st.before), yEnd: .value("After", st.after), width: .fixed(6))
                        .foregroundStyle(st.spend ? Color.orange : (st.amt > 0 ? Color.green : Color.purple))
                }
            }
            ForEach(b.cash.actuals, id: \.d) { a in
                if let d = YMD(iso: a.d) {
                    PointMark(x: .value("Date", d.date), y: .value("My balance", a.v))
                        .symbol(.diamond)
                        .symbolSize(90)
                        .foregroundStyle(Color.primary)
                }
            }
            if let sel {
                RuleMark(x: .value("Selected", sel.date))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleDays * 86400)
        .chartScrollPosition(x: $scrollDate)
        .chartXSelection(value: $selected)
        .chartYScale(domain: axis.lo...axis.hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: axis.ticks) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(axisLabel(d)).font(.caption2) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: visibleDays > 200 ? Date.FormatStyle().month(.abbreviated) : Date.FormatStyle().month(.abbreviated).day())
            }
        }
        .chartPlotStyle { plot in plot.clipped() }
        .frame(height: 290)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { v in visibleDays = min(max(baseDays / v.magnification, 7), maxDays) }
                .onEnded { _ in baseDays = visibleDays }
        )
        .accessibilityLabel("Cash flow chart. Swipe to move through time.")

        Text(caption(sel))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minHeight: 36, alignment: .topLeading)

        balanceForm(b)
    }

    private func caption(_ st: Budget.SeriesStep?) -> String {
        guard let st else { return "Drag to move. Pinch, or use + and −, to zoom. Tap a bar for details. Scale changes how tall the chart is." }
        if st.isActual { return "\(st.due.nice): you typed your balance, \(money(st.after)) (the plan said \(money(st.before)))." }
        return "\(st.due.nice): \(st.name) \(st.amt > 0 ? "+" : "−")\(money(abs(st.amt))). Balance after: \(money(st.after))."
    }

    @ViewBuilder
    private func balanceForm(_ b: Budget) -> some View {
        Divider()
        Text("My chequing balance").font(.headline)
        Text("Type what your bank app shows. It becomes a marker on the chart, so you can see if you are ahead of or behind the plan.")
            .font(.footnote).foregroundStyle(.secondary)
        HStack {
            TextField("for example 2450", text: $nowText)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
            DatePicker("As of", selection: $nowDay, in: ...Date(), displayedComponents: .date).labelsHidden()
        }
        if let formError { Text(formError).font(.footnote).foregroundStyle(Color.red) }
        Button {
            guard let v = Double(nowText.replacingOccurrences(of: ",", with: ".")) else { formError = "Type the balance your bank shows, like 2450."; return }
            formError = nil
            store.addActual(v, on: YMD(date: nowDay))
            let diff = store.budget.diff(for: Actual(d: YMD(date: nowDay).iso, v: v))
            store.say("Saved. Your balance is \(money(v))." + (diff.map { " That is \(money(abs($0))) \($0 > 0 ? "ahead of" : "behind") the plan." } ?? ""))
            nowText = ""
        } label: { Text("Save my balance").frame(maxWidth: .infinity) }
        .themedButton(prominent: true)

        Toggle("Update the forecast from it", isOn: Binding(get: { b.cash.follow }, set: { v in store.update { $0.cash.follow = v } }))
        Toggle("Include everyday spending", isOn: Binding(get: { b.cash.spend }, set: { v in store.update { $0.cash.spend = v } }))

        let recent = Array(b.cash.actuals.suffix(5).reversed())
        if !recent.isEmpty {
            Text("Recent balances").font(.subheadline.weight(.semibold))
            ForEach(recent, id: \.d) { a in
                HStack {
                    VStack(alignment: .leading) {
                        Text(money(a.v)).font(.body.weight(.semibold))
                        Text(YMD(iso: a.d)?.nice ?? a.d).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let d = b.diff(for: a) {
                        Text("\(money(abs(d))) \(d > 0 ? "ahead" : "behind")").font(.caption.bold()).foregroundStyle(d > 0 ? Color.green : Color.orange)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { store.removeActual(a) }.buttonStyle(.borderless)
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @Environment(BudgetStore.self) private var store
    @AppStorage("schemeChoice") private var scheme: SchemeChoice = .auto
    @AppStorage("easyMode") private var easy = false
    @State private var showNew = false
    @State private var showRename = false
    @State private var confirmDelete = false
    @State private var nameText = ""
    @State private var backupURL: URL?
    @State private var allURL: URL?

    var body: some View {
        let b = store.budget
        let start = b.cashStart(store.viewing, b.cash)
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Light or dark", selection: $scheme) {
                        ForEach(SchemeChoice.allCases) { c in Text(c.title).tag(c) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Easy mode (big print)", isOn: $easy)
                    Button("Wallpaper and colors…") { store.sheet = .theme }
                }

                Section("Budget") {
                    LabeledContent("Showing", value: b.name)
                    Button("New budget…") { nameText = ""; showNew = true }
                    Button("Rename…") { nameText = b.name; showRename = true }
                    Button("Add an example budget") { store.addExample() }
                    Button("Delete this budget", role: .destructive) { confirmDelete = true }
                        .disabled(store.library.budgets.count < 2)
                }

                Section {
                    Button {
                        store.sheet = .startBalance
                    } label: {
                        LabeledContent("Balance on the 1st of \(Calendar.current.monthSymbols[store.viewing.m - 1])",
                                       value: start.kind == .unset ? "Not set" : money(start.v))
                    }
                    LabeledContent("Low balance line") {
                        TextField("500", value: Binding(get: { b.cash.warn }, set: { v in store.update { $0.cash.warn = max(0, v) } }), format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Carry over each month", isOn: Binding(get: { b.cash.carry }, set: { v in store.update { $0.cash.carry = v } }))
                    Toggle("Update the forecast from my balance", isOn: Binding(get: { b.cash.follow }, set: { v in store.update { $0.cash.follow = v } }))
                    Toggle("Include everyday spending", isOn: Binding(get: { b.cash.spend }, set: { v in store.update { $0.cash.spend = v } }))
                } header: {
                    Text("Cash flow")
                } footer: {
                    Text("Type your chequing balance on the Insights tab to see if you are ahead of or behind the plan.")
                }

                Section {
                    ForEach(b.items.filter { $0.type == .bill }) { it in
                        Toggle(isOn: Binding(get: { it.automatic }, set: { on in
                            var n = it
                            n.automatic = on
                            n.autoSince = on ? YMD.today.iso : nil
                            store.upsert(n)
                            if on { store.applyAutoPay() }
                        })) {
                            VStack(alignment: .leading) {
                                Text(it.name)
                                Text(money(it.amount)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Automatic bills")
                } footer: {
                    Text("An automatic bill marks itself paid on its due date, from the day you switch it on.")
                }

                Section("Loans and cards") {
                    ForEach(b.liveLoans) { l in
                        Button { store.sheet = .loan(l) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(l.name).foregroundStyle(Color.primary)
                                    Text(l.isCard ? "Card" : "Loan").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: .capsule)
                                    if Budget.isLinked(l) { Text("Follows your bills").font(.caption2.bold()).foregroundStyle(Color.green) }
                                }
                                Text(l.isCard ? "\(money(l.balance)) used of \(money(l.total))" : "\(money(l.balance)) left of \(money(l.total))")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.delete(l) }
                            Button("Looks right") { store.checkIn(l, balance: l.balance) }.tint(.green)
                        }
                    }
                    Button("Add a loan or card") { store.sheet = .loan(nil) }
                }

                Section {
                    if let url = backupURL {
                        ShareLink(item: url) { Label("Save a backup file", systemImage: "arrow.down.doc") }
                    }
                    if store.library.budgets.count > 1, let url = allURL {
                        ShareLink(item: url) { Label("Save all budgets in one file", systemImage: "square.stack.3d.up") }
                    }
                    Button { store.showRestorePicker = true } label: { Label("Restore from a file…", systemImage: "arrow.up.doc") }
                    Button { store.sheet = .importBackup } label: { Label("Paste a backup…", systemImage: "doc.on.clipboard") }
                } header: {
                    Text("Back up and restore")
                } footer: {
                    Text("A backup file holds everything in “\(b.name)”: the items, every payment with its date, loans and cards, and your balances. It is the same file the web app saves, so a budget can move between them. Restoring asks first: add a new budget, replace one, or merge into it. Wallpaper and colors are not included. The all-budgets file is for moving to a new phone, and only this app reads it.")
                }

                Section {
                    Text("TapBudget version \(AppInfo.version)").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background { Backdrop() }
            .alert("New budget", isPresented: $showNew) {
                TextField("Name", text: $nameText)
                Button("Create") { store.addBudget(named: nameText) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename budget", isPresented: $showRename) {
                TextField("Name", text: $nameText)
                Button("Save") { store.renameBudget(nameText) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete “\(b.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete budget", role: .destructive) { store.deleteBudget() }
            } message: {
                Text("This removes its bills, payments and balances from this phone.")
            }
            .budgetChrome("Settings", month: false)
            .task(id: store.revision) {
                backupURL = store.backupFileURL()
                allURL = store.library.budgets.count > 1 ? store.backupFileURL(all: true) : nil
            }
        }
    }
}

// MARK: - Sheets

struct ItemForm: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let editing: Item?
    @State private var name: String
    @State private var type: ItemType
    @State private var amountText: String
    @State private var biweekly: Bool
    @State private var dayText: String
    @State private var anchor: Date
    @State private var account: String
    @State private var automatic: Bool
    @State private var error: String?

    init(editing: Item?) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _type = State(initialValue: editing?.type ?? .bill)
        _amountText = State(initialValue: editing.map { $0.amount == $0.amount.rounded() ? String(Int($0.amount)) : String($0.amount) } ?? "")
        _biweekly = State(initialValue: editing?.biweekly ?? false)
        _dayText = State(initialValue: editing?.day.map { String($0) } ?? "")
        _anchor = State(initialValue: editing?.anchor.flatMap { YMD(iso: $0)?.date } ?? Date())
        _account = State(initialValue: editing?.account ?? "")
        _automatic = State(initialValue: editing?.automatic ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $type) {
                        ForEach(ItemType.allCases) { t in Text(t.label).tag(t) }
                    }
                } footer: {
                    Text(type.hint)
                }
                Section {
                    TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                    if type != .variable {
                        Picker("How often", selection: $biweekly) {
                            Text("Every month").tag(false)
                            Text("Every 2 weeks").tag(true)
                        }
                    }
                    if biweekly && type != .variable {
                        DatePicker("First date", selection: $anchor, displayedComponents: .date)
                    } else {
                        TextField(type == .variable ? "Day of the month (optional)" : "Due day of the month (1–31)", text: $dayText)
                            .keyboardType(.numberPad)
                    }
                    TextField("Account (optional)", text: $account)
                }
                if type == .bill {
                    Section {
                        Toggle("Pays itself on its date", isOn: $automatic)
                    } footer: {
                        Text("An automatic bill marks itself paid on its due date.")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(Color.red) }
                }
                if let item = editing {
                    Section { Button("Delete this item", role: .destructive) { store.delete(item); dismiss() } }
                }
            }
            .navigationTitle(editing == nil ? "Add an item" : "Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    private func save() {
        let nm = name.trimmingCharacters(in: .whitespaces)
        guard !nm.isEmpty else { error = "Please enter a name."; return }
        guard let amt = Double(amountText.replacingOccurrences(of: ",", with: ".")), amt >= 0 else { error = "Please enter an amount."; return }
        var item = editing ?? Item(name: nm, type: type, amount: amt)
        item.name = nm
        item.type = type
        item.amount = amt
        item.account = account.trimmingCharacters(in: .whitespaces)
        let dayTrim = dayText.trimmingCharacters(in: .whitespaces)
        if type == .variable {
            item.biweekly = false; item.anchor = nil
            if dayTrim.isEmpty { item.day = nil }
            else if let d = Int(dayTrim), (1...31).contains(d) { item.day = d }
            else { error = "Please enter a day from 1 to 31, or leave it empty."; return }
        } else if biweekly {
            item.biweekly = true; item.anchor = YMD(date: anchor).iso; item.day = nil
        } else {
            guard let d = Int(dayTrim), (1...31).contains(d) else { error = "Please enter a due day from 1 to 31."; return }
            item.biweekly = false; item.anchor = nil; item.day = d
        }
        if type == .bill && automatic {
            if !item.automatic { item.autoSince = YMD.today.iso }
            item.automatic = true
        } else {
            item.automatic = false; item.autoSince = nil
        }
        store.upsert(item)
        if item.automatic { store.applyAutoPay() }
        store.say(editing == nil ? "Added “\(nm)”." : "Saved “\(nm)”.")
        dismiss()
    }
}

struct StartBalanceSheet: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var startText = ""
    @State private var nowText = ""
    @State private var warnText = ""
    @State private var carry = true
    @State private var follow = true
    @State private var spend = true
    @State private var error: String?

    private func number(_ t: String) -> Double? { Double(t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }

    /// The budget's cash settings with what is typed here applied, so the preview matches what Save will do.
    private var draft: Cash {
        var c = store.budget.cash
        if let s = number(startText) { c.starts[store.viewing.key] = s }
        if let n = number(nowText) { c.actuals.removeAll { $0.d == YMD.today.iso }; c.actuals.append(Actual(d: YMD.today.iso, v: n)); c.actuals.sort { $0.d < $1.d } }
        c.warn = number(warnText) ?? c.warn
        c.carry = carry; c.follow = follow; c.spend = spend
        return c
    }

    var body: some View {
        let monthName = Calendar.current.monthSymbols[store.viewing.m - 1]
        let model = store.budget.cashModel(store.viewing, cash: draft)
        let note = store.budget.cashNote(model)
        NavigationStack {
            Form {
                Section {
                    TextField("For example 2500", text: $startText).keyboardType(.numbersAndPunctuation)
                } header: {
                    Text("Balance on the 1st of \(monthName)")
                } footer: {
                    Text("What was in your chequing account on the 1st. You can leave this empty if you type your balance right now below.")
                }
                Section {
                    TextField("For example 2450", text: $nowText).keyboardType(.numbersAndPunctuation)
                } header: {
                    Text("Chequing balance right now (optional)")
                } footer: {
                    Text("Adds a marker to the chart so you can see if you are ahead of or behind the plan.")
                }
                Section("Low balance line") {
                    TextField("500", text: $warnText).keyboardType(.decimalPad)
                }
                Section {
                    Toggle("Update the forecast from it", isOn: $follow)
                    Toggle("Include everyday spending", isOn: $spend)
                    Toggle("Carry over each month", isOn: $carry)
                }
                Section("With these numbers") {
                    Label(note.pill, systemImage: note.health.icon).foregroundStyle(note.health.color)
                    Text(note.text).font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(Color.red) } }
            }
            .navigationTitle("Starting balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear {
                let c = store.budget.cash
                if let v = c.starts[store.viewing.key] { startText = String(v) }
                if let a = c.actuals.last, a.d == YMD.today.iso { nowText = String(a.v) }
                warnText = c.warn == c.warn.rounded() ? String(Int(c.warn)) : String(c.warn)
                carry = c.carry; follow = c.follow; spend = c.spend
            }
        }
    }

    private func save() {
        let s = number(startText), n = number(nowText)
        if startText.trimmingCharacters(in: .whitespaces) != "" && s == nil { error = "Type the balance on the 1st as a number, like 2500."; return }
        if nowText.trimmingCharacters(in: .whitespaces) != "" && n == nil { error = "Type your balance right now as a number, like 2450."; return }
        if s == nil && n == nil && store.budget.cash.starts[store.viewing.key] == nil {
            error = "Enter your balance on the 1st, or your chequing balance right now."; return
        }
        guard let w = number(warnText), w >= 0 else { error = "Enter the low balance line as 0 or more."; return }
        store.update { b in
            if let s { b.cash.starts[store.viewing.key] = round2(s) }
            if let n { b.cash.actuals.removeAll { $0.d == YMD.today.iso }; b.cash.actuals.append(Actual(d: YMD.today.iso, v: round2(n))); b.cash.actuals.sort { $0.d < $1.d } }
            b.cash.warn = round2(w); b.cash.carry = carry; b.cash.follow = follow; b.cash.spend = spend
            b.isSample = false
        }
        store.say(n == nil ? "Starting balance saved." : "Saved. Your balance now is \(money(n ?? 0)).")
        dismiss()
    }
}

struct LoanForm: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let editing: Loan?
    @State private var name: String
    @State private var isCard: Bool
    @State private var totalText: String
    @State private var balanceText: String
    @State private var aprText: String
    @State private var paymentText: String
    @State private var payBill: String?
    @State private var accounts: Set<String>
    @State private var error: String?

    init(editing: Loan?) {
        self.editing = editing
        func text(_ v: Double?) -> String { guard let v, v != 0 else { return "" }; return v == v.rounded() ? String(Int(v)) : String(v) }
        _name = State(initialValue: editing?.name ?? "")
        _isCard = State(initialValue: editing?.isCard ?? false)
        _totalText = State(initialValue: text(editing?.total))
        _balanceText = State(initialValue: editing == nil ? "" : (editing!.balance == editing!.balance.rounded() ? String(Int(editing!.balance)) : String(editing!.balance)))
        _aprText = State(initialValue: text(editing?.apr))
        _paymentText = State(initialValue: text(editing?.payment))
        _payBill = State(initialValue: editing?.payBill)
        _accounts = State(initialValue: Set(editing?.accounts ?? []))
    }

    var body: some View {
        let bills = store.budget.billItems()
        let labels = store.budget.accountLabels()
        NavigationStack {
            Form {
                Section {
                    if editing == nil {
                        Picker("Type", selection: $isCard) {
                            Text("Loan").tag(false)
                            Text("Credit card").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    TextField(isCard ? "Name, like Rewards Visa" : "Name, like Car loan", text: $name)
                    TextField(isCard ? "Credit limit" : "Total value", text: $totalText).keyboardType(.decimalPad)
                    TextField("Balance now", text: $balanceText).keyboardType(.decimalPad)
                }
                Section {
                    Picker(isCard ? "Bill that pays this card" : "Bill that pays this loan", selection: $payBill) {
                        Text("None, I will update it myself").tag(String?.none)
                        ForEach(bills) { b in Text("\(b.name) · \(money(b.amount))").tag(Optional(b.id)) }
                    }
                } footer: {
                    Text("Tick that bill paid and this balance drops by the amount you paid. Untick it and the balance goes back. You never type a payment.")
                }
                if isCard {
                    Section {
                        if labels.isEmpty { Text("None of your bills has an Account yet. Give a bill one, like Visa, and it can count toward this card.").font(.footnote).foregroundStyle(.secondary) }
                        ForEach(labels, id: \.self) { a in
                            Toggle(a, isOn: Binding(get: { accounts.contains(a) }, set: { on in if on { accounts.insert(a) } else { accounts.remove(a) } }))
                        }
                    } header: {
                        Text("Bills charged to this card")
                    } footer: {
                        Text("Pick the Account names of the bills you pay with this card. Ticking one of them adds to the balance.")
                    }
                } else {
                    Section {
                        TextField("Interest rate, a year (optional)", text: $aprText).keyboardType(.decimalPad)
                    } footer: {
                        Text("With a rate, each payment is split into interest and principal, so the balance matches your statement more closely.")
                    }
                }
                if payBill == nil {
                    Section("Monthly payment (optional)") {
                        TextField("Payment amount", text: $paymentText).keyboardType(.decimalPad)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(Color.red) } }
                if let l = editing {
                    Section { Button("Delete", role: .destructive) { store.delete(l); dismiss() } }
                }
            }
            .navigationTitle(editing == nil ? "Add a loan or card" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    private func number(_ t: String) -> Double? { Double(t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }

    private func save() {
        let nm = name.trimmingCharacters(in: .whitespaces)
        guard !nm.isEmpty else { error = "Please enter a name."; return }
        guard let total = number(totalText), total > 0 else { error = isCard ? "Please enter the credit limit." : "Please enter the total value."; return }
        guard let balance = number(balanceText), balance >= 0 else { error = "Please enter the balance now, or 0 if it is paid off."; return }
        let rate = aprText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : number(aprText)
        if !isCard, let r = rate, r < 0 || r > 100 { error = "Please enter the interest rate as a number from 0 to 100, or leave it empty."; return }
        var payment = number(paymentText) ?? 0
        if let pb = payBill, let bill = store.budget.items.first(where: { $0.id == pb }) { payment = bill.amount }
        var loan = editing ?? Loan(name: nm, isCard: isCard, total: total, balance: balance)
        loan.name = nm; loan.isCard = isCard; loan.total = total; loan.payment = payment
        loan.payBill = payBill
        loan.accounts = isCard ? labels().filter { accounts.contains($0) } : []
        loan.apr = (!isCard && (rate ?? 0) > 0) ? rate : nil
        loan = store.budget.rebased(loan, balance: balance)        // from now on, new ticks move the balance
        store.upsert(loan)
        store.say("Saved “\(nm)”.")
        dismiss()
    }

    private func labels() -> [String] { store.budget.accountLabels() }
}

struct ImportSheet: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).frame(minHeight: 220).font(.system(.footnote, design: .monospaced))
                } header: {
                    Text("Paste a backup")
                } footer: {
                    Text("Paste the contents of a backup file. You are asked how to restore it before anything changes.")
                }
                if let error { Section { Text(error).foregroundStyle(Color.red) } }
            }
            .navigationTitle("Import a backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        guard store.readBackup(text, fileName: "") != nil else { error = "That does not look like a TapBudget backup."; return }
                        let pasted = text
                        dismiss()
                        Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            if let e = store.stageRestore(pasted, fileName: "") { store.say(e) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Theme: colors, Flat or Glass, switch styles, wallpaper

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0                    // plain Swift: no Scanner, so no SDK differences
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255, opacity: 1)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

/// The three colors of the budget being shown, and how it looks.
struct Palette: Equatable {
    var brand = Color(hex: "#2ebfd9")
    var primary = Color(hex: "#0e7c91")
    var accent = Color(hex: "#fdcb2f")
    var look: LookKind = .glass
    var switchKind: SwitchKind = .classic

    init() {}
    init(_ t: Theme) {
        brand = Color(hex: t.colors.brand)
        primary = Color(hex: t.colors.primary)
        accent = Color(hex: t.colors.accent)
        look = t.look
        switchKind = t.switchKind
    }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette() }
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Liquid Glass when the look is Glass; a solid fill when it is Flat.
struct SurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    @Environment(\.palette) private var palette

    @ViewBuilder func body(content: Content) -> some View {
        if palette.look == .glass {
            if let tint {
                content.glassEffect(.regular.tint(tint), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content.background(flatFill, in: shape)
        }
    }

    private var flatFill: Color {
        if let tint { return tint.opacity(0.28) }
        return Color(uiColor: .secondarySystemGroupedBackground)
    }
}

extension View {
    func surface<S: Shape>(_ shape: S, tint: Color? = nil) -> some View { modifier(SurfaceModifier(shape: shape, tint: tint)) }
    func themedButton(prominent: Bool = false) -> some View { modifier(ThemedButtonModifier(prominent: prominent)) }
    func themed(_ palette: Palette) -> some View { modifier(ThemeApplier(palette: palette)) }
}

struct ThemedButtonModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.palette) private var palette

    @ViewBuilder func body(content: Content) -> some View {
        if palette.look == .glass {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}

struct ThemedSwitches: ViewModifier {
    @Environment(\.palette) private var palette

    @ViewBuilder func body(content: Content) -> some View {
        if palette.switchKind == .classic {
            content
        } else {
            content.toggleStyle(ThemedSwitchStyle(kind: palette.switchKind))
        }
    }
}

/// Applies a budget's palette, tint and switch style to everything inside.
struct ThemeApplier: ViewModifier {
    let palette: Palette
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .modifier(ThemedSwitches())
            .environment(\.palette, palette)
            .tint(scheme == .dark ? palette.brand : palette.primary)
    }
}

// MARK: Switch styles

struct SwitchGraphic: View {
    let kind: SwitchKind
    let isOn: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            track
            knob.frame(width: 24, height: 24).padding(3)
        }
        .frame(width: 52, height: 32)
        .animation(.snappy(duration: 0.18), value: isOn)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var track: some View {
        switch kind {
        case .classic:
            Capsule().fill(isOn ? Color.green : Color.secondary.opacity(0.35))
        case .check:
            Capsule().fill(isOn ? Color(hex: "#2e9b63") : Color(hex: "#e0575b"))
                .overlay(Capsule().strokeBorder(isOn ? Color(hex: "#1f7a4b") : Color(hex: "#b83a3f"), lineWidth: 2))
                .overlay(alignment: isOn ? .leading : .trailing) {
                    Image(systemName: isOn ? "checkmark" : "xmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                }
        case .orb:
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.5), lineWidth: 1.5))
        case .sun:
            Capsule().strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
        case .soft:
            Capsule().fill(isOn ? palette.brand.opacity(0.25) : Color.clear)
                .overlay(Capsule().strokeBorder(palette.primary, lineWidth: 1.5))
        }
    }

    @ViewBuilder private var knob: some View {
        let dark = scheme == .dark
        switch kind {
        case .classic:
            Circle().fill(Color.white).shadow(color: Color.black.opacity(0.25), radius: 1.5, y: 1)
        case .check:
            Circle().fill(Color(hex: "#f4f4f6")).overlay(Circle().strokeBorder(Color.black.opacity(0.16), lineWidth: 1))
        case .orb:
            if isOn {
                Circle()
                    .fill(RadialGradient(colors: dark ? [Color(hex: "#c9ffd9"), Color(hex: "#2ee07a"), Color(hex: "#12994a")]
                                                      : [Color(hex: "#3fd17a"), Color(hex: "#0f8a3c"), Color(hex: "#075c27")],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 16))
                    .shadow(color: Color(hex: dark ? "#2ee07a" : "#14a34b").opacity(0.7), radius: 6)
            } else {
                Circle()
                    .fill(RadialGradient(colors: dark ? [Color(hex: "#ffa38f"), Color(hex: "#e5533d"), Color(hex: "#9d2918")]
                                                      : [Color(hex: "#ff7a68"), Color(hex: "#c42a1d"), Color(hex: "#7d160d")],
                                         center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: 16))
                    .blur(radius: 1.2)
                    .shadow(color: Color(hex: dark ? "#e5533d" : "#d92d20").opacity(0.5), radius: 5)
            }
        case .sun:
            if isOn {
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: dark ? "#fff6c9" : "#ffe27a"), dark ? palette.accent : Color(hex: "#f59a0c"), Color(hex: dark ? "#e8780a" : "#c2410c")],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 16))
                    .overlay(Circle().strokeBorder(dark ? Color.clear : Color(hex: "#b45309"), lineWidth: 1.5))
                    .shadow(color: (dark ? palette.accent : Color(hex: "#f59a0c")).opacity(0.7), radius: 6)
            } else {
                Circle()
                    .strokeBorder(dark ? palette.accent : Color(hex: "#c2570a"), lineWidth: 3)
                    .shadow(color: (dark ? palette.accent : Color(hex: "#c2570a")).opacity(0.5), radius: 4)
            }
        case .soft:
            if isOn { Circle().fill(palette.primary) } else { Circle().strokeBorder(palette.primary, lineWidth: 3) }
        }
    }
}

struct ThemedSwitchStyle: ToggleStyle {
    let kind: SwitchKind

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            SwitchGraphic(kind: kind, isOn: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

// MARK: Wallpaper pictures (kept in Application Support, one per budget)

@MainActor
enum WallpaperFiles {
    private static var cache: [String: UIImage] = [:]

    private static var folder: URL {
        let d = URL.applicationSupportDirectory.appending(path: "wallpapers")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func image(_ name: String) -> UIImage? {
        if let i = cache[name] { return i }
        guard let data = try? Data(contentsOf: folder.appending(path: name)), let img = UIImage(data: data) else { return nil }
        cache[name] = img
        return img
    }

    /// Shrinks the picture, saves it, and returns its file name.
    static func save(_ data: Data, for budgetID: String) -> String? {
        guard let src = UIImage(data: data) else { return nil }
        let longest = max(src.size.width, src.size.height)
        let scale = longest > 1600 ? 1600 / longest : 1
        let size = CGSize(width: src.size.width * scale, height: src.size.height * scale)
        let img = UIGraphicsImageRenderer(size: size).image { _ in src.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = img.jpegData(compressionQuality: 0.8) else { return nil }
        let name = "\(budgetID)-\(Int(Date().timeIntervalSince1970)).jpg"
        do { try jpeg.write(to: folder.appending(path: name), options: .atomic) } catch { return nil }
        return name
    }

    static func remove(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: name))
        cache[name] = nil
    }
}

func ordinal(_ n: Int) -> String {
    let suffix: String
    if (11...13).contains(n % 100) { suffix = "th" }
    else {
        switch n % 10 {
        case 1: suffix = "st"
        case 2: suffix = "nd"
        case 3: suffix = "rd"
        default: suffix = "th"
        }
    }
    return "\(n)\(suffix)"
}

func greetingText() -> String {
    let h = Calendar.current.component(.hour, from: Date())
    return h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
}

// MARK: - The slide-out menu on the left

struct MenuOverlay: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if store.menuOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { store.menuOpen = false }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    MenuDrawer()
                        .frame(width: min(340, geo.size.width * 0.88))
                        .transition(.move(edge: .leading))
                        .gesture(DragGesture().onEnded { v in
                            if v.translation.width < -50 { store.menuOpen = false }
                        })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(.snappy(duration: 0.28), value: store.menuOpen)
        }
        .allowsHitTesting(store.menuOpen)
    }
}

struct MenuRowLabel: View {
    let title: String
    let icon: String
    var selected = false
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).frame(width: 26).foregroundStyle(.tint)
            Text(title).foregroundStyle(Color.primary)
            Spacer()
            if selected { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.tint) }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .background(selected ? palette.brand.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MenuDrawer: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.palette) private var palette
    @AppStorage("schemeChoice") private var scheme: SchemeChoice = .auto
    @AppStorage("easyMode") private var easy = false
    @State private var query = ""
    @State private var backupURL: URL?
    @State private var allURL: URL?

    private func show(_ words: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || words.localizedCaseInsensitiveContains(q)
    }

    /// Closes the menu, then shows a sheet once the menu has slid away.
    private func open(_ sheet: SheetKind) {
        store.menuOpen = false
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            store.sheet = sheet
        }
    }

    private func row(_ title: String, _ icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { MenuRowLabel(title: title, icon: icon, selected: selected) }
            .buttonStyle(.plain)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 4)
            content()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBox
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    budgetsSection
                    toolsSection
                    backupSection
                    appearanceSection
                    aboutSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            Text("TapBudget version \(AppInfo.version)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity)
        .background {
            Rectangle()
                .fill(palette.look == .glass ? AnyShapeStyle(Material.regularMaterial) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)))
                .ignoresSafeArea()
        }
        .shadow(color: Color.black.opacity(0.25), radius: 18)
        .task(id: store.revision) {
            backupURL = store.backupFileURL()
            allURL = store.library.budgets.count > 1 ? store.backupFileURL(all: true) : nil
        }
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 32)).foregroundStyle(palette.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text("TapBudget").font(.headline)
                Text(store.budget.name).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { store.menuOpen = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                .themedButton()
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close menu")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var searchBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search menu", text: $query).textFieldStyle(.plain).submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .surface(Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var budgetsSection: some View {
        let budgets = store.library.budgets
        if show("budgets manage example") || budgets.contains(where: { show($0.name) }) {
            section("Budgets") {
                ForEach(budgets) { b in
                    if show("\(b.name) budget") {
                        row(b.name, b.id == store.library.activeID ? "checkmark.circle.fill" : "circle", selected: b.id == store.library.activeID) {
                            store.switchBudget(b.id)
                            store.menuOpen = false
                        }
                    }
                }
                if show("manage budgets") { row("Manage budgets…", "rectangle.stack") { open(.manageBudgets) } }
                if show("add an example budget") {
                    row("Add an example budget", "star") {
                        store.addExample()
                        store.menuOpen = false
                        store.say("Example budget added.")
                    }
                }
            }
        }
    }

    @ViewBuilder private var toolsSection: some View {
        if show("tools add item edit items") {
            section("Tools") {
                if show("add item") { row("Add item", "plus") { open(.item(nil)) } }
                if show("edit items") { row("Edit items", "pencil") { open(.allItems) } }
            }
        }
    }

    /// Opens the file picker once the menu has slid away.
    private func pickFile() {
        store.menuOpen = false
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            store.showRestorePicker = true
        }
    }

    @ViewBuilder private var backupSection: some View {
        if show("backup save restore file all budgets paste") {
            section("Backup") {
                if show("save a backup file"), let url = backupURL {
                    ShareLink(item: url) { MenuRowLabel(title: "Save a backup file", icon: "arrow.down.doc") }
                        .buttonStyle(.plain)
                }
                if show("save all budgets in one file"), store.library.budgets.count > 1, let url = allURL {
                    ShareLink(item: url) { MenuRowLabel(title: "Save all budgets in one file", icon: "square.stack.3d.up") }
                        .buttonStyle(.plain)
                }
                if show("restore from a file") { row("Restore from a file…", "arrow.up.doc") { pickFile() } }
                if show("paste a backup") { row("Paste a backup…", "doc.on.clipboard") { open(.importBackup) } }
            }
        }
    }

    @ViewBuilder private var appearanceSection: some View {
        if show("appearance auto light dark easy mode big print wallpaper colors look switches theme") {
            section("Appearance") {
                Picker("Appearance", selection: $scheme) {
                    ForEach(SchemeChoice.allCases) { c in Text(c.title).tag(c) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                Toggle(isOn: $easy) { Label("Easy mode (big print)", systemImage: "textformat.size") }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .onChange(of: easy) { _, on in if on { store.menuOpen = false } }
                row("Wallpaper and colors…", "paintpalette") { open(.theme) }
            }
        }
    }

    @ViewBuilder private var aboutSection: some View {
        if show("about privacy policy support help") {
            section("About") {
                row("About TapBudget", "info.circle") { open(.about) }
                Link(destination: URL(string: "https://tapbudget-ashy.vercel.app/about/privacy.html")!) {
                    MenuRowLabel(title: "Privacy policy", icon: "hand.raised")
                }
                .buttonStyle(.plain)
                Link(destination: URL(string: "https://tapbudget-ashy.vercel.app/about/support.html")!) {
                    MenuRowLabel(title: "Support", icon: "questionmark.circle")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Wallpaper and colors

struct ThemeSheet: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var tryIt = true

    var body: some View {
        let t = store.budget.theme
        NavigationStack {
            Form {
                Section {
                    Text("These settings are for “\(store.budget.name)”. Each budget keeps its own wallpaper, colors, look and switches. Light, Dark or Auto is set in the menu and is for the whole app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                wallpaperSection(t)
                lookSection(t)
                gaugeSection(t)
                switchSection(t)
                colorSection(t)
            }
            .navigationTitle("Wallpaper and colors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let name = WallpaperFiles.save(data, for: store.budget.id) {
                        WallpaperFiles.remove(store.budget.theme.wallpaper.fileName)
                        store.setTheme { $0.wallpaper.fileName = name }
                    }
                    photo = nil
                }
            }
        }
    }

    // MARK: Wallpaper

    @ViewBuilder private func wallpaperSection(_ t: Theme) -> some View {
        Section {
            PhotosPicker(selection: $photo, matching: .images) {
                Label(t.wallpaper.fileName == nil ? "Choose a photo" : "Choose a different photo", systemImage: "photo")
            }
            if let name = t.wallpaper.fileName, let img = WallpaperFiles.image(name) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    HStack { Text("Dim"); Spacer(); Text("\(Int((t.wallpaper.dim * 100).rounded()))%").foregroundStyle(.secondary) }
                    Slider(value: Binding(get: { store.budget.theme.wallpaper.dim }, set: { v in store.setTheme { $0.wallpaper.dim = v } }), in: 0...0.7)
                }
                VStack(alignment: .leading) {
                    HStack { Text("Blur"); Spacer(); Text("\(Int(t.wallpaper.blur.rounded()))").foregroundStyle(.secondary) }
                    Slider(value: Binding(get: { store.budget.theme.wallpaper.blur }, set: { v in store.setTheme { $0.wallpaper.blur = v } }), in: 0...20)
                }
                Button("Remove wallpaper", role: .destructive) {
                    WallpaperFiles.remove(name)
                    store.setTheme { $0.wallpaper.fileName = nil }
                }
            }
        } header: {
            Text("Wallpaper")
        } footer: {
            Text("A picture from your photos behind the app. Dim and blur keep the text easy to read. It stays on this phone.")
        }
    }

    // MARK: Look

    @ViewBuilder private func lookSection(_ t: Theme) -> some View {
        Section {
            Picker("Look", selection: Binding(get: { store.budget.theme.look }, set: { v in store.setTheme { $0.look = v } })) {
                Text("Flat").tag(LookKind.flat)
                Text("Glass").tag(LookKind.glass)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Look")
        } footer: {
            Text("Flat keeps the cards, pills and menu solid. Glass makes them see-through Liquid Glass. The tab bar and the bars at the top are always the system's glass on iOS 26 and later.")
        }
    }

    // MARK: Gauges

    @ViewBuilder private func gaugeSection(_ t: Theme) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(GaugeStyle.allCases) { g in
                    Button { store.setTheme { $0.gauge = g } } label: {
                        VStack(spacing: 8) {
                            GaugeSample(style: g, tint: Color(hex: t.colors.brand))
                                .frame(height: 54)
                            Text(g.title).font(.caption.weight(.semibold)).foregroundStyle(Color.primary).multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(t.gauge == g ? Color(hex: t.colors.primary) : Color.secondary.opacity(0.3), lineWidth: t.gauge == g ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(g.title). \(g.detail)")
                    .accessibilityAddTraits(t.gauge == g ? .isSelected : [])
                }
            }
            Toggle("Show a line under each gauge", isOn: Binding(get: { store.budget.theme.gaugeAmounts }, set: { v in store.setTheme { $0.gaugeAmounts = v } }))
        } header: {
            Text("Gauges")
        } footer: {
            Text("The three gauges at the top of Overview: Bills, Money in and Spending. The line under each says what is left, such as “$735 to pay”.")
        }
    }

    // MARK: Switches

    @ViewBuilder private func switchSection(_ t: Theme) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(SwitchKind.allCases) { k in
                    Button { store.setTheme { $0.switchKind = k } } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                SwitchGraphic(kind: k, isOn: true)
                                SwitchGraphic(kind: k, isOn: false)
                            }
                            Text(k.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                            Text(k.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(t.switchKind == k ? Color(hex: t.colors.primary) : Color.secondary.opacity(0.3), lineWidth: t.switchKind == k ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(t.switchKind == k ? .isSelected : [])
                }
            }
            Toggle("Try it. Tap the switch.", isOn: $tryIt)
        } header: {
            Text("Switches")
        } footer: {
            Text("How the paid switch on each bill, and the other on and off switches, look. It changes straight away.")
        }
    }

    // MARK: Colors

    @ViewBuilder private func colorSection(_ t: Theme) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ThemeColors.presets) { p in
                    Button {
                        store.setTheme { $0.colors = ThemeColors(preset: p.id, brand: p.brand, primary: p.primary, accent: p.accent) }
                    } label: {
                        VStack(spacing: 8) {
                            HStack(spacing: 0) {
                                Color(hex: p.brand)
                                Color(hex: p.primary)
                                Color(hex: p.accent)
                            }
                            .frame(height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(p.name).font(.footnote.weight(.semibold)).foregroundStyle(Color.primary)
                        }
                        .padding(8)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(t.colors.preset == p.id ? Color(hex: t.colors.primary) : Color.secondary.opacity(0.3), lineWidth: t.colors.preset == p.id ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(p.name)
                    .accessibilityAddTraits(t.colors.preset == p.id ? .isSelected : [])
                }
            }
            ColorPicker("Bill and heading color", selection: Binding(get: { Color(hex: store.budget.theme.colors.brand) },
                                                                    set: { c in store.setTheme { $0.colors.brand = c.hexString; $0.colors.preset = "custom" } }), supportsOpacity: false)
            ColorPicker("Bar and chart color", selection: Binding(get: { Color(hex: store.budget.theme.colors.primary) },
                                                                set: { c in store.setTheme { $0.colors.primary = c.hexString; $0.colors.preset = "custom" } }), supportsOpacity: false)
            ColorPicker("Money in color", selection: Binding(get: { Color(hex: store.budget.theme.colors.accent) },
                                                           set: { c in store.setTheme { $0.colors.accent = c.hexString; $0.colors.preset = "custom" } }), supportsOpacity: false)
            Button("Back to Cyan") { store.setTheme { $0.colors = ThemeColors() } }
        } header: {
            Text("Colors")
        } footer: {
            Text("Pick a ready-made set, or choose your own three colors.")
        }
    }
}

// MARK: - Manage budgets, Edit items, About

struct ManageBudgetsSheet: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var showRename = false
    @State private var nameText = ""
    @State private var pendingDelete: Budget?

    var body: some View {
        NavigationStack {
            List {
                Section("Your budgets") {
                    ForEach(store.library.budgets) { b in
                        Button { store.switchBudget(b.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.name).foregroundStyle(Color.primary)
                                    Text("\(b.items.count) items" + (b.isSample ? " · example" : "")).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if b.id == store.library.activeID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .swipeActions {
                            if store.library.budgets.count > 1 {
                                Button("Delete", role: .destructive) { pendingDelete = b }
                            }
                        }
                    }
                }
                Section {
                    Button("New budget…") { nameText = ""; showNew = true }
                    Button("Rename this budget…") { nameText = store.budget.name; showRename = true }
                    Button("Add an example budget") { store.addExample() }
                } footer: {
                    Text("Swipe a budget to delete it. A new budget starts with the colors and look that were showing.")
                }
            }
            .navigationTitle("Manage budgets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("New budget", isPresented: $showNew) {
                TextField("Name", text: $nameText)
                Button("Create") { store.addBudget(named: nameText) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename budget", isPresented: $showRename) {
                TextField("Name", text: $nameText)
                Button("Save") { store.renameBudget(nameText) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this budget?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { b in
                Button("Delete “\(b.name)”", role: .destructive) { store.deleteBudget(id: b.id) }
            } message: { _ in
                Text("This removes its bills, payments and balances from this phone.")
            }
        }
    }
}

struct ItemsListSheet: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private func detail(_ it: Item) -> String {
        if it.type == .variable { return it.day.map { "Budget · on the \(ordinal($0))" } ?? "Budget · spread through the month" }
        if it.biweekly { return "Every 2 weeks" }
        return "The \(ordinal(it.day ?? 1)) of each month"
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(ItemType.allCases) { type in
                    let items = store.budget.items.filter { $0.type == type }.sorted { $0.name < $1.name }
                    if !items.isEmpty {
                        Section(type.label) {
                            ForEach(items) { it in
                                Button { store.sheet = .item(it) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(it.name).foregroundStyle(Color.primary)
                                            Text(detail(it)).font(.footnote).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(money(it.amount)).monospacedDigit().foregroundStyle(Color.primary)
                                    }
                                }
                                .swipeActions { Button("Delete", role: .destructive) { store.delete(it) } }
                            }
                        }
                    }
                }
                Section { Button("Add an item") { store.sheet = .item(nil) } }
            }
            .navigationTitle("Edit items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TapBudget").font(.title2.bold())
                        Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
                        Text("A simple budget tracker. Switch a bill on when you pay it, and the date is filled in for you.")
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Text("Your budgets are saved on this phone only. There is no account, no server, and nothing is sent anywhere.")
                }
                Section {
                    Link("Privacy policy", destination: URL(string: "https://tapbudget-ashy.vercel.app/about/privacy.html")!)
                    Link("Support", destination: URL(string: "https://tapbudget-ashy.vercel.app/about/support.html")!)
                    Link("Email tapbudget17@gmail.com", destination: URL(string: "mailto:tapbudget17@gmail.com")!)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Easy mode: big print, four big buttons, plain words

enum EasyTab: Hashable { case home, overview, bills, more }

struct EasyRoot: View {
    @AppStorage("easyXL") private var extraLarge = false
    @State private var tab: EasyTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: EasyTab.home) { EasyHome(go: { tab = $0 }) }
            Tab("Overview", systemImage: "chart.bar", value: EasyTab.overview) { EasyOverview(go: { tab = $0 }) }
            Tab("Bills", systemImage: "list.bullet", value: EasyTab.bills) { EasyBills() }
            Tab("More", systemImage: "ellipsis", value: EasyTab.more) { EasyMore() }
        }
        .dynamicTypeSize(extraLarge ? DynamicTypeSize.accessibility2 : DynamicTypeSize.xxxLarge)
    }
}

struct EasyCard<Content: View>: View {
    var tint: Color?
    let content: Content

    init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(RoundedRectangle(cornerRadius: 24), tint: tint)
    }
}

struct EasyButton: View {
    let title: String
    var icon: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .themedButton(prominent: prominent)
        .controlSize(.large)
    }
}

struct EasyHome: View {
    @Environment(BudgetStore.self) private var store
    let go: (EasyTab) -> Void

    private func homeTint(late: Bool, soon: Bool) -> Color? { late ? Color.red : (soon ? Color.orange : nil) }

    var body: some View {
        let b = store.budget
        let ym = YM.current
        let nx = b.easyNext(in: ym)
        let s = b.stats(in: ym)
        let acct = b.easyAccount(b.cashModel(ym))
        let unpaidBills = b.rows(in: ym).filter { !$0.isPaid && $0.item.type == .bill }
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if b.items.isEmpty {
                        EasyCard {
                            Text("Welcome").font(.largeTitle.bold())
                            Text("Let’s add your first bill. It only takes a minute.").font(.title3)
                        }
                        EasyButton(title: "Add a bill", prominent: true) { store.sheet = .item(nil) }
                    } else {
                        if let n = nx.next {
                            let w = easyWhen(n.due, income: false)
                            EasyCard(tint: homeTint(late: !nx.late.isEmpty, soon: w.soon)) {
                                Text(nx.late.isEmpty ? "Your next bill" : (nx.late.count == 1 ? "This bill is late" : "\(nx.late.count) bills are late. This one is the oldest."))
                                    .font(.subheadline.weight(.bold))
                                HStack {
                                    Text(n.item.name).font(.title.bold())
                                    Spacer()
                                    Text(money(n.item.amount)).font(.title.bold())
                                }
                                Text(w.text).font(.title3.weight(.semibold))
                                if let note = b.linkWords(for: n.item) { Text(note).font(.callout) }
                                EasyButton(title: "I paid it", icon: "checkmark", prominent: true) { store.setPaid(n, true) }
                            }
                        } else if !unpaidBills.isEmpty {
                            EasyCard(tint: Color.green) {
                                Text("Nothing to do").font(.title.bold())
                                Text("The rest of this month’s bills pay by themselves.").font(.title3)
                            }
                        } else if s.billsTotal > 0 {
                            EasyCard(tint: Color.green) {
                                Text("All paid").font(.title.bold())
                                Text("Every bill for \(ym.title) is paid. Well done.").font(.title3)
                            }
                        }
                        EasyCard {
                            Text("This month").font(.subheadline.weight(.bold))
                            HStack { Text("Bills left to pay"); Spacer(); Text(money(s.billsLeft)).font(.title3.bold()) }
                            HStack { Text("Money still to come"); Spacer(); Text(money(s.inExpected - s.inReceived)).font(.title3.bold()) }
                        }
                        if let a = acct {
                            EasyCard(tint: a.health.color) {
                                Text("Your account").font(.subheadline.weight(.bold))
                                Text(a.headline).font(.title.bold())
                                Text(a.detail).font(.title3)
                            }
                        } else {
                            EasyCard {
                                Text("Your account").font(.subheadline.weight(.bold))
                                Text("Tell us what is in your account and we will tell you if you will have enough.").font(.title3)
                                EasyButton(title: "Tell us my balance") { store.sheet = .startBalance }
                            }
                        }
                        EasyButton(title: "See all my bills") { go(.bills) }
                        EasyButton(title: "Add a bill") { store.sheet = .item(nil) }
                    }
                }
                .padding(16)
            }
            .background { Backdrop() }
            .navigationTitle(greetingText())
        }
    }
}

struct EasyOverview: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.palette) private var palette
    let go: (EasyTab) -> Void
    @State private var nextMonth = false

    private func billsLine(unpaid: Int, left: Double, late: Int) -> String {
        if unpaid == 0 { return "Every bill is paid" }
        var line = "\(money(left)) still to pay"
        if late > 0 { line += late == 1 ? ". 1 is late" : ". \(late) are late" }
        return line
    }

    private func easyStatus(late: Int, soon: Int, model: Budget.CashModel, notPast: Bool) -> (level: Health, head: String) {
        if late > 0 { return (.red, late == 1 ? "1 bill is late" : "\(late) bills are late") }
        if notPast && model.below0 { return (.red, "Your balance may run short") }
        if soon > 0 { return (.amber, soon == 1 ? "1 bill is due soon" : "\(soon) bills are due soon") }
        if notPast && model.under { return (.amber, "Watch your balance") }
        return (.green, "Everything looks good")
    }

    var body: some View {
        let b = store.budget
        let ym = YM.current.adding(nextMonth ? 1 : 0)
        let t = YMD.today
        let rows = b.rows(in: ym)
        let bills = rows.filter { $0.item.type == .bill }
        let ins = rows.filter { $0.item.type == .income }
        let paidB = bills.filter { $0.isPaid }
        let unpaidB = bills.filter { !$0.isPaid }
        let late = unpaidB.filter { $0.due < t }
        let soon = unpaidB.filter { $0.due >= t && $0.due.dayNumber - t.dayNumber <= 3 }
        let expIn = ins.reduce(0.0) { $0 + $1.shownAmount }
        let gotIn = ins.filter { $0.isPaid }.reduce(0.0) { $0 + $1.shownAmount }
        let model = b.cashModel(ym)
        let notPast = ym >= YM.current
        let status = easyStatus(late: late.count, soon: soon.count, model: model, notPast: notPast)
        let level = status.level
        let head = status.head
        let coming = Array(rows.filter { !$0.isPaid }.prefix(4))
        let acct = b.easyAccount(model)
        let s = b.stats(in: ym)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Month", selection: $nextMonth) {
                        Text("This month").tag(false)
                        Text("Next month").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if b.items.isEmpty {
                        EasyCard { Text("Nothing to show yet").font(.title.bold()); Text("Add your first bill and this page will fill in.").font(.title3) }
                    } else {
                        EasyCard(tint: level.color) {
                            HStack(spacing: 12) {
                                Image(systemName: level == .green ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").font(.largeTitle)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(head).font(.title.bold())
                                    Text(level == .green ? "Nothing needs your attention right now." : "Open Home to take care of it.").font(.title3)
                                }
                            }
                        }
                        if !bills.isEmpty {
                            EasyCard {
                                Text("Bills").font(.subheadline.weight(.bold))
                                Text("\(paidB.count) of \(bills.count) paid").font(.title.bold())
                                ProgressView(value: Double(paidB.count) / Double(max(1, bills.count))).tint(late.isEmpty ? palette.brand : Color.red).scaleEffect(x: 1, y: 2.5)
                                Text(billsLine(unpaid: unpaidB.count, left: s.billsLeft, late: late.count)).font(.title3)
                            }
                        }
                        if !ins.isEmpty {
                            EasyCard {
                                Text("Money in").font(.subheadline.weight(.bold))
                                Text("\(money(gotIn, whole: true)) of \(money(expIn, whole: true))").font(.title.bold())
                                ProgressView(value: expIn > 0 ? gotIn / expIn : 0).tint(palette.accent).scaleEffect(x: 1, y: 2.5)
                                Text(expIn > gotIn ? "\(money(expIn - gotIn)) still to come" : "All received").font(.title3)
                            }
                        }
                        if s.planned > 0 {
                            EasyCard {
                                Text("Everyday spending").font(.subheadline.weight(.bold))
                                Text("\(money(s.spent, whole: true)) of \(money(s.planned, whole: true))").font(.title.bold())
                                ProgressView(value: min(1, s.spent / s.planned)).tint(s.spent > s.planned ? Color.red : palette.primary).scaleEffect(x: 1, y: 2.5)
                                Text(s.spent > s.planned ? "\(money(s.spent - s.planned)) over what you planned" : "\(money(s.planned - s.spent)) left to spend").font(.title3)
                            }
                        }
                        if let a = acct {
                            EasyCard {
                                Text("Your account").font(.subheadline.weight(.bold))
                                Text(a.headline).font(.title.bold())
                                HStack { Text("Starts at"); Spacer(); Text(money(model.start)).bold() }
                                HStack { Text("Lowest point"); Spacer(); Text(money(model.low)).bold() }
                                HStack { Text("Ends at"); Spacer(); Text(money(model.end)).bold() }
                            }
                        } else {
                            EasyCard {
                                Text("Your account").font(.subheadline.weight(.bold))
                                Text("Tell us what is in your account and we will show if you will have enough.").font(.title3)
                                EasyButton(title: "Tell us my balance") { store.sheet = .startBalance }
                            }
                        }
                        EasyCard {
                            Text("Coming up").font(.subheadline.weight(.bold))
                            if coming.isEmpty { Text("Nothing else this month.").font(.title3) }
                            ForEach(coming) { r in
                                let w = easyWhen(r.due, income: r.item.type == .income)
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.item.name).font(.title3.bold())
                                        Text(w.text).foregroundStyle(w.late ? Color.red : Color.secondary)
                                    }
                                    Spacer()
                                    Text((r.item.type == .income ? "+" : "") + money(r.item.amount)).font(.title3.bold())
                                }
                            }
                        }
                        EasyButton(title: "See all my bills") { go(.bills) }
                    }
                }
                .padding(16)
            }
            .background { Backdrop() }
            .navigationTitle("Overview")
        }
    }
}

struct EasyBills: View {
    @Environment(BudgetStore.self) private var store
    @State private var nextMonth = false

    var body: some View {
        let b = store.budget
        let ym = YM.current.adding(nextMonth ? 1 : 0)
        let rows = b.rows(in: ym)
        let toPay = rows.filter { !$0.isPaid && $0.item.type == .bill }
        let coming = rows.filter { !$0.isPaid && $0.item.type == .income }
        let done = rows.filter { $0.isPaid }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Month", selection: $nextMonth) {
                        Text("This month").tag(false)
                        Text("Next month").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(ym.title).font(.subheadline).foregroundStyle(.secondary)
                    if rows.isEmpty {
                        EasyCard { Text("Nothing here yet.").font(.title3) }
                    }
                    if !toPay.isEmpty { Text("Bills to pay").font(.title3.bold()); ForEach(toPay) { EasyBillRow(row: $0) } }
                    if !coming.isEmpty { Text("Money coming in").font(.title3.bold()); ForEach(coming) { EasyBillRow(row: $0) } }
                    if !done.isEmpty { Text("Done").font(.title3.bold()); ForEach(done) { EasyBillRow(row: $0) } }
                    EasyButton(title: "Add a bill", prominent: true) { store.sheet = .item(nil) }
                }
                .padding(16)
            }
            .background { Backdrop() }
            .navigationTitle("My bills")
        }
    }
}

struct EasyBillRow: View {
    @Environment(BudgetStore.self) private var store
    let row: BillRow

    var body: some View {
        let isIncome = row.item.type == .income
        let w = easyWhen(row.due, income: isIncome)
        let verb = isIncome ? "Received" : "Paid"
        let paidOn = YMD(iso: row.pay?.on ?? "")?.nice ?? ""
        let lateTint: Color? = (!row.isPaid && w.late) ? Color.red : nil
        EasyCard(tint: lateTint) {
            HStack {
                Text(row.item.name).font(.title3.bold())
                Spacer()
                Text(money(row.shownAmount)).font(.title3.bold())
            }
            if row.isPaid {
                Label("\(verb) \(paidOn)", systemImage: "checkmark").font(.headline).foregroundStyle(Color.green)
            } else {
                Label(w.text, systemImage: w.late ? "exclamationmark.triangle.fill" : "calendar").font(.headline).foregroundStyle(w.late ? Color.red : Color.primary)
                if let note = store.budget.linkWords(for: row.item) { Text(note).font(.callout) }
            }
            if !row.isPaid && row.item.automatic {
                Text("This one \(isIncome ? "arrives" : "pays") by itself on its date.").font(.callout)
            } else if !row.isPaid {
                EasyButton(title: isIncome ? "I got paid" : "I paid it", icon: "checkmark", prominent: true) { store.setPaid(row, true) }
            } else if !row.item.automatic {
                EasyButton(title: "Undo") { store.setPaid(row, false) }
            }
            Button("Change or remove") { store.sheet = .item(row.item) }
                .font(.callout)
                .underline()
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

struct EasyMore: View {
    @Environment(BudgetStore.self) private var store
    @AppStorage("easyMode") private var easy = false
    @AppStorage("easyXL") private var extraLarge = false
    @State private var backupURL: URL?

    var body: some View {
        let b = store.budget
        let start = b.cashStart(YM.current, b.cash)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    EasyCard {
                        Text("Print size").font(.subheadline.weight(.bold))
                        Picker("Print size", selection: $extraLarge) {
                            Text("Large").tag(false)
                            Text("Extra large").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    EasyCard {
                        Text("My account balance").font(.subheadline.weight(.bold))
                        Text(start.kind == .unset ? "Not set yet." : "About \(money(start.v)) on the 1st of \(Calendar.current.monthSymbols[YM.current.m - 1]).").font(.title3)
                        EasyButton(title: start.kind == .unset ? "Tell us my balance" : "Change my balance") { store.sheet = .startBalance }
                    }
                    if store.library.budgets.count > 1 {
                        EasyCard {
                            Text("My budgets").font(.subheadline.weight(.bold))
                            Text("Showing: \(b.name)").font(.title3)
                            ForEach(store.library.budgets.filter { $0.id != store.library.activeID }) { o in
                                EasyButton(title: "Show \(o.name)") { store.switchBudget(o.id) }
                            }
                        }
                    }
                    EasyCard {
                        Text("Keep a copy").font(.subheadline.weight(.bold))
                        Text("Save a backup copy of your budget on this phone, in case you ever need it.").font(.title3)
                        if let url = backupURL {
                            ShareLink(item: url) {
                                Label("Save a backup copy", systemImage: "square.and.arrow.up").font(.title3.weight(.bold)).frame(maxWidth: .infinity, minHeight: 56)
                            }
                            .themedButton()
                            .controlSize(.large)
                        }
                        EasyButton(title: "Restore from a backup file") { store.showRestorePicker = true }
                    }
                    EasyCard {
                        Text("The full app").font(.subheadline.weight(.bold))
                        Text("It has charts, spending budgets, loans, colors and more.").font(.title3)
                        EasyButton(title: "Use the full app") { easy = false }
                    }
                    Text("TapBudget version \(AppInfo.version)").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .background { Backdrop() }
            .navigationTitle("More")
            .task(id: store.revision) { backupURL = store.backupFileURL() }
        }
    }
}

// MARK: - Restore from a backup file: asks what to do first

struct RestoreSheet: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var target = "new"                  // "new", or the id of an existing budget
    @State private var mode: RestoreMode = .replace
    @State private var newName = ""
    @State private var confirmReplace = false
    @State private var started = false
    @State private var snapshot: PendingRestore?       // this sheet keeps its own copy, so it does not flicker while it closes

    private var pending: PendingRestore? { snapshot ?? store.pendingRestore }

    private func summary(_ b: Budget) -> String {
        var bits = ["\(b.items.count) \(b.items.count == 1 ? "item" : "items")"]
        if !b.paid.isEmpty { bits.append("\(b.paid.count) \(b.paid.count == 1 ? "payment" : "payments") recorded") }
        if !b.loans.isEmpty { bits.append("\(b.loans.count) \(b.loans.count == 1 ? "loan or card" : "loans and cards")") }
        if !b.cash.starts.isEmpty || !b.cash.actuals.isEmpty { bits.append("balances") }
        return bits.joined(separator: ", ")
    }

    private func start(_ p: PendingRestore) {
        guard !started else { return }
        started = true
        snapshot = p
        newName = p.budgets.first?.name ?? ""
        // a budget with the same name is the likely target, unless the only budget is the untouched example
        let loneExample = store.library.budgets.count == 1 && store.library.budgets[0].isSample
        if p.budgets.count == 1, !loneExample, let match = store.library.budgets.first(where: { $0.name.lowercased() == newName.lowercased() }) { target = match.id }
    }

    private func finish(_ p: PendingRestore) {
        let text = store.applyRestore(p, mode: target == "new" ? .addNew : mode, into: target == "new" ? nil : target, newName: newName)
        dismiss()
        store.say(text)
    }

    var body: some View {
        NavigationStack {
            if let p = pending {
                Form {
                    Section {
                        if p.budgets.count == 1, let b = p.budgets.first {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(b.name).font(.headline)
                                Text(summary(b)).foregroundStyle(.secondary)
                                Text(p.fileName.isEmpty ? "Pasted text" : p.fileName).font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(p.budgets) { b in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.name).font(.headline)
                                    Text(summary(b)).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(p.budgets.count == 1 ? "In this backup" : "In this file: \(p.budgets.count) budgets")
                    }

                    if p.budgets.count == 1 {
                        Section {
                            Picker("Restore into", selection: $target) {
                                Text("A new budget").tag("new")
                                ForEach(store.library.budgets) { b in Text("Existing: \(b.name)").tag(b.id) }
                            }
                            if target == "new" {
                                TextField("Name for the new budget", text: $newName)
                            } else {
                                Picker("How to restore", selection: $mode) {
                                    Text("Replace everything in it").tag(RestoreMode.replace)
                                    Text("Merge: add and update, keep the rest").tag(RestoreMode.merge)
                                }
                            }
                        } footer: {
                            if target == "new" {
                                if store.library.budgets.count == 1 && store.library.budgets[0].isSample {
                                    Text("This replaces the example budget.")
                                } else {
                                    Text("Nothing you have now is changed.")
                                }
                            } else if let t = store.library.budgets.first(where: { $0.id == target }) {
                                Text(mode == .replace ? "This overwrites what is saved in “\(t.name)”." : "Items with the same id are updated. Everything else in “\(t.name)” stays.")
                            }
                        }
                    } else {
                        Section {
                            Text(store.library.budgets.count == 1 && store.library.budgets[0].isSample
                                 ? "These are added as new budgets, and they replace the example budget."
                                 : "These are added as new budgets. Nothing you have now is changed.")
                        }
                    }

                    Section {
                        Button {
                            if target != "new" && mode == .replace { confirmReplace = true } else { finish(p) }
                        } label: {
                            Text(p.budgets.count > 1 ? "Add all \(p.budgets.count) budgets" : (target == "new" ? "Add as a new budget" : (mode == .replace ? "Replace it" : "Merge into it")))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .themedButton(prominent: true)
                        .controlSize(.large)
                        .listRowBackground(Color.clear)
                        .disabled(target == "new" && p.budgets.count == 1 && newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .navigationTitle("Restore a backup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.pendingRestore = nil; dismiss() } } }
                .task { start(p) }
                .confirmationDialog("Replace everything in this budget?", isPresented: $confirmReplace, titleVisibility: .visible) {
                    Button("Replace it", role: .destructive) { finish(p) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Its items, payments and balances are overwritten by the backup. This cannot be undone.")
                }
            } else {
                ContentUnavailableView("Nothing to restore", systemImage: "doc.questionmark", description: Text("Choose a backup file first."))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            }
        }
    }
}

// MARK: - The three gauges on Overview: five looks, chosen in Wallpaper and colors

struct GaugeStrip: View {
    @Environment(BudgetStore.self) private var store
    @Environment(\.palette) private var palette

    private func tint(_ f: GaugeFigure) -> Color {
        switch f.kind {
        case .bills: return palette.brand
        case .moneyIn: return palette.accent
        case .spending: return f.over ? Color.red : palette.primary
        }
    }

    var body: some View {
        let t = store.budget.theme
        let figures = gaugeFigures(store.budget.stats(in: store.viewing))
        if t.gauge == .bars {
            GaugeBars(figures: figures, tint: tint, showDetail: t.gaugeAmounts)
        } else {
            HStack(spacing: 10) {
                ForEach(figures) { f in
                    GaugeTile(figure: f, tint: tint(f), style: t.gauge, showDetail: t.gaugeAmounts)
                }
            }
        }
    }
}

struct GaugeTile: View {
    let figure: GaugeFigure
    let tint: Color
    let style: GaugeStyle
    let showDetail: Bool

    var body: some View {
        VStack(spacing: 8) {
            dial
            VStack(spacing: 2) {
                Text(figure.title).font(.footnote.weight(.semibold))
                if showDetail {
                    Text(figure.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .surface(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(figure.spoken)
    }

    @ViewBuilder private var dial: some View {
        switch style {
        case .thin: RingDial(figure: figure, tint: tint, thin: true)
        case .arc: ArcDial(figure: figure, tint: tint)
        case .capsules: MeterDial(figure: figure, tint: tint)
        default: RingDial(figure: figure, tint: tint, thin: false)
        }
    }
}

/// A full ring with a soft glow, or a thin one with a bigger number.
struct RingDial: View {
    let figure: GaugeFigure
    let tint: Color
    var thin = false

    var body: some View {
        let f = min(1, max(0, figure.fraction))
        let w: CGFloat = thin ? 4 : 11
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: w)
            Circle()
                .trim(from: 0, to: max(0.004, f))
                .stroke(AngularGradient(colors: [tint.opacity(thin ? 1 : 0.55), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(max(8, 360 * f))),
                        style: StrokeStyle(lineWidth: w, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(thin ? 0 : 0.40), radius: 5)
            Text(figure.center)
                .font(.system(size: thin ? 27 : 21, weight: thin ? .semibold : .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, w + 6)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 96)
        .animation(.snappy, value: f)
    }
}

/// An open gauge, three quarters of a circle, like a dial.
struct ArcDial: View {
    let figure: GaugeFigure
    let tint: Color

    var body: some View {
        let f = min(1, max(0, figure.fraction))
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: max(0.004, 0.75 * f))
                .stroke(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(max(8, 270 * f))),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: tint.opacity(0.35), radius: 4)
            Text(figure.center)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 14)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 96)
        .animation(.snappy, value: f)
    }
}

/// A tall meter that fills from the bottom, with the number underneath.
struct MeterDial: View {
    let figure: GaugeFigure
    let tint: Color

    var body: some View {
        let f = min(1, max(0, figure.fraction))
        VStack(spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.10))
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                        .frame(height: max(14, g.size.height * f))
                        .shadow(color: tint.opacity(0.35), radius: 5)
                }
            }
            .frame(width: 40, height: 96)
            Text(figure.center)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .animation(.snappy, value: f)
    }
}

/// One compact card with three bars.
struct GaugeBars: View {
    let figures: [GaugeFigure]
    let tint: (GaugeFigure) -> Color
    let showDetail: Bool

    var body: some View {
        VStack(spacing: 16) {
            ForEach(figures) { f in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(f.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(f.center).font(.system(.subheadline, design: .rounded).weight(.bold)).monospacedDigit()
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.10))
                            Capsule()
                                .fill(LinearGradient(colors: [tint(f).opacity(0.6), tint(f)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(12, g.size.width * min(1, max(0, f.fraction))))
                        }
                    }
                    .frame(height: 12)
                    if showDetail { Text(f.detail).font(.caption).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(f.spoken)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .surface(RoundedRectangle(cornerRadius: 26))
        .animation(.snappy, value: figures.map(\.fraction))
    }
}

/// A small picture of a style, for the chooser in Wallpaper and colors.
struct GaugeSample: View {
    let style: GaugeStyle
    let tint: Color

    var body: some View {
        switch style {
        case .rings, .thin:
            let w: CGFloat = style == .rings ? 8 : 3
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: w)
                Circle().trim(from: 0, to: 0.7).stroke(tint, style: StrokeStyle(lineWidth: w, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 50, height: 50)
        case .arc:
            ZStack {
                Circle().trim(from: 0, to: 0.75).stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                Circle().trim(from: 0, to: 0.75 * 0.7).stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            }
            .rotationEffect(.degrees(135))
            .frame(width: 50, height: 50)
        case .bars:
            VStack(spacing: 7) {
                ForEach([0.9, 0.6, 0.35], id: \.self) { f in
                    Capsule().fill(Color.primary.opacity(0.12)).frame(height: 7)
                        .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: 60 * f, height: 7) }
                }
            }
            .frame(width: 60)
        case .capsules:
            HStack(spacing: 6) {
                ForEach([0.85, 0.55, 0.3], id: \.self) { f in
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.12)).frame(width: 14, height: 50)
                        .overlay(alignment: .bottom) { RoundedRectangle(cornerRadius: 6).fill(tint).frame(width: 14, height: 50 * f) }
                }
            }
        }
    }
}
