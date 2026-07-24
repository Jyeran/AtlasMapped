import MapKit
import SwiftUI

struct OfflineMapsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var areaPendingDeletion: OfflineMapArea?
    @State private var selectedArea: OfflineMapArea?

    var body: some View {
        ZStack {
            AtlasTheme.paper.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 18) {
                    header
                    selectAreaCard
                    savedAreasSection
                    sourceNote
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .modifier(OfflineMapsSizing())
        .sheet(item: $selectedArea) { area in
            OfflineAreaDetailView(areaID: area.id)
                .environmentObject(state)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Delete downloaded map?", isPresented: deletionAlertIsPresented, presenting: areaPendingDeletion) { area in
            Button("Delete \(area.name)", role: .destructive) {
                withAnimation(AtlasMotion.standard) { state.offline.delete(area) }
                areaPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { areaPendingDeletion = nil }
        } message: { area in
            Text("Atlas will remove the locally stored tiles for “\(area.name)” and free the space they use.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AtlasTheme.orange)
                .frame(width: 46, height: 46)
                .background(AtlasTheme.orange.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Offline maps")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(AtlasTheme.forest)
                Text("Carry only the terrain you need.")
                    .font(.subheadline)
                    .foregroundStyle(AtlasTheme.moss)
            }

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(AtlasTheme.forest.opacity(0.08), in: Circle())
            }
            .buttonStyle(AtlasPressButtonStyle())
            .foregroundStyle(AtlasTheme.forest)
            .accessibilityLabel("Close offline maps")
        }
    }

    private var selectAreaCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "lasso")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AtlasTheme.orange)
                    .frame(width: 44, height: 44)
                    .background(AtlasTheme.orange.opacity(0.11), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose an area on the map")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(AtlasTheme.forest)
                    Text("Draw a freeform boundary. Atlas downloads only the tiles that touch your selection.")
                        .font(.subheadline)
                        .foregroundStyle(AtlasTheme.moss)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                dismiss()
                state.beginOfflineSelection()
            } label: {
                Label("Select area", systemImage: "hand.draw.fill")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(OfflineMapsPrimaryButtonStyle())
        }
        .padding(18)
        .atlasPanel()
    }

    private var savedAreasSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("SAVED ON THIS DEVICE", systemImage: "internaldrive.fill")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(AtlasTheme.moss)
                Spacer()
                Text(storageSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AtlasTheme.moss)
            }

            if state.offline.areas.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "map")
                        .font(.system(size: 28))
                        .foregroundStyle(AtlasTheme.moss)
                    Text("Nothing downloaded yet")
                        .font(.headline)
                        .foregroundStyle(AtlasTheme.forest)
                    Text("Your selected areas will appear here with their storage use.")
                        .font(.caption)
                        .foregroundStyle(AtlasTheme.moss)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ForEach(state.offline.areas) { area in
                    areaCard(area)
                }
            }
        }
    }

    private func areaCard(_ area: OfflineMapArea) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 13) {
                Button { selectedArea = area } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AtlasTheme.forest)
                            .frame(width: 42, height: 42)
                            .background(AtlasTheme.moss.opacity(0.13), in: Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            Text(area.name)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(AtlasTheme.forest)
                            Text("\(area.tiles.count.formatted()) tiles · \(areaSize(area))")
                                .font(.caption)
                                .foregroundStyle(AtlasTheme.moss)
                            if area.trailDataVersion == nil {
                                Text("Detailed trails update available")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AtlasTheme.orange)
                            }
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AtlasTheme.moss.opacity(0.7))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(AtlasPressButtonStyle())
                .accessibilityLabel("View \(area.name) coverage")

                Spacer(minLength: 8)

                if let value = state.offline.progress[area.id], value < 1 {
                    Button("Cancel") { state.offline.cancel(area) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(AtlasPressButtonStyle())
                        .foregroundStyle(AtlasTheme.orange)
                } else if state.offline.isComplete(area) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AtlasTheme.forest)
                        .accessibilityLabel("Downloaded")
                } else {
                    Button { state.offline.resume(area) } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 36, height: 36)
                            .background(AtlasTheme.moss.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(AtlasPressButtonStyle())
                    .foregroundStyle(AtlasTheme.forest)
                    .accessibilityLabel("Resume \(area.name)")
                }

                Button(role: .destructive) { areaPendingDeletion = area } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(AtlasTheme.orange.opacity(0.10), in: Circle())
                }
                .buttonStyle(AtlasPressButtonStyle())
                .foregroundStyle(AtlasTheme.orange)
                .accessibilityLabel("Delete \(area.name)")
            }

            if let value = state.offline.progress[area.id], value < 1 {
                ProgressView(value: value)
                    .tint(AtlasTheme.orange)
                Text("Downloading · \(value.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.caption2)
                    .foregroundStyle(AtlasTheme.moss)
            }

            if let error = state.offline.errors[area.id] {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(AtlasTheme.orange)
            }
        }
        .padding(14)
        .background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AtlasTheme.moss.opacity(0.12), lineWidth: 1)
        }
    }

    private var sourceNote: some View {
        Label {
            Text("Offline packages include USGS topography plus selectable OpenStreetMap and USDA Forest Service trails, names, trailheads, and outdoor points.")
        } icon: {
            Image(systemName: "info.circle.fill")
        }
        .font(.caption)
        .foregroundStyle(AtlasTheme.moss)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AtlasTheme.moss.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { areaPendingDeletion != nil },
            set: { if !$0 { areaPendingDeletion = nil } }
        )
    }

    private var storageSummary: String {
        let count = state.offline.areas.count
        let size = ByteCountFormatter.string(fromByteCount: state.offline.totalBytes, countStyle: .file)
        return "\(count) · \(size)"
    }

    private func areaSize(_ area: OfflineMapArea) -> String {
        guard area.byteCount > 0 else { return "pending" }
        return ByteCountFormatter.string(fromByteCount: area.byteCount, countStyle: .file)
    }
}

