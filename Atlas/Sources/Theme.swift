import SwiftUI

enum AtlasTheme {
    static let orange = Color(red: 0.95, green: 0.31, blue: 0.04)
    static let trailBlue = Color(red: 0.08, green: 0.48, blue: 0.96)
    static let forest = Color(red: 0.12, green: 0.22, blue: 0.16)
    static let moss = Color(red: 0.36, green: 0.44, blue: 0.34)
    static let paper = Color(red: 0.97, green: 0.97, blue: 0.94)
    static let panelRadius: CGFloat = 18
}

enum AtlasUnitSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case metric
    case imperial

    var id: String { rawValue }
    var title: String { self == .metric ? "Metric" : "Imperial" }

    func distance(_ meters: Double) -> String {
        let value = self == .metric ? meters / 1_000 : meters / 1_609.344
        let unit = self == .metric ? "km" : "mi"
        let digits = abs(value) < 10 ? 2 : (abs(value) < 100 ? 1 : 0)
        return "\(value.formatted(.number.precision(.fractionLength(0...digits)))) \(unit)"
    }

    func elevation(_ meters: Double) -> String {
        if self == .metric {
            return "\(meters.formatted(.number.precision(.fractionLength(1)))) m"
        }
        return "\((meters * 3.28084).formatted(.number.precision(.fractionLength(0)))) ft"
    }

    func signedElevation(_ meters: Double) -> String {
        let prefix = meters > 0 ? "+" : ""
        return prefix + elevation(meters)
    }

    func pace(secondsPerMile: Double?) -> String {
        guard let secondsPerMile, secondsPerMile.isFinite, secondsPerMile > 0 else { return "—" }
        let seconds = self == .metric ? secondsPerMile / 1.609344 : secondsPerMile
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remaining = total % 60
        return "\(String(format: "%d:%02d", minutes, remaining)) /\(self == .metric ? "km" : "mi")"
    }
}

enum AtlasMotion {
    static let quick = Animation.smooth(duration: 0.16)
    static let standard = Animation.smooth(duration: 0.24)
    static let panel = Animation.spring(response: 0.34, dampingFraction: 0.86)
}

struct AtlasPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(AtlasMotion.quick, value: configuration.isPressed)
    }
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

extension RoutePinColor {
    var color: Color {
        switch self {
        case .blue: AtlasTheme.trailBlue
        case .orange: AtlasTheme.orange
        case .forest: AtlasTheme.forest
        case .red: .red
        case .purple: .purple
        case .brown: .brown
        }
    }

    var title: String { rawValue.capitalized }
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
