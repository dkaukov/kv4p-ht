import SwiftUI

// MARK: - Theme Mode

enum AppThemeMode: String, CaseIterable, Identifiable {
    case light, dark, system, night
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light:  return "Light"
        case .dark:   return "Dark"
        case .system: return "System"
        case .night:  return "Night"
        }
    }
}

// MARK: - Theme Tokens (mirrors kv-ui.jsx KV_THEMES)

struct AppTheme {
    let mode: AppThemeMode

    let bg:         Color
    let surface:    Color
    let surface2:   Color
    let elevated:   Color
    let label:      Color
    let label2:     Color
    let label3:     Color
    let sep:        Color
    let hairline:   Color
    let accent:     Color
    let accentSoft: Color
    let green:      Color
    let greenSoft:  Color
    let red:        Color
    let redSoft:    Color
    let amber:      Color
    let fill:       Color
    let fill2:      Color
    let chrome:     Color
    let meterTrack: Color
    let isDark:     Bool

    // MARK: Dark
    static let dark = AppTheme(
        mode: .dark,
        bg:         Color(hex: "000000"),
        surface:    Color(hex: "1C1C1E"),
        surface2:   Color(hex: "2C2C2E"),
        elevated:   Color(hex: "262629"),
        label:      Color.white,
        label2:     Color.white.opacity(0.62),
        label3:     Color.white.opacity(0.32),
        sep:        Color(hex: "545458").opacity(0.55),
        hairline:   Color(hex: "545458").opacity(0.34),
        accent:     Color(hex: "0A84FF"),
        accentSoft: Color(hex: "0A84FF").opacity(0.18),
        green:      Color(hex: "30D158"),
        greenSoft:  Color(hex: "30D158").opacity(0.18),
        red:        Color(hex: "FF453A"),
        redSoft:    Color(hex: "FF453A").opacity(0.20),
        amber:      Color(hex: "FF9F0A"),
        fill:       Color(hex: "787880").opacity(0.30),
        fill2:      Color(hex: "787880").opacity(0.20),
        chrome:     Color(hex: "141416").opacity(0.78),
        meterTrack: Color(hex: "787880").opacity(0.24),
        isDark:     true
    )

    // MARK: Light
    static let light = AppTheme(
        mode: .light,
        bg:         Color(hex: "F2F2F7"),
        surface:    Color.white,
        surface2:   Color.white,
        elevated:   Color.white,
        label:      Color.black,
        label2:     Color(hex: "3C3C43").opacity(0.60),
        label3:     Color(hex: "3C3C43").opacity(0.30),
        sep:        Color(hex: "3C3C43").opacity(0.29),
        hairline:   Color(hex: "3C3C43").opacity(0.13),
        accent:     Color(hex: "007AFF"),
        accentSoft: Color(hex: "007AFF").opacity(0.12),
        green:      Color(hex: "34C759"),
        greenSoft:  Color(hex: "34C759").opacity(0.16),
        red:        Color(hex: "FF3B30"),
        redSoft:    Color(hex: "FF3B30").opacity(0.14),
        amber:      Color(hex: "FF9500"),
        fill:       Color(hex: "787880").opacity(0.16),
        fill2:      Color(hex: "787880").opacity(0.10),
        chrome:     Color(hex: "F9F9FC").opacity(0.80),
        meterTrack: Color(hex: "787880").opacity(0.20),
        isDark:     false
    )

    // MARK: Night (red-on-black — preserves dark adaptation)
    static let night = AppTheme(
        mode: .night,
        bg:         Color(hex: "000000"),
        surface:    Color(hex: "170303"),
        surface2:   Color(hex: "220606"),
        elevated:   Color(hex: "1D0404"),
        label:      Color(hex: "FF6B5E"),
        label2:     Color(hex: "FF6B5E").opacity(0.62),
        label3:     Color(hex: "FF6B5E").opacity(0.30),
        sep:        Color(hex: "FF5046").opacity(0.22),
        hairline:   Color(hex: "FF5046").opacity(0.14),
        accent:     Color(hex: "FF453A"),
        accentSoft: Color(hex: "FF453A").opacity(0.18),
        green:      Color(hex: "FF6B5E"),
        greenSoft:  Color(hex: "FF453A").opacity(0.16),
        red:        Color(hex: "FF453A"),
        redSoft:    Color(hex: "FF453A").opacity(0.24),
        amber:      Color(hex: "FF6B5E"),
        fill:       Color(hex: "FF5046").opacity(0.14),
        fill2:      Color(hex: "FF5046").opacity(0.08),
        chrome:     Color(hex: "0C0202").opacity(0.82),
        meterTrack: Color(hex: "FF5046").opacity(0.16),
        isDark:     true
    )

    static func forMode(_ mode: AppThemeMode, systemColorScheme: ColorScheme) -> AppTheme {
        switch mode {
        case .light:  return .light
        case .dark:   return .dark
        case .night:  return .night
        case .system: return systemColorScheme == .dark ? .dark : .light
        }
    }
}

// MARK: - Environment Key

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.dark
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Hex color init

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: h).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >>  8) & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
