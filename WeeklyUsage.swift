import Foundation

struct WeeklyUsage {
    let remaining: Double
    let resetsAt: Date?
    let fetchedAt: Date

    var display: String { "\(Int(remaining.rounded()))%" }

    static func parse(_ result: [String: Any], now: Date = Date()) -> WeeklyUsage? {
        // Weekly is identified by duration, never by primary/secondary position.
        let bucket: [String: Any]?
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any], !buckets.isEmpty {
            bucket = buckets["codex"] as? [String: Any]
        } else {
            let legacy = result["rateLimits"] as? [String: Any]
            let id = legacy?["limitId"] as? String
            bucket = id == nil || id == "codex" ? legacy : nil
        }
        guard let bucket else { return nil }
        for name in ["primary", "secondary"] {
            guard let window = bucket[name] as? [String: Any],
                  (window["windowDurationMins"] as? NSNumber)?.intValue == 10_080,
                  let used = window["usedPercent"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(),
                  used.doubleValue.isFinite else { continue }
            let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return WeeklyUsage(remaining: min(100, max(0, 100 - used.doubleValue)),
                               resetsAt: reset, fetchedAt: now)
        }
        return nil
    }

    func isCurrent(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) < 180 && (resetsAt == nil || now < resetsAt!)
    }
}

import CoreFoundation

func runUsageTests() {
    func window(_ used: Any, _ duration: Int) -> [String: Any] {
        ["usedPercent": used, "windowDurationMins": duration]
    }
    func parse(_ primary: [String: Any], _ secondary: [String: Any]? = nil) -> WeeklyUsage? {
        var bucket: [String: Any] = ["primary": primary]
        if let secondary { bucket["secondary"] = secondary }
        return WeeklyUsage.parse(["rateLimitsByLimitId": ["codex": bucket]])
    }
    precondition(parse(window(23, 10080))?.display == "77%")
    precondition(parse(window(89, 300), window(24, 10080))?.display == "76%")
    precondition(parse(window(0, 10080))?.display == "100%")
    precondition(parse(window(100, 10080))?.display == "0%")
    precondition(parse(window(103, 10080))?.display == "0%")
    precondition(parse(window(23, 300)) == nil)
    precondition(parse(window(NSNull(), 10080)) == nil)
    precondition(parse(window(true, 10080)) == nil)
    precondition(WeeklyUsage.parse(["rateLimitsByLimitId": ["other": ["primary": window(1, 10080)]]]) == nil)
    precondition(WeeklyUsage.parse(["rateLimits": ["primary": window(23, 10080)]])?.display == "77%")
    let now = Date()
    precondition(!WeeklyUsage(remaining: 77, resetsAt: nil, fetchedAt: now.addingTimeInterval(-181)).isCurrent(at: now))
    precondition(!WeeklyUsage(remaining: 77, resetsAt: now.addingTimeInterval(-1), fetchedAt: now).isCurrent(at: now))
    print("12 weekly-usage checks passed")
}
