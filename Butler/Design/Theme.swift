import SwiftUI
import UIKit
import CoreText

/// The "青花" design language. Every color is a light/dark pair taken from the Paper designs.
enum Theme {
    // MARK: Colors

    static let ground = Color(light: 0xFFFFFF, dark: 0x0B0E17)
    static let surface = Color(light: 0xF3F5FB, dark: 0x151A2A)
    static let ink = Color(light: 0x10131C, dark: 0xEEF1F8)
    static let inkSoft = Color(light: 0x3A3F4E, dark: 0xB4BACB)
    static let muted = Color(light: 0x6B7080, dark: 0x8E95A8)
    static let faint = Color(light: 0x9AA0B2, dark: 0x5A627A)
    static let hairline = Color(light: 0xE7EAF2, dark: 0x232A3D)
    static let dashed = Color(light: 0xD5DAE8, dark: 0x2A3148)
    /// Cobalt used for text, strokes and outlines.
    static let cobalt = Color(light: 0x1F3FA8, dark: 0x8FA5F5)
    /// Cobalt used as a solid fill behind white glyphs.
    static let cobaltFill = Color(light: 0x1F3FA8, dark: 0x3553C9)
    /// The single "today / expired" accent.
    static let vermilion = Color(light: 0xD2381F, dark: 0xF0563A)
    static let vermilionFill = Color(light: 0xD2381F, dark: 0xE0482C)
    /// Inverted capsule: dark in light mode, light in dark mode.
    static let capsule = Color(light: 0x10131C, dark: 0xEEF1F8)
    static let capsuleText = Color(light: 0xC9CEDC, dark: 0x5A6072)

    // MARK: Type

    /// Serif CJK display face. Uses bundled Noto Serif SC when present, otherwise the system serif.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        if let name = FontRegistry.serifCJKName(for: weight) {
            return .custom(name, fixedSize: size)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// Instrument Serif for numerals and dates, italic by default.
    static func numeral(_ size: CGFloat, italic: Bool = true) -> Font {
        let name = italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular"
        if FontRegistry.isAvailable(name) {
            return .custom(name, fixedSize: size)
        }
        let base = Font.system(size: size, weight: .regular, design: .serif)
        return italic ? base.italic() : base
    }

    static func body(_ size: CGFloat = 16, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Small letter-spaced section label, e.g. "这 一 周 要 吃 掉 的".
    static let eyebrow = Font.system(size: 11, weight: .semibold)
    static let eyebrowTracking: CGFloat = 2.6
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Registers fonts shipped in the app bundle so no Info.plist entry is required.
enum FontRegistry {
    private static let bundledFiles = [
        "InstrumentSerif-Regular", "InstrumentSerif-Italic",
        "NotoSerifSC-Regular", "NotoSerifSC-SemiBold", "NotoSerifSC-Bold",
    ]

    static func registerBundledFonts() {
        for file in bundledFiles {
            for ext in ["ttf", "otf"] {
                guard let url = Bundle.main.url(forResource: file, withExtension: ext) else { continue }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    static func isAvailable(_ postScriptName: String) -> Bool {
        UIFont(name: postScriptName, size: 12) != nil
    }

    static func serifCJKName(for weight: Font.Weight) -> String? {
        let candidates: [String]
        switch weight {
        case .bold, .heavy, .black: candidates = ["NotoSerifSC-Bold", "NotoSerifSC-SemiBold"]
        case .semibold, .medium: candidates = ["NotoSerifSC-SemiBold", "NotoSerifSC-Bold"]
        default: candidates = ["NotoSerifSC-Regular"]
        }
        return candidates.first { isAvailable($0) }
    }
}

extension Date {
    /// "9月4日" regardless of the device region.
    var monthDay: String {
        let parts = Calendar.current.dateComponents([.month, .day], from: self)
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    /// "9月4日 20:14" regardless of the device region.
    var monthDayTime: String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: self)
        return monthDay + String(format: " %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "Sep 22, 15:46" — the italic masthead stamp.
    var stamp: String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: self)
        let day = formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US")))
        return day + String(format: ", %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "2026.09.28", the way dates are printed on packaging.
    var packageStyle: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return String(format: "%04d.%02d.%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
