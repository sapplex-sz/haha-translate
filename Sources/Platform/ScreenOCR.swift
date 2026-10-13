import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

enum ScreenOCRError: LocalizedError {
    case busy
    case permissionDenied
    case displayUnavailable
    case invalidSelection
    case noText
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy: return L("截图识别正在进行，请先完成或按 Esc 取消。")
        case .permissionDenied:
            return L("需要屏幕录制权限才能截图识别。请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 HaHa翻译，然后重试；系统可能要求重新打开应用。")
        case .displayUnavailable: return L("显示器已断开或无法读取，请重新选择截图区域。")
        case .invalidSelection: return L("选择区域太小，请重新拖动选择需要翻译的文字。")
        case .noText: return L("没有识别到文字。请缩小选区、放大原文，或选择更清晰的文字区域。")
        case let .recognitionFailed(message): return L("截图文字识别未能完成：%@", message)
        }
    }
}

/// Screenshots are created only after an explicit call, retained in memory, and never saved.
/// The caller owns hiding/restoring its document and translation windows around this call.
@MainActor
final class ScreenOCR {
    private var operationID: UUID?
    private var selector: OCRSelectionCoordinator?
    private let defaults: UserDefaults
    private let permissionRequestedKey = "HaHaTranslate.didRequestScreenRecording"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func captureSelection() async throws -> String {
        guard operationID == nil else { throw ScreenOCRError.busy }
        let id = UUID()
        operationID = id
        defer {
            selector?.cancel()
            selector = nil
            operationID = nil
        }
        try Task.checkCancellation()
        try ensurePermission()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let availableIDs = Set(content.displays.map(\.displayID))
        let screens = NSScreen.screens.filter { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return availableIDs.contains(CGDirectDisplayID(id.uint32Value))
        }
        guard !screens.isEmpty else { throw ScreenOCRError.displayUnavailable }

        let selection: OCRSelection = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let coordinator = OCRSelectionCoordinator(screens: screens) { [weak self] result in
                    if self?.operationID == id { self?.selector = nil }
                    continuation.resume(with: result)
                }
                selector = coordinator
                coordinator.begin()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operationID == id else { return }
                self?.selector?.cancel()
            }
        }
        // Let WindowServer remove the overlays before sampling the selected area.
        try await Task.sleep(nanoseconds: 150_000_000)
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw ScreenOCRError.displayUnavailable
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let sourceRect = try OCRGeometry.sourceRect(selection.rect, screenFrame: selection.screenFrame)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = max(1, Int(ceil(sourceRect.width * scale)))
        config.height = max(1, Int(ceil(sourceRect.height * scale)))
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = false
        config.preservesAspectRatio = true
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        let worker = OCRRecognitionWorker(image: image)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try worker.recognize() }.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func ensurePermission() throws {
        if CGPreflightScreenCaptureAccess() { return }
        // A denial is handled with an actionable message, not another prompt on every click.
        guard !defaults.bool(forKey: permissionRequestedKey) else { throw ScreenOCRError.permissionDenied }
        defaults.set(true, forKey: permissionRequestedKey)
        let granted = CGRequestScreenCaptureAccess()
        guard granted || CGPreflightScreenCaptureAccess() else { throw ScreenOCRError.permissionDenied }
    }
}

struct OCRSelection {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let rect: CGRect
}

enum OCRGeometry {
    /// AppKit uses a bottom-left desktop origin. ScreenCaptureKit sourceRect uses
    /// top-left points relative to the chosen display, independently of other displays.
    static func sourceRect(_ selection: CGRect, screenFrame: CGRect) throws -> CGRect {
        let clipped = selection.standardized.intersection(screenFrame)
        guard !clipped.isNull, !clipped.isEmpty, clipped.width >= 8, clipped.height >= 8 else {
            throw ScreenOCRError.invalidSelection
        }
        return CGRect(x: clipped.minX - screenFrame.minX,
                      y: screenFrame.maxY - clipped.maxY,
                      width: clipped.width, height: clipped.height)
    }

