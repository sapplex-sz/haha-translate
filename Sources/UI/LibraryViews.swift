import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var models: ModelStore
    @State private var deleting: TranslationModel?
    @State private var localError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text(L("下载来源")).font(.system(size: 12))
                    Picker(L("下载来源"), selection: $models.downloadSourceChoice) {
                        ForEach(ModelDownloadChoice.allCases) { Text($0.displayName).tag($0) }
                    }.id(localization.resolvedLanguage).labelsHidden().frame(width: 260).controlSize(.small).disabled(models.downloadingModel != nil)
                        .help(L("下载前自动比较可用线路，选择更快的来源；也可手动指定。"))
                    Spacer(minLength: 0)
                }
                VStack(spacing: 0) {
                    ForEach(TranslationModel.allCases) { model in
                        modelCard(model)
                        if model != TranslationModel.allCases.last { Divider().padding(.horizontal, 12) }
                    }
                }.background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(Palette.line) }
                if let status = models.statusMessage, models.downloadingModel == nil {
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let error = localError ?? models.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red)
                            .textSelection(.enabled)
                        if localError == nil, let details = models.errorDetails {
                            DisclosureGroup(L("错误详情")) {
                                Text(details).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                Button(L("复制错误详情")) {
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(details, forType: .string)
                                }.buttonStyle(QuietButtonStyle())
                            }.font(.system(size: 11))
                        }
                        if localError == nil, let failed = models.failedDownloadModel {
                            HStack(spacing: 10) {
                                Button(L("重试下载")) { startDownload(failed) }.buttonStyle(QuietButtonStyle())
                                    .disabled(models.downloadingModel != nil)
                                Link(L("用浏览器下载"), destination: failed.downloadURL(for: models.selectedDownloadSource)).font(.system(size: 11))
                            }
                        }
                    }
                }
                DisclosureGroup(L("关于模型")) {
                    Text(L("两种模型均在本机运行，安装前会校验文件完整性。专业模型使用更多磁盘与内存；译文仍需结合上下文核对。开源许可可在设置中查看。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    Button(L("开源许可")) { app.settingsPane = .about; app.section = .settings }.buttonStyle(.link).font(.system(size: 11))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.bottom, 14)
        }.confirmationDialog(L("删除这个离线模型？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L("删除模型"), role: .destructive) {
                guard let model = deleting else { return }; deleting = nil
                Task { await app.unload(); do { try models.delete(model) } catch { localError = error.localizedDescription } }
            }
        } message: { Text(L("只删除所选模型文件。之后可以重新下载，你的术语表不会受影响。")) }
    }

    private func modelCard(_ model: TranslationModel) -> some View {
        let installed = models.isInstalled(model)
        let active = installed && models.selectedModel == model
        let downloading = models.downloadingModel == model
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(model.displayName).font(.system(size: 13, weight: .semibold))
                        Text(model.formattedSize).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(model == .light ? L("体积小，适合日常翻译。") : L("保留更多模型精度。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if installed {
                    if active {
                        Label(L("正在使用"), systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.orange)
                    } else {
                        Button(L("使用这个模型")) {
                            Task { await app.unload(); models.selectedModel = model; app.notify(L("已切换模型")) }
                        }.buttonStyle(QuietButtonStyle()).disabled(app.isTranslating || app.isMaintainingModel || models.downloadingModel != nil)
                    }
                    Button { deleting = model } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(L("删除模型"))
                        .disabled(app.isTranslating || app.isMaintainingModel || models.downloadingModel != nil)
                } else if !downloading {
                    Button(L("导入文件")) { importModel(model) }.buttonStyle(QuietButtonStyle()).disabled(models.downloadingModel != nil)
                    Button(L("下载模型")) { startDownload(model) }.buttonStyle(PrimaryButtonStyle()).disabled(models.downloadingModel != nil)
                }
            }
            if downloading {
                ProgressView(value: models.downloadProgress ?? 0).tint(Palette.orange)
                HStack {
                    Text(models.statusMessage ?? L("正在准备…"))
                    Spacer()
                    Text(L("%d%%", Int((models.downloadProgress ?? 0) * 100)))
                    Button(L("取消")) { models.cancelDownload() }.buttonStyle(.plain)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(14)
    }

    private func startDownload(_ model: TranslationModel) {
        localError = nil
        Task { await models.download(model) }
    }

    private func importModel(_ model: TranslationModel) {
        localError = nil
        let panel = NSOpenPanel()
        panel.title = L("导入 %@", model.displayName)
        panel.message = L("请选择 %@ 的完整模型文件。导入时会核验文件完整性。", model.displayName)
        // GGUF has no system-wide registered UTI. Accept files here and validate
        // the exact publisher size and digest in ModelStore before installation.
        panel.allowedContentTypes = [.item]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try await models.importModel(from: url, as: model); app.notify(L("模型导入完成")) }
            catch { localError = error.localizedDescription }
        }
    }
}

