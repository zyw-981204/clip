import AppKit

/// Marked `@unchecked Sendable` because:
/// - `lastChangeCount` / `lastChangeAt` / `paused` are only mutated from the
///   serial timer queue, plus a few notification handlers (sleep/wake/lock/
///   unlock) which set `paused` atomically. The worst-case race is one
///   spurious tick on resume, which dedups via `insertOrPromote`.
/// - `store`, `filter`, `blacklist`, `frontmost`, `source` are themselves
///   thread-safe or pure functions.
final class PasteboardObserver: @unchecked Sendable {
    static let maxBytes = 256 * 1024
    static let hardSkipBytes = 5 * 1024 * 1024

    /// Pasteboard types we treat as images, in order of preference. PNG is
    /// the most common modern format; TIFF is the legacy macOS default;
    /// PDF covers vector copies (e.g., from Preview / Keynote).
    static let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png,                                        "image/png"),
        (.tiff,                                       "image/tiff"),
        (NSPasteboard.PasteboardType("com.adobe.pdf"), "application/pdf"),
    ]

    private let source: PasteboardSource
    private let store: HistoryStore
    private let filter: () -> PrivacyFilter
    private let blacklist: () -> Set<String>
    private let frontmost: () -> (bundleID: String?, name: String?)
    private(set) var lastChangeCount: Int

    // Adaptive timer state
    private var timer: DispatchSourceTimer?
    private var lastChangeAt: Int64 = 0
    private var paused: Bool = false
    private let queue = DispatchQueue(label: "clip.pasteboard.observer", qos: .utility)
    private var notificationTokens: [NSObjectProtocol] = []

    init(source: PasteboardSource, store: HistoryStore,
         filter: @escaping () -> PrivacyFilter,
         blacklist: @escaping () -> Set<String>,
         frontmost: @escaping () -> (bundleID: String?, name: String?))
    {
        self.source = source
        self.store = store
        self.filter = filter
        self.blacklist = blacklist
        self.frontmost = frontmost
        self.lastChangeCount = source.changeCount
    }

    deinit {
        timer?.cancel()
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        for token in notificationTokens {
            ws.removeObserver(token)
            dnc.removeObserver(token)
        }
    }

    @discardableResult
    func tick(now: Int64) throws -> Bool {
        let cc = source.changeCount
        guard cc != lastChangeCount else { return false }
        lastChangeCount = cc

        let types = Set(source.types())
        let app = frontmost()

        // Privacy filter: bundle-id blacklist + concealed/transient/auto-gen
        // markers + internal-paste guard. Applied first because it's cheap
        // and short-circuits both text and image paths. We pass a non-empty
        // placeholder so the filter's "empty-after-trim" rule (which is a
        // text-only concern) doesn't fire here; each branch below verifies
        // its own content non-emptiness.
        if filter().reasonToSkip(types: types, content: "x",
                                 sourceBundleID: app.bundleID,
                                 blacklist: blacklist()) != nil {
            return false
        }

        // Text branch — preferred when text is present, since most "copy from
        // a webpage" cases pull both an image render and the underlying text
        // and the user almost always means the text.
        if types.contains(.string) {
            if let size = source.data(forType: .string)?.count, size > Self.hardSkipBytes {
                return false
            }
            if let raw = source.string(forType: .string),
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let (content, truncated) = ClipItem.truncateIfNeeded(raw, limit: Self.maxBytes)
                let item = ClipItem(
                    content: content,
                    contentHash: ClipItem.contentHash(of: content),
                    sourceBundleID: app.bundleID,
                    sourceAppName: app.name,
                    createdAt: now,
                    pinned: false,
                    byteSize: ClipItem.byteSize(of: content),
                    truncated: truncated
                )
                try store.insertOrPromote(item, now: now)
                return true
            }
        }

        // Image branch — only if no usable text was on the pasteboard.
        for (uti, mime) in Self.imageTypes {
            guard types.contains(uti) else { continue }
            guard let bytes = source.data(forType: uti) else { continue }
            // 5 MB cap on raw bytes (matches text hardSkipBytes).
            guard bytes.count <= Self.hardSkipBytes else { return false }
            try store.insertImage(
                bytes: bytes,
                mimeType: mime,
                sourceBundleID: app.bundleID,
                sourceAppName: app.name,
                now: now
            )
            return true
        }

        return false
    }

    func resetBaseline() { lastChangeCount = source.changeCount }

    // MARK: - Adaptive timer + lifecycle (Task 33)

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { [weak self] in self?.fire() }
        reschedule(t, interval: 1.0)
        t.resume()
        self.timer = t
        installLifecycleObservers()
    }

    func pause() { paused = true }
    func resume() { resetBaseline(); paused = false }

    private func fire() {
        guard !paused else { return }
        let now = Int64(Date().timeIntervalSince1970)
        do {
            let changed = try tick(now: now)
            if changed { lastChangeAt = now }
            if let t = timer { reschedule(t, interval: pickInterval(now: now)) }
        } catch {
            // log only; never crash the polling loop
        }
    }

    private func pickInterval(now: Int64) -> TimeInterval {
        let ago = now - lastChangeAt
        if ago < 60   { return 0.5 }
        if ago > 300  { return 3.0 }
        return 1.0
    }

    private func reschedule(_ t: DispatchSourceTimer, interval: TimeInterval) {
        t.schedule(deadline: .now() + interval, repeating: interval,
                   leeway: .milliseconds(100))
    }

    private func installLifecycleObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        notificationTokens.append(ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.paused = true })
        notificationTokens.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.resetBaseline(); self?.paused = false })

        let dnc = DistributedNotificationCenter.default()
        notificationTokens.append(dnc.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil
        ) { [weak self] _ in self?.paused = true })
        notificationTokens.append(dnc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil
        ) { [weak self] _ in self?.resetBaseline(); self?.paused = false })
    }
}
