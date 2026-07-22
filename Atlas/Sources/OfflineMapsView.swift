import SwiftUI

struct OfflineMapsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var areaPendingDeletion: OfflineMapArea?

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
        .alert("Delete downloaded map?", isPresented: deletionAlertIsPresented, presenting: areaPendingDeletion) { area in
            Button("Delete \(area.name)", role: .destructive) {
                withAnimation(.snappy) { state.offline.delete(area) }
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
            .buttonStyle(.plain)
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

                Spacer(minLength: 8)

                if let value = state.offline.progress[area.id], value < 1 {
                    Button("Cancel") { state.offline.cancel(area) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
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
                    .buttonStyle(.plain)
                    .foregroundStyle(AtlasTheme.forest)
                    .accessibilityLabel("Resume \(area.name)")
                }

                Button(role: .destructive) { areaPendingDeletion = area } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(AtlasTheme.orange.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
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
