import Foundation

public enum ClipboardContentKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case text
    case richText
    case url
    case file
    case image

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .url: "URL"
        case .file: "File"
        case .image: "Image"
        }
    }
}

public struct ClipboardSource: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let applicationName: String?

    public init(bundleIdentifier: String? = nil, applicationName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
    }
}

public struct ClipboardCapturePolicy: Sendable {
    public let enabledKinds: Set<ClipboardContentKind>
    public let excludedBundleIdentifiers: Set<String>

    public init(
        enabledKinds: Set<ClipboardContentKind>,
        excludedBundleIdentifiers: Set<String> = []
    ) {
        self.enabledKinds = enabledKinds
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    public func allows(kind: ClipboardContentKind, source: ClipboardSource) -> Bool {
        guard enabledKinds.contains(kind) else { return false }
        if let bundleIdentifier = source.bundleIdentifier,
           excludedBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }
        return true
    }
}

/// A database-ready clipboard entry. Binary pasteboard flavors are stored externally;
/// `representations` contains only small UTF-8 values and `assetPaths` contains relative paths.
public struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let contentHash: String
    public let kind: ClipboardContentKind
    public let displayText: String?
    public let sourceBundleIdentifier: String?
    public let sourceApplicationName: String?
    public let createdAt: Date
    public var isPinned: Bool
    public let isScreenshot: Bool
    public var representations: [String: String]
    public var assetPaths: [String: String]
    public var previewAssetPath: String?

    public init(
        id: String = UUID().uuidString,
        contentHash: String,
        kind: ClipboardContentKind,
        displayText: String?,
        source: ClipboardSource = ClipboardSource(),
        createdAt: Date = Date(),
        isPinned: Bool = false,
        isScreenshot: Bool = false,
        representations: [String: String] = [:],
        assetPaths: [String: String] = [:],
        previewAssetPath: String? = nil
    ) {
        self.id = id
        self.contentHash = contentHash
        self.kind = kind
        self.displayText = displayText
        self.sourceBundleIdentifier = source.bundleIdentifier
        self.sourceApplicationName = source.applicationName
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.isScreenshot = isScreenshot
        self.representations = representations
        self.assetPaths = assetPaths
        self.previewAssetPath = previewAssetPath
    }
}

public struct NormalizedClipboardItem: Equatable, Sendable {
    public let item: ClipboardItem
    public let binaryRepresentations: [String: Data]

    public init(item: ClipboardItem, binaryRepresentations: [String: Data]) {
        self.item = item
        self.binaryRepresentations = binaryRepresentations
    }
}

public enum ClipboardStoreError: Error, LocalizedError {
    case unsupportedContent
    case invalidAssetPath(String)
    case database(String)
    case encoding(String)
    case missingAsset(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedContent:
            "This clipboard item has no supported representation."
        case .invalidAssetPath:
            "A saved clipboard asset path is invalid."
        case .database:
            "The local clipboard history database could not complete an operation."
        case .encoding:
            "Clipboard metadata could not be encoded for local storage."
        case .missingAsset:
            "A saved clipboard asset is no longer available."
        }
    }
}
