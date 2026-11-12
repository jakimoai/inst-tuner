import SwiftUI

/// Colours from a sunburst guitar finish, from the dark edge in to the honey centre.
enum Palette {
    static let ebony = Color(red: 0.071, green: 0.043, blue: 0.039)
    static let rosewood = Color(red: 0.165, green: 0.090, blue: 0.071)
    static let cherry = Color(red: 0.557, green: 0.165, blue: 0.094)
    static let amber = Color(red: 0.898, green: 0.565, blue: 0.169)
    static let honey = Color(red: 0.969, green: 0.784, blue: 0.408)
    static let pearl = Color(red: 0.953, green: 0.925, blue: 0.875)
    static let nickel = Color(red: 0.612, green: 0.604, blue: 0.580)
    static let bronze = Color(red: 0.725, green: 0.541, blue: 0.290)
}

enum Typeface {
    /// The note name: a heavy Clarendon, the kind of slab found on old amp badges.
    static func glyph(_ size: CGFloat) -> Font {
        .custom("Superclarendon-Black", fixedSize: size)
    }

    /// Numbers and labels. Grows and shrinks with the iPhone's text size setting.
    static func data(_ size: CGFloat) -> Font {
        .custom("DINAlternate-Bold", size: size, relativeTo: .body)
    }

    /// For text whose size is set by the drawing around it, like scale labels.
    static func fixedData(_ size: CGFloat) -> Font {
        .custom("DINAlternate-Bold", fixedSize: size)
    }
}

enum Format {
    /// Signed cents with a true minus sign, dropping the decimal once it stops being useful.
    static func cents(_ value: Double) -> String {
        let magnitude = abs(value)
        let digits = magnitude < 99.95 ? String(format: "%.1f", magnitude) : String(format: "%.0f", magnitude)
        if digits == "0.0" { return "0.0" }
        return (value < 0 ? "−" : "+") + digits
    }

    static func hertz(_ value: Double) -> String {
        String(format: "%.2f Hz", value)
    }
}
