import CoreGraphics

/// Built-in color palettes for pose rendering.
public enum ColorPalette {

    // MARK: - Alphabet palette (26 colors)

    /// The "alphabet" palette: 26 visually distinct colors matching Python SLEAP.
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

    // MARK: - Catscale palette (10 colors)

    /// The "catscale" palette: 10 categorical colors.
    public static let catscale: [CGColor] = [
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

    // MARK: - Lookup

    /// Returns the palette array for a given name. Falls back to `alphabet` for unknown names.
    public static func palette(named name: String) -> [CGColor] {
        switch name {
        case "alphabet": return alphabet
        case "catscale": return catscale
        default: return alphabet
        }
    }

    /// Returns a color from the named palette, wrapping around for indices beyond the palette length.
    public static func color(at index: Int, palette name: String = "alphabet") -> CGColor {
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
