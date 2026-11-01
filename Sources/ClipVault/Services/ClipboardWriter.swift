import AppKit
import Foundation

public final class ClipboardWriter: @unchecked Sendable {
    private let assetStore: AssetStore
    private let pasteboard: NSPasteboard

    public init(assetStore: AssetStore, pasteboard: NSPasteboard = .general) {
        self.assetStore = assetStore
        self.pasteboard = pasteboard
    }

    @discardableResult
    public func restore(_ item: ClipboardItem) throws -> Bool {
        var binaryRepresentations: [String: Data] = [:]
        for (type, path) in item.assetPaths {
            binaryRepresentations[type] = try assetStore.read(path)
        }
        guard !item.representations.isEmpty || !binaryRepresentations.isEmpty else {
            throw ClipboardStoreError.unsupportedContent
        }

        let writeToPasteboard = { [self] in
            let pasteboardItem = NSPasteboardItem()
            var hasRepresentation = false
            for (type, value) in item.representations {
                let pasteboardType = NSPasteboard.PasteboardType(type)
                let succeeded: Bool
                if ClipboardNormalizer.richTextTypes.contains(type) {
                    succeeded = pasteboardItem.setData(Data(value.utf8), forType: pasteboardType)
                } else {
                    succeeded = pasteboardItem.setString(value, forType: pasteboardType)
                }
                hasRepresentation = hasRepresentation || succeeded
            }
            for (type, data) in binaryRepresentations {
                hasRepresentation = pasteboardItem.setData(
                    data,
                    forType: NSPasteboard.PasteboardType(type)
                ) || hasRepresentation
            }
            guard hasRepresentation else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects([pasteboardItem])
        }

        let succeeded = Thread.isMainThread
            ? writeToPasteboard()
            : DispatchQueue.main.sync(execute: writeToPasteboard)
        guard succeeded else {
            throw ClipboardStoreError.database("macOS rejected the clipboard write.")
        }
        return true
    }
}
