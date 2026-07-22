import SwiftUI

struct RouteProgressCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var didSave = false
    @State private var elevationChartMode: ElevationChartMode = .profile
    var onExpand: () -> Void = {}

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                wideLayout
            }
        }
        .padding(14)
        .padding(.top, 5)
        .padding(.trailing, 32)
        .atlasPanel()
        .overlay(alignment: .top) {
            Button(action: onExpand) {
                VStack(spacing: 2) {
                    Capsule()
                        .fill(.secondary.opacity(0.42))
                        .frame(width: 34, height: 4)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show route and waypoint details")
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                routeHistoryButton(
                    systemImage: "arrow.uturn.backward",
                    label: "Undo route edit",
                    isEnabled: state.canUndoRouteEdit,
                    action: state.undoRouteEdit
                )
                routeHistoryButton(
                    systemImage: "arrow.uturn.forward",
                    label: "Redo route edit",
                    isEnabled: state.canRedoRouteEdit,
                    action: state.redoRouteEdit
                )
                Button { state.clearActiveRoute() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear active route")
            }
            .padding(8)
        }
        .onChange(of: state.currentRouteName) { _, _ in
            didSave = false
        }
        .alert("Couldn’t fit route", isPresented: routeFitAlert) {
            Button("OK", role: .cancel) { state.routeFitError = nil }
        } message: {
            Text(state.routeFitError ?? "Try drawing closer to a connected mapped trail.")
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    if value.translation.height < -42 { onExpand() }
                },
            including: .gesture
        )
    }

    private var routeSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.hiking")
                .font(.title2)
                .foregroundStyle(AtlasTheme.orange)
                .frame(width: 46, height: 46)
                .background(Circle().stroke(AtlasTheme.orange.opacity(0.45)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    TextField("Route name", text: $state.currentRouteName)
                        .textFieldStyle(.plain)
                        .font(.title3.bold())
                        .lineLimit(1)
                        .onSubmit { state.normalizeCurrentRouteName() }
                        .accessibilityLabel("Route name, editable")
                        .frame(width: 190)

                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AtlasTheme.orange.opacity(0.28))
                        .frame(height: 1)
                        .offset(y: 2)
                }
                HStack(spacing: 14) {
                    Label(routeDistanceLabel, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    Label(elevationGainLabel, systemImage: "mountain.2.fill")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var elevationProfile: some View {
        ElevationProfileView(
            elevations: elevationChartMode == .profile
                ? state.routeElevationProfile
                : RouteMath.cumulativeElevationGain(in: state.routeElevationProfile),
            mode: $elevationChartMode,
            progress: state.routeProgress,
            showsPosition: state.isTracking,
            isLoading: state.isLoadingElevationProfile,
            error: state.elevationProfileError
        )
        .contentShape(Rectangle())
        .frame(minWidth: 190, idealWidth: 320, maxWidth: .infinity)
    }

    private var startButton: some View {
        Button { state.startRouteTracking() } label: {
            Label("Start", systemImage: "play.fill")
                .font(.system(size: 16, weight: .bold))
                .frame(minWidth: 126, minHeight: 46)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(AtlasTheme.orange, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityHint("Starts GPS progress tracking for this route")
    }

    private var saveButton: some View {
        Button {
            state.normalizeCurrentRouteName()
            state.saveCurrentRoute()
            withAnimation(.snappy) { didSave = true }
        } label: {
            Label(didSave ? "Saved" : "Save route", systemImage: didSave ? "checkmark" : "bookmark.fill")
                .font(.system(size: 14, weight: .bold))
                .frame(minWidth: 108, minHeight: 44)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(didSave ? .white : AtlasTheme.forest)
        .background(
            didSave ? AtlasTheme.forest : AtlasTheme.moss.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .accessibilityHint("Saves this route on this device")
    }

    private var fitButton: some View {
        Button {
            state.fitCurrentRouteToTrails()
        } label: {
            ZStack {
                if state.isFittingRoute {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: state.isRouteFitted
                            ? "checkmark"
                            : "point.topleft.down.to.point.bottomright.curvepath")
                        if horizontalSizeClass != .compact {
                            Text(state.isRouteFitted ? "Fitted" : "Fit trail")
                        }
                    }
                }
            }
            .font(.system(size: 14, weight: .bold))
            .frame(minWidth: horizontalSizeClass == .compact ? 44 : 92, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AtlasTheme.forest)
        .background(AtlasTheme.moss.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .disabled(state.isFittingRoute || state.routePoints.count < 2 || state.isRouteFitted)
        .accessibilityLabel(state.isRouteFitted ? "Route fitted to trail" : "Fit route to nearby trails")
        .accessibilityHint("Replaces the drawn route with a matching continuous mapped trail")
    }

    private var trackingMetrics: some View {
        HStack(spacing: 10) {
            metric("Elevation", value: elevationLabel)
            metric("Progress", value: state.routeProgress.formatted(.percent.precision(.fractionLength(0))))
            metric("Distance from route", value: distanceFromRouteLabel)
            endButton
        }
    }

    private var endButton: some View {
        Button { state.endRouteTracking() } label: {
            Text("End")
                .font(.subheadline.weight(.bold))
                .frame(minWidth: 64, minHeight: 42)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AtlasTheme.orange)
        .background(AtlasTheme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityHint("Stops tracking and keeps the route loaded")
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .tracking(0.45)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(height: 20, alignment: .bottomLeading)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(minWidth: 62, alignment: .leading)
    }

    private var wideLayout: some View {
        HStack(spacing: 20) {
            routeSummary
            elevationProfile
            fitButton
            saveButton
            if state.isTracking {
                trackingMetrics
            } else {
                startButton
            }
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            routeSummary
            elevationProfile
            if state.isTracking {
                trackingMetrics
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    fitButton
                    saveButton
                }
            } else {
                HStack(spacing: 10) {
                    fitButton
                    saveButton
                    startButton
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var routeDistanceLabel: String {
        Measurement(value: state.routeDistance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private var elevationGainLabel: String {
        if state.isLoadingElevationProfile { return "Sampling…" }
        guard !state.routeElevationProfile.isEmpty else { return "—" }
        return Measurement(value: state.routeElevationGainMeters.rounded(), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    private var elevationLabel: String {
        guard let elevation = state.currentRouteElevationMeters else { return "—" }
        return Measurement(value: elevation.rounded(), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    private var distanceFromRouteLabel: String {
        guard let distance = state.distanceFromRouteMeters else { return "—" }
        return Measurement(value: distance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private var routeFitAlert: Binding<Bool> {
        Binding(
            get: { state.routeFitError != nil },
            set: { if !$0 { state.routeFitError = nil } }
        )
    }

    private func routeHistoryButton(
        systemImage: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .bold))
                .frame(width: 28, height: 28)
                .background(.primary.opacity(isEnabled ? 0.07 : 0.035), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? AtlasTheme.forest : .secondary.opacity(0.42))
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

}

enum ElevationChartMode: String, CaseIterable, Identifiable {
    case profile
    case totalGain

    var id: Self { self }

    var title: String {
        switch self {
        case .profile: "Raw"
        case .totalGain: "Accumulated"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .profile: "raw elevation profile"
        case .totalGain: "accumulated elevation gain"
        }
    }
}

struct ElevationWaypointMarker: Identifiable {
    let id: UUID
    let sequence: Int
    let progress: Double
    let kind: RouteWaypointKind
}

struct ElevationProfileView: View {
    let elevations: [Double]
    @Binding var mode: ElevationChartMode
    let progress: Double
    let showsPosition: Bool
    let isLoading: Bool
    let error: String?
    var waypointMarkers: [ElevationWaypointMarker] = []
    var graphHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("ELEVATION")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.55)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    ForEach(ElevationChartMode.allCases) { option in
                        Button {
                            withAnimation(.snappy) { mode = option }
                        } label: {
                            Text(option.title.uppercased())
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .tracking(0.25)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .foregroundStyle(mode == option ? AtlasTheme.orange : .secondary)
                                .background(
                                    mode == option ? AtlasTheme.orange.opacity(0.14) : .clear,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(option.accessibilityTitle)")
                        .accessibilityAddTraits(mode == option ? .isSelected : [])
                    }
                }
                .padding(2)
                .background(.primary.opacity(0.055), in: Capsule())
            }

            GeometryReader { proxy in
                let points = graphPoints(in: proxy.size)

                ZStack {
                    if points.isEmpty {
                        HStack(spacing: 6) {
                            if isLoading { ProgressView().controlSize(.small) }
                            Image(systemName: isLoading ? "mountain.2" : "exclamationmark.triangle")
                                .foregroundStyle(isLoading ? AtlasTheme.moss : AtlasTheme.orange)
                            Text(isLoading ? "Sampling actual terrain…" : (error ?? "Elevation not sampled yet"))
                                .lineLimit(1)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    Path { path in
                        guard let first = points.first, let last = points.last else { return }
                        path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                        path.addLine(to: first)
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [AtlasTheme.orange.opacity(0.24), AtlasTheme.orange.opacity(0.025)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        path.addLines(Array(points.dropFirst()))
                    }
                    .stroke(AtlasTheme.orange, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                    ForEach(waypointMarkers) { marker in
                        let markerPoint = point(at: marker.progress, in: proxy.size)
                        Rectangle()
                            .fill(marker.kind.color.opacity(0.18))
                            .frame(width: 1, height: max(1, proxy.size.height - 8))
                            .position(x: markerPoint.x, y: proxy.size.height / 2)

                        Text(marker.sequence.formatted())
                            .font(.system(size: 7.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background(marker.kind.color, in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: 1.5))
                            .position(markerPoint)
                    }

                    if showsPosition {
                        Circle()
                            .fill(AtlasTheme.trailBlue)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                            .shadow(color: AtlasTheme.trailBlue.opacity(0.38), radius: 4)
                            .position(positionPoint(in: proxy.size))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .frame(height: graphHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Route \(mode.accessibilityTitle)")
        .accessibilityValue(showsPosition ? "Current position \(progress.formatted(.percent))" : "Tracking not started")
    }

    private func graphPoints(in size: CGSize) -> [CGPoint] {
        guard elevations.count > 1 else { return [] }
        let minimum = elevations.min() ?? 0
        let maximum = elevations.max() ?? minimum
        let range = max(1, maximum - minimum)
        return elevations.enumerated().map { index, elevation in
            let x = Double(index) / Double(elevations.count - 1) * size.width
            let normalized = (elevation - minimum) / range
            let y = 4 + (1 - normalized) * max(1, size.height - 8)
            return CGPoint(x: x, y: y)
        }
    }

    private func positionPoint(in size: CGSize) -> CGPoint {
        point(at: progress, in: size)
    }

    private func point(at routeProgress: Double, in size: CGSize) -> CGPoint {
        guard elevations.count > 1 else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let clampedProgress = min(1, max(0, routeProgress))
        let scaledIndex = clampedProgress * Double(elevations.count - 1)
        let lowerIndex = min(elevations.count - 1, Int(scaledIndex.rounded(.down)))
        let upperIndex = min(elevations.count - 1, lowerIndex + 1)
        let fraction = scaledIndex - Double(lowerIndex)
        let elevation = elevations[lowerIndex] + (elevations[upperIndex] - elevations[lowerIndex]) * fraction
        let minimum = elevations.min() ?? 0
        let maximum = elevations.max() ?? minimum
        let normalized = (elevation - minimum) / max(1, maximum - minimum)
        let markerInset = 7.0
        return CGPoint(
            x: markerInset + clampedProgress * max(1, size.width - markerInset * 2),
            y: 4 + (1 - normalized) * max(1, size.height - 8)
        )
    }
}
