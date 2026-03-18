import CoreGraphics

/// Built-in color palettes for pose rendering.
///
/// Palettes match the Python sleap-io rendering module for consistency.
public enum ColorPalette {

    // MARK: - Standard palette (MATLAB default, 7 colors)

    /// The "standard" palette: MATLAB default colors. Default in Python SLEAP.
    public static let standard: [CGColor] = [
        cgColor(0x00, 0x72, 0xBD),  // Blue
        cgColor(0xD9, 0x53, 0x19),  // Orange
        cgColor(0xED, 0xB1, 0x20),  // Yellow/Gold
        cgColor(0x7E, 0x2F, 0x8E),  // Purple
        cgColor(0x77, 0xAC, 0x30),  // Green
        cgColor(0x4D, 0xBE, 0xEE),  // Light blue
        cgColor(0xA2, 0x14, 0x2F),  // Dark red
    ]

    // MARK: - Alphabet palette (26 colors)

    /// The "alphabet" palette: 26 visually distinct colors.
    public static let alphabet: [CGColor] = [
        cgColor(0xF0, 0xA3, 0xFF),
        cgColor(0x00, 0x75, 0xDC),
        cgColor(0x99, 0x3F, 0x00),
        cgColor(0x4C, 0x00, 0x5C),
        cgColor(0x19, 0x19, 0x19),
        cgColor(0x00, 0x5C, 0x31),
        cgColor(0x2B, 0xCE, 0x48),
        cgColor(0xFF, 0xCC, 0x99),
        cgColor(0x80, 0x80, 0x80),
        cgColor(0x94, 0xFF, 0xB5),
        cgColor(0x8F, 0x7C, 0x00),
        cgColor(0x9D, 0xCC, 0x00),
        cgColor(0xC2, 0x00, 0x88),
        cgColor(0x00, 0x33, 0x80),
        cgColor(0xFF, 0xA4, 0x05),
        cgColor(0xFF, 0xA8, 0xBB),
        cgColor(0x42, 0x66, 0x00),
        cgColor(0xFF, 0x00, 0x10),
        cgColor(0x5E, 0xF1, 0xF2),
        cgColor(0x00, 0x99, 0x8F),
        cgColor(0xE0, 0xFF, 0x66),
        cgColor(0x74, 0x0A, 0xFF),
        cgColor(0x99, 0x00, 0x00),
        cgColor(0xFF, 0xFF, 0x80),
        cgColor(0xFF, 0xE1, 0x00),
        cgColor(0xFF, 0x50, 0x05),
    ]

    // MARK: - Tableau 10 palette

    /// The "tableau10" palette: Tableau's categorical colors.
    public static let tableau10: [CGColor] = [
        cgColor(0x1F, 0x77, 0xB4),
        cgColor(0xFF, 0x7F, 0x0E),
        cgColor(0x2C, 0xA0, 0x2C),
        cgColor(0xD6, 0x27, 0x28),
        cgColor(0x94, 0x67, 0xBD),
        cgColor(0x8C, 0x56, 0x4B),
        cgColor(0xE3, 0x77, 0xC2),
        cgColor(0x7F, 0x7F, 0x7F),
        cgColor(0xBC, 0xBD, 0x22),
        cgColor(0x17, 0xBE, 0xCF),
    ]

    // MARK: - Distinct palette (10 high-contrast colors)

    public static let distinct: [CGColor] = [
        cgColor(0xFF, 0x64, 0x64),
        cgColor(0x64, 0x64, 0xFF),
        cgColor(0x64, 0xFF, 0x64),
        cgColor(0xFF, 0xFF, 0x64),
        cgColor(0xFF, 0x64, 0xFF),
        cgColor(0x64, 0xFF, 0xFF),
        cgColor(0xFF, 0xB4, 0x64),
        cgColor(0xB4, 0x64, 0xFF),
        cgColor(0xFF, 0x96, 0x96),
        cgColor(0x96, 0xFF, 0xC8),
    ]

    // MARK: - Rainbow palette (12 colors)

    public static let rainbow: [CGColor] = [
        cgColor(0xFF, 0x00, 0x00),
        cgColor(0xFF, 0x7F, 0x00),
        cgColor(0xFF, 0xFF, 0x00),
        cgColor(0x7F, 0xFF, 0x00),
        cgColor(0x00, 0xFF, 0x00),
        cgColor(0x00, 0xFF, 0x7F),
        cgColor(0x00, 0xFF, 0xFF),
        cgColor(0x00, 0x7F, 0xFF),
        cgColor(0x00, 0x00, 0xFF),
        cgColor(0x7F, 0x00, 0xFF),
        cgColor(0xFF, 0x00, 0xFF),
        cgColor(0xFF, 0x00, 0x7F),
    ]

    // MARK: - Seaborn palette (10 colors)

    public static let seaborn: [CGColor] = [
        cgColor(0x4C, 0x72, 0xB0),
        cgColor(0xDD, 0x84, 0x52),
        cgColor(0x55, 0xA8, 0x68),
        cgColor(0xC4, 0x4E, 0x52),
        cgColor(0x81, 0x72, 0xB3),
        cgColor(0x93, 0x78, 0x60),
        cgColor(0xDA, 0x8B, 0xC3),
        cgColor(0x8C, 0x8C, 0x8C),
        cgColor(0xCC, 0xB9, 0x74),
        cgColor(0x64, 0xB5, 0xCD),
    ]

    // MARK: - Lookup

    /// All available palette names, in display order.
    public static let allNames: [String] = [
        "standard", "alphabet", "tableau10", "distinct",
        "rainbow", "seaborn",
    ]

    /// Returns the palette array for a given name. Falls back to `standard` for unknown names.
    public static func palette(named name: String) -> [CGColor] {
        switch name {
        case "standard": return standard
        case "alphabet": return alphabet
        case "tableau10", "catscale": return tableau10
        case "distinct": return distinct
        case "rainbow": return rainbow
        case "seaborn": return seaborn
        default: return standard
        }
    }

    /// Returns a color from the named palette, wrapping around for indices beyond the palette length.
    public static func color(at index: Int, palette name: String = "standard") -> CGColor {
        let pal = palette(named: name)
        return pal[index % pal.count]
    }

    // MARK: - Helpers

    private static func cgColor(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGColor {
        CGColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
    }
}
