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

struct Budget: Identifiable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var items: [Item] = []
    var paid: [String: Pay] = [:]
    var loans: [Loan] = []
    var cash = Cash()
    var isSample = false

    enum CodingKeys: String, CodingKey { case id, name, items, paid = "pay", loans, cash, isSample = "sample" }

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

// MARK: - The store: saving, automatic payments, and every change the screens make

enum SheetKind: Identifiable {
    case item(Item?)            // nil = a new item
    case startBalance
    case loan(Loan?)            // nil = a new loan or card
    case importBackup

    var id: String {
        switch self {
        case .item(let i): return "item-\(i?.id ?? "new")"
        case .startBalance: return "start"
        case .loan(let l): return "loan-\(l?.id ?? "new")"
        case .importBackup: return "import"
        }
    }
}

enum AppInfo {
    static let version = "1.0"
}

@MainActor
@Observable
final class BudgetStore {
    var library: Library
    var viewing: YM = .current
    var sheet: SheetKind?
    var toast: String?
    var revision = 0                                  // goes up on every change, so the charts know to redraw

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
        let b = Budget(name: name.isEmpty ? "New budget" : name)
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

    func deleteBudget() {
        guard library.budgets.count > 1 else { return }
        library.budgets.removeAll { $0.id == library.activeID }
        library.activeID = library.budgets[0].id
        save()
    }

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
    }

    func exportJSON() -> String {
        struct Out: Encodable { var app = "budget-tracker"; var version = 2; var name: String; var items: [Item]; var pay: [String: Pay]; var loans: [Loan]; var cash: Cash }
        let b = budget
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(Out(name: b.name, items: b.items, pay: b.paid, loans: b.loans, cash: b.cash)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Adds the pasted backup as a new budget. Returns an error message, or nil if it worked.
    func importBackup(_ text: String) -> String? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let backup = try? JSONDecoder().decode(Backup.self, from: data), let items = backup.items else {
            return "That does not look like a TapBudget backup."
        }
        var b = Budget(name: backup.name ?? "Imported budget")
        b.items = items
        b.paid = backup.pay ?? [:]
        b.loans = backup.loans ?? []
        b.cash = backup.cash ?? Cash()
        library.budgets.append(b)
        library.activeID = b.id
        save()
        return nil
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

// MARK: - Shared look: Liquid Glass on the controls that float, plain cards for the content

struct Backdrop: View {
    var body: some View {
        LinearGradient(colors: [Color.teal.opacity(0.30), Color.cyan.opacity(0.10), Color(uiColor: .systemBackground)],
                       startPoint: .top, endPoint: .center)
            .ignoresSafeArea()
    }
}

struct CardSurface: ViewModifier {
    let glass: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if glass {
            content.glassEffect(.regular, in: .rect(cornerRadius: 26))
        } else {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
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
            .glassEffect(.regular.tint(h.color.opacity(0.35)), in: .capsule)
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
                .glassEffect(.regular, in: .capsule)
                Button("Today") { store.viewing = .current }
                    .buttonStyle(.glass)
                HealthPill()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

struct BudgetMenu: View {
    @Environment(BudgetStore.self) private var store
    var body: some View {
        Menu {
            Picker("Budget", selection: Binding(get: { store.library.activeID }, set: { store.switchBudget($0) })) {
                ForEach(store.library.budgets) { b in Text(b.name).tag(b.id) }
            }
        } label: {
            Label(store.budget.name, systemImage: "rectangle.stack")
        }
    }
}

struct BudgetChrome: ViewModifier {
    let title: String
    @Environment(BudgetStore.self) private var store

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { BudgetMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.sheet = .item(nil) } label: { Label("Add an item", systemImage: "plus") }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { MonthBar() }
    }
}

extension View {
    func budgetChrome(_ title: String) -> some View { modifier(BudgetChrome(title: title)) }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 96)
            .padding(.horizontal, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Root: five tabs, always all visible (the iOS 27 SDK crashes if a TabView selection points at a hidden tab)

enum AppTab: Hashable { case overview, bills, spending, insights, settings }

struct ContentView: View {
    @Environment(BudgetStore.self) private var store
    @State private var tab: AppTab = .overview

    var body: some View {
        @Bindable var store = store
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
        .sheet(item: $store.sheet) { kind in
            SheetRouter(kind: kind)
        }
        .overlay(alignment: .bottom) {
            if let text = store.toast { ToastView(text: text) }
        }
        .animation(.snappy, value: store.toast)
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

struct RingChip: View {
    let title: String
    let value: Double
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(label).font(.subheadline.bold()).monospacedDigit()
            }
            .frame(width: 84, height: 84)
            Text(title).font(.footnote.weight(.semibold))
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(label)")
    }
}

struct GaugeStrip: View {
    @Environment(BudgetStore.self) private var store
    var body: some View {
        let s = store.budget.stats(in: store.viewing)
        let billsFrac = s.billsTotal == 0 ? 0.0 : Double(s.billsPaid) / Double(s.billsTotal)
        let inFrac = s.inExpected == 0 ? 0.0 : s.inReceived / s.inExpected
        let spendFrac = s.planned == 0 ? 0.0 : s.spent / s.planned
        let inLabel = s.inExpected == 0 ? "–" : "\(Int((inFrac * 100).rounded()))%"
        let spendLabel = s.planned == 0 ? "–" : "\(Int((spendFrac * 100).rounded()))%"
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    RingChip(title: "Bills", value: billsFrac, label: "\(s.billsPaid)/\(s.billsTotal)", tint: .teal)
                    RingChip(title: "Money in", value: inFrac, label: inLabel, tint: .green)
                    RingChip(title: "Spending", value: spendFrac, label: spendLabel, tint: spendFrac > 1 ? .red : .orange)
                }
            }
        }
        .scrollClipDisabled()
    }
}

struct WaterfallChart: View {
    let model: Budget.CashModel

    private func color(_ c: Budget.Col) -> Color {
        switch c.kind {
        case .total: return .cyan
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
                    .glassEffect(.regular.tint(note.health.color.opacity(0.3)), in: .capsule)
                Spacer()
                Button { store.sheet = .startBalance } label: { Label(startText, systemImage: "pencil").font(.subheadline) }
                    .buttonStyle(.glass)
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
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func legendItems(_ m: Budget.CashModel) -> [(String, Color)] {
        var out: [(String, Color)] = [("Money in", .green), ("Bills", .purple), ("Total", .cyan)]
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
                            .tint(l.isCard ? Color.orange : Color.teal)
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
        NavigationStack {
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
    }
}

struct BillRowView: View {
    @Environment(BudgetStore.self) private var store
    let row: BillRow

    var body: some View {
        let late = !row.isPaid && row.item.type == .bill && row.due < YMD.today
        let isIncome = row.item.type == .income
        let effect = store.budget.effect(for: row.item, key: row.key, isPaid: row.isPaid)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { row.isPaid }, set: { store.setPaid(row, $0) })) { Text(isIncome ? "Received" : "Paid") }
                    .labelsHidden()
                    .fixedSize()
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
                    .background(Color.teal.opacity(0.16), in: .capsule)
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
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
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
                            .foregroundStyle(Color.teal.gradient)
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
    @State private var series: Budget.Series?
    @State private var plan: Budget.Series?
    @State private var visibleDays = 60.0
    @State private var baseDays = 60.0
    @State private var scrollDate = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
    @State private var selected: Date?
    @State private var nowText = ""
    @State private var nowDay = Date()
    @State private var formError: String?

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
            Button("Set it up") { store.sheet = .startBalance }.buttonStyle(.glass)
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
            .buttonStyle(.glass)
        }

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.0) { p in
                    Button(p.0) { setDays(p.1); goToday() }
                        .buttonStyle(.glass)
                        .tint(abs(visibleDays - p.1) < p.1 * 0.12 ? Color.teal : nil)
                }
            }
        }

        Chart {
            ForEach(s.points) { p in
                AreaMark(x: .value("Date", p.date), y: .value("Balance", p.value))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.teal.opacity(0.16))
                LineMark(x: .value("Date", p.date), y: .value("Balance", p.value), series: .value("Line", "Balance"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.teal)
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
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(kfmt(d)).font(.caption2) } }
            }
        }
        .frame(height: 270)
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
        guard let st else { return "Drag to move. Pinch, or use + and −, to zoom. Tap a bar for details." }
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
        .buttonStyle(.glassProminent)

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
    @State private var showNew = false
    @State private var showRename = false
    @State private var confirmDelete = false
    @State private var nameText = ""

    var body: some View {
        let b = store.budget
        let start = b.cashStart(store.viewing, b.cash)
        NavigationStack {
            Form {
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
                    ShareLink("Share a backup", item: store.exportJSON())
                    Button("Import a backup…") { store.sheet = .importBackup }
                } header: {
                    Text("Back up")
                } footer: {
                    Text("The backup is the same file the web app saves, so you can move a budget between them.")
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
            .budgetChrome("Settings")
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
                    Text("Paste the contents of a backup file from the web app. It is added as a new budget, so nothing you have here is replaced.")
                }
                if let error { Section { Text(error).foregroundStyle(Color.red) } }
            }
            .navigationTitle("Import a backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        if let e = store.importBackup(text) { error = e } else { store.say("Imported."); dismiss() }
                    }
                }
            }
        }
    }
}
