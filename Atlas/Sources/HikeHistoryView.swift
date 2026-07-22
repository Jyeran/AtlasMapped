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
                                    HikeSummaryView(hike: hike)
                                } label: {
                                    hikeRow(hike)
                                }
                                .buttonStyle(.plain)
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
                    Label(HikeFormatting.distance(hike.distanceMeters), systemImage: "figure.walk")
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
    let hike: RecordedHike

    private var pace: Double? {
        guard hike.distanceMeters >= 20 else { return nil }
        return hike.activeDuration / (hike.distanceMeters / 1_609.344)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                stats
                splitSection("START / STOP LEGS", splits: hike.splits.filter { $0.kind == .activeLeg })
                splitSection("WAYPOINT SPLITS", splits: hike.splits.filter { $0.kind == .waypoint })
                splitSection("MANUAL SPLITS", splits: hike.splits.filter { $0.kind == .manual })
            }
            .padding(20)
        }
        .background(AtlasTheme.paper.ignoresSafeArea())
        .navigationTitle("Hike summary")
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
            summaryMetric("Distance", HikeFormatting.distance(hike.distanceMeters), "figure.walk")
            summaryMetric("Active time", HikeFormatting.duration(hike.activeDuration), "timer")
            summaryMetric("Elapsed", HikeFormatting.duration(hike.elapsedDuration), "clock")
            summaryMetric("Pace", HikeFormatting.pace(pace), "speedometer")
            summaryMetric("Elevation gain", HikeFormatting.elevation(hike.elevationGainMeters), "mountain.2.fill")
            summaryMetric("GPS points", "\(hike.samples.count)", "point.3.connected.trianglepath.dotted")
        }
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
                        Text(HikeFormatting.distance(split.distanceMeters))
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

enum HikeFormatting {
    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func elevation(_ meters: Double) -> String {
        Measurement(value: meters.rounded(), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }

    static func pace(_ secondsPerMile: Double?) -> String {
        guard let secondsPerMile, secondsPerMile.isFinite else { return "—" }
        return "\(duration(secondsPerMile)) /mi"
    }
}
