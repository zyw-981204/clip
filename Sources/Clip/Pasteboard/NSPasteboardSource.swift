import AppKit

final class NSPasteboardSource: PasteboardSource {
    private let pb: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pb = pasteboard }

    var changeCount: Int { pb.changeCount }
    func types() -> [NSPasteboard.PasteboardType] { pb.types ?? [] }
    func string(forType t: NSPasteboard.PasteboardType) -> String? { pb.string(forType: t) }
    func data(forType t: NSPasteboard.PasteboardType) -> Data? { pb.data(forType: t) }
}
