import AppKit
@testable import Clip

final class FakePasteboardSource: PasteboardSource {
    var changeCount: Int = 0
    var typesByCount: [Int: [NSPasteboard.PasteboardType]] = [:]
    var stringByCount: [Int: String] = [:]
    var dataByCount: [Int: Data] = [:]

    func types() -> [NSPasteboard.PasteboardType] { typesByCount[changeCount] ?? [] }
    func string(forType t: NSPasteboard.PasteboardType) -> String? { stringByCount[changeCount] }
    func data(forType t: NSPasteboard.PasteboardType) -> Data? { dataByCount[changeCount] }

    /// Simulate a new copy. Caller can override types and explicitly set raw data
    /// (used by the 5MB test which doesn't want to allocate a giant Swift String).
    func push(string: String, types: [NSPasteboard.PasteboardType] = [.string],
              dataOverride: Data? = nil) {
        changeCount += 1
        typesByCount[changeCount] = types
        stringByCount[changeCount] = string
        dataByCount[changeCount] = dataOverride ?? Data(string.utf8)
    }

    /// Push only data + types without a Swift string (for hard-skip > 5MB test).
    func pushDataOnly(data: Data, types: [NSPasteboard.PasteboardType] = [.string]) {
        changeCount += 1
        typesByCount[changeCount] = types
        dataByCount[changeCount] = data
        stringByCount[changeCount] = nil
    }
}
