import Foundation

public struct PlanUsageSample: Sendable, Equatable {
    public var t: Date
    public var org: String
    /// 5-hour window percent.
    public var fiveHour: Double?
    /// Seven-day window percent.
    public var sevenDay: Double?
    public init(t: Date, org: String, fiveHour: Double?, sevenDay: Double?) {
        self.t = t; self.org = org; self.fiveHour = fiveHour; self.sevenDay = sevenDay
    }
}

public enum UsageLevel: Sendable, Equatable { case normal, warning, critical }

public struct PlanUsageSnapshot: Sendable, Equatable {
    public var updatedAt: Date
    public var org: String
    /// nil = show "—".
    public var fiveHour: Double?
    public var sevenDay: Double?
}

public enum PlanUsage {
    public static let fiveHourWindow: TimeInterval = 5 * 3600
    public static let sevenDayWindow: TimeInterval = 7 * 86400
    public static let warnAt: Double = 80
    public static let criticalAt: Double = 95

    /// Tolerant parse of `{"version":2,"samples":[{"t":ms,"org":uuid,"u":{"fh":%,"sd":%}}]}`; bad samples skipped.
    public static func parse(_ data: Data) -> [PlanUsageSample] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [Any] else { return [] }
        return samples.compactMap { item in
            guard let s = item as? [String: Any], let t = (s["t"] as? NSNumber)?.doubleValue,
                  let org = s["org"] as? String, !org.isEmpty else { return nil }
            let u = s["u"] as? [String: Any]
            let fh = (u?["fh"] as? NSNumber)?.doubleValue
            let sd = (u?["sd"] as? NSNumber)?.doubleValue
            return PlanUsageSample(t: Date(timeIntervalSince1970: t / 1000), org: org, fiveHour: fh, sevenDay: sd)
        }
    }

    public static func latestPerOrg(_ samples: [PlanUsageSample]) -> [String: PlanUsageSample] {
        var out: [String: PlanUsageSample] = [:]
        for s in samples where (out[s.org].map { s.t > $0.t } ?? true) { out[s.org] = s }
        return out
    }

    /// Latest sample by `t` for `org` (or across all orgs when nil).
    public static func latest(_ samples: [PlanUsageSample], org: String? = nil) -> PlanUsageSample? {
        samples.filter { org == nil || $0.org.caseInsensitiveCompare(org!) == .orderedSame }.max { $0.t < $1.t }
    }

    public static func snapshot(_ samples: [PlanUsageSample], org: String? = nil, now: Date = Date()) -> PlanUsageSnapshot? {
        guard let s = latest(samples, org: org) else { return nil }
        let age = now.timeIntervalSince(s.t)
        return PlanUsageSnapshot(updatedAt: s.t, org: s.org,
                                 fiveHour: age > fiveHourWindow ? nil : s.fiveHour,
                                 sevenDay: age > sevenDayWindow ? nil : s.sevenDay)
    }

    public static func level(_ percent: Double?) -> UsageLevel {
        guard let p = percent else { return .normal }
        if p >= criticalAt { return .critical }
        if p >= warnAt { return .warning }
        return .normal
    }

    public static func display(_ percent: Double?) -> String {
        guard let p = percent else { return "—" }
        return "\(Int(p.rounded()))%"
    }
}
