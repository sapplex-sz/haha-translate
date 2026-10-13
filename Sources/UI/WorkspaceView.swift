import AppKit
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var models: ModelStore
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var appearance = AppAppearance.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 160)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(app.section.title).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    if app.section == .translate {
                        Button { app.section = .models } label: {
                            Label(models.isInstalled(models.selectedModel) ? models.selectedModel.displayName : L("尚未下载模型"), systemImage: "internaldrive")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.buttonStyle(.plain).help(L("离线模型"))
                    }
                }.padding(.horizontal, 18).padding(.vertical, 12)
                if let error = app.error, app.section != .translate {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red)
                        Spacer(minLength: 8)
                        Button { app.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L("关闭提示"))
                    }.padding(.horizontal, 18).padding(.bottom, 10)
                }
                Group {
                    switch app.section {
                    case .translate: TranslationWorkspace()
                    case .history: HistoryView()
                    case .glossary: GlossaryView()
                    case .models: ModelsView()
                    case .settings: SettingsView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.background(Palette.background).frame(minWidth: 800, minHeight: 420)
            .tint(appearance.theme.accent).environment(\.locale, localization.locale)
            .overlay(alignment: .bottom) {
                if let toast = app.toast {
                    Text(toast).font(.system(size: 12)).multilineTextAlignment(.center).padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                        .padding(.horizontal, 20).padding(.bottom, 48).allowsHitTesting(false)
                }
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                BrandMark(size: 26)
                Text("HaHa").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .accessibilityLabel(L("HaHa翻译"))
            }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 14)
            ForEach(WorkspaceSection.allCases) { section in
                Button { app.section = section } label: {
                    Label(section.title, systemImage: section.icon)
                        .font(.system(size: 12, weight: app.section == section ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                        .foregroundStyle(app.section == section ? appearance.theme.accent : .primary)
                        .background(app.section == section ? appearance.theme.accent.opacity(0.09) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).padding(.horizontal, 8).accessibilityIdentifier("navigation.\(section.rawValue)")
            }
            Spacer(minLength: 0)
        }.background(Color.primary.opacity(0.018))
    }
}

struct TranslationWorkspace: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var models: ModelStore
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var appearance = AppAppearance.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !models.isInstalled(models.selectedModel) {
                HStack(spacing: 10) {
                    Text(L("首次下载轻量模型后，即可离线使用。你也可以导入已有模型。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(L("下载模型")) { app.section = .models }.buttonStyle(QuietButtonStyle())
                }.padding(10).background(Palette.softOrange, in: RoundedRectangle(cornerRadius: 7))
            }
            languageBar
            HStack(spacing: 10) { editorCard; resultCard }.frame(maxHeight: .infinity)
            if let error = app.error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let warning = app.numberWarning {
                Label(warning, systemImage: "number.circle").font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if app.isTranslating { ProgressView().controlSize(.mini) }
                if !app.status.isEmpty { Text(app.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                if let elapsed = app.elapsed { Text(L("%.1f 秒", elapsed)).font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                if app.isTranslating {
                    Button(L("停止翻译"), systemImage: "stop.fill") { app.cancel() }.buttonStyle(QuietButtonStyle())
                } else {
                    Button { app.translate() } label: { Label(L("翻译"), systemImage: "arrow.right") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!app.canTranslate)
                        .keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("translate.button")
                }
            }
        }.padding(.horizontal, 18).padding(.bottom, 14)
    }

    private var languageBar: some View {
        HStack(spacing: 8) {
            Picker(L("原文语言"), selection: $app.sourceLanguage) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }.id(localization.resolvedLanguage).labelsHidden().frame(width: 160)
                .help(L("原文语言")).accessibilityIdentifier("translation.sourceLanguage")
            Button { app.swapLanguages() } label: { Image(systemName: "arrow.left.arrow.right") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L("交换语言与原译文"))
            if app.translationMode == .automaticPair {
                Text(app.actualTarget.title).font(.system(size: 12)).lineLimit(1)
                    .frame(width: 150, alignment: .leading).help(L("目标语言"))
            } else {
                Picker(L("目标语言"), selection: $app.targetLanguage) {
                    ForEach(AppLanguage.allCases.filter { $0 != .automatic }) { Text($0.title).tag($0) }
                }.id(localization.resolvedLanguage).labelsHidden().frame(width: 150)
                    .help(L("目标语言")).accessibilityIdentifier("translation.targetLanguage")
            }
            Spacer(minLength: 4)
            Menu {
                Picker(L("翻译方向"), selection: $app.translationMode) {
                    Text(L("双向语言对")).tag(TranslationDirectionMode.automaticPair)
                    Text(L("固定目标语言")).tag(TranslationDirectionMode.fixedTarget)
                }
                Divider()
                Button(L("调整")) { app.settingsPane = .translation; app.section = .settings }
            } label: {
                Text(app.translationMode == .automaticPair ? L("双向语言对") : L("固定目标语言"))
                    .font(.system(size: 11)).lineLimit(1)
            }.menuStyle(.borderlessButton).fixedSize().help(L("翻译方向"))
        }.controlSize(.small).disabled(app.isTranslating).padding(.bottom, 2)
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text(L("原文")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { if let text = NSPasteboard.general.string(forType: .string) { app.input = text } } label: { Image(systemName: "doc.on.clipboard") }
                    .help(L("粘贴文字")).disabled(app.isTranslating)
                Button { app.screenshotAction?() } label: { Image(systemName: "viewfinder") }
                    .help(L("截图识别并翻译")).disabled(app.isTranslating)
                Button { app.input = ""; app.output = ""; app.error = nil } label: { Image(systemName: "xmark") }
                    .help(L("清空")).disabled(app.isTranslating || app.input.isEmpty)
            }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.secondary).padding(10)
            ZStack(alignment: .topLeading) {
                if app.input.isEmpty {
                    Text(L("在这里输入，或粘贴一段文字…")).font(.system(size: 14)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 13).padding(.top, 6).allowsHitTesting(false)
                }
                TextEditor(text: $app.input).font(.system(size: 14)).lineSpacing(4)
                    .scrollContentBackground(.hidden).padding(.horizontal, 7)
                    .disabled(app.isTranslating).accessibilityIdentifier("translation.input")
            }.frame(minHeight: 150, maxHeight: .infinity)
            Text(L("%d / 12,000", app.input.count)).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(app.input.count > 12_000 ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1) }
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("译文")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !app.output.isEmpty { Text(app.resultLanguageTitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }.padding(10)
            ScrollView {
                if app.output.isEmpty {
                    Text(app.isTranslating ? L("正在本机翻译…") : L("译文会出现在这里"))
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 6)
                } else {
                    Text(app.output).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.top, 3).accessibilityIdentifier("translation.output")
                }
            }.frame(minHeight: 150, maxHeight: .infinity)
            HStack {
                Spacer(minLength: 0)
                Button { app.copy() } label: { Label(L("复制"), systemImage: "doc.on.doc") }
                    .buttonStyle(QuietButtonStyle()).disabled(app.output.isEmpty)
            }.padding(8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1) }
    }
}

