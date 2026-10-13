import AppKit
import Carbon
import Combine
import SwiftUI

@main struct HaHaTranslateMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = HaHaAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class HaHaAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let models = ModelStore()
    lazy var state = AppState(models: models)
    private var mainWindow: NSWindow?
    private var quickWindow: NSPanel?
    private var statusItem: NSStatusItem?
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var subscriptions: Set<AnyCancellable> = []
    private let screenOCR = ScreenOCR()
    private var capturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        configureStatusItem()
        AppLocalization.shared.$language.dropFirst().sink { [weak self] _ in
            // @Published sends before didSet installs the lookup snapshot.
            DispatchQueue.main.async {
                guard let self else { return }
                self.configureMenu(); self.configureStatusItem()
                self.mainWindow?.title = L("HaHa翻译")
                self.quickWindow?.title = L("HaHa翻译")
            }
        }.store(in: &subscriptions)
        registerHotKeys()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        state.showMainWindow = { [weak self] in self?.showMain() }
        state.showQuickWindow = { [weak self] in self?.showQuick() }
        state.dismissQuickWindow = { [weak self] in self?.quickWindow?.orderOut(nil) }
        state.screenshotAction = { [weak self] in self?.captureScreen() }
        state.$isPinned.sink { [weak self] pinned in self?.quickWindow?.level = pinned ? .floating : .normal }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        showMain()
        #if DEBUG
        processDevelopmentArguments()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let panel = quickWindow, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return false // Already handled; do not let AppKit raise the main window over the panel.
        }
        if !flag {
            showMain()
            return false
        }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        for key in hotKeys { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
        models.cancelDownload()
    }
    @objc private func willSleep() { Task { await state.unload() } }

    func showMain() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = L("HaHa翻译")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 800, height: 448)
            window.contentView = NSHostingView(rootView: LocalizedAppRoot { [state = self.state, models = self.models] in WorkspaceView().environmentObject(state).environmentObject(models).padding(.top, 28).ignoresSafeArea(.container, edges: .top).background(Palette.background.ignoresSafeArea()) })
            window.setFrameAutosaveName("HaHaMainWindowCompactV2")
            window.center(); window.delegate = self
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showQuick() {
        if quickWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.minSize = NSSize(width: 400, height: 300)
            panel.title = L("HaHa翻译")
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: LocalizedAppRoot { [state = self.state] in
                QuickTranslationView().environmentObject(state).ignoresSafeArea(.container, edges: .top)
            })
            quickWindow = panel
        }
        if !state.isPinned || quickWindow?.isVisible != true {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let size = quickWindow?.frame.size ?? NSSize(width: 460, height: 360)
                let x = min(max(mouse.x + 16, visible.minX + 12), visible.maxX - size.width - 12)
                let y = min(max(mouse.y - size.height, visible.minY + 12), visible.maxY - size.height - 12)
                quickWindow?.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
        quickWindow?.level = state.isPinned ? .floating : .normal
        quickWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func translateSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = L("没有可翻译的文字。") as NSString; return
        }
        state.receive(text)
    }

    @objc private func showMainAction() { showMain() }
    @objc private func translateClipboardAction() { state.translateClipboard() }
    @objc private func screenshotAction() { captureScreen() }
    @objc private func settingsAction() { state.section = .settings; showMain() }
    @objc private func aboutAction() { state.settingsPane = .about; state.section = .settings; showMain() }
    @objc private func modelsAction() { state.section = .models; showMain() }
    @objc private func quitAction() { NSApp.terminate(nil) }
    @objc private func translationSectionAction() { state.section = .translate; showMain() }

    private func captureScreen() {
        guard !capturing, !state.isTranslating else { state.notify(L("请先完成或停止当前翻译。")); return }
        state.rememberApplication()
        capturing = true
        let mainWasVisible = mainWindow?.isVisible == true
        mainWindow?.orderOut(nil); quickWindow?.orderOut(nil)
        Task {
            defer { capturing = false }
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let text = try await screenOCR.captureSelection()
                state.receive(text, rememberSource: false)
            } catch is CancellationError {
                if mainWasVisible { showMain() }
            } catch {
                state.error = error.localizedDescription; showMain()
            }
        }
    }

    private func configureStatusItem() {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: L("HaHa翻译"))
        item.button?.setAccessibilityLabel(L("HaHa翻译"))
        image?.isTemplate = true; item.button?.image = image
        let menu = NSMenu()
        menu.addItem(menuItem(L("打开 HaHa翻译"), #selector(showMainAction)))
        menu.addItem(.separator())
        menu.addItem(menuItem(L("翻译剪贴板  ⌥D"), #selector(translateClipboardAction)))
        menu.addItem(menuItem(L("截图翻译  ⌥S"), #selector(screenshotAction)))
        menu.addItem(.separator())
        menu.addItem(menuItem(L("离线模型…"), #selector(modelsAction)))
        menu.addItem(menuItem(L("设置…"), #selector(settingsAction), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem(L("退出 HaHa翻译"), #selector(quitAction), key: "q"))
        item.menu = menu; statusItem = item
    }

    private func configureMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(menuItem(L("关于 HaHa翻译"), #selector(aboutAction)))
        appMenu.addItem(menuItem(L("设置…"), #selector(settingsAction), key: ","))
        let services = NSMenu(); let servicesItem = NSMenuItem(title: L("服务"), action: nil, keyEquivalent: ""); servicesItem.submenu = services
        appMenu.addItem(servicesItem); NSApp.servicesMenu = services
        appMenu.addItem(.separator()); appMenu.addItem(menuItem(L("退出 HaHa翻译"), #selector(quitAction), key: "q"))
        let editItem = NSMenuItem(); let edit = NSMenu(title: L("编辑")); editItem.submenu = edit; menu.addItem(editItem)
        for (title, selector, key) in [(L("撤销"), Selector(("undo:")), "z"), (L("剪切"), #selector(NSText.cut(_:)), "x"), (L("复制"), #selector(NSText.copy(_:)), "c"), (L("粘贴"), #selector(NSText.paste(_:)), "v"), (L("全选"), #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        let translateItem = NSMenuItem()
        let translateMenu = NSMenu(title: L("翻译"))
        translateItem.submenu = translateMenu; menu.addItem(translateItem)
        let clipboardItem = menuItem(L("翻译剪贴板"), #selector(translateClipboardAction), key: "d")
        clipboardItem.keyEquivalentModifierMask = .option
        translateMenu.addItem(clipboardItem)
        let screenshotItem = menuItem(L("截图翻译…"), #selector(screenshotAction), key: "s")
        screenshotItem.keyEquivalentModifierMask = .option
        translateMenu.addItem(screenshotItem)
        let viewItem = NSMenuItem(); let view = NSMenu(title: L("窗口")); viewItem.submenu = view; menu.addItem(viewItem)
        view.addItem(menuItem(L("翻译"), #selector(translationSectionAction), key: "1"))
        #if DEBUG
        view.addItem(.separator())
        view.addItem(menuItem("紧凑窗口尺寸", #selector(compactCanvasAction)))
        view.addItem(menuItem("最小窗口尺寸", #selector(minimumCanvasAction)))
        view.addItem(menuItem(L("商店截图尺寸"), #selector(storeCanvasAction)))
        let exportItem = menuItem(L("导出当前真实界面"), #selector(exportStoreCaptureAction), key: "e")
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(exportItem)
        view.addItem(menuItem("导出快捷浮窗", #selector(exportQuickCaptureAction)))
        view.addItem(menuItem("深色测试", #selector(darkTestAction)))
        view.addItem(menuItem("跟随系统外观", #selector(systemTestAction)))
        #endif
        NSApp.mainMenu = menu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }

    private func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            guard id.signature == 0x48414841, id.id == 1 || id.id == 2 else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<HaHaAppDelegate>.fromOpaque(data).takeUnretainedValue()
            let hotKeyID = id.id
            DispatchQueue.main.async {
                if hotKeyID == 1 { delegate.state.translateClipboard() }
                else { delegate.captureScreen() }
            }
            return noErr
        }, 1, &spec, context, &handler)
        guard handlerStatus == noErr, handler != nil else {
            state.error = L("系统快捷键处理器未能启动（OSStatus %d）。你仍可使用菜单栏或系统服务翻译。", handlerStatus)
            return
        }
        var failures: [String] = []
        for (id, code) in [(UInt32(1), UInt32(kVK_ANSI_D)), (UInt32(2), UInt32(kVK_ANSI_S))] {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(code, UInt32(optionKey), EventHotKeyID(signature: 0x48414841, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference { hotKeys.append(reference) }
            else {
                let shortcut = id == 1 ? "⌥D" : "⌥S"
                if status == OSStatus(eventHotKeyExistsErr) {
                    failures.append(L("快捷键 %@ 已被占用（OSStatus %d）。", shortcut, status))
                } else if status == noErr {
                    failures.append(L("快捷键 %@ 注册未返回有效句柄（OSStatus %d）。", shortcut, status))
                } else {
                    failures.append(L("快捷键 %@ 注册失败（OSStatus %d）。", shortcut, status))
                }
            }
        }
        if !failures.isEmpty {
            state.error = failures.joined(separator: "\n") + L("\n你仍可使用菜单栏或系统服务翻译。")
        }
    }

    #if DEBUG
    @objc private func compactCanvasAction() { resizeTestWindow(width: 880, height: 500) }
    @objc private func minimumCanvasAction() { resizeTestWindow(width: 800, height: 448) }
    @objc private func darkTestAction() { mainWindow?.appearance = NSAppearance(named: .darkAqua); quickWindow?.appearance = NSAppearance(named: .darkAqua) }
    @objc private func systemTestAction() { mainWindow?.appearance = nil; quickWindow?.appearance = nil }
    @objc private func storeCanvasAction() {
        resizeTestWindow(width: 1280, height: 800)
    }
    private func resizeTestWindow(width: CGFloat, height: CGFloat) {
        showMain()
        guard let window = mainWindow else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: width, height: height)), display: true)
        window.center()
    }

    @objc private func exportStoreCaptureAction() {
        guard let view = mainWindow?.contentView else { return }
        exportCapture(view, name: state.section.rawValue)
    }
    @objc private func exportQuickCaptureAction() {
        guard let panel = quickWindow, panel.isVisible, let view = panel.contentView else { return }
        exportCapture(view, name: "quick")
    }
    private func exportCapture(_ view: NSView, name: String) {
        do {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let sourceImage = bitmap.cgImage,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
            let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.fill(bounds)
            }
            context.draw(sourceImage, in: bounds)
            guard let opaqueImage = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: opaqueImage).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HaHaStoreCaptures", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let filename = name
            try png.write(to: folder.appendingPathComponent(filename + ".png"), options: .atomic)
            let evidence: [String: Any] = ["source": state.input, "translation": state.output, "model": models.selectedModel.rawValue, "sha256": models.selectedModel.sha256, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "build": AppVersion.build, "locale": AppLocalization.shared.resolvedLanguage, "settingsPane": state.settingsPane.rawValue, "appearance": view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "", "createdAt": ISO8601DateFormatter().string(from: Date()), "method": "NSView cacheDisplay of live application content"]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent(filename + ".json"), options: .atomic)
        } catch { state.error = L("截图导出失败：%@", error.localizedDescription) }
    }

    private func processDevelopmentArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--development-import-model"), args.indices.contains(index + 1) else { return }
        let file = URL(fileURLWithPath: args[index + 1])
        Task {
            do {
                if !models.isInstalled(.light) { try await models.importModel(from: file, as: .light) }
                if let textIndex = args.firstIndex(of: "--development-text"), args.indices.contains(textIndex + 1) {
                    state.input = args[textIndex + 1]; state.translate()
                }
            } catch { state.error = error.localizedDescription }
        }
    }
    #endif
}


/// Re-evaluate localized content without replacing the window or editor identity.
private struct LocalizedAppRoot<Content: View>: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().environment(\.locale, localization.locale).tint(appearance.theme.accent)
    }
}
