import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

@main
enum CoreTestRunner {
    private static var failures: [String] = []
    private static var passed = 0
    private static let selectedTests = Set(CommandLine.arguments.dropFirst())
    private static var executedTests: Set<String> = []

    static func main() throws {
        run("normalizes supported clipboard flavors") { try normalizationChecks() }
        run("hashes clipboard flavors deterministically") { try hashChecks() }
        run("tracks clipboard and screenshot stability") { try monitorGateChecks() }
        run("routes history filters and keyboard commands") { try navigationAndFilterChecks() }
        run("reuses cached history preview images") { try historyPreviewCacheChecks() }
        run("derives native menu state simply") { try menuBarPresentationChecks() }
        run("only reads and stores changed clipboard states") { try clipboardMonitorChecks() }
        run("pauses and resumes clipboard polling") { try clipboardMonitorLifecycleChecks() }
        run("captures stable screenshots once") { try screenshotMonitorChecks() }
        run("coalesces screenshot event and retry work") { try screenshotWorkCoalescingChecks() }
        run("auto-copies duplicate screenshots once") { try screenshotDuplicateAutoCopyChecks() }
        run("restores original rich clipboard flavors") { try clipboardRestoreChecks() }
        run("persists URL and file representations") { try urlAndFilePersistenceChecks() }
        run("persists, deduplicates, pins, and cleans history") { try persistenceChecks() }
        run("clears unpinned history and retains pinned rows") { try clearUnpinnedChecks() }
        run("stores local history with restrictive permissions") { try storagePermissionsChecks() }
        run("loads the requested first-run defaults") { try preferencesDefaultsChecks() }
        run("applies type toggles and app exclusions") { try capturePolicyChecks() }
        run("retains shared assets until final reference") { try sharedAssetReferenceChecks() }
        run("removes orphaned external assets") { try orphanRecoveryChecks() }
        run("migrates legacy history transactionally") { try migrationChecks() }

        let unmatchedTests = selectedTests.subtracting(executedTests)
        if !unmatchedTests.isEmpty {
            failures.append("Unknown test filter(s): \(unmatchedTests.sorted().joined(separator: ", "))")
        }
        print("\n\(passed) checks passed, \(failures.count) failed")
        if !failures.isEmpty {
            failures.forEach { print("FAIL: \($0)") }
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ name: String, body: () throws -> Void) {
        guard selectedTests.isEmpty || selectedTests.contains(name) else { return }
        executedTests.insert(name)
        do {
            try body()
            passed += 1
            print("PASS: \(name)")
        } catch {
            failures.append("\(name): \(error.localizedDescription)")
        }
    }

    private static func normalizationChecks() throws {
        let plain = ClipboardNormalizer.normalize([
            "public.utf8-plain-text": Data("hello\nworld".utf8)
        ])
        try expect(plain?.item.kind == .text, "plain text should classify as text")
        try expect(plain?.item.displayText == "hello\nworld", "plain text preview should remain exact")
        try expect(plain?.item.representations["public.utf8-plain-text"] == "hello\nworld", "original text flavor should be retained")

        let rich = ClipboardNormalizer.normalize([
            "public.rtf": Data("{\\rtf1\\ansi Rich}".utf8),
            "public.utf8-plain-text": Data("Rich".utf8)
        ])
        try expect(rich?.item.kind == .richText, "RTF should classify as rich text")
        try expect(rich?.binaryRepresentations["public.rtf"] != nil, "RTF bytes should be kept out of SQLite")
        try expect(rich?.item.representations["public.utf8-plain-text"] == "Rich", "plain preview should accompany rich text")

        let url = ClipboardNormalizer.normalize(["public.url": Data("https://example.test/path".utf8)])
        try expect(url?.item.kind == .url, "URL should classify as URL")
        let file = ClipboardNormalizer.normalize(["public.file-url": Data("file:///tmp/example.txt".utf8)])
        try expect(file?.item.kind == .file, "file URL should classify as file")
        let validImageData = try makePNG()
        let image = ClipboardNormalizer.normalize(["public.png": validImageData])
        try expect(image?.item.kind == .image, "PNG flavor should classify as image")
        try expect(image?.binaryRepresentations["public.png"] == validImageData, "valid image bytes should remain binary assets")
        let corruptImageData = Data([0x89, 0x50, 0x4e, 0x47])
        try expect(ClipboardNormalizer.normalize(["public.png": corruptImageData]) == nil, "undecodable image-only content should be skipped")
        let mixed = ClipboardNormalizer.normalize([
            "public.png": corruptImageData,
            "public.utf8-plain-text": Data("valid text".utf8)
        ])
        try expect(mixed?.item.kind == .text, "invalid image flavor should not override valid text")
        try expect(mixed?.binaryRepresentations["public.png"] == nil, "invalid image bytes should not be retained")
        try expect(mixed?.item.representations["public.utf8-plain-text"] == "valid text", "other valid flavors should be preserved")
        try expect(ClipboardNormalizer.normalize(["unsupported.type": Data([1])]) == nil, "unsupported-only content should be skipped")
    }

    private static func hashChecks() throws {
        let first: [String: Data] = [
            "public.utf8-plain-text": Data("same".utf8),
            "public.url": Data("https://example.test".utf8)
        ]
        let reversed: [String: Data] = [
            "public.url": Data("https://example.test".utf8),
            "public.utf8-plain-text": Data("same".utf8)
        ]
        try expect(ClipboardNormalizer.stableHash(first) == ClipboardNormalizer.stableHash(reversed), "dictionary order must not affect hash")
        try expect(ClipboardNormalizer.stableHash(first) != ClipboardNormalizer.stableHash(["public.utf8-plain-text": Data("same".utf8)]), "all saved flavors should contribute to hash")
    }

    private static func monitorGateChecks() throws {
        var changeTracker = ClipboardChangeTracker()
        try expect(changeTracker.shouldRead(changeCount: 3), "first pasteboard state should be read")
        try expect(!changeTracker.shouldRead(changeCount: 3), "unchanged pasteboard state should be ignored")
        try expect(changeTracker.shouldRead(changeCount: 4), "new pasteboard state should be read")

        var stability = ScreenshotStabilityTracker()
        let signature = ScreenshotFileSignature(size: 2048, modificationDate: Date(timeIntervalSince1970: 10))
        try expect(!stability.observe(path: "/tmp/capture.png", signature: signature, observedAt: Date(timeIntervalSince1970: 10)), "first screenshot observation is not stable")
        try expect(!stability.observe(path: "/tmp/capture.png", signature: signature, observedAt: Date(timeIntervalSince1970: 10.2)), "matching metadata alone must not pass before the settle interval")
        try expect(stability.observe(path: "/tmp/capture.png", signature: signature, observedAt: Date(timeIntervalSince1970: 10.4)), "matching signature after the settle interval is stable")
        try expect(!stability.observe(path: "/tmp/capture.png", signature: ScreenshotFileSignature(size: 4096, modificationDate: signature.modificationDate), observedAt: Date(timeIntervalSince1970: 11)), "a file that changes during write must become unstable")
    }

    private static func navigationAndFilterChecks() throws {
        let text = ClipboardItem(contentHash: "text", kind: .text, displayText: "A note")
        let richText = ClipboardItem(contentHash: "rich", kind: .richText, displayText: "Formatted note")
        let image = ClipboardItem(contentHash: "image", kind: .image, displayText: "Image")
        let url = ClipboardItem(contentHash: "url", kind: .url, displayText: "https://example.test")
        let file = ClipboardItem(contentHash: "file", kind: .file, displayText: "file:///tmp/note")
        try expect(HistoryFilter.all.includes(file), "All should include file items")
        try expect(HistoryFilter.text.includes(text) && HistoryFilter.text.includes(richText), "Text should include plain and rich text")
        try expect(HistoryFilter.images.includes(image), "Images should include image items")
        try expect(HistoryFilter.urls.includes(url) && !HistoryFilter.urls.includes(file), "URLs should filter URL items separately")

        try expect(HistoryKeyRouter.command(forKeyCode: 126, commandPressed: false, searchIsEmpty: true, editingText: false) == .previous, "up arrow should move selection backward")
        try expect(HistoryKeyRouter.command(forKeyCode: 125, commandPressed: false, searchIsEmpty: true, editingText: false) == .next, "down arrow should move selection forward")
        try expect(HistoryKeyRouter.command(forKeyCode: 36, commandPressed: false, searchIsEmpty: true, editingText: false) == .restore, "Enter should restore the selected item")
        try expect(HistoryKeyRouter.command(forKeyCode: 53, commandPressed: false, searchIsEmpty: true, editingText: false) == .close, "Escape should close history")
        try expect(HistoryKeyRouter.command(forKeyCode: 3, commandPressed: true, searchIsEmpty: false, editingText: true) == .focusSearch, "Command+F should focus search")
        try expect(HistoryKeyRouter.command(forKeyCode: 51, commandPressed: false, searchIsEmpty: false, editingText: true) == nil, "Delete should edit a non-empty search field")
        try expect(HistoryKeyRouter.command(forKeyCode: 51, commandPressed: false, searchIsEmpty: true, editingText: true) == .delete, "Delete should remove the selected item when search is empty")

        try expect(HistorySelection.nextIndex(currentIndex: nil, count: 3, offset: 1) == 0, "first down arrow should select the first result")
        try expect(HistorySelection.nextIndex(currentIndex: 0, count: 3, offset: 1) == 1, "down arrow should advance selection")
        try expect(HistorySelection.nextIndex(currentIndex: 2, count: 3, offset: 1) == 2, "selection should stop at the last result")
        try expect(HistorySelection.nextIndex(currentIndex: nil, count: 0, offset: 1) == nil, "empty history should have no selection")
    }

    private static func historyPreviewCacheChecks() throws {
        var loadCount = 0
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let cache = HistoryPreviewImageCache(imageLoader: { _ in
            loadCount += 1
            return image
        })
        let url = URL(fileURLWithPath: "/cache-test/preview.png")
        let first = cache.image(for: url)
        let second = cache.image(for: url)
        try expect(first === image && second === image, "cached history previews should reuse the same image")
        try expect(loadCount == 1, "repeated preview rendering should load the image once")
    }

    private static func menuBarPresentationChecks() throws {
        try expect(MenuBarPresentation.monitoringTitle(isPaused: false) == "Pause Monitoring", "active monitoring should offer pause")
        try expect(MenuBarPresentation.monitoringTitle(isPaused: true) == "Resume Monitoring", "paused monitoring should offer resume")
        try expect(!MenuBarPresentation.canClearHistory(itemCount: 0), "empty history should disable clear")
        try expect(MenuBarPresentation.canClearHistory(itemCount: 1), "nonempty history should enable clear")
    }

    private static func clipboardMonitorChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = try AssetStore(rootURL: directory.appendingPathComponent("Assets", isDirectory: true))
        let store = try SQLiteHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), assetStore: assets)
        let source = FakeClipboardSource()
        var captures = 0
        let monitor = ClipboardMonitor(source: source, store: store, onCapture: { _ in captures += 1 })

        source.changeCount = 10
        source.values = ["public.utf8-plain-text": Data("first".utf8)]
        monitor.pollOnceForTesting()
        try expect(source.readCount == 1 && captures == 1, "first change should be read and stored")
        monitor.pollOnceForTesting()
        try expect(source.readCount == 1 && captures == 1, "unchanged change count must not reread or write")
        source.changeCount = 11
        source.values = ["public.utf8-plain-text": Data("second".utf8)]
        monitor.pollOnceForTesting()
        try expect(source.readCount == 2 && captures == 2, "new change count should be processed once")
        try expect(try store.count() == 2, "only changed clipboard states should persist")

        source.changeCount = 12
        source.values = ["public.utf8-plain-text": Data("disabled type".utf8)]
        let disabledMonitor = ClipboardMonitor(source: source, store: store, shouldCapture: { _, _ in false })
        disabledMonitor.pollOnceForTesting()
        try expect(try store.count() == 2, "disabled content types must not be stored")
    }

    private static func clipboardMonitorLifecycleChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = try AssetStore(rootURL: directory.appendingPathComponent("Assets", isDirectory: true))
        let store = try SQLiteHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), assetStore: assets)
        let source = FakeClipboardSource()
        let captureLock = NSLock()
        let captured = DispatchSemaphore(value: 0)
        var captureCount = 0
        let monitor = ClipboardMonitor(source: source, store: store, interval: 0.2, onCapture: { _ in
            captureLock.lock()
            captureCount += 1
            captureLock.unlock()
            captured.signal()
        })

        source.changeCount = 20
        source.values = ["public.utf8-plain-text": Data("before pause".utf8)]
        monitor.start()
        guard captured.wait(timeout: .now() + 3) == .success else {
            throw TestFailure("clipboard monitor did not capture before pause")
        }
        monitor.stopAndWaitForTesting()
        source.changeCount = 21
        source.values = ["public.utf8-plain-text": Data("during pause".utf8)]
        Thread.sleep(forTimeInterval: 0.5)
        try expect(source.readCount == 1 && (try store.count()) == 1, "stopped monitor should not read or persist clipboard changes")

        monitor.start()
        guard captured.wait(timeout: .now() + 3) == .success else {
            throw TestFailure("clipboard monitor did not resume")
        }
        monitor.stopAndWaitForTesting()
        captureLock.lock()
        let finalCaptureCount = captureCount
        captureLock.unlock()
        try expect(source.readCount == 2 && finalCaptureCount == 2, "resumed monitor should capture the next changed state once")
        try expect(try store.count() == 2, "resumed clipboard history should contain both captured states")
    }

    private static func screenshotMonitorChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshotFolder = directory.appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshotFolder, withIntermediateDirectories: true)
        let imageData = try makePNG()
        try imageData.write(to: screenshotFolder.appendingPathComponent("Screenshot.png"))
        try Data([0x00, 0x01, 0x02]).write(to: screenshotFolder.appendingPathComponent("Invalid.png"))

        let assets = try AssetStore(rootURL: directory.appendingPathComponent("Assets", isDirectory: true))
        let store = try SQLiteHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), assetStore: assets)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.clipvault.tests-" + UUID().uuidString))
        let initialPasteboardChangeCount = pasteboard.changeCount
        let writer = ClipboardWriter(assetStore: assets, pasteboard: pasteboard)
        let captured = DispatchSemaphore(value: 0)
        let captureLock = NSLock()
        var captureCount = 0
        let monitor = ScreenshotMonitor(
            store: store,
            assetStore: assets,
            clipboardWriter: writer,
            autoCopyEnabled: { true },
            onCapture: { _ in
                captureLock.lock()
                captureCount += 1
                captureLock.unlock()
                captured.signal()
            }
        )
        defer { monitor.stopAndWaitForTesting() }
        monitor.start(folderURL: screenshotFolder)
        guard waitPumpingMainRunLoop(for: captured, timeout: 5) else {
            throw TestFailure("stable screenshot was not captured within five seconds")
        }

        let items = try store.allItems()
        try expect(items.count == 1, "invalid image files should be ignored")
        guard let screenshot = items.first,
              screenshot.isScreenshot,
              let imagePath = screenshot.assetPaths["public.png"],
              let previewPath = screenshot.previewAssetPath else {
            throw TestFailure("screenshot history and thumbnail were not saved")
        }
        try expect(try assets.read(imagePath) == imageData, "original screenshot bytes should be kept")
        try expect((try? assets.read(previewPath)) != nil, "a local thumbnail should be created")

        let pasteboardDeadline = Date().addingTimeInterval(3)
        while pasteboard.changeCount == initialPasteboardChangeCount && Date() < pasteboardDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(
            pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")) == imageData,
            "auto-copy should place the screenshot on the injected pasteboard"
        )
        let finalPasteboardChangeCount = pasteboard.changeCount
        pumpMainRunLoop(for: 0.6)
        try expect(pasteboard.changeCount == finalPasteboardChangeCount, "the stable screenshot should not be copied more than once")

        monitor.stopAndWaitForTesting()
        let secondImageData = try makePNG(red: 0.2)
        try secondImageData.write(to: screenshotFolder.appendingPathComponent("Screenshot2.png"))
        pumpMainRunLoop(for: 0.6)
        try expect(try store.count() == 1, "paused screenshot monitor should ignore new files")
        monitor.start(folderURL: screenshotFolder)
        guard waitPumpingMainRunLoop(for: captured, timeout: 5) else {
            throw TestFailure("resumed screenshot monitor did not import a new stable file")
        }
        monitor.stopAndWaitForTesting()
        captureLock.lock()
        let finalCaptureCount = captureCount
        captureLock.unlock()
        try expect(finalCaptureCount == 2 && (try store.count()) == 2, "resumed screenshot monitor should import once")
    }

    private static func screenshotWorkCoalescingChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshotFolder = directory.appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshotFolder, withIntermediateDirectories: true)
        let screenshotURL = screenshotFolder.appendingPathComponent("Screenshot.png")
        try makePNG().write(to: screenshotURL)

        let assets = try AssetStore(rootURL: directory.appendingPathComponent("Assets", isDirectory: true))
        let store = try SQLiteHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), assetStore: assets)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.clipvault.tests-" + UUID().uuidString))
        let monitor = ScreenshotMonitor(
            store: store,
            assetStore: assets,
            clipboardWriter: ClipboardWriter(assetStore: assets, pasteboard: pasteboard),
            autoCopyEnabled: { false }
        )
        defer { monitor.stopAndWaitForTesting() }

        monitor.start(folderURL: screenshotFolder)
        monitor.signalDirectoryEventsForTesting(100)
        let firstScanDeadline = Date().addingTimeInterval(3)
        while monitor.directoryScanCountForTesting() == 0 && Date() < firstScanDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try expect(monitor.directoryScanCountForTesting() == 1, "a directory-event burst should coalesce into one scan")

        let pendingRetries = monitor.scheduleStabilityCheckBurstForTesting(
            directory.appendingPathComponent("RetryProbe.png"),
            count: 5
        )
        try expect(pendingRetries == 1, "repeated checks of one path should schedule only one delayed retry")

        monitor.signalDirectoryEventsForTesting(100)
        let secondScanDeadline = Date().addingTimeInterval(3)
        while monitor.directoryScanCountForTesting() < 2 && Date() < secondScanDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try expect(monitor.directoryScanCountForTesting() == 2, "a later event burst should queue only one additional scan")
    }

    private static func screenshotDuplicateAutoCopyChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshotFolder = directory.appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshotFolder, withIntermediateDirectories: true)
        let imageData = try makePNG(red: 0.4)
        try imageData.write(to: screenshotFolder.appendingPathComponent("Duplicate.png"))

        let assets = try AssetStore(rootURL: directory.appendingPathComponent("Assets", isDirectory: true))
        let store = try SQLiteHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), assetStore: assets)
        guard let normalized = ClipboardNormalizer.normalize(["public.png": imageData]),
              case .inserted = try store.insert(normalized) else {
            throw TestFailure("clipboard image was not inserted before screenshot scan")
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.clipvault.tests-" + UUID().uuidString))
        let initialChangeCount = pasteboard.changeCount
        let monitor = ScreenshotMonitor(
            store: store,
            assetStore: assets,
            clipboardWriter: ClipboardWriter(assetStore: assets, pasteboard: pasteboard),
            autoCopyEnabled: { true }
        )
        defer { monitor.stopAndWaitForTesting() }
        monitor.start(folderURL: screenshotFolder)

        let deadline = Date().addingTimeInterval(5)
        while pasteboard.changeCount == initialChangeCount && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(pasteboard.changeCount != initialChangeCount, "duplicate screenshot should be restored to the pasteboard")
        try expect(
            pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")) == imageData,
            "duplicate screenshot bytes should be copied unchanged"
        )
        try expect(try store.count() == 1, "duplicate screenshot should not create another history row")
        let copiedChangeCount = pasteboard.changeCount
        pumpMainRunLoop(for: 0.6)
        try expect(pasteboard.changeCount == copiedChangeCount, "the same screenshot file should be copied only once")
    }

    private static func makePNG(red: CGFloat = 1) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestFailure("could not create a tiny test image")
        }
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage() else { throw TestFailure("could not create a test image") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw TestFailure("could not create a PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestFailure("could not encode test PNG") }
        return Data(referencing: output)
    }

    private static func clipboardRestoreChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = try AssetStore(rootURL: directory.appendingPathComponent("Assets", isDirectory: true))
        let store = try SQLiteHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), assetStore: assets)
        let rtfBytes = Data("{\\\\rtf1\\\\ansi Restored}".utf8)
        let normalized = ClipboardNormalizer.normalize([
            "public.rtf": rtfBytes,
            "public.utf8-plain-text": Data("Restored".utf8)
        ])!
        guard case let .inserted(item) = try store.insert(normalized) else {
            throw TestFailure("rich clipboard record was unexpectedly deduplicated")
        }

        let pasteboardName = NSPasteboard.Name("org.clipvault.tests-" + UUID().uuidString)
        let pasteboard = NSPasteboard(name: pasteboardName)
        let writer = ClipboardWriter(assetStore: assets, pasteboard: pasteboard)
        try expect(try writer.restore(item), "writer should restore saved content")
        try expect(
            pasteboard.data(forType: NSPasteboard.PasteboardType("public.rtf")) == rtfBytes,
            "original RTF bytes should be restored exactly"
        )
        try expect(
            pasteboard.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text")) == "Restored",
            "plain-text fallback should remain available"
        )

        let urlValue = "https://example.test/restore"
        guard let urlNormalized = ClipboardNormalizer.normalize(["public.url": Data(urlValue.utf8)]),
              case let .inserted(urlItem) = try store.insert(urlNormalized) else {
            throw TestFailure("URL clipboard item was not inserted")
        }
        try writer.restore(urlItem)
        try expect(
            pasteboard.string(forType: NSPasteboard.PasteboardType("public.url")) == urlValue,
            "URL flavor should restore unchanged"
        )

        let fileValue = "file:///tmp/ClipVault-restore.txt"
        guard let fileNormalized = ClipboardNormalizer.normalize(["public.file-url": Data(fileValue.utf8)]),
              case let .inserted(fileItem) = try store.insert(fileNormalized) else {
            throw TestFailure("file URL clipboard item was not inserted")
        }
        try writer.restore(fileItem)
        try expect(
            pasteboard.string(forType: NSPasteboard.PasteboardType("public.file-url")) == fileValue,
            "file URL flavor should restore unchanged"
        )

        let imageBytes = try makePNG(red: 0.6)
        guard let imageNormalized = ClipboardNormalizer.normalize(["public.png": imageBytes]),
              case let .inserted(imageItem) = try store.insert(imageNormalized) else {
            throw TestFailure("image clipboard item was not inserted")
        }
        try writer.restore(imageItem)
        try expect(
            pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")) == imageBytes,
            "image flavor should restore unchanged"
        )
    }

    private static func urlAndFilePersistenceChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = try AssetStore(rootURL: directory.appendingPathComponent("Assets", isDirectory: true))
        let store = try SQLiteHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), assetStore: assets)
        let values = [
            ("public.url", "https://example.test/clipvault"),
            ("public.file-url", "file:///tmp/ClipVault.txt")
        ]
        for (type, value) in values {
            guard let normalized = ClipboardNormalizer.normalize([type: Data(value.utf8)]),
                  case let .inserted(item) = try store.insert(normalized) else {
                throw TestFailure("supported URL flavor was not persisted")
            }
            let saved = try store.item(id: item.id)
            try expect(saved?.representations[type] == value, "URL representation should round-trip unchanged")
        }
        try expect(try store.count() == 2, "URL and file URL should persist as separate items")
    }

    private static func persistenceChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = try AssetStore(rootURL: directory.appendingPathComponent("Assets", isDirectory: true))
        let store = try SQLiteHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), assetStore: assets)

        let pinned = ClipboardNormalizer.normalize(
            ["public.utf8-plain-text": Data("pinned".utf8)],
            source: ClipboardSource(bundleIdentifier: "org.example.editor", applicationName: "Example Editor"),
            createdAt: Date(timeIntervalSince1970: 30)
        )!
        guard case let .inserted(pinnedItem) = try store.insert(pinned) else { throw TestFailure("first insert was deduplicated") }
        let persistedPinned = try store.item(id: pinnedItem.id)
        try expect(persistedPinned?.sourceBundleIdentifier == "org.example.editor", "source bundle metadata should persist")
        try expect(persistedPinned?.sourceApplicationName == "Example Editor", "source app name should persist")
        try store.setPinned(true, id: pinnedItem.id)
        guard case .duplicate = try store.insert(pinned) else { throw TestFailure("same clipboard content was not deduplicated") }
        try expect(try store.allItems(pinnedOnly: true).first?.id == pinnedItem.id, "Pinned filter should return only pinned records")
        try store.setPinned(false, id: pinnedItem.id)
        try expect(try store.allItems(pinnedOnly: true).isEmpty, "Unpinning should remove an item from the Pinned filter")
        try store.setPinned(true, id: pinnedItem.id)

        _ = try store.insert(normalizedText("older", date: 20))
        _ = try store.insert(normalizedText("newer", date: 40))
        let expiredImage = ClipboardNormalizer.normalize(
            ["public.png": try makePNG()],
            createdAt: Date(timeIntervalSince1970: 10)
        )!
        guard case let .inserted(expiredImageItem) = try store.insert(expiredImage),
              let expiredImagePath = expiredImageItem.assetPaths["public.png"] else {
            throw TestFailure("expired image asset was not inserted")
        }
        try expect(try store.count() == 4, "four unique history items should persist")
        try expect(try store.allItems(search: "newer").count == 1, "search should filter local history")
        try expect(try store.cleanup(to: 2) == 2, "cleanup should remove eligible unpinned history")
        try expect(!FileManager.default.fileExists(atPath: try assets.url(for: expiredImagePath).path), "cleanup should remove the expired image asset")
        let retained = try store.allItems()
        try expect(retained.count == 2, "history limit should be applied")
        try expect(retained.contains(where: { $0.id == pinnedItem.id && $0.isPinned }), "pinned item should survive cleanup")
        try expect(retained.contains(where: { $0.displayText == "newer" }), "newer unpinned item should survive cleanup")
        try expect(try store.delete(id: retained.first(where: { $0.displayText == "newer" })!.id), "individual deletion should remove a selected item")

        let rich = ClipboardNormalizer.normalize([
            "public.rtf": Data("{\\\\rtf1\\\\ansi Rich}".utf8),
            "public.utf8-plain-text": Data("Rich".utf8)
        ])!
        guard case let .inserted(richItem) = try store.insert(rich),
              let rtfPath = richItem.assetPaths["public.rtf"] else {
            throw TestFailure("RTF bytes were not stored as an external asset")
        }
        try expect(FileManager.default.fileExists(atPath: try assets.url(for: rtfPath).path), "RTF asset should exist after insert")

        let binary = ClipboardNormalizer.normalize(["public.png": try makePNG(red: 0.5)])!
        guard case let .inserted(imageItem) = try store.insert(binary),
              let imagePath = imageItem.assetPaths["public.png"] else {
            throw TestFailure("image bytes were not saved as an external asset")
        }
        try expect(FileManager.default.fileExists(atPath: try assets.url(for: imagePath).path), "asset file should exist after insert")
        try store.clearHistory()
        try expect(try store.count() == 0, "clear should remove every row")
        try expect(!FileManager.default.fileExists(atPath: try assets.url(for: imagePath).path), "clear should remove external image assets")
        try expect(!FileManager.default.fileExists(atPath: try assets.url(for: rtfPath).path), "clear should remove external RTF assets")
    }

    private static func clearUnpinnedChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = try AssetStore(rootURL: directory.appendingPathComponent("Assets", isDirectory: true))
        let store = try SQLiteHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), assetStore: assets)
        guard case let .inserted(pinned) = try store.insert(normalizedText("keep pinned", date: 1)),
              case let .inserted(unpinned) = try store.insert(normalizedText("remove me", date: 2)) else {
            throw TestFailure("history setup failed")
        }
        try store.setPinned(true, id: pinned.id)
        let imageData = try makePNG(red: 0.7)
        guard let image = ClipboardNormalizer.normalize(["public.png": imageData]),
              case let .inserted(imageItem) = try store.insert(image),
              let assetPath = imageItem.assetPaths["public.png"] else {
            throw TestFailure("image asset setup failed")
        }
        try expect(try store.clearUnpinned() == 2, "clear-unpinned should remove all unpinned rows")
        let retained = try store.allItems()
        try expect(retained.count == 1 && retained.first?.id == pinned.id, "pinned history should survive clear-unpinned")
        try expect(try store.item(id: unpinned.id) == nil, "unpinned text should be removed")
        try expect((try? assets.read(assetPath)) == nil, "unreferenced unpinned assets should be removed")
        try expect(try store.clearUnpinned() == 0, "repeating clear-unpinned should be harmless")
    }

    private static func storagePermissionsChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataDirectory = directory.appendingPathComponent("ClipVault", isDirectory: true)
        let assets = try AssetStore(rootURL: dataDirectory.appendingPathComponent("Assets", isDirectory: true))
        let store = try SQLiteHistoryStore(databaseURL: dataDirectory.appendingPathComponent("history.sqlite"), assetStore: assets)
        guard case let .inserted(item) = try store.insert(
            ClipboardNormalizer.normalize(["public.png": try makePNG(red: 0.8)])!
        ), let path = item.assetPaths["public.png"] else {
            throw TestFailure("private asset setup failed")
        }
        let mode = { (url: URL) -> Int? in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
        }
        try expect((mode(dataDirectory).map { $0 & 0o777 }) == 0o700, "history directory should be private to the current user")
        try expect((mode(assets.rootURL).map { $0 & 0o777 }) == 0o700, "asset directory should be private to the current user")
        try expect((mode(try assets.url(for: path)).map { $0 & 0o777 }) == 0o600, "binary assets should not be readable by other local users")
        try expect((mode(store.databaseURL).map { $0 & 0o777 }) == 0o600, "SQLite database should not be readable by other local users")
    }

    private static func preferencesDefaultsChecks() throws {
        try MainActor.assumeIsolated {
            let suite = "org.clipvault.tests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw TestFailure("could not create isolated preference domain")
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = AppPreferences(defaults: defaults)
            try expect(preferences.historyLimit == 500, "default history limit should be 500")
            try expect(preferences.shortcut == .optionV, "default shortcut should be Option+V")
            try expect(preferences.textMonitoringEnabled && preferences.imageMonitoringEnabled && preferences.urlMonitoringEnabled, "clipboard monitoring types should start enabled")
            try expect(preferences.screenshotMonitoringEnabled && preferences.autoCopyScreenshots, "screenshot detection and auto-copy should start enabled")
            try expect(preferences.launchAtLogin && preferences.showMenuBarIcon, "launch-at-login and menu icon should start enabled")
            try expect(!preferences.monitoringPaused, "monitoring should start resumed")
            try expect(preferences.excludedApplicationBundleIDs.isEmpty, "application exclusions should start empty")
        }
    }

    private static func capturePolicyChecks() throws {
        let policy = ClipboardCapturePolicy(
            enabledKinds: [.text, .url],
            excludedBundleIdentifiers: ["org.example.private"]
        )
        try expect(
            policy.allows(kind: .text, source: ClipboardSource(bundleIdentifier: "org.example.editor")),
            "enabled content type from a normal app should be captured"
        )
        try expect(
            !policy.allows(kind: .image, source: ClipboardSource(bundleIdentifier: "org.example.editor")),
            "disabled content type should be ignored"
        )
        try expect(
            !policy.allows(kind: .text, source: ClipboardSource(bundleIdentifier: "org.example.private")),
            "excluded applications should not be captured"
        )
    }

    private static func sharedAssetReferenceChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = try AssetStore(rootURL: directory.appendingPathComponent("Assets", isDirectory: true))
        let store = try SQLiteHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), assetStore: assets)
        let sharedImage = try makePNG(red: 0.3)
        var ids: [String] = []
        var sharedPath: String?
        for label in ["first", "second"] {
            guard let normalized = ClipboardNormalizer.normalize([
                "public.png": sharedImage,
                "public.utf8-plain-text": Data(label.utf8)
            ]), case let .inserted(item) = try store.insert(normalized),
               let path = item.assetPaths["public.png"] else {
                throw TestFailure("image with distinct text metadata should be inserted")
            }
            ids.append(item.id)
            sharedPath = path
        }
        guard let sharedPath,
              try assets.read(sharedPath) == sharedImage else {
            throw TestFailure("binary asset should be available before deleting either row")
        }
        try expect(try store.delete(id: ids[0]), "first history row should delete")
        try expect(try assets.read(sharedPath) == sharedImage, "shared asset must remain for the other row")
        try expect(try store.delete(id: ids[1]), "last referencing history row should delete")
        try expect((try? assets.read(sharedPath)) == nil, "asset should be removed when its final reference is deleted")
    }

    private static func orphanRecoveryChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assetRoot = directory.appendingPathComponent("Assets", isDirectory: true)
        let firstAssets = try AssetStore(rootURL: assetRoot)
        let orphanPath = try firstAssets.store(Data([1, 2, 3]), typeIdentifier: "public.png")
        let dbURL = directory.appendingPathComponent("history.sqlite")
        _ = try SQLiteHistoryStore(databaseURL: dbURL, assetStore: firstAssets)
        try expect(!FileManager.default.fileExists(atPath: try firstAssets.url(for: orphanPath).path), "startup recovery should remove unreferenced assets")
    }

    private static func migrationChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyDatabaseURL = directory.appendingPathComponent("legacy.sqlite")
        try executeSQLite("""
            CREATE TABLE history (
                id TEXT PRIMARY KEY NOT NULL,
                content_hash TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                display_text TEXT,
                source_bundle_id TEXT,
                source_application_name TEXT,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                is_screenshot INTEGER NOT NULL DEFAULT 0,
                representations_json TEXT NOT NULL,
                asset_paths_json TEXT NOT NULL,
                preview_asset_path TEXT
            );
            INSERT INTO history (
                id, content_hash, kind, display_text, created_at, last_used_at,
                is_pinned, is_screenshot, representations_json, asset_paths_json
            ) VALUES (
                'legacy-id', 'legacy-hash', 'text', 'Preserved history', 1, 1,
                0, 0, '{"public.utf8-plain-text":"Preserved history"}', '{}'
            );
            PRAGMA user_version = 0;
            """, at: legacyDatabaseURL)
        let legacyAssets = try AssetStore(rootURL: directory.appendingPathComponent("LegacyAssets", isDirectory: true))
        let migratedStore = try SQLiteHistoryStore(databaseURL: legacyDatabaseURL, assetStore: legacyAssets)
        try expect(try sqliteInteger(at: legacyDatabaseURL, query: "PRAGMA user_version;") == 1, "migration should record the new schema version")
        try expect(try migratedStore.count() == 1, "legacy history rows should survive migration")
        try expect(try migratedStore.allItems().first?.displayText == "Preserved history", "legacy history content should remain readable")
        try expect(
            try sqliteInteger(
                at: legacyDatabaseURL,
                query: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN ('history_created_at', 'history_pinned');"
            ) == 2,
            "migration should create the history indexes"
        )

        let brokenDatabaseURL = directory.appendingPathComponent("broken.sqlite")
        try executeSQLite(
            "CREATE TABLE history (id TEXT PRIMARY KEY, created_at REAL); PRAGMA user_version = 0;",
            at: brokenDatabaseURL
        )
        let brokenAssets = try AssetStore(rootURL: directory.appendingPathComponent("BrokenAssets", isDirectory: true))
        var migrationFailed = false
        do {
            _ = try SQLiteHistoryStore(databaseURL: brokenDatabaseURL, assetStore: brokenAssets)
        } catch {
            migrationFailed = true
        }
        try expect(migrationFailed, "an incompatible legacy schema should fail migration")
        try expect(try sqliteInteger(at: brokenDatabaseURL, query: "PRAGMA user_version;") == 0, "failed migration should not advance the schema version")
        try expect(
            try sqliteInteger(
                at: brokenDatabaseURL,
                query: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'history_created_at';"
            ) == 0,
            "failed migration should roll back indexes created earlier in the transaction"
        )
    }

    private static func executeSQLite(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil)
        guard status == SQLITE_OK, let openedDatabase = database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open test database"
            if let database { sqlite3_close(database) }
            throw TestFailure(message)
        }
        defer { sqlite3_close(openedDatabase) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(openedDatabase, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(openedDatabase))
            sqlite3_free(errorMessage)
            throw TestFailure(message)
        }
    }

    private static func sqliteInteger(at url: URL, query: String) throws -> Int {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let openedDatabase = database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open test database"
            if let database { sqlite3_close(database) }
            throw TestFailure(message)
        }
        defer { sqlite3_close(openedDatabase) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(openedDatabase, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestFailure(String(cString: sqlite3_errmsg(openedDatabase)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TestFailure(String(cString: sqlite3_errmsg(openedDatabase)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func waitPumpingMainRunLoop(
        for semaphore: DispatchSemaphore,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if semaphore.wait(timeout: .now()) == .success { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return semaphore.wait(timeout: .now()) == .success
    }

    private static func pumpMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func normalizedText(_ text: String, date: TimeInterval) throws -> NormalizedClipboardItem {
        guard let item = ClipboardNormalizer.normalize(
            ["public.utf8-plain-text": Data(text.utf8)],
            createdAt: Date(timeIntervalSince1970: date)
        ) else { throw TestFailure("text normalization returned no item") }
        return item
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClipVaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure(message) }
    }
}

private final class FakeClipboardSource: ClipboardSnapshotSource {
    var changeCount = 0
    var values: [String: Data] = [:]
    var readCount = 0
    var source = ClipboardSource(bundleIdentifier: "test.source", applicationName: "Test Source")

    func currentRepresentations() -> [String: Data] {
        readCount += 1
        return values
    }
}

private struct TestFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