struct QuickTranslationView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var appearance = AppAppearance.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                BrandMark(size: 20)
                Text(L("HaHa翻译")).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Button { app.isPinned.toggle() } label: { Image(systemName: app.isPinned ? "pin.fill" : "pin") }.help(L("固定浮窗"))
                    .foregroundStyle(app.isPinned ? appearance.theme.accent : .secondary)
                Button { app.showMainWindow?() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help(L("打开主窗口"))
                Button { app.dismissQuickWindow?() } label: { Image(systemName: "xmark") }.keyboardShortcut(.escape, modifiers: []).help(L("关闭浮窗"))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("原文")).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                ScrollView {
                    Text(app.input).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 65)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack {
                Text(L("译文")).foregroundStyle(appearance.theme.accent)
                Spacer()
                if !app.output.isEmpty { Text(app.resultLanguageTitle).foregroundStyle(.secondary) }
            }.font(.system(size: 10, weight: .medium))
            ScrollView {
                if app.output.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        if app.isTranslating { ProgressView().controlSize(.small) }
                        Text(app.isTranslating ? L("正在本机翻译…") : L("译文会出现在这里")).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 3).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(app.output).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(minHeight: 65, maxHeight: .infinity)
            if let error = app.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let warning = app.numberWarning {
                Text(warning).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 10) {
                if app.isTranslating {
                    Button(L("停止")) { app.cancel() }.buttonStyle(QuietButtonStyle())
                }
                Spacer(minLength: 0)
                Button(L("复制")) { app.copy() }.buttonStyle(QuietButtonStyle()).disabled(app.output.isEmpty)
                Button(L("复制并返回")) { app.copy(returnToApp: true) }.buttonStyle(PrimaryButtonStyle()).disabled(app.output.isEmpty)
                    .accessibilityIdentifier("quick.copyReturn")
            }
        }.padding(14).frame(minWidth: 400, idealWidth: 460, maxWidth: .infinity, minHeight: 300, idealHeight: 360, maxHeight: .infinity)
            .background(Palette.background).tint(appearance.theme.accent).environment(\.locale, localization.locale)
            .overlay(alignment: .bottom) {
                if let toast = app.toast {
                    Text(toast).font(.system(size: 11)).multilineTextAlignment(.center).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 20).padding(.bottom, 64)
                        .allowsHitTesting(false)
                }
            }
    }
}
