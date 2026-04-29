import AppKit

protocol PasteboardSource {
    var changeCount: Int { get }
    func types() -> [NSPasteboard.PasteboardType]
    func string(forType: NSPasteboard.PasteboardType) -> String?
    func data(forType: NSPasteboard.PasteboardType) -> Data?
}
