import AppKit

final class PasteboardObserver {
    static let maxBytes = 256 * 1024
    static let hardSkipBytes = 5 * 1024 * 1024

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

        // Hard size guard: check raw data size BEFORE materializing as Swift String.
        if let size = source.data(forType: .string)?.count, size > Self.hardSkipBytes {
            return false
        }

        guard let raw = source.string(forType: .string) else { return false }
        let app = frontmost()
        if filter().reasonToSkip(types: types, content: raw,
                                 sourceBundleID: app.bundleID,
                                 blacklist: blacklist()) != nil {
            return false
        }

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
