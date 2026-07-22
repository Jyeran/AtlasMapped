import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    private var usesSidebar: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        Group {
            if usesSidebar {
                NavigationSplitView(columnVisibility: $sidebarVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
                } detail: {
                    MapScreen(isSidebarCollapsed: sidebarVisibility == .detailOnly) {
                        withAnimation(.snappy) { sidebarVisibility = .all }
                    }
                }
            } else {
                MapScreen()
            }
        }
        .onChange(of: state.isTracking) { _, isTracking in
            guard isTracking, usesSidebar else { return }
            withAnimation(.snappy) { sidebarVisibility = .detailOnly }
        }
        .sheet(isPresented: $state.showOfflineMaps) {
            OfflineMapsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $state.showRouteTransfer) {
            RouteTransferView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $state.showHikeHistory) {
            HikeHistoryView()
                .environmentObject(state)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $state.completedHike) { hike in
            NavigationStack {
                HikeSummaryView(hike: hike)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { state.completedHike = nil }
                        }
                    }
            }
        }
        .task { state.location.requestAccessAndStart() }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Atlas")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(AtlasTheme.forest)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)

            Label("Map", systemImage: "map.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AtlasTheme.forest)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(AtlasTheme.moss.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 10)

            Button { state.showOfflineMaps = true } label: {
                Label("Offline maps", systemImage: "arrow.down.to.line")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SidebarButtonStyle())

            Button { state.showLayers.toggle() } label: {
                Label("Layers", systemImage: "square.3.layers.3d")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SidebarButtonStyle())

            Button { state.showRouteTransfer = true } label: {
                Label("Route plans", systemImage: "map.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SidebarButtonStyle())

            if !state.hasActiveHike {
                Button { state.startFreeRecording() } label: {
                    Label("Start recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SidebarButtonStyle())
            }

            Button { state.showHikeHistory = true } label: {
                Label("Hike history", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SidebarButtonStyle())

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text(state.currentRouteName.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("Boulder, Colorado")
                    .font(.subheadline.weight(.medium))
                Label("Topographic · Trails", systemImage: "mountain.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(AtlasTheme.paper)
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 24)
            .frame(minHeight: 44)
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}
