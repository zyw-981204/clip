import Foundation

/// Snapshot of retention settings, loaded from UserDefaults with sensible
/// defaults. The pruner reads this on every tick so the UI can change limits
/// live without a restart.
///
/// Text and image rows have separate count caps because the disk pressure
/// scales very differently — 500 text rows is ~50 KB, 500 image rows can be
/// hundreds of MB.
struct RetentionConfig {
    let maxItems: Int       // text rows
    let maxImageItems: Int  // image rows
    let maxDays: Int        // age cap (applies to both kinds)

    static func current() -> RetentionConfig {
        let d = UserDefaults.standard
        let items  = (d.object(forKey: "clip.retention.maxItems")      as? Int) ?? 500
        let images = (d.object(forKey: "clip.retention.maxImageItems") as? Int) ?? 100
        let days   = (d.object(forKey: "clip.retention.maxDays")       as? Int) ?? 30
        return RetentionConfig(maxItems: items, maxImageItems: images, maxDays: days)
    }
}
