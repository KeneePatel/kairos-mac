import Foundation

/// What a key's account has left, as Ollama reports it (`GET https://ollama.com/api/balance`,
/// docs.ollama.com/api/balance, 2026-10-23): credits included for the plan's month and any bought
/// ones. Older plans report a session and a weekly allowance as percentages instead. Every key of
/// one account shares it; Ollama allows 10 of these requests a minute.
public struct CreditBalance: Sendable, Equatable {
    /// An older plan's allowance: how much is left, and when it fills again.
    public struct Window: Sendable, Equatable {
        public let remainingPercent: Double
        public let resets: Date?

        public init(remainingPercent: Double, resets: Date?) {
            self.remainingPercent = remainingPercent
            self.resets = resets
        }
    }

    /// Included credits left this period, and the period's whole allowance, in US dollars.
    public var included: Double?
    public var allowance: Double?
    /// When the period ends and the included credits fill again.
    public var periodEnd: Date?
    /// Bought credits left, in US dollars; they don't expire with the period.
    public var purchased: Double?
    public var session: Window?
    public var weekly: Window?

    public init(
        included: Double? = nil, allowance: Double? = nil, periodEnd: Date? = nil, purchased: Double? = nil,
        session: Window? = nil, weekly: Window? = nil
    ) {
        self.included = included
        self.allowance = allowance
        self.periodEnd = periodEnd
        self.purchased = purchased
        self.session = session
        self.weekly = weekly
    }

    /// Either shape, or a mix; fields it doesn't know are ignored.
    public static func parse(_ data: Data) throws(LLMError) -> CreditBalance {
        guard case .object(let reply) = try JSONValue(parsing: String(decoding: data, as: UTF8.self)) else {
            throw .invalidJSON("balance")
        }
        var balance = CreditBalance()
        if case .object(let included)? = reply["included"] {
            balance.included = number(included["balance_usd"])
            balance.allowance = number(included["allowance_usd"])
            if case .object(let period)? = included["period"] { balance.periodEnd = date(period["until"]) }
            balance.session = window(included["session"])
            balance.weekly = window(included["weekly"])
        }
        if case .object(let purchased)? = reply["purchased"] { balance.purchased = number(purchased["balance_usd"]) }
        guard balance != CreditBalance() else { throw .invalidJSON("balance has no amounts") }
        return balance
    }

    /// One bar for the included credits, or one each for an older plan's session and week.
    public var bars: [UsageBar] {
        var bars: [UsageBar] = []
        let bought = purchased ?? 0
        if let allowance, allowance > 0 {
            let left = max(0, included ?? 0)
            bars.append(
                UsageBar(
                    label: "Credits", left: min(1, left / allowance),
                    detail: "\(Self.dollars(left)) of \(Self.dollars(allowance)) left"
                        + (bought > 0 ? ", plus \(Self.dollars(bought)) bought" : ""),
                    resets: periodEnd, usedUp: left <= 0 && bought <= 0))
        } else if included != nil || purchased != nil {
            // No allowance this period (the Free plan's free models cost nothing): what's left to spend.
            let left = max(0, included ?? 0) + bought
            bars.append(
                UsageBar(
                    label: "Credits", left: nil,
                    detail: left > 0 ? "\(Self.dollars(left)) left" : "No credits: only the free models",
                    resets: periodEnd))
        }
        for (label, window) in [("This session", session), ("This week", weekly)] {
            guard let window else { continue }
            let percent = min(100, max(0, window.remainingPercent))
            bars.append(
                UsageBar(
                    label: label, left: percent / 100, detail: "\(Int(percent.rounded()))% left",
                    resets: window.resets, usedUp: percent <= 0))
        }
        return bars
    }

    /// "$3.20", whatever this Mac's region: Ollama bills in US dollars.
    static func dollars(_ value: Double) -> String { String(format: "$%.2f", value) }

    private static func number(_ value: JSONValue?) -> Double? {
        if case .number(let number)? = value { return number }
        return nil
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard case .string(let text)? = value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    private static func window(_ value: JSONValue?) -> Window? {
        guard case .object(let fields)? = value, let percent = number(fields["remaining_percent"]) else { return nil }
        return Window(remainingPercent: percent, resets: date(fields["resets_at"]))
    }
}