struct HistoryView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @EnvironmentObject private var app: AppState
    @State private var clearConfirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(L("保存翻译历史"), isOn: $app.historyEnabled).toggleStyle(.switch).controlSize(.small).font(.system(size: 12)).help(L("默认不保存。开启后，最多保存 100 条在本机；关闭后停止新增，已有记录可手动清空。"))
                Spacer()
                if !app.history.isEmpty { Button(L("清空记录")) { clearConfirmation = true }.buttonStyle(QuietButtonStyle()) }
            }
            if app.history.isEmpty {
                EmptyState(icon: "clock", title: L("暂无记录"), detail: L("开启后保存最近 100 条翻译。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(app.history) { item in
                            Button { app.restore(item) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text(item.date, style: .date); Text(item.date, style: .time); Spacer(); Text(item.languageTitle) }.font(.system(size: 10)).foregroundStyle(.tertiary)
                                    Text(item.source).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                    Text(item.translation).font(.system(size: 13)).lineLimit(2).lineSpacing(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Palette.paper, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).disabled(app.isTranslating)
                        }
                    }
                }
            }
        }.padding(.horizontal, 18).padding(.bottom, 14)
            .confirmationDialog(L("清空所有翻译历史？"), isPresented: $clearConfirmation, titleVisibility: .visible) {
                Button(L("清空记录"), role: .destructive) { app.clearHistory() }
            } message: { Text(L("清空后无法恢复，当前编辑区的文字不受影响。")) }
    }
}

