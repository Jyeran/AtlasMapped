import ActivityKit
import SwiftUI
import WidgetKit

struct AtlasTrackingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AtlasTrackingAttributes.self) { context in
            AtlasLockScreenTrackingView(context: context)
                .activityBackgroundTint(AtlasLiveTheme.paper)
                .activitySystemActionForegroundColor(AtlasLiveTheme.forest)
                .widgetURL(URL(string: "atlas://tracking"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.phase == .paused ? "Paused" : "Tracking")
                    } icon: {
                        Image(systemName: context.attributes.mode == .plannedRoute
                            ? "figure.hiking"
                            : "record.circle.fill")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(AtlasLiveTheme.forest)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(AtlasLiveTheme.orange)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.routeName)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 18) {
                        islandMetric("Pace", value: pace(context.state))
                        islandMetric(
                            context.attributes.mode == .plannedRoute ? "Remaining" : "Distance",
                            value: context.attributes.mode == .plannedRoute
                                ? distance(context.state.remainingMeters, metric: context.state.usesMetricUnits)
                                : distance(context.state.distanceMeters, metric: context.state.usesMetricUnits)
                        )
                        islandMetric("Gain", value: elevation(context.state.elevationGainMeters, metric: context.state.usesMetricUnits))
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .paused ? "pause.fill" : "figure.hiking")
                    .foregroundStyle(AtlasLiveTheme.orange)
            } compactTrailing: {
                Text(context.attributes.mode == .plannedRoute
                    ? context.state.progress.formatted(.percent.precision(.fractionLength(0)))
                    : shortDistance(context.state.distanceMeters, metric: context.state.usesMetricUnits))
                    .font(.caption2.bold().monospacedDigit())
            } minimal: {
                Image(systemName: context.state.phase == .paused ? "pause.fill" : "figure.hiking")
                    .foregroundStyle(AtlasLiveTheme.orange)
            }
            .widgetURL(URL(string: "atlas://tracking"))
            .keylineTint(AtlasLiveTheme.orange)
        }
    }

    private func islandMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold().monospacedDigit())
                .lineLimit(1)
        }
    }
}

private struct AtlasLockScreenTrackingView: View {
    let context: ActivityViewContext<AtlasTrackingAttributes>

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: context.attributes.mode == .plannedRoute
                    ? "figure.hiking"
                    : "record.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AtlasLiveTheme.orange)
                    .frame(width: 38, height: 38)
                    .background(AtlasLiveTheme.orange.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.routeName)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(AtlasLiveTheme.forest)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(context.state.phase == .paused ? Color.secondary : AtlasLiveTheme.orange)
                            .frame(width: 6, height: 6)
                        Text(context.state.phase == .paused ? "Paused" : "Recording")
                        Text("·")
                        Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if context.attributes.mode == .plannedRoute {
                    Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(AtlasLiveTheme.orange)
                }
            }

            HStack(spacing: 8) {
                metric("PACE", pace(context.state))
                metric(
                    context.attributes.mode == .plannedRoute ? "REMAINING" : "DISTANCE",
                    context.attributes.mode == .plannedRoute
                        ? distance(context.state.remainingMeters, metric: context.state.usesMetricUnits)
                        : distance(context.state.distanceMeters, metric: context.state.usesMetricUnits)
                )
                metric(
                    context.attributes.mode == .plannedRoute ? "ETA" : "GAIN",
                    context.attributes.mode == .plannedRoute
                        ? eta(context.state.eta)
                        : elevation(context.state.elevationGainMeters, metric: context.state.usesMetricUnits)
                )
                metric(
                    "ELEVATION",
                    elevation(context.state.elevationMeters, metric: context.state.usesMetricUnits)
                )
            }

            if context.state.elevationProfileMeters.count > 1 {
                ElevationTrace(
                    elevations: context.state.elevationProfileMeters,
                    progress: context.state.progress,
                    isPlannedRoute: context.attributes.mode == .plannedRoute
                )
                .frame(height: 30)
            }

            if context.attributes.mode == .plannedRoute {
                HStack(spacing: 12) {
                    Label(
                        context.state.nextWaypointName ?? "Finish",
                        systemImage: "flag.fill"
                    )
                    Spacer()
                    Text(distance(
                        context.state.nextWaypointRemainingMeters,
                        metric: context.state.usesMetricUnits
                    ))
                    Label(
                        elevation(
                            context.state.elevationGainMeters,
                            metric: context.state.usesMetricUnits
                        ),
                        systemImage: "mountain.2.fill"
                    )
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AtlasLiveTheme.forest.opacity(0.78))
            }
        }
        .padding(14)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(AtlasLiveTheme.forest)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ElevationTrace: View {
    let elevations: [Double]
    let progress: Double
    let isPlannedRoute: Bool

    var body: some View {
        GeometryReader { proxy in
            let points = chartPoints(in: proxy.size)
            ZStack(alignment: .leading) {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(
                    AtlasLiveTheme.orange,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )

                if isPlannedRoute, !points.isEmpty {
                    let index = min(
                        points.count - 1,
                        max(0, Int((Double(points.count - 1) * progress).rounded()))
                    )
                    Circle()
                        .fill(AtlasLiveTheme.trailBlue)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .position(points[index])
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func chartPoints(in size: CGSize) -> [CGPoint] {
        guard let minimum = elevations.min(),
              let maximum = elevations.max() else { return [] }
        let range = max(1, maximum - minimum)
        return elevations.enumerated().map { index, elevation in
            CGPoint(
                x: size.width * CGFloat(index) / CGFloat(max(1, elevations.count - 1)),
                y: size.height - (size.height * CGFloat((elevation - minimum) / range))
            )
        }
    }
}

private enum AtlasLiveTheme {
    static let orange = Color(red: 0.95, green: 0.31, blue: 0.04)
    static let trailBlue = Color(red: 0.08, green: 0.48, blue: 0.96)
    static let forest = Color(red: 0.12, green: 0.22, blue: 0.16)
    static let paper = Color(red: 0.97, green: 0.97, blue: 0.94)
}

private func distance(_ meters: Double?, metric: Bool) -> String {
    guard let meters, meters.isFinite else { return "—" }
    let value = metric ? meters / 1_000 : meters / 1_609.344
    let digits = abs(value) < 10 ? 1 : 0
    return value.formatted(.number.precision(.fractionLength(0...digits)))
        + (metric ? " km" : " mi")
}

private func shortDistance(_ meters: Double, metric: Bool) -> String {
    distance(meters, metric: metric)
}

private func elevation(_ meters: Double?, metric: Bool) -> String {
    guard let meters, meters.isFinite else { return "—" }
    if metric {
        return meters.formatted(.number.precision(.fractionLength(0))) + " m"
    }
    return (meters * 3.28084).formatted(.number.precision(.fractionLength(0))) + " ft"
}

private func pace(_ state: AtlasTrackingAttributes.ContentState) -> String {
    guard let secondsPerMile = state.paceSecondsPerMile,
          secondsPerMile.isFinite,
          secondsPerMile > 0 else { return "—" }
    let seconds = state.usesMetricUnits ? secondsPerMile / 1.609344 : secondsPerMile
    let total = Int(seconds.rounded())
    return "\(total / 60):\(String(format: "%02d", total % 60))"
        + (state.usesMetricUnits ? "/km" : "/mi")
}

private func eta(_ date: Date?) -> String {
    date?.formatted(date: .omitted, time: .shortened) ?? "—"
}
