import AppKit
import Foundation

public protocol ClipboardSnapshotSource {
    var changeCount: Int { get }
    func currentRepresentations() -> [String: Data]
    var source: ClipboardSource { get }
}

public final class PasteboardSnapshotSource: ClipboardSnapshotSource {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public var source: ClipboardSource {
        let application = NSWorkspace.shared.frontmostApplication
        return ClipboardSource(
            bundleIdentifier: application?.bundleIdentifier,
            applicationName: application?.localizedName
        )
    }

    public func currentRepresentations() -> [String: Data] {
        var result: [String: Data] = [:]
        for type in pasteboard.types ?? [] {
            guard ClipboardNormalizer.supportedTypes.contains(type.rawValue) else { continue }
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                result[type.rawValue] = data
            } else if let value = pasteboard.string(forType: type),
                      let data = value.data(using: .utf8), !data.isEmpty {
                result[type.rawValue] = data
            }
        }
        return result
    }
}

public struct ClipboardChangeTracker: Sendable {
    private var lastChangeCount: Int?

    public init() {}

    public mutating func shouldRead(changeCount: Int) -> Bool {
        guard lastChangeCount != changeCount else { return false }
        lastChangeCount = changeCount
        return true
    }
}

public final class ClipboardMonitor {
    private let queue = DispatchQueue(label: "org.clipvault.clipboard-monitor", qos: .utility)
    private let source: ClipboardSnapshotSource
    private let store: SQLiteHistoryStore
    private let interval: TimeInterval
    private let shouldCapture: (ClipboardContentKind, ClipboardSource) -> Bool
    private let onCapture: (ClipboardItem) -> Void
    private let onError: (Error) -> Void
    private var timer: DispatchSourceTimer?
    private var tracker = ClipboardChangeTracker()

    public init(
        source: ClipboardSnapshotSource = PasteboardSnapshotSource(),
        store: SQLiteHistoryStore,
        interval: TimeInterval = 0.5,
        shouldCapture: @escaping (ClipboardContentKind, ClipboardSource) -> Bool = { _, _ in true },
        onCapture: @escaping (ClipboardItem) -> Void = { _ in },
        onError: @escaping (Error) -> Void = { _ in }
    ) {
        self.source = source
        self.store = store
        self.interval = max(0.2, interval)
        self.shouldCapture = shouldCapture
        self.onCapture = onCapture
        self.onError = onError
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.interval, leeway: .milliseconds(120))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    func stopAndWaitForTesting() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
        guard let timer else { return }
        timer.setEventHandler {}
        timer.cancel()
        self.timer = nil
    }

    func pollOnceForTesting() {
        queue.sync { poll() }
    }

    private func poll() {
        let count = source.changeCount
        guard tracker.shouldRead(changeCount: count) else { return }
        guard let normalized = ClipboardNormalizer.normalize(
            source.currentRepresentations(),
            source: source.source
        ) else { return }
        guard shouldCapture(normalized.item.kind, source.source) else { return }
        do {
            if case let .inserted(item) = try store.insert(normalized) {
                onCapture(item)
            }
        } catch {
            onError(error)
        }
    }
}
