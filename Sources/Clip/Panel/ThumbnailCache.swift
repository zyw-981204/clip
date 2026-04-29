import AppKit

/// In-memory cache of pre-rasterized 64×64 thumbnails (2× retina backing for
/// 32pt display) keyed by `clip_blobs.id`.
///
/// **Why pre-rasterize:** the obvious implementation —
/// `NSImage(size:flipped:_:)` with a draw closure — defers the expensive
/// downscale to every render call. With 1.5MB PNGs and SwiftUI re-rendering
/// all 10 rows on each selection change, that turns ↑↓ navigation into a
/// noticeable ~1s stall per keypress. Drawing the full-resolution source
/// into a 64×64 `NSBitmapImageRep` once and caching the resulting bitmap
/// makes subsequent renders trivial.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSNumber, NSImage>()

    /// Display size in points. Backing pixels are 2× this for Retina.
    static let displaySize: CGFloat = 32

    private init() {
        cache.countLimit = 200      // ≥ retention image cap (100) × 2
        cache.totalCostLimit = 32 * 1024 * 1024   // 32 MB ceiling
    }

    /// Return a cached 32×32 thumbnail or, on miss, decode the source PNG,
    /// rasterize it into a 64×64 bitmap aspect-fit, cache, and return.
    func thumbnail(for blobID: Int64, store: HistoryStore) -> NSImage? {
        let key = NSNumber(value: blobID)
        if let hit = cache.object(forKey: key) { return hit }

        guard let bytes = try? store.blob(id: blobID),
              let src = NSImage(data: bytes)
        else { return nil }

        let backing = Int(Self.displaySize * 2)        // 64×64 pixels
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: backing, pixelsHigh: backing,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Aspect-fit rect inside the 64×64 backing.
        let srcSize = src.size
        let target = CGFloat(backing)
        let scale = min(target / srcSize.width, target / srcSize.height)
        let drawW = srcSize.width * scale
        let drawH = srcSize.height * scale
        let drawX = (target - drawW) / 2
        let drawY = (target - drawH) / 2
        src.draw(in: NSRect(x: drawX, y: drawY, width: drawW, height: drawH))
        NSGraphicsContext.restoreGraphicsState()

        let thumb = NSImage(size: NSSize(width: Self.displaySize,
                                         height: Self.displaySize))
        thumb.addRepresentation(rep)
        cache.setObject(thumb, forKey: key, cost: backing * backing * 4)
        return thumb
    }

    /// Drop the cached entry — call when an image item is deleted so memory
    /// reclaims promptly even before NSCache decides to evict.
    func invalidate(blobID: Int64) {
        cache.removeObject(forKey: NSNumber(value: blobID))
    }
}
