import CryptoKit
import Foundation
import ImageIO

public enum ClipboardNormalizer {
    public static let plainTextTypes: Set<String> = [
        "public.utf8-plain-text",
        "public.plain-text",
        "NSStringPboardType",
        "com.apple.traditional-mac-plain-text"
    ]

    public static let richTextTypes: Set<String> = [
        "public.rtf",
        "NSRTFPboardType",
        "public.html"
    ]

    public static let urlTypes: Set<String> = ["public.url", "NSURLPboardType"]
    public static let fileURLTypes: Set<String> = ["public.file-url"]
    public static let imageTypes: Set<String> = [
        "public.png", "public.tiff", "public.jpeg", "public.gif", "com.apple.icns"
    ]

    public static let supportedTypes = plainTextTypes
        .union(richTextTypes)
        .union(urlTypes)
        .union(fileURLTypes)
        .union(imageTypes)

    public static func normalize(
        _ rawRepresentations: [String: Data],
        source: ClipboardSource = ClipboardSource(),
        createdAt: Date = Date(),
        isScreenshot: Bool = false
    ) -> NormalizedClipboardItem? {
        let representations = rawRepresentations
            .filter { supportedTypes.contains($0.key) && !$0.value.isEmpty }
            .filter { !imageTypes.contains($0.key) || isDecodableImage($0.value) }
        guard !representations.isEmpty else { return nil }

        let kind = contentKind(for: representations.keys)
        var textValues: [String: String] = [:]
        var binaryValues: [String: Data] = [:]
        for (type, data) in representations {
            if isStringType(type), let value = String(data: data, encoding: .utf8) {
                textValues[type] = value
            } else {
                binaryValues[type] = data
            }
        }

        let displayText = makeDisplayText(kind: kind, values: textValues, binary: binaryValues)
        let contentHash = stableHash(representations)
        let item = ClipboardItem(
            contentHash: contentHash,
            kind: kind,
            displayText: displayText,
            source: source,
            createdAt: createdAt,
            isScreenshot: isScreenshot,
            representations: textValues
        )
        return NormalizedClipboardItem(item: item, binaryRepresentations: binaryValues)
    }

    public static func contentKind(for types: some Sequence<String>) -> ClipboardContentKind {
        let available = Set(types)
        if !available.isDisjoint(with: imageTypes) { return .image }
        if !available.isDisjoint(with: fileURLTypes) { return .file }
        if !available.isDisjoint(with: urlTypes) { return .url }
        if !available.isDisjoint(with: richTextTypes) { return .richText }
        return .text
    }

    public static func stableHash(_ representations: [String: Data]) -> String {
        var hasher = SHA256()
        for type in representations.keys.sorted() {
            let typeBytes = Data(type.utf8)
            let value = representations[type] ?? Data()
            var typeLength = UInt64(typeBytes.count).bigEndian
            var valueLength = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &typeLength) { hasher.update(data: Data($0)) }
            hasher.update(data: typeBytes)
            withUnsafeBytes(of: &valueLength) { hasher.update(data: Data($0)) }
            hasher.update(data: value)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func imageTypeIdentifier(forFileExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "png": "public.png"
        case "tif", "tiff": "public.tiff"
        case "jpg", "jpeg": "public.jpeg"
        case "gif": "public.gif"
        case "icns": "com.apple.icns"
        default: nil
        }
    }

    private static func isStringType(_ type: String) -> Bool {
        plainTextTypes.contains(type)
            || urlTypes.contains(type)
            || fileURLTypes.contains(type)
    }

    private static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1
            ] as CFDictionary
        ) != nil
    }

    private static func makeDisplayText(
        kind: ClipboardContentKind,
        values: [String: String],
        binary: [String: Data]
    ) -> String? {
        switch kind {
        case .text:
            return firstValue(in: plainTextTypes, values: values)
        case .richText:
            return firstValue(in: plainTextTypes.union(richTextTypes), values: values)
                ?? "Rich text"
        case .url:
            return firstValue(in: urlTypes.union(plainTextTypes), values: values)
        case .file:
            return firstValue(in: fileURLTypes, values: values)
                ?? firstValue(in: plainTextTypes, values: values)
        case .image:
            if let description = firstValue(in: plainTextTypes, values: values), !description.isEmpty {
                return description
            }
            return binary.values.first.map { "Image (\($0.count.formatted()) bytes)" } ?? "Image"
        }
    }

    private static func firstValue(in types: Set<String>, values: [String: String]) -> String? {
        for type in types.sorted() {
            if let value = values[type], !value.isEmpty { return value }
        }
        return nil
    }
}
