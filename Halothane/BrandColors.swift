import SwiftUI

/// Halothane brand palette (see branding/halothane-brand.png). The teal is also
/// the asset-catalog AccentColor, so default controls pick it up automatically;
/// these named colors are for explicit brand chrome (wordmark, logo glyph).
/// Semantic state colors (orange = warn, red = paused) are intentionally NOT
/// part of the brand palette — they must stay legible and conventional.
extension Color {
    /// Primary accent — teal/aqua. #45C5D6
    static let halothaneTeal = Color(red: 0.271, green: 0.773, blue: 0.839)
    /// Soft mint, for subtle fills/backgrounds. #BFE9EC
    static let halothaneMint = Color(red: 0.749, green: 0.914, blue: 0.925)
    /// Deep charcoal — the monogram ink. #2A2E32
    static let halothaneInk = Color(red: 0.165, green: 0.180, blue: 0.196)
    /// Silver grey — secondary text/strokes. #8A9296
    static let halothaneSlate = Color(red: 0.541, green: 0.573, blue: 0.588)
}