private struct OfflineMapsSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(minWidth: 560, idealWidth: 640, minHeight: 620, idealHeight: 760)
        #else
        content
        #endif
    }
}

private struct OfflineMapsPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(AtlasTheme.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct OfflineAreaDetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let areaID: UUID

    @State private var name = ""
    @FocusState private var isEditingName: Bool

    private var area: OfflineMapArea? {
        state.offline.areas.first { $0.id == areaID }
    }

    var body: some View {
        ZStack {
            AtlasTheme.paper.ignoresSafeArea()

            if let area {
                ScrollView {
                    VStack(spacing: 18) {
                        header(area)
                        coverageMap(area)
                        nameCard(area)
                        metadataCard(area)
                    }
                    .padding(22)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Offline area unavailable",
                    systemImage: "map",
                    description: Text("This downloaded area is no longer stored on this device.")
                )
            }
        }
        .modifier(OfflineAreaDetailSizing())
        .onAppear { name = area?.name ?? "" }
    }

    private func header(_ area: OfflineMapArea) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "map.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AtlasTheme.orange)
                .frame(width: 46, height: 46)
                .background(AtlasTheme.orange.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(area.name)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(AtlasTheme.forest)
                Text("Offline coverage")
                    .font(.subheadline)
                    .foregroundStyle(AtlasTheme.moss)
            }

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(AtlasTheme.forest.opacity(0.08), in: Circle())
            }
            .buttonStyle(AtlasPressButtonStyle())
            .foregroundStyle(AtlasTheme.forest)
            .accessibilityLabel("Close offline area")
        }
    }

    private func coverageMap(_ area: OfflineMapArea) -> some View {
        ZStack(alignment: .bottomLeading) {
            OfflineAreaCoverageMap(area: area)

            Label("Downloaded boundary", systemImage: "lasso")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AtlasTheme.forest)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(12)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AtlasTheme.moss.opacity(0.15), lineWidth: 1)
        }
        .accessibilityLabel("Interactive map showing the downloaded boundary for \(area.name)")
    }

    private func nameCard(_ area: OfflineMapArea) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("AREA NAME", systemImage: "pencil")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(AtlasTheme.moss)

            HStack(spacing: 10) {
                TextField("Offline area name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(AtlasTheme.forest)
                    .focused($isEditingName)
                    .submitLabel(.done)
                    .onSubmit { saveName(area) }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 13))

                Button { saveName(area) } label: {
                    Text("Save")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(minWidth: 66, minHeight: 48)
                }
                .buttonStyle(OfflineMapsPrimaryButtonStyle())
                .disabled(trimmedName.isEmpty || trimmedName == area.name)
                .opacity(trimmedName.isEmpty || trimmedName == area.name ? 0.45 : 1)
            }
        }
        .padding(16)
        .atlasPanel()
    }

    private func metadataCard(_ area: OfflineMapArea) -> some View {
        HStack(spacing: 0) {
            detailMetric(
                value: area.tiles.count.formatted(),
                label: "Tiles",
                systemImage: "square.grid.3x3.fill"
            )
            Divider().frame(height: 46)
            detailMetric(
                value: area.byteCount > 0
                    ? ByteCountFormatter.string(fromByteCount: area.byteCount, countStyle: .file)
                    : "Pending",
                label: "Storage",
                systemImage: "internaldrive.fill"
            )
            Divider().frame(height: 46)
            detailMetric(
                value: area.createdAt.formatted(date: .abbreviated, time: .omitted),
                label: "Created",
                systemImage: "calendar"
            )
        }
        .padding(.vertical, 16)
        .atlasPanel()
    }

    private func detailMetric(value: String, label: String, systemImage: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AtlasTheme.orange)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(AtlasTheme.forest)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AtlasTheme.moss)
        }
        .frame(maxWidth: .infinity)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveName(_ area: OfflineMapArea) {
        guard state.offline.rename(area, to: name) else { return }
        name = trimmedName
        isEditingName = false
    }
}

