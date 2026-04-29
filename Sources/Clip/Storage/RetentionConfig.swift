import Foundation

/// Snapshot of retention settings, loaded from UserDefaults with sensible
/// defaults (500 items, 30 days). The pruner reads this on every tick so the
/// UI can change limits live without a restart.
struct RetentionConfig {
    let maxItems: Int
    let maxDays: Int

    static func current() -> RetentionConfig {
        let d = UserDefaults.standard
        let items = (d.object(forKey: "clip.retention.maxItems") as? Int) ?? 500
        let days  = (d.object(forKey: "clip.retention.maxDays")  as? Int) ?? 30
        return RetentionConfig(maxItems: items, maxDays: days)
    }
}
