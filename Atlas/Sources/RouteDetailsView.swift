import SwiftUI

struct RouteDetailsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var elevationChartMode: ElevationChartMode = .profile

    var body: some View {
        ZStack {
            AtlasTheme.paper.opacity(0.72).ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    header
                    terrainSummary
                    fitToTrailAction
                    fitHistoryActions
                    elevationChart

                    Text("WAYPOINTS")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(AtlasTheme.moss)
                        .padding(.horizontal, 4)

                    if state.routeWaypointSummaries.isEmpty {
                        emptyWaypoints
                    } else {
                        ForEach(state.routeWaypointSummaries) { waypoint in
                            WaypointStatsCard(waypoint: waypoint)
                                .environmentObject(state)
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "mountain.2.fill")
                        Text("Elevation sampled from USGS 3DEP terrain along the route.")
                        Spacer()
                        Button("Refresh") { state.refreshElevationProfile() }
                            .buttonStyle(AtlasPressButtonStyle())
                            .fontWeight(.bold)
                            .foregroundStyle(AtlasTheme.orange)
                    }
                    .font(.caption)
                    .foregroundStyle(AtlasTheme.moss)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 18)
                }
                .padding(20)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AtlasTheme.orange)
                .frame(width: 48, height: 48)
                .background(AtlasTheme.orange.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(state.currentRouteName)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(AtlasTheme.forest)
                Text("Route details")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AtlasTheme.moss)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(AtlasTheme.moss.opacity(0.10), in: Circle())
            }
            .buttonStyle(AtlasPressButtonStyle())
            .foregroundStyle(AtlasTheme.forest)
            .accessibilityLabel("Close route details")
        }
    }

    private var terrainSummary: some View {
        HStack(spacing: 0) {
            summaryMetric("Distance", value: formatDistance(state.routeDistance))
            Divider().frame(height: 38)
            summaryMetric("Total gain", value: elevationGain)
            Divider().frame(height: 38)
            summaryMetric("Waypoints", value: state.routeWaypointSummaries.count.formatted())
        }
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AtlasTheme.moss.opacity(0.10), lineWidth: 1)
        )
    }

    private var elevationChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            ElevationProfileView(
                elevations: elevationChartMode == .profile
                    ? state.routeElevationProfile
                    : RouteMath.cumulativeElevationGain(in: state.routeElevationProfile),
                mode: $elevationChartMode,
                progress: state.routeProgress,
                showsPosition: state.isTracking,
                isLoading: state.isLoadingElevationProfile,
                error: state.elevationProfileError,
                waypointMarkers: state.routeWaypointSummaries.map {
                    ElevationWaypointMarker(
                        id: $0.id,
                        sequence: $0.sequence,
                        progress: $0.progress,
                        kind: $0.kind
                    )
                },
                graphHeight: 112,
                probeMarkers: state.routeElevationProbeSummaries.map(ElevationProbeMarker.init),
                onProbeTap: state.selectRouteElevationProbe,
                onProbeDrag: state.moveRouteElevationProbe
            )

            if !state.routeElevationProbeSummaries.isEmpty {
                ElevationProbeReadout(compact: false)
                    .environmentObject(state)
            } else {
                Label("Tap two points on the curve to compare them on the route", systemImage: "hand.tap")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AtlasTheme.moss.opacity(0.10), lineWidth: 1)
        )
    }

    private var fitToTrailAction: some View {
        Button {
            state.fitCurrentRouteToTrails()
        } label: {
            HStack(spacing: 12) {
                Group {
                    if state.isFittingRoute { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: state.isRouteFitted
                            ? "checkmark"
                            : "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
                .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.isRouteFitted ? "Route fitted" : "Fit to trail")
                        .font(.subheadline.bold())
                    Text(state.isRouteFitted
                        ? "Use Undo to restore the hand-drawn route"
                        : "Match this route to nearby mapped trail geometry")
                        .font(.caption)
                        .foregroundStyle(AtlasTheme.moss)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(AtlasTheme.moss)
            }
            .foregroundStyle(AtlasTheme.forest)
            .padding(14)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(AtlasPressButtonStyle())
        .background(AtlasTheme.moss.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(state.isFittingRoute || state.routePoints.count < 2 || state.isRouteFitted)
        .alert("Couldn’t fit route", isPresented: routeFitAlert) {
            Button("OK", role: .cancel) { state.routeFitError = nil }
        } message: {
            Text(state.routeFitError ?? "Try drawing closer to a connected mapped trail.")
        }
    }

    private var fitHistoryActions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                historyAction(
                    title: "Undo",
                    systemImage: "arrow.uturn.backward",
                    enabled: state.canUndoRouteEdit,
                    action: state.undoRouteEdit
                )
                historyAction(
                    title: "Redo",
                    systemImage: "arrow.uturn.forward",
                    enabled: state.canRedoRouteEdit,
                    action: state.redoRouteEdit
                )
            }
            historyAction(
                title: "Reverse route order",
                systemImage: "arrow.up.arrow.down",
                enabled: state.routePoints.count > 1,
                action: state.reverseRoute
            )
        }
    }

    private func historyAction(
        title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(AtlasPressButtonStyle())
        .foregroundStyle(enabled ? AtlasTheme.forest : AtlasTheme.moss.opacity(0.42))
        .background(AtlasTheme.moss.opacity(enabled ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .disabled(!enabled)
    }

    private var routeFitAlert: Binding<Bool> {
        Binding(
            get: { state.routeFitError != nil },
            set: { if !$0 { state.routeFitError = nil } }
        )
    }

    private func summaryMetric(_ title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(AtlasTheme.forest)
                .monospacedDigit()
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AtlasTheme.moss)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyWaypoints: some View {
        Label("Short-press the route tool on the map to add a named waypoint.", systemImage: "mappin.and.ellipse")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AtlasTheme.moss)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var elevationGain: String {
        if state.isLoadingElevationProfile { return "Sampling…" }
        guard !state.routeElevationProfile.isEmpty else { return "—" }
        return formatElevation(state.routeElevationGainMeters)
    }
}

private struct WaypointStatsCard: View {
    @EnvironmentObject private var state: AppState
    private enum FocusedField { case name, note }
    @FocusState private var focusedField: FocusedField?
    @State private var showRemoveConfirmation = false
    @State private var nameDraft: String
    @State private var noteDraft: String
    let waypoint: RouteWaypointSummary

    init(waypoint: RouteWaypointSummary) {
        self.waypoint = waypoint
        _nameDraft = State(initialValue: waypoint.name)
        _noteDraft = State(initialValue: waypoint.note)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(waypoint.sequence.formatted())
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(waypoint.kind.color, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))

            VStack(alignment: .leading, spacing: 12) {
                TextField("Waypoint name", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(AtlasTheme.forest)
                    .focused($focusedField, equals: .name)
                    .onSubmit {
                        finishEditing()
                        focusedField = nil
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(focusedField == .name ? AtlasTheme.orange : .clear)
                            .frame(height: 1.5)
                            .offset(y: 4)
                    }

                HStack(spacing: 8) {
                    stat("Elevation", value: waypoint.elevationMeters.map(formatElevation) ?? "—")
                    stat("Along route", value: formatDistance(waypoint.distanceAlongMeters))
                    stat("To next", value: waypoint.distanceToNextMeters.map(formatDistance) ?? "Finish")
                }

                TextField("Add a waypoint comment…", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(AtlasTheme.forest)
                    .lineLimit(2...4)
                    .focused($focusedField, equals: .note)
                    .padding(10)
                    .background(AtlasTheme.moss.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack {
                    Label(waypointKindLabel, systemImage: waypoint.kind.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(waypoint.kind.color)
                    Spacer()
                    Button(role: .destructive) { showRemoveConfirmation = true } label: {
                        Label("Remove waypoint", systemImage: "trash")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(AtlasPressButtonStyle())
                    .foregroundStyle(.red)
                }
            }

            Image(systemName: waypoint.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(waypoint.kind.color)
                .padding(.top, 4)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AtlasTheme.moss.opacity(0.10), lineWidth: 1)
        )
        .onChange(of: focusedField) { previous, current in
            if previous == .name, current != .name { finishEditing() }
            if previous == .note, current != .note { commitNote() }
        }
        .onDisappear {
            finishEditing()
            commitNote()
        }
        .alert("Remove \(waypoint.name)?", isPresented: $showRemoveConfirmation) {
            Button("Remove", role: .destructive) { state.removeWaypoint(id: waypoint.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalExplanation)
        }
    }

    private var waypointKindLabel: String {
        switch waypoint.kind {
        case .standard: "Route waypoint"
        case .pin: "Map pin"
        case .trailhead: "Trailhead"
        case .peak: "Peak"
        case .saddle: "Mountain pass"
        case .viewpoint: "Viewpoint"
        case .shelter: "Shelter"
        case .campsite: "Campsite"
        case .water: "Drinking water"
        case .spring: "Spring"
        }
    }

    private var removalExplanation: String {
        let count = state.routeWaypointSummaries.count
        if count > 1, waypoint.sequence == 1 || waypoint.sequence == count {
            return "This is an edge waypoint, so the route will be trimmed to the next sequenced waypoint."
        }
        return "The waypoint marker will be removed while the route’s existing shape remains unchanged."
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .tracking(0.35)
                .foregroundStyle(AtlasTheme.moss)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AtlasTheme.forest)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func finishEditing() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? waypoint.name : trimmed
        nameDraft = resolved
        if resolved != waypoint.name {
            state.setWaypointName(id: waypoint.id, name: resolved)
        }
    }

    private func commitNote() {
        guard noteDraft != waypoint.note else { return }
        state.setWaypointNote(id: waypoint.id, note: noteDraft)
    }
}

private func formatDistance(_ meters: Double) -> String {
    Measurement(value: meters, unit: UnitLength.meters)
        .formatted(.measurement(width: .abbreviated, usage: .road))
}

private func formatElevation(_ meters: Double) -> String {
    Measurement(value: meters.rounded(), unit: UnitLength.meters)
        .formatted(.measurement(width: .abbreviated, usage: .asProvided))
}
