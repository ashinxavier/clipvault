import CoreGraphics
import Foundation
import ImageIO
import Darwin

public struct ScreenshotFileSignature: Equatable, Sendable {
    public let size: Int64
    public let modificationDate: Date?

    public init(size: Int64, modificationDate: Date?) {
        self.size = size
        self.modificationDate = modificationDate
    }
}

public struct ScreenshotStabilityTracker: Sendable {
    private struct Observation: Sendable {
        let signature: ScreenshotFileSignature
        let firstObservedAt: Date
    }

    private var previous: [String: Observation] = [:]

    public init() {}

    public mutating func observe(
        path: String,
        signature: ScreenshotFileSignature,
        observedAt: Date = Date(),
        minimumStableDuration: TimeInterval = 0.35
    ) -> Bool {
        if let previousObservation = previous[path], previousObservation.signature == signature {
            return observedAt.timeIntervalSince(previousObservation.firstObservedAt) >= minimumStableDuration
        }
        previous[path] = Observation(signature: signature, firstObservedAt: observedAt)
        return false
    }

    public mutating func remove(path: String) {
        previous.removeValue(forKey: path)
    }
}

public enum ScreenshotMonitorError: Error, LocalizedError {
    case folderUnavailable
    case fileUnreadable

    public var errorDescription: String? {
        switch self {
        case .folderUnavailable: "The screenshot folder could not be monitored."
        case .fileUnreadable: "A screenshot could not be read safely."
        }
    }
}

public final class ScreenshotMonitor {
    private let queue = DispatchQueue(label: "org.clipvault.screenshot-monitor", qos: .utility)
    private let fileManager: FileManager
    private let store: SQLiteHistoryStore
    private let assetStore: AssetStore
    private let clipboardWriter: ClipboardWriter
    private let autoCopyEnabled: () -> Bool
    private let onCapture: (ClipboardItem) -> Void
    private let onError: (Error) -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var watchedFolder: URL?
    private var descriptor: Int32?
    private var stability = ScreenshotStabilityTracker()
    private var attempts: [String: Int] = [:]
    private var capturedSignatures: [String: ScreenshotFileSignature] = [:]

    public init(
        store: SQLiteHistoryStore,
        assetStore: AssetStore,
        clipboardWriter: ClipboardWriter,
        fileManager: FileManager = .default,
        autoCopyEnabled: @escaping () -> Bool,
        onCapture: @escaping (ClipboardItem) -> Void = { _ in },
        onError: @escaping (Error) -> Void = { _ in }
    ) {
        self.store = store
        self.assetStore = assetStore
        self.clipboardWriter = clipboardWriter
        self.fileManager = fileManager
        self.autoCopyEnabled = autoCopyEnabled
        self.onCapture = onCapture
        self.onError = onError
    }

    public func start(folderURL: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            let folder = folderURL.standardizedFileURL
            do {
                try self.fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                self.watchedFolder = folder
                let fd = Darwin.open(folder.path, O_EVTONLY)
                guard fd >= 0 else { throw ScreenshotMonitorError.folderUnavailable }
                self.descriptor = fd
                let watcher = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .extend, .attrib, .rename, .delete],
                    queue: self.queue
                )
                watcher.setEventHandler { [weak self] in self?.scan() }
                watcher.setCancelHandler { Darwin.close(fd) }
                self.directorySource = watcher
                watcher.resume()
                self.scan()
            } catch {
                self.watchedFolder = nil
                self.onError(error)
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    func stopAndWaitForTesting() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
        directorySource?.setEventHandler {}
        directorySource?.cancel()
        directorySource = nil
        descriptor = nil
        watchedFolder = nil
        stability = ScreenshotStabilityTracker()
        attempts.removeAll()
    }

    private func scan() {
        guard let folder = watchedFolder else { return }
        do {
            let files = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            for file in files where isSupportedImage(file) {
                checkForStability(file)
            }
        } catch {
            onError(ScreenshotMonitorError.folderUnavailable)
        }
    }

    private func checkForStability(_ url: URL) {
        guard let watchedFolder,
              url.deletingLastPathComponent().standardizedFileURL == watchedFolder else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { return }
            let signature = ScreenshotFileSignature(size: Int64(size), modificationDate: values.contentModificationDate)
            let path = url.path
            guard capturedSignatures[path] != signature else { return }
            if stability.observe(path: path, signature: signature) {
                importStableImage(url, signature: signature)
                stability.remove(path: path)
                attempts.removeValue(forKey: path)
            } else {
                let count = attempts[path, default: 0] + 1
                attempts[path] = count
                if count > 120 {
                    stability.remove(path: path)
                    attempts.removeValue(forKey: path)
                    return
                }
                queue.asyncAfter(deadline: .now() + .milliseconds(350)) { [weak self] in
                    self?.checkForStability(url)
                }
            }
        } catch {
            onError(ScreenshotMonitorError.fileUnreadable)
        }
    }

    private func importStableImage(_ url: URL, signature: ScreenshotFileSignature) {
        guard let type = ClipboardNormalizer.imageTypeIdentifier(forFileExtension: url.pathExtension),
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0,
              CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64
                ] as CFDictionary
              ) != nil,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let normalized = ClipboardNormalizer.normalize([type: data], isScreenshot: true) else {
            return
        }
        do {
            switch try store.insert(normalized) {
            case .duplicate:
                capturedSignatures[url.path] = signature
                if autoCopyEnabled(),
                   let existingItem = try store.allItems().first(where: { $0.contentHash == normalized.item.contentHash }) {
                    try clipboardWriter.restore(existingItem)
                }
            case let .inserted(item):
                capturedSignatures[url.path] = signature
                onCapture(item)
                if autoCopyEnabled() {
                    do {
                        try clipboardWriter.restore(item)
                    } catch {
                        onError(error)
                    }
                }
            }
        } catch {
            onError(error)
        }
    }

    private func isSupportedImage(_ url: URL) -> Bool {
        ClipboardNormalizer.imageTypeIdentifier(forFileExtension: url.pathExtension) != nil
    }
}
