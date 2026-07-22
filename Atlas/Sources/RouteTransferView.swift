import SwiftUI
import UniformTypeIdentifiers

struct RouteTransferView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var exportDocument: AtlasRouteDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var message: String?
    @State private var routePendingDeletion: RoutePlan?

    var body: some View {
        ZStack {
            AtlasTheme.paper.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 18) {
                    header
                    syncCard
                    savedRoutesSection
                    transferCard

                    if let message {
                        statusMessage(message)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .modifier(RouteTransferSizing())
        .alert("Delete this route?", isPresented: deletionAlertIsPresented, presenting: routePendingDeletion) { plan in
            Button("Delete \(plan.name)", role: .destructive) {
                withAnimation(.snappy) { state.routes.delete(plan) }
                message = "Deleted \(plan.name) from this device."
                routePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { routePendingDeletion = nil }
        } message: { plan in
            Text("This removes “\(plan.name)” from this device. This cannot be undone.")
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .atlasRoute,
            defaultFilename: normalizedName.replacingOccurrences(of: " ", with: "-")
        ) { result in
            if case .failure = result { message = "The route could not be exported." }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.atlasRoute, .json]) { result in
            importRoute(result)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AtlasTheme.orange)
                .frame(width: 46, height: 46)
                .background(AtlasTheme.orange.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Route plans")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(AtlasTheme.forest)
                Text("Plan here. Hike anywhere.")
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
            .accessibilityLabel("Close route plans")
        }
    }

    private var syncCard: some View {
        HStack(spacing: 13) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(AtlasTheme.forest)
                .frame(width: 42, height: 42)
                .background(AtlasTheme.forest.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Saved on this device")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(AtlasTheme.forest)
                Text("Use AirDrop or Files below to move routes between devices.")
                    .font(.caption)
                    .foregroundStyle(AtlasTheme.moss)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(16)
        .background(AtlasTheme.moss.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var savedRoutesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("SAVED ROUTES", symbol: "map.fill")
                Spacer()
                Text("\(state.routes.routes.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AtlasTheme.moss)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(AtlasTheme.moss.opacity(0.12), in: Capsule())
            }

            if state.routes.routes.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "map")
                        .font(.system(size: 28))
                        .foregroundStyle(AtlasTheme.moss)
                    Text("No routes saved yet")
                        .font(.headline)
                        .foregroundStyle(AtlasTheme.forest)
                    Text("Draw a route on the map, then save it for offline use.")
                        .font(.caption)
                        .foregroundStyle(AtlasTheme.moss)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(.white.opacity(0.46), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ForEach(state.routes.routes) { plan in
                    routeCard(plan)
                }
            }
        }
    }

    private var transferCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("AIRDROP OR FILES", symbol: "square.and.arrow.up")

            Text("Move a route between devices using Atlas’s portable route file.")
                .font(.subheadline)
                .foregroundStyle(AtlasTheme.moss)

            HStack(spacing: 10) {
                transferButton("Import", symbol: "square.and.arrow.down") { showImporter = true }
                transferButton("Export", symbol: "square.and.arrow.up") {
                    exportDocument = AtlasRouteDocument(plan: state.currentRoutePlan(named: normalizedName))
                    showExporter = true
                }
                .disabled(state.routePoints.count < 2)
            }
        }
        .padding(18)
        .atlasPanel()
    }

    private func routeCard(_ plan: RoutePlan) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AtlasTheme.orange)
                .frame(width: 42, height: 42)
                .background(AtlasTheme.orange.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(plan.name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AtlasTheme.forest)
                Text(routeSummary(plan))
                    .font(.caption)
                    .foregroundStyle(AtlasTheme.moss)
            }

            Spacer(minLength: 8)

            Button {
                state.loadRoute(plan)
                dismiss()
            } label: {
                Text("Open")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 15)
                    .frame(minHeight: 38)
                    .background(AtlasTheme.forest, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) { routePendingDeletion = plan } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(AtlasTheme.orange.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AtlasTheme.orange)
            .accessibilityLabel("Delete \(plan.name)")
        }
        .padding(14)
        .background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AtlasTheme.moss.opacity(0.12), lineWidth: 1)
        }
    }

    private func transferButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
    }

    private func sectionLabel(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(AtlasTheme.moss)
    }

    private func statusMessage(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AtlasTheme.forest)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AtlasTheme.forest.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { routePendingDeletion != nil },
            set: { if !$0 { routePendingDeletion = nil } }
        )
    }

    private var normalizedName: String {
        let trimmed = state.currentRouteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Route" : trimmed
    }

    private func routeSummary(_ plan: RoutePlan) -> String {
        "\(formattedDistance(plan.distanceMeters)) · \(plan.waypoints.count) points"
    }

    private func formattedDistance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private func importRoute(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let plan = try JSONDecoder.atlas.decode(RoutePlan.self, from: data)
            state.routes.importPlan(plan)
            message = "Imported \(plan.name)."
        } catch {
            message = "That file is not a valid Atlas route."
        }
    }
}

private struct RouteTransferSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(minWidth: 560, idealWidth: 640, minHeight: 620, idealHeight: 760)
        #else
        content
        #endif
    }
}

private struct AtlasSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AtlasTheme.forest)
            .background(.white.opacity(configuration.isPressed ? 0.45 : 0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AtlasTheme.moss.opacity(0.18), lineWidth: 1)
            }
    }
}
