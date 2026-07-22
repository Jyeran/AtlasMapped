import SwiftUI

enum AtlasTheme {
    static let orange = Color(red: 0.95, green: 0.31, blue: 0.04)
    static let trailBlue = Color(red: 0.08, green: 0.48, blue: 0.96)
    static let forest = Color(red: 0.12, green: 0.22, blue: 0.16)
    static let moss = Color(red: 0.36, green: 0.44, blue: 0.34)
    static let paper = Color(red: 0.97, green: 0.97, blue: 0.94)
    static let panelRadius: CGFloat = 18
}

extension RouteWaypointKind {
    var color: Color {
        switch self {
        case .standard: AtlasTheme.orange
        case .pin, .water, .spring: AtlasTheme.trailBlue
        case .trailhead: AtlasTheme.forest
        case .peak, .saddle: Color(red: 0.35, green: 0.29, blue: 0.20)
        case .viewpoint: Color(red: 0.20, green: 0.39, blue: 0.43)
        case .shelter, .campsite: Color(red: 0.44, green: 0.34, blue: 0.20)
        }
    }
}

struct AtlasPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AtlasTheme.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AtlasTheme.panelRadius, style: .continuous)
                    .stroke(.white.opacity(0.48), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.12), radius: 16, y: 7)
    }
}

extension View {
    func atlasPanel() -> some View { modifier(AtlasPanelModifier()) }
}
