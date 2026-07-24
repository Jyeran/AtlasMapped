import SwiftUI

struct LayerPanel: View {
    @EnvironmentObject private var state: AppState
    private let usgsURL = URL(string: "https://www.usgs.gov/programs/national-geospatial-program/national-map")!
    private let openStreetMapURL = URL(string: "https://www.openstreetmap.org/copyright")!
    private let forestServiceURL = URL(string: "https://data.fs.usda.gov/geodata/edw/datasets.php")!

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Button { state.showLayers = false } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(AtlasPressButtonStyle())
                .accessibilityLabel("Close layers")
            }
            .padding(.bottom, 4)

            layerRow("USGS Topographic", symbol: "mountain.2", selected: true)

            Text("The same USGS topo map is used online and in downloaded areas.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.top, 2)

            Divider().padding(.vertical, 3)

            Button { state.showTrails.toggle() } label: {
                layerRow("Detailed trails", symbol: "figure.hiking", selected: state.showTrails)
            }
            .buttonStyle(AtlasPressButtonStyle())

            Text("OSM paths + official Forest Service trails, with names and trailheads.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.top, 2)

            Divider().padding(.vertical, 3)

            Menu {
                Link("USGS Topographic Map", destination: usgsURL)
                Link("OpenStreetMap attribution", destination: openStreetMapURL)
                Link("USDA Forest Service data", destination: forestServiceURL)
            } label: {
                Label("Map data & credits", systemImage: "info.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
        }
        .padding(14)
        .frame(width: 248)
        .atlasPanel()
    }

    private func layerRow(_ title: String, symbol: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(selected ? AtlasTheme.forest : .secondary)
                .frame(width: 26)
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            if selected { Image(systemName: "checkmark").font(.caption.bold()) }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(selected ? AtlasTheme.moss.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}