private struct OfflineAreaDetailSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(minWidth: 600, idealWidth: 680, minHeight: 650, idealHeight: 760)
        #else
        content
        #endif
    }
}

@MainActor
private struct OfflineAreaCoverageMap {
    let area: OfflineMapArea

    func makeMap(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsScale = true
        map.showsUserLocation = false
        map.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)

        let topo = CachedTileOverlay(
            kind: .topographic,
            urlTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
            allowsNetwork: false,
            storesNetworkTiles: false,
            sourceMaximumZoom: 16
        )
        topo.canReplaceMapContent = false
        topo.minimumZ = 0
        topo.maximumZ = 19
        map.addOverlay(topo, level: .aboveRoads)
        installBoundary(on: map)
        focus(on: map)
        return map
    }

    func updateMap(_ map: MKMapView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func installBoundary(on map: MKMapView) {
        let coordinates = area.coordinates
        guard coordinates.count >= 3 else { return }
        map.addOverlay(MKPolygon(coordinates: coordinates, count: coordinates.count), level: .aboveLabels)
    }

    private func focus(on map: MKMapView) {
        let coordinates = area.coordinates
        guard let first = coordinates.first else { return }
        let south = coordinates.reduce(first.latitude) { min($0, $1.latitude) }
        let north = coordinates.reduce(first.latitude) { max($0, $1.latitude) }
        let west = coordinates.reduce(first.longitude) { min($0, $1.longitude) }
        let east = coordinates.reduce(first.longitude) { max($0, $1.longitude) }
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (south + north) / 2,
                    longitude: (west + east) / 2
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: max(0.005, (north - south) * 1.35),
                    longitudeDelta: max(0.005, (east - west) * 1.35)
                )
            ),
            animated: false
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = PlatformColor(red: 0.95, green: 0.31, blue: 0.04, alpha: 0.16)
                renderer.strokeColor = PlatformColor(red: 0.95, green: 0.31, blue: 0.04, alpha: 0.95)
                renderer.lineWidth = 3
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

#if os(iOS)
extension OfflineAreaCoverageMap: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ uiView: MKMapView, context: Context) { updateMap(uiView, context: context) }
}
#else
extension OfflineAreaCoverageMap: NSViewRepresentable {
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ nsView: MKMapView, context: Context) { updateMap(nsView, context: context) }
}
#endif