struct GlossaryView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @EnvironmentObject private var app: AppState
    @State private var source = ""
    @State private var target = ""
    @State private var validation: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField(L("原词"), text: $source).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                TextField(L("期望译法"), text: $target).textFieldStyle(.roundedBorder)
                Button(L("添加")) { add() }.buttonStyle(PrimaryButtonStyle()).disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(L("为名称与术语提供参考译法。"))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            if let validation { Text(validation).font(.system(size: 11)).foregroundStyle(.orange) }
            if app.glossary.isEmpty {
                EmptyState(icon: "text.book.closed", title: L("暂无术语"), detail: L("在上方添加原词与期望译法。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(app.glossary) { entry in
                            HStack(spacing: 18) {
                                Text(entry.source).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                                Text(entry.target).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                                Button { app.glossary.removeAll { $0.id == entry.id }; app.saveGlossary() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).help(L("删除词条"))
                            }.padding(.horizontal, 12).padding(.vertical, 10)
                            Divider().opacity(0.4)
                        }
                    }.background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }.padding(.horizontal, 18).padding(.bottom, 14)
    }
    private func add() {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count <= 80, t.count <= 120, app.glossary.count < 200 else { validation = L("最多 200 条术语；原词限 80 字符，译法限 120 字符。"); return }
        if let index = app.glossary.firstIndex(where: { $0.source.caseInsensitiveCompare(s) == .orderedSame }) {
            app.glossary[index].target = t
        } else { app.glossary.append(.init(source: s, target: t)) }
        app.saveGlossary(); source = ""; target = ""; validation = nil
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, translation, shortcuts, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return L("通用")
        case .translation: return L("翻译")
        case .shortcuts: return L("快捷键")
        case .about: return L("关于")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @State private var showPrivacy = false
    @State private var showLicenses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L("设置"), selection: $app.settingsPane) {
                ForEach(SettingsPane.allCases) { Text($0.title).tag($0) }
            }.id(localization.resolvedLanguage).pickerStyle(.segmented).tint(appearance.theme.action)
                .labelsHidden().frame(maxWidth: 520).accessibilityIdentifier("settings.pane")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch app.settingsPane {
                    case .general: appearanceSettings; modelSettings
                    case .translation: translationSettings
                    case .shortcuts: shortcutSettings
                    case .about: privacySettings
                    }
                }.frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.horizontal, 18).padding(.bottom, 14)
            .sheet(isPresented: $showLicenses) { LicenseView() }
            .sheet(isPresented: $showPrivacy) { privacySheet }
    }

    private var appearanceSettings: some View {
        settingsGroup(L("外观与语言")) {
            preferenceRow(L("界面语言")) {
                Picker(L("界面语言"), selection: $localization.language) {
                    ForEach(AppLocalization.supportedLanguages) { language in
                        Text(language.id == "system" ? L("跟随系统") : language.name).tag(language.id)
                    }
                }.labelsHidden().accessibilityIdentifier("settings.interfaceLanguage")
                    .help(L("仅改变应用界面的语言，不影响原文与译文。"))
            }
            HStack(spacing: 8) {
                Text(L("精选主题")).font(.system(size: 12)).frame(width: 130, alignment: .leading)
                ForEach(AppTheme.allCases) { theme in
                    Button { appearance.theme = theme } label: {
                        Circle().fill(theme.action).frame(width: 22, height: 22)
                            .overlay {
                                if appearance.theme == theme {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                }
                            }.padding(3)
                            .overlay { Circle().strokeBorder(appearance.theme == theme ? theme.accent : .clear, lineWidth: 1) }
                    }.buttonStyle(.plain).help(theme.title).accessibilityLabel(theme.title)
                        .accessibilityIdentifier("settings.theme.\(theme.rawValue)")
                        .accessibilityAddTraits(appearance.theme == theme ? .isSelected : [])
                }
                Text(appearance.theme.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }.help(L("主题随系统自动适配浅色与深色外观。"))
        }
    }

    private var translationSettings: some View {
        settingsGroup(L("翻译习惯")) {
            preferenceRow(L("翻译方向")) {
                Picker(L("翻译方向"), selection: $app.translationMode) {
                    Text(L("双向语言对")).tag(TranslationDirectionMode.automaticPair)
                    Text(L("固定目标语言")).tag(TranslationDirectionMode.fixedTarget)
                }.id(localization.resolvedLanguage).labelsHidden().accessibilityIdentifier("settings.translationMode")
            }
            if app.translationMode == .automaticPair {
                preferenceRow(L("语言 A")) {
                    Picker(L("语言 A"), selection: $app.pairLanguageA) {
                        ForEach(AppLanguage.allCases.filter { $0 != .automatic && $0 != app.pairLanguageB }) { Text($0.title).tag($0) }
                    }.id(localization.resolvedLanguage).labelsHidden().accessibilityIdentifier("settings.pairLanguageA")
                }
                preferenceRow(L("语言 B")) {
                    Picker(L("语言 B"), selection: $app.pairLanguageB) {
                        ForEach(AppLanguage.allCases.filter { $0 != .automatic && $0 != app.pairLanguageA }) { Text($0.title).tag($0) }
                    }.id(localization.resolvedLanguage).labelsHidden().accessibilityIdentifier("settings.pairLanguageB")
                }
                Text(L("%@ 与 %@ 自动互译；遇到其他语言或无法识别时，默认译为 %@。", app.pairLanguageA.title, app.pairLanguageB.title, app.pairLanguageA.title))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                preferenceRow(L("目标语言")) {
                    Picker(L("目标语言"), selection: $app.targetLanguage) {
                        ForEach(AppLanguage.allCases.filter { $0 != .automatic }) { Text($0.title).tag($0) }
                    }.id(localization.resolvedLanguage).labelsHidden().accessibilityIdentifier("settings.targetLanguage")
                        .help(L("不同原文语言都译为同一个目标语言。"))
                }
            }
            Divider().padding(.vertical, 2)
            preferenceRow(L("原文语言")) {
                Picker(L("原文语言"), selection: $app.sourceLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }.id(localization.resolvedLanguage).labelsHidden().accessibilityIdentifier("settings.sourceLanguage")
                    .help(L("推荐自动识别。短词或多义词可手动指定原文语言，主窗口也可随时调整。"))
            }
        }.disabled(app.isTranslating)
    }

    private var modelSettings: some View {
        settingsGroup(L("模型与内存")) {
            preferenceRow(L("模型保温时间")) {
                Picker(L("模型保温时间"), selection: $app.keepWarmMinutes) {
                    Text(L("1 分钟 · 更省内存")).tag(1)
                    Text(L("3 分钟 · 均衡")).tag(3)
                    Text(L("10 分钟 · 连续阅读")).tag(10)
                }.id(localization.resolvedLanguage).labelsHidden()
                    .help(L("连续翻译可复用已加载的模型。超过保温时间后自动释放，下次翻译会重新加载。"))
            }
            HStack {
                Text(L("立即释放模型内存")).font(.system(size: 12)).frame(width: 130, alignment: .leading)
                Button(L("释放")) { Task { await app.unload() } }.buttonStyle(QuietButtonStyle())
                    .disabled(app.isTranslating || app.isMaintainingModel)
            }
        }
    }

    private var shortcutSettings: some View {
        settingsGroup(L("顺手的快捷方式")) {
            shortcut(L("翻译剪贴板文字"), "⌥D")
            shortcut(L("截图识别并翻译"), "⌥S")
            shortcut(L("在主窗口翻译"), "⌘↩")
            shortcut(L("关闭快捷浮窗"), "Esc")
            DisclosureGroup(L("翻译选中的文字")) {
                Text(L("选中文字后，在当前应用的「服务」菜单中选择「使用HaHa翻译」；部分应用也会在右键菜单显示「服务」。"))
                Text(L("适用于支持文本服务的应用。如果没有此入口，可在系统设置 → 键盘 → 键盘快捷键 → 服务中启用并设置快捷键；也可以先复制文字，再按 ⌥D。"))
                Text(L("快捷键冲突时会在启动后提示。截图权限只在你第一次截图时申请。"))
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var privacySettings: some View {
        settingsGroup(L("HaHa翻译")) {
            Text(L("版本 %@ (%@)", AppVersion.version, AppVersion.build)).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(L("本地处理")).font(.system(size: 12))
            HStack(spacing: 10) {
                Button(L("隐私说明")) { showPrivacy = true }.buttonStyle(QuietButtonStyle())
                Button(L("开源许可")) { showLicenses = true }.buttonStyle(QuietButtonStyle())
                Link(L("联系支持 ↗"), destination: URL(string: "mailto:sapplex@icloud.com?subject=HaHaTranslate%20Support")!)
                    .font(.system(size: 12))
            }
        }
    }

    private var privacySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("隐私说明")).font(.system(size: 17, weight: .semibold))
            ScrollView {
                Text(L("HaHa翻译在这台 Mac 上识别与翻译文字，不把原文、译文或截图发送到翻译服务器。\n\n只有你主动下载模型或打开外部支持链接时才访问网络。模型托管方会接收提供下载所需的网络信息，例如 IP 地址；请求不包含你的翻译内容。\n\n术语表与自选开启的历史保存在本机，你可在应用中删除。模型可单独删除，不影响术语。截图仅在识别期间处理，不默认保存。\n\n联系方式：sapplex@icloud.com"))
                    .font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button(L("完成")) { showPrivacy = false }.buttonStyle(PrimaryButtonStyle()) }
        }.padding(20).frame(width: 520, height: 440).environment(\.locale, localization.locale).tint(appearance.theme.accent)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.bottom, 2)
            content()
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
    }
    private func preferenceRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).frame(width: 130, alignment: .leading)
            content().frame(maxWidth: 260, alignment: .leading)
            Spacer(minLength: 0)
        }.controlSize(.small)
    }
    private func shortcut(_ title: String, _ key: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).frame(width: 210, alignment: .leading)
            Text(key).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(.vertical, 2)
    }
}

struct LicenseView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "HyMT2"
    private let names = ["HyMT2", "llama.cpp-MIT", "jsonhpp-MIT", "llamafile-MIT", "additional-MIT-notices"]
    private var content: String {
        guard let url = Bundle.main.url(forResource: selected, withExtension: "txt") ?? Bundle.main.url(forResource: selected, withExtension: "txt", subdirectory: "Licenses"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return L("许可文件未找到，请联系 sapplex@icloud.com。") }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(L("开源软件与模型许可")).font(.system(size: 17, weight: .semibold)); Spacer(); Button(L("完成")) { dismiss() } }
            Picker(L("组件"), selection: $selected) { ForEach(names, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
            ScrollView { Text(content).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(20).frame(width: 620, height: 460)
    }
}