    static func clampedRect(from start: CGPoint, to end: CGPoint, bounds: CGRect) -> CGRect {
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)),
                    y: min(bounds.maxY, max(bounds.minY, point.y)))
        }
        let a = clamp(start)
        let b = clamp(end)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

@MainActor
private final class OCRSelectionCoordinator {
    private let screens: [NSScreen]
    private var completion: ((Result<OCRSelection, Error>) -> Void)?
    private var windows: [OCRSelectionWindow] = []
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    init(screens: [NSScreen], completion: @escaping (Result<OCRSelection, Error>) -> Void) {
        self.screens = screens
        self.completion = completion
    }

    func begin() {
        NSApp.activate()
        for screen in screens {
            let window = OCRSelectionWindow(contentRect: screen.frame, styleMask: .borderless,
                                             backing: .buffered, defer: false, screen: screen)
            window.setFrame(screen.frame, display: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.sharingType = .none
            window.acceptsMouseMovedEvents = true
            window.title = L("HaHa翻译截图选区")
            let view = OCRSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onCancel = { [weak self] in self?.cancel() }
            view.onSelection = { [weak self, weak window] localRect in
                guard let self, let window,
                      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
                let global = window.convertToScreen(localRect)
                let selection = OCRSelection(displayID: CGDirectDisplayID(number.uint32Value),
                                             screenFrame: screen.frame, rect: global)
                self.finish(.success(selection))
            }
            window.contentView = view
            window.makeFirstResponder(view)
            windows.append(window)
            window.orderFrontRegardless()
        }
        let pointer = NSEvent.mouseLocation
        let focused = windows.first { $0.frame.contains(pointer) } ?? windows.first
        focused?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(.failure(ScreenOCRError.displayUnavailable)) }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<OCRSelection, Error>) {
        guard let completion else { return }
        self.completion = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        for window in windows {
            (window.contentView as? OCRSelectionView)?.onSelection = nil
            (window.contentView as? OCRSelectionView)?.onCancel = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        NSCursor.arrow.set()
        completion(result)
    }
}

private final class OCRSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class OCRSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var dragStart: CGPoint?
    private var selectedRect: CGRect?
    private var hint = L("拖动选择文字区域 · Esc 取消")

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if let selectedRect { shade.appendRect(selectedRect) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.20).setFill()
        shade.fill()
        if let selectedRect {
            let border = NSBezierPath(rect: selectedRect)
            border.lineWidth = 2
            NSColor(calibratedRed: 0.15, green: 0.83, blue: 0.65, alpha: 1).setStroke()
            border.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: hint, attributes: attributes)
        let size = text.size()
        let bubble = CGRect(x: max(16, (bounds.width - size.width) / 2 - 18), y: max(16, bounds.height - 86),
                            width: min(bounds.width - 32, size.width + 36), height: 46)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 14, yRadius: 14).fill()
        text.draw(at: CGPoint(x: bubble.minX + 18, y: bubble.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragStart = convert(event.locationInWindow, from: nil)
        selectedRect = nil
        hint = L("拖动选择文字区域 · Esc 取消")
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        selectedRect = OCRGeometry.clampedRect(from: dragStart, to: convert(event.locationInWindow, from: nil), bounds: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStart else { return }
        self.dragStart = nil
        let rect = OCRGeometry.clampedRect(from: dragStart, to: convert(event.locationInWindow, from: nil), bounds: bounds)
        guard rect.width >= 8, rect.height >= 8 else {
            selectedRect = nil
            hint = L("选区太小，请重新拖动 · Esc 取消")
            needsDisplay = true
            return
        }
        onSelection?(rect)
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }
}

struct OCRTextLine {
    let text: String
    let bounds: CGRect
}

enum OCRTextLayout {
    /// Preserve uncertain breaks. Join only likely wrapped lines; keep headings, lists,
    /// larger vertical gaps and differently indented blocks separate.
    static func text(from input: [OCRTextLine]) -> String {
        let orderedByY = input.compactMap { line -> OCRTextLine? in
            let value = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : OCRTextLine(text: value, bounds: line.bounds)
        }.sorted {
            if $0.bounds.midY != $1.bounds.midY { return $0.bounds.midY > $1.bounds.midY }
            return $0.bounds.minX < $1.bounds.minX
        }
        // Group near-baseline fragments after a strict sort, instead of using a
        // tolerance in the comparator (which would make the ordering non-transitive).
        var rows: [[OCRTextLine]] = []
        for line in orderedByY {
            if let anchor = rows.last?.first,
               abs(anchor.bounds.midY - line.bounds.midY) < min(anchor.bounds.height, line.bounds.height) * 0.45 {
                rows[rows.count - 1].append(line)
            } else { rows.append([line]) }
        }
        let lines = rows.flatMap { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
        guard let first = lines.first else { return "" }
        let heights = lines.map(\.bounds.height).sorted()
        let medianHeight = max(0.001, heights[heights.count / 2])
        let widest = lines.map(\.bounds.width).max() ?? 1
        var result = first.text
        for index in 1..<lines.count {
            let previous = lines[index - 1]
            let current = lines[index]
            let gap = previous.bounds.minY - current.bounds.maxY
            let sameRow = abs(previous.bounds.midY - current.bounds.midY) < medianHeight * 0.45
            let newBlock = gap > medianHeight * 0.85 || isListItem(current.text)
            let aligned = abs(previous.bounds.minX - current.bounds.minX) < 0.025
            let similarHeight = abs(previous.bounds.height - current.bounds.height) < medianHeight * 0.30
            let lastCharacter = previous.text.last.map(String.init) ?? ""
            let endsSentence = "。！？.!?:：；;".contains(lastCharacter)
            let likelyWrap = !newBlock && aligned && similarHeight && !endsSentence &&
                previous.bounds.width > widest * 0.72 && gap < medianHeight * 0.85
            if sameRow || likelyWrap {
                let separator = joinsWithoutSpace(previous.text, current.text) ? "" : " "
                result += separator + current.text
            } else {
                result += (newBlock ? "\n\n" : "\n") + current.text
            }
        }
        return result
    }

    private static func isListItem(_ text: String) -> Bool {
        text.range(of: #"^(?:[•●▪◦\-\*]|\d+[\.)、]|[一二三四五六七八九十]+、)\s*"#,
                   options: .regularExpression) != nil
    }

    private static func joinsWithoutSpace(_ left: String, _ right: String) -> Bool {
        guard let a = left.unicodeScalars.last, let b = right.unicodeScalars.first else { return false }
        func isCJK(_ value: UInt32) -> Bool {
            (0x2E80...0x9FFF).contains(value) || (0xFF00...0xFFEF).contains(value) ||
            (0xF900...0xFAFF).contains(value) || (0x20000...0x3134F).contains(value)
        }
        return isCJK(a.value) && isCJK(b.value)
    }
}

final class OCRRecognitionWorker: @unchecked Sendable {
    private let image: CGImage
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var cancelled = false

    init(image: CGImage) { self.image = image }

    func cancel() {
        lock.lock()
        cancelled = true
        let request = self.request
        lock.unlock()
        request?.cancel()
    }

    func recognize() throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"].filter(supported.contains)
        lock.lock()
        self.request = request
        let isCancelled = cancelled
        lock.unlock()
        defer {
            lock.lock()
            self.request = nil
            lock.unlock()
        }
        if isCancelled { throw CancellationError() }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw CancellationError() }
            throw ScreenOCRError.recognitionFailed(error.localizedDescription)
        }
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        let lines = (request.results ?? []).compactMap { observation -> OCRTextLine? in
            guard let value = observation.topCandidates(1).first?.string else { return nil }
            return OCRTextLine(text: value, bounds: observation.boundingBox)
        }
        let text = OCRTextLayout.text(from: lines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScreenOCRError.noText }
        return text
    }
}
