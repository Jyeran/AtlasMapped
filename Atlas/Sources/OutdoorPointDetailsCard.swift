import CoreLocation
import SwiftUI

struct OutdoorPointDetailsCard: View {
    @EnvironmentObject private var state: AppState
    @State private var sampledElevationMeters: Double?
    @State private var isSamplingElevation = false

    var body: some View {
        if let point = state.selectedOutdoorPoint {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 11) {
                    Image(systemName: point.kind.symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(iconColor(for: point.kind))
                        .frame(width: 40, height: 40)
                        .background(iconColor(for: point.kind).opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(point.name)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(AtlasTheme.forest)
                            .lineLimit(2)
                        Text(point.kind.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button { state.dismissOutdoorPoint() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(AtlasTheme.moss.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(AtlasPressButtonStyle())
                    .foregroundStyle(AtlasTheme.forest)
                    .accessibilityLabel("Close place details")
                }

                HStack(spacing: 0) {
                    metric(
                        title: "Elevation",
                        value: displayedElevation.map(elevationLabel)
                            ?? (isSamplingElevation ? "Sampling…" : "—"),
                        symbol: "mountain.2.fill"
                    )
                    Divider().frame(height: 42)
                    metric(
                        title: "Latitude",
                        value: coordinate(point).latitude.formatted(.number.precision(.fractionLength(4))),
                        symbol: "arrow.up"
                    )
                    Divider().frame(height: 42)
                    metric(
                        title: "Longitude",
                        value: coordinate(point).longitude.formatted(.number.precision(.fractionLength(4))),
                        symbol: "arrow.right"
                    )
                }
                .padding(.vertical, 11)
                .background(AtlasTheme.moss.opacity(0.075), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                if let description = point.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !point.facts.isEmpty {
                    VStack(spacing: 9) {
                        ForEach(Array(point.facts.prefix(6).enumerated()), id: \.offset) { _, fact in
                            HStack(alignment: .firstTextBaseline) {
                                Text(fact.label)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 16)
                                Text(fact.value)
                                    .fontWeight(.semibold)
                                    .multilineTextAlignment(.trailing)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(12)
                    .background(AtlasTheme.moss.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }

                HStack(spacing: 10) {
                    Label(elevationSource(point), systemImage: "info.circle")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let website = point.website, let url = URL(string: website) {
                        Link(destination: url) {
                            Label("Website", systemImage: "safari")
                                .font(.caption.weight(.bold))
                        }
                    }
                }
            }
            .padding(16)
            .frame(minWidth: 300, idealWidth: 390, maxWidth: 430)
            .atlasPanel()
            .accessibilityElement(children: .contain)
            .task(id: point.id) {
                sampledElevationMeters = nil
                guard point.elevationMeters == nil else { return }
                isSamplingElevation = true
                defer { isSamplingElevation = false }
                sampledElevationMeters = try? await ElevationService().elevation(at: coordinate(point))
            }
        }
    }

    private var displayedElevation: Double? {
        state.selectedOutdoorPoint?.elevationMeters ?? sampledElevationMeters
    }

    private func metric(title: String, value: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Label(title.uppercased(), systemImage: symbol)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.35)
                .foregroundStyle(AtlasTheme.moss)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(AtlasTheme.forest)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
    }

    private func elevationLabel(_ meters: Double) -> String {
        state.unitSystem.elevation(meters)
    }

    private func coordinate(_ point: OutdoorPointFeature) -> CLLocationCoordinate2D {
        point.coordinate.coordinate
    }

    private func elevationSource(_ point: OutdoorPointFeature) -> String {
        point.elevationMeters == nil && sampledElevationMeters != nil
            ? "OpenStreetMap details · USGS 3DEP elevation"
            : "OpenStreetMap details"
    }

    private func iconColor(for kind: OutdoorPointKind) -> Color {
        switch kind {
        case .trailhead: AtlasTheme.forest
        case .peak, .saddle: Color(red: 0.35, green: 0.29, blue: 0.20)
        case .viewpoint: Color(red: 0.20, green: 0.39, blue: 0.43)
        case .shelter, .campsite: Color(red: 0.44, green: 0.34, blue: 0.20)
        case .water, .spring: AtlasTheme.trailBlue
        }
    }
}
