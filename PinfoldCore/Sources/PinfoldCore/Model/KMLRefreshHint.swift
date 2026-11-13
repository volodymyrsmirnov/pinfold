import Foundation

/// Refresh hints in seconds (`<refreshInterval>`, `<minRefreshPeriod>`, `Cache-Control: max-age`),
/// made safe to store and to schedule with. A file or a server can write anything there: `inf`
/// and `nan` cannot be encoded as JSON, and a huge value overflows `Duration` when a timer is armed.
public enum KMLRefreshHint {
    /// The longest gap a hint may set: 30 days.
    public static let maxSeconds: TimeInterval = 30 * 24 * 3600

    /// `value` when it is finite and positive, capped at `maxSeconds`; `nil` otherwise.
    public static func sanitised(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return min(value, maxSeconds)
    }
}
