import MapKit
import SwiftUI

struct HikeHistoryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if state.hikes.hikes.isEmpty {
                    ContentUnavailableView(
                        "No recorded hikes",
                        systemImage: "figure.hiking",
                        description: Text("Start a planned route or record freely. Finished hikes will appear here.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(state.hikes.hikes) { hike in
                                NavigationLink {
                                    HikeSummaryView(hike: hike, allowsDeletion: true)
                                        .environmentObject(state)
                                } label: {
                                    hikeRow(hike)
                                }
                                .buttonStyle(AtlasPressButtonStyle())
                                .contextMenu {
                                    Button("Delete hike", systemImage: "trash", role: .destructive) {
                                        state.hikes.delete(id: hike.id)
                                    }
                                }
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .background(AtlasTheme.paper.ignoresSafeArea())
            .navigationTitle("Hike history")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func hikeRow(_ hike: RecordedHike) -> some View {
        HStack(spacing: 14) {
            Image(systemName: hike.mode == .plannedRoute ? "map.fill" : "record.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AtlasTheme.orange)
                .frame(width: 48, height: 48)
                .background(AtlasTheme.orange.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(hike.name)
                    .font(.headline)
                    .foregroundStyle(AtlasTheme.forest)
                Text(hike.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label(state.unitSystem.distance(hike.distanceMeters), systemImage: "figure.walk")
                    Label(HikeFormatting.duration(hike.activeDuration), systemImage: "timer")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AtlasTheme.moss)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct HikeSummaryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let hike: RecordedHike
    var allowsDeletion = false
    @State private var showsDeleteConfirmation = false

    private var pace: Double? {
        guard hike.distanceMeters >= 20 else { return nil }
        return hike.activeDuration / (hike.distanceMeters / 1_609.344)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                trackMap
                stats
                splitSection("START / STOP LEGS", splits: hike.splits.filter { $0.kind == .activeLeg })
                splitSection("WAYPOINT SPLITS", splits: hike.splits.filter { $0.kind == .waypoint })
                splitSection("MANUAL SPLITS", splits: hike.splits.filter { $0.kind == .manual })
                if allowsDeletion { deleteButton }
            }
            .padding(20)
        }
        .background(AtlasTheme.paper.ignoresSafeArea())
        .navigationTitle("Hike summary")
        .confirmationDialog(
            "Delete this hike?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete hike", role: .destructive) {
                state.hikes.delete(id: hike.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recorded path, statistics, and splits will be permanently removed.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.hiking")
                .font(.title2)
                .foregroundStyle(AtlasTheme.orange)
                .frame(width: 56, height: 56)
                .background(AtlasTheme.orange.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(hike.name)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(AtlasTheme.forest)
                Text(hike.startedAt.formatted(date: .complete, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            summaryMetric("Distance", state.unitSystem.distance(hike.distanceMeters), "figure.walk")
            summaryMetric("Active time", HikeFormatting.duration(hike.activeDuration), "timer")
            summaryMetric("Elapsed", HikeFormatting.duration(hike.elapsedDuration), "clock")
            summaryMetric("Pace", state.unitSystem.pace(secondsPerMile: pace), "speedometer")
            summaryMetric("Elevation gain", state.unitSystem.elevation(hike.elevationGainMeters), "mountain.2.fill")
            summaryMetric("GPS points", "\(hike.samples.count)", "point.3.connected.trianglepath.dotted")
        }
    }

    @ViewBuilder
    private var trackMap: some View {
        if hike.samples.isEmpty {
            Label("No GPS path was captured for this hike", systemImage: "location.slash")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 110)
                .background(AtlasTheme.moss.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        } else {
            VStack(alignment: .leading, spacing: 9) {
                HikeTrackMap(hike: hike, allowsNetwork: state.connectivity.isOnline)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AtlasTheme.moss.opacity(0.13), lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    Text("FASTER")
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.48, blue: 0.84),
                            Color(red: 0.16, green: 0.58, blue: 0.38),
                            Color(red: 0.95, green: 0.58, blue: 0.14),
                            AtlasTheme.orange
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 5)
                    .clipShape(Capsule())
                    Text("SLOWER")
                }
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recorded GPS path colored from faster blue to slower orange")
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showsDeleteConfirmation = true
        } label: {
            Label("Delete hike", systemImage: "trash")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(AtlasPressButtonStyle())
        .foregroundStyle(.red)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func summaryMetric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(AtlasTheme.forest)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AtlasTheme.moss.opacity(0.09), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    @ViewBuilder
    private func splitSection(_ title: String, splits: [HikeSplit]) -> some View {
        if !splits.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(AtlasTheme.moss)
                ForEach(splits) { split in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(split.name).font(.subheadline.weight(.semibold))
                            Text(split.endedAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(state.unitSystem.distance(split.distanceMeters))
                        Text(HikeFormatting.duration(split.duration))
                    }
                    .font(.subheadline.monospacedDigit())
                    .padding(.vertical, 7)
                }
            }
            .padding(16)
            .background(.white.opacity(0.64), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

struct HikeCompletionReviewView: View {
    @EnvironmentObject private var state: AppState
    let hike: RecordedHike
    @State private var showsDiscardConfirmation = false

    var body: some View {
        NavigationStack {
            HikeSummaryView(hike: hike)
                .environmentObject(state)
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 12) {
                        Button(role: .destructive) {
                            showsDiscardConfirmation = true
                        } label: {
                            Label("Discard", systemImage: "trash")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }
                        .buttonStyle(AtlasPressButtonStyle())
                        .foregroundStyle(.red)
                        .background(.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                        Button(action: state.saveCompletedHike) {
                            Label("Save hike", systemImage: "checkmark")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }
                        .buttonStyle(AtlasPressButtonStyle())
                        .foregroundStyle(.white)
                        .background(AtlasTheme.forest, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                }
        }
        .confirmationDialog(
            "Discard this hike?",
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard hike", role: .destructive, action: state.discardCompletedHike)
            Button("Keep reviewing", role: .cancel) {}
        } message: {
            Text("The recorded path and all collected hike data will be removed.")
        }
    }
}

struct HikePaceTrackSegment {
    let coordinates: [CLLocationCoordinate2D]
    let secondsPerMile: Double?
}

enum HikePaceTrackBuilder {
    static func segments(from samples: [HikeTrackSample], targetSegmentCount: Int = 280) -> [HikePaceTrackSegment] {
        guard samples.count > 1 else { return [] }
        var runs: [[HikeTrackSample]] = []
        var currentRun: [HikeTrackSample] = []

        for sample in samples {
            if sample.beginsSegment, !currentRun.isEmpty {
                if currentRun.count > 1 { runs.append(currentRun) }
                currentRun = []
            }
            currentRun.append(sample)
        }
        if currentRun.count > 1 { runs.append(currentRun) }

        let usablePairs = runs.reduce(0) { $0 + max(0, $1.count - 1) }
        let chunkSize = max(1, Int(ceil(Double(usablePairs) / Double(max(1, targetSegmentCount)))))
        var result: [HikePaceTrackSegment] = []

        for run in runs {
            var start = 0
            while start < run.count - 1 {
                let end = min(run.count - 1, start + chunkSize)
                let chunk = Array(run[start...end])
                let distance = HikeMetrics.distance(in: chunk)
                let duration = chunk.last!.timestamp.timeIntervalSince(chunk.first!.timestamp)
                let pace: Double? = distance >= 1 && duration > 0
                    ? duration / (distance / 1_609.344)
                    : nil
                result.append(HikePaceTrackSegment(
                    coordinates: chunk.map(\.coordinate.coordinate),
                    secondsPerMile: pace?.isFinite == true ? pace : nil
                ))
                start = end
            }
        }
        return result
    }
}

private final class HikePacePolyline: MKPolyline {
    var normalizedPace: Double?
}

@MainActor
struct HikeTrackMap {
    let hike: RecordedHike
    let allowsNetwork: Bool

    fileprivate func makeMap(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        return map
    }

    fileprivate func updateMap(_ map: MKMapView, context: Context) {
        guard context.coordinator.renderedHikeID != hike.id
                || context.coordinator.renderedNetworkAccess != allowsNetwork else { return }
        context.coordinator.renderedHikeID = hike.id
        context.coordinator.renderedNetworkAccess = allowsNetwork
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })

        let topo = CachedTileOverlay(
            kind: .topographic,
            urlTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
            allowsNetwork: allowsNetwork,
            storesNetworkTiles: false,
            sourceMaximumZoom: 16
        )
        topo.canReplaceMapContent = true
        topo.minimumZ = 0
        topo.maximumZ = 19
        map.addOverlay(topo, level: .aboveRoads)

        let segments = HikePaceTrackBuilder.segments(from: hike.samples)
        let paces = segments.compactMap(\.secondsPerMile).sorted()
        let fastPace = percentile(0.10, in: paces)
        let slowPace = percentile(0.90, in: paces)

        for segment in segments where segment.coordinates.count > 1 {
            let line = HikePacePolyline(
                coordinates: segment.coordinates,
                count: segment.coordinates.count
            )
            if let pace = segment.secondsPerMile,
               let fastPace,
               let slowPace {
                line.normalizedPace = slowPace > fastPace
                    ? min(1, max(0, (pace - fastPace) / (slowPace - fastPace)))
                    : 0.5
            }
            map.addOverlay(line, level: .aboveLabels)
        }

        if let first = hike.samples.first {
            let annotation = MKPointAnnotation()
            annotation.coordinate = first.coordinate.coordinate
            annotation.title = "Start"
            map.addAnnotation(annotation)
        }
        if hike.samples.count > 1, let last = hike.samples.last {
            let annotation = MKPointAnnotation()
            annotation.coordinate = last.coordinate.coordinate
            annotation.title = "Finish"
            map.addAnnotation(annotation)
        }

        focus(map, on: hike.samples.map(\.coordinate.coordinate))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func percentile(_ fraction: Double, in values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let index = min(values.count - 1, max(0, Int((Double(values.count - 1) * fraction).rounded())))
        return values[index]
    }

    private func focus(_ map: MKMapView, on coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else { return }
        var rect = MKMapRect(origin: MKMapPoint(first), size: .init(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(origin: point, size: .init(width: 0, height: 0)))
        }
        let minimumMapSpan = 1_800.0
        if rect.width < minimumMapSpan {
            rect = rect.insetBy(dx: -(minimumMapSpan - rect.width) / 2, dy: 0)
        }
        if rect.height < minimumMapSpan {
            rect = rect.insetBy(dx: 0, dy: -(minimumMapSpan - rect.height) / 2)
        }
        #if os(iOS)
        map.setVisibleMapRect(
            rect,
            edgePadding: UIEdgeInsets(top: 34, left: 28, bottom: 34, right: 28),
            animated: false
        )
        #else
        map.setVisibleMapRect(
            rect,
            edgePadding: NSEdgeInsets(top: 34, left: 28, bottom: 34, right: 28),
            animated: false
        )
        #endif
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var renderedHikeID: UUID?
        var renderedNetworkAccess: Bool?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            guard let paceLine = overlay as? HikePacePolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: paceLine)
            renderer.strokeColor = Self.color(for: paceLine.normalizedPace)
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let reuseIdentifier = "atlas-hike-endpoint"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseIdentifier)
            view.annotation = annotation
            view.markerTintColor = annotation.title == "Start"
                ? PlatformColor(red: 0.10, green: 0.52, blue: 0.32, alpha: 1)
                : PlatformColor(red: 0.95, green: 0.31, blue: 0.04, alpha: 1)
            view.glyphImage = PlatformImage.atlasSymbol(
                named: annotation.title == "Start" ? "figure.hiking" : "flag.checkered"
            )
            view.titleVisibility = .visible
            return view
        }

        private static func color(for normalizedPace: Double?) -> PlatformColor {
            guard let value = normalizedPace else {
                return PlatformColor(red: 0.19, green: 0.36, blue: 0.25, alpha: 0.88)
            }
            let stops: [(Double, (Double, Double, Double))] = [
                (0.00, (0.10, 0.48, 0.84)),
                (0.38, (0.16, 0.58, 0.38)),
                (0.72, (0.95, 0.58, 0.14)),
                (1.00, (0.95, 0.31, 0.04))
            ]
            let upperIndex = stops.firstIndex { $0.0 >= value } ?? stops.index(before: stops.endIndex)
            let lowerIndex = max(stops.startIndex, upperIndex - 1)
            let lower = stops[lowerIndex], upper = stops[upperIndex]
            let amount = upper.0 > lower.0 ? (value - lower.0) / (upper.0 - lower.0) : 0
            return PlatformColor(
                red: lower.1.0 + (upper.1.0 - lower.1.0) * amount,
                green: lower.1.1 + (upper.1.1 - lower.1.1) * amount,
                blue: lower.1.2 + (upper.1.2 - lower.1.2) * amount,
                alpha: 0.94
            )
        }
    }
}

#if os(iOS)
extension HikeTrackMap: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ uiView: MKMapView, context: Context) { updateMap(uiView, context: context) }
}
#else
extension HikeTrackMap: NSViewRepresentable {
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ nsView: MKMapView, context: Context) { updateMap(nsView, context: context) }
}
#endif

enum HikeFormatting {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }

}
