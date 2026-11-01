import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class AssetStore: @unchecked Sendable {
    public let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: rootURL.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootURL.appendingPathComponent("previews", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.rootURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.rootURL.appendingPathComponent("assets").path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.rootURL.appendingPathComponent("previews").path)
    }

    @discardableResult
    public func store(_ data: Data, typeIdentifier: String) throws -> String {
        let folder = rootURL.appendingPathComponent("assets", isDirectory: true)
        let extensionName = UTType(typeIdentifier)?.preferredFilenameExtension ?? "bin"
        let name = "\(ClipboardNormalizer.stableHash([typeIdentifier: data])).\(extensionName)"
        let destination = folder.appendingPathComponent(name, isDirectory: false)
        if !fileManager.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return "assets/\(name)"
    }

    public func makePreview(from data: Data, contentHash: String) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480
                ] as CFDictionary
              ) else { return nil }

        let previewData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            previewData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let name = "\(contentHash).png"
        let path = "previews/\(name)"
        do {
            let previewURL = rootURL.appendingPathComponent(path)
            try Data(referencing: previewData).write(to: previewURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previewURL.path)
            return path
        } catch {
            return nil
        }
    }

    public func read(_ relativePath: String) throws -> Data {
        guard let data = fileManager.contents(atPath: try resolve(relativePath).path) else {
            throw ClipboardStoreError.missingAsset(relativePath)
        }
        return data
    }

    public func url(for relativePath: String) throws -> URL {
        try resolve(relativePath)
    }

    public func remove(_ relativePaths: [String]) throws {
        for path in Set(relativePaths) {
            let url = try resolve(path)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func removeOrphans(keeping relativePaths: Set<String>) throws {
        for folderName in ["assets", "previews"] {
            let folder = rootURL.appendingPathComponent(folderName, isDirectory: true)
            guard let files = fileManager.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in files {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let relativePath = "\(folderName)/\(fileURL.lastPathComponent)"
                if !relativePaths.contains(relativePath) {
                    try fileManager.removeItem(at: fileURL)
                }
            }
        }
    }

    public func storageUsageBytes() -> Int64 {
        guard let files = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return files.reduce(into: Int64(0)) { total, entry in
            guard let url = entry as? URL,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            total += Int64(size)
        }
    }

    private func resolve(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw ClipboardStoreError.invalidAssetPath(relativePath)
        }
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(rootURL.path + "/") else {
            throw ClipboardStoreError.invalidAssetPath(relativePath)
        }
        return candidate
    }
}
