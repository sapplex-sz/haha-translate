import AppKit
import Combine
import SwiftUI

/// A small set of accents, with separate light/dark values for readable controls.
enum AppTheme: String, CaseIterable, Identifiable {
    case orange, ocean, forest, violet, rose, graphite

    var id: String { rawValue }
    var title: String {
        switch self {
        case .orange: return L("暖橘")
        case .ocean: return L("海蓝")
        case .forest: return L("松绿")
        case .violet: return L("鸢紫")
        case .rose: return L("玫瑰")
        case .graphite: return L("石墨")
        }
    }

    private var lightRGB: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .orange: return (0.77, 0.24, 0.11)
        case .ocean: return (0.08, 0.37, 0.68)
        case .forest: return (0.13, 0.43, 0.32)
        case .violet: return (0.43, 0.29, 0.68)
        case .rose: return (0.69, 0.23, 0.39)
        case .graphite: return (0.30, 0.35, 0.41)
        }
    }
    private var darkRGB: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .orange: return (1.00, 0.57, 0.37)
        case .ocean: return (0.41, 0.68, 0.97)
        case .forest: return (0.40, 0.75, 0.57)
        case .violet: return (0.72, 0.59, 0.96)
        case .rose: return (0.95, 0.53, 0.67)
        case .graphite: return (0.69, 0.74, 0.81)
        }
    }
    var accent: Color {
        let light = lightRGB, dark = darkRGB
        return Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
    /// Stronger fills keep white button labels legible in either system appearance.
    var action: Color {
        let rgb = lightRGB
        return Color(red: Double(rgb.0), green: Double(rgb.1), blue: Double(rgb.2))
    }
}

@MainActor final class AppAppearance: ObservableObject {
    static let shared = AppAppearance()
    static let preferenceKey = "HaHaTranslate.theme"
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Self.preferenceKey) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .orange
    }
}

@MainActor enum Palette {
    // Retain the original name so platform views use the selected accent too.
    static var orange: Color { AppAppearance.shared.theme.accent }
    static var action: Color { AppAppearance.shared.theme.action }
    static let ink = Color.primary
    static let background = Color(nsColor: .windowBackgroundColor)
    static let paper = Color(nsColor: .textBackgroundColor)
    static var softOrange: Color { orange.opacity(0.075) }
    static let line = Color.primary.opacity(0.08)
}

enum AppVersion {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
}

struct BrandMark: View {
    var size: CGFloat = 42
    var body: some View {
        Image("BrandMark").resizable().interpolation(.high)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @ObservedObject private var appearance = AppAppearance.shared
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(.white).background(appearance.theme.action.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct StatusPill: View {
    let title: String
    var color: Color = .green
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.system(size: 10, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.08), in: Capsule())
    }
}

struct EmptyState: View {
    @ObservedObject private var appearance = AppAppearance.shared
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}
