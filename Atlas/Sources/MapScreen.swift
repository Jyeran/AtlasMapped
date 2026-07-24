import MapKit
import SwiftUI

struct MapScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var mapCommand: MapCommand?
    @State private var showRouteDetails = false
    @State private var routeDetailsDetent: PresentationDetent = .large
    @State private var showSearch = false
    var isSidebarCollapsed = false
    var onShowSidebar: (() -> Void)?

    private let topControlPadding: CGFloat = 12

    private var usesCompactTopControls: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            // One renderer and one visual source on every device: USGS Topo
            // raster tiles, with Atlas's interactive trail data above them.
            AtlasMapView(command: $mapCommand)
            .ignoresSafeArea()

            if state.isSelectingOfflineArea {
                OfflineSelectionHUD()
            } else {
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            if isSidebarCollapsed {
                                Button { onShowSidebar?() } label: {
                                    Image(systemName: "line.3.horizontal")
                                        .font(.system(size: 17, weight: .semibold))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(AtlasPressButtonStyle())
                                .atlasPanel()
                                .accessibilityLabel("Show sidebar")
                            }
                            CompassElevationBar(compact: usesCompactTopControls)
                            Spacer(minLength: 8)
                            #if os(iOS)
                            topActionControls
                            #endif
                        }

                        if state.showLayers {
                            HStack {
                                Spacer()
                                LayerPanel()
                            }
                            .transition(
                                .move(edge: .top)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.97, anchor: .topTrailing))
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, topControlPadding)

                    Spacer()

                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            if state.selectedTool == .measure, state.measurePoints.count > 1 {
                                MeasurementReadout()
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                            MapAttributionBadge()
                        }
                        Spacer()
                        ToolRail(command: $mapCommand)
                            .layoutPriority(2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    if state.hasActiveRoute || state.hasActiveHike {
                        RouteProgressCard {
                            routeDetailsDetent = .large
                            showRouteDetails = true
                        }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            #if os(macOS)
            if !state.isSelectingOfflineArea {
                topActionControls
                .padding(.top, topControlPadding)
                .padding(.trailing, 16)
            }
            #endif
        }
        .overlay(alignment: .top) {
            if state.selectedPin != nil, !state.isSelectingOfflineArea {
                PinEditorCard()
                    .environmentObject(state)
                    .padding(.horizontal, 16)
                    .padding(.top, 126)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
            } else if state.selectedOutdoorPoint != nil, !state.isSelectingOfflineArea {
                OutdoorPointDetailsCard()
                    .environmentObject(state)
                    .padding(.horizontal, 16)
                    .padding(.top, 126)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .animation(AtlasMotion.panel, value: state.selectedPinID)
        .animation(AtlasMotion.panel, value: state.selectedOutdoorPoint?.id)
        .animation(AtlasMotion.panel, value: state.showLayers)
        .animation(AtlasMotion.panel, value: state.hasActiveRoute)
        .animation(AtlasMotion.standard, value: state.measurePoints.count > 1)
        .sheet(isPresented: $showRouteDetails) {
            RouteDetailsView()
                .environmentObject(state)
                .presentationDetents([.medium, .large], selection: $routeDetailsDetent)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showSearch) {
            MapSearchView()
                .environmentObject(state)
        }
        .onChange(of: state.mapFocusRequest) { _, request in
            guard let request else { return }
            mapCommand = .focus(request.bounds)
        }
        .task {
            state.refreshElevationProfileIfNeeded()
        }
    }

    private var topActionControls: some View {
        HStack(spacing: usesCompactTopControls ? 7 : 8) {
            topControlButton(symbol: "magnifyingglass", accessibilityLabel: "Search maps and routes") {
                showSearch = true
            }

            if !state.showLayers {
                topControlButton(symbol: "square.3.layers.3d", accessibilityLabel: "Layers") {
                    state.showLayers = true
                }
            }

            Menu {
                if !state.hasActiveHike {
                    Button { state.startFreeRecording() } label: {
                        Label("Start recording", systemImage: "record.circle")
                    }
                }
                Button { state.showHikeHistory = true } label: {
                    Label("Hike history", systemImage: "clock.arrow.circlepath")
                }
                Button { state.showLayers.toggle() } label: {
                    Label("Map layers", systemImage: "square.3.layers.3d")
                }
                Button { state.showOfflineMaps = true } label: {
                    Label("Offline maps", systemImage: "arrow.down.to.line")
                }
                Button { state.showRouteTransfer = true } label: {
                    Label("Route plans", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: usesCompactTopControls ? 42 : 44, height: usesCompactTopControls ? 42 : 44)
            }
            .menuIndicator(.hidden)
            .buttonStyle(AtlasPressButtonStyle())
            .atlasPanel()
            .accessibilityLabel("Map menu")
        }
    }

    private func topControlButton(
        symbol: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: usesCompactTopControls ? 42 : 44, height: usesCompactTopControls ? 42 : 44)
        }
        .buttonStyle(AtlasPressButtonStyle())
        .atlasPanel()
        .accessibilityLabel(accessibilityLabel)
    }
}

struct MapSearchView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var knownOutdoorHits: [KnownOutdoorSearchHit] = []
    @State private var isSearching = false
    @FocusState private var searchIsFocused: Bool

    private var routeHits: [RoutePlan] {
        var candidates = state.routes.routes
        if state.hasActiveRoute,
           !candidates.contains(where: { $0.id == state.currentRouteID }) {
            candidates.insert(state.currentRoutePlan(), at: 0)
        }
        guard !query.isEmpty else { return Array(candidates.prefix(5)) }
        return candidates.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var coordinateHit: CLLocationCoordinate2D? {
        let values = query
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .compactMap { Double($0) }
        guard values.count == 2,
              (-90...90).contains(values[0]),
              (-180...180).contains(values[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: values[0], longitude: values[1])
    }

    var body: some View {
        #if os(macOS)
        macSearchPane
            .task(id: query) { await runSearch() }
            .frame(width: 660, height: 700)
        #else
        iOSSearchPane
            .task(id: query) { await runSearch() }
        #endif
    }

    #if os(iOS)
    private var iOSSearchPane: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        Label("Search saved and hand-drawn routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        Label("Find mountains, trails, and trailheads", systemImage: "mountain.2")
                        Label("Or enter coordinates: 39.985, -105.294", systemImage: "location.viewfinder")
                    } header: {
                        Text("Explore Atlas")
                    }
                    .foregroundStyle(AtlasTheme.moss)
                }

                if let coordinateHit {
                    Section("Coordinates") {
                        Button { focus(on: coordinateHit) } label: {
                            searchRow(
                                title: String(format: "%.5f, %.5f", coordinateHit.latitude, coordinateHit.longitude),
                                subtitle: "Open this coordinate",
                                symbol: "location.fill"
                            )
                        }
                    }
                }

                if !routeHits.isEmpty {
                    Section(query.isEmpty ? "Recent routes" : "Routes") {
                        ForEach(routeHits) { route in
                            Button {
                                state.loadRoute(route)
                                dismiss()
                            } label: {
                                searchRow(
                                    title: route.name,
                                    subtitle: "\(formattedDistance(route.distanceMeters)) · saved route",
                                    symbol: "point.topleft.down.to.point.bottomright.curvepath"
                                )
                            }
                        }
                    }
                }

                if !knownOutdoorHits.isEmpty {
                    Section("Atlas trail data") {
                        ForEach(knownOutdoorHits) { hit in
                            Button { open(hit) } label: {
                                searchRow(title: hit.name, subtitle: hit.kind.label, symbol: hit.kind.symbol)
                            }
                        }
                    }
                }

                if isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching hiking sources…")
                            .foregroundStyle(.secondary)
                    }
                } else if query.count >= 2,
                          routeHits.isEmpty,
                          knownOutdoorHits.isEmpty,
                          coordinateHit == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Search")
            #if os(iOS)
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Routes, mountains, trails, trailheads")
            #else
            .listStyle(.inset)
            .searchable(text: $query, prompt: "Routes, mountains, trails, trailheads")
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    #endif

    #if os(macOS)
    private var macSearchPane: some View {
        ZStack {
            AtlasTheme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                macHeader
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if query.isEmpty {
                            macExploreCard
                        }

                        if let coordinateHit {
                            macSection(title: "Coordinates", symbol: "location.viewfinder") {
                                macResultButton(
                                    title: String(format: "%.5f, %.5f", coordinateHit.latitude, coordinateHit.longitude),
                                    subtitle: "Open this coordinate",
                                    symbol: "location.fill"
                                ) { focus(on: coordinateHit) }
                            }
                        }

                        if !routeHits.isEmpty {
                            macSection(
                                title: query.isEmpty ? "Recent routes" : "Routes",
                                symbol: "point.topleft.down.to.point.bottomright.curvepath"
                            ) {
                                ForEach(routeHits) { route in
                                    macResultButton(
                                        title: route.name,
                                        subtitle: "\(formattedDistance(route.distanceMeters)) · saved route",
                                        symbol: "point.topleft.down.to.point.bottomright.curvepath"
                                    ) {
                                        state.loadRoute(route)
                                        dismiss()
                                    }
                                }
                            }
                        }

                        if !knownOutdoorHits.isEmpty {
                            macSection(title: "Trails and terrain", symbol: "mountain.2.fill") {
                                ForEach(knownOutdoorHits) { hit in
                                    macResultButton(
                                        title: hit.name,
                                        subtitle: hit.kind.label,
                                        symbol: hit.kind.symbol
                                    ) { open(hit) }
                                }
                            }
                        }

                        if isSearching {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small).tint(AtlasTheme.orange)
                                Text("Searching hiking sources…")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(AtlasTheme.moss)
                            }
                            .padding(.vertical, 4)
                        } else if query.count >= 2,
                                  routeHits.isEmpty,
                                  knownOutdoorHits.isEmpty,
                                  coordinateHit == nil {
                            VStack(spacing: 10) {
                                Image(systemName: "binoculars.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(AtlasTheme.orange)
                                Text("No outdoor matches yet")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                    .foregroundStyle(AtlasTheme.forest)
                                Text("Try a trail, peak, trailhead, saved route, or coordinates.")
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundStyle(AtlasTheme.moss)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 38)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var macHeader: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "binoculars.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AtlasTheme.orange)
                    .frame(width: 48, height: 48)
                    .background(AtlasTheme.orange.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explore Atlas")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(AtlasTheme.forest)
                    Text("Routes, trails, peaks, and trailheads")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(AtlasTheme.moss)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 42, height: 42)
                        .background(AtlasTheme.moss.opacity(0.10), in: Circle())
                }
                .buttonStyle(AtlasPressButtonStyle())
                .foregroundStyle(AtlasTheme.forest)
                .accessibilityLabel("Close search")
            }

            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(searchIsFocused ? AtlasTheme.orange : AtlasTheme.moss)
                TextField("Search a trail, mountain, route, or coordinates", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(AtlasTheme.forest)
                    .focused($searchIsFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AtlasTheme.moss.opacity(0.72))
                    }
                    .buttonStyle(AtlasPressButtonStyle())
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(searchIsFocused ? AtlasTheme.orange.opacity(0.65) : AtlasTheme.moss.opacity(0.13), lineWidth: 1.2)
            }
            .shadow(color: AtlasTheme.forest.opacity(0.05), radius: 12, y: 5)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .background(
            LinearGradient(
                colors: [AtlasTheme.paper, AtlasTheme.moss.opacity(0.055)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(AtlasTheme.moss.opacity(0.10)).frame(height: 1)
        }
    }

    private var macExploreCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("SEARCH THE BACKCOUNTRY")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(AtlasTheme.moss)
            macHint("Your saved and hand-drawn routes", symbol: "point.topleft.down.to.point.bottomright.curvepath")
            macHint("Mountains, trails, and trailheads", symbol: "mountain.2.fill")
            macHint("Coordinates · 39.985, -105.294", symbol: "location.viewfinder")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AtlasTheme.moss.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AtlasTheme.moss.opacity(0.09), lineWidth: 1)
        }
    }

    private func macHint(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AtlasTheme.orange)
                .frame(width: 30, height: 30)
                .background(AtlasTheme.orange.opacity(0.10), in: Circle())
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(AtlasTheme.forest)
        }
    }

    private func macSection<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title.uppercased(), systemImage: symbol)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.15)
                .foregroundStyle(AtlasTheme.moss)
            VStack(spacing: 8) { content() }
        }
    }

    private func macResultButton(
        title: String,
        subtitle: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            searchRow(title: title, subtitle: subtitle, symbol: symbol)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(AtlasTheme.moss.opacity(0.11), lineWidth: 1)
                }
        }
        .buttonStyle(AtlasPressButtonStyle())
    }
    #endif

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, coordinateHit == nil else {
            knownOutdoorHits = []
            isSearching = false
            return
        }
        isSearching = true
        do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
        guard !Task.isCancelled else { return }

        // Cached and downloaded hiking data should appear immediately; remote
        // landmark services enrich the list without blocking what we have.
        let known = await TrailDataService.shared.searchKnownFeatures(matching: trimmed)
        guard !Task.isCancelled else { return }
        knownOutdoorHits = deduplicatedSearchHits(known)

        let remote = await TrailDataService.shared.searchRemoteFeatures(matching: trimmed)
        guard !Task.isCancelled else { return }
        let combinedKnown = known + remote
        knownOutdoorHits = deduplicatedSearchHits(combinedKnown)
        isSearching = false
    }

    private func deduplicatedSearchHits(_ hits: [KnownOutdoorSearchHit]) -> [KnownOutdoorSearchHit] {
        var seenKnown = Set<String>()
        return hits.filter {
            seenKnown.insert("\($0.kind.rawValue)|\($0.name.lowercased())").inserted
        }
    }

    private func open(_ hit: KnownOutdoorSearchHit) {
        if let coordinates = hit.trailCoordinates?.map(\.coordinate), coordinates.count > 1 {
            state.createRouteFromTrail(named: hit.name, coordinates: coordinates)
        } else {
            if let point = hit.outdoorPoint { state.selectOutdoorPoint(point) }
            focus(on: hit.coordinate.coordinate)
        }
        dismiss()
    }

    private func focus(on coordinate: CLLocationCoordinate2D) {
        state.focusMap(on: [coordinate])
        dismiss()
    }

    private func formattedDistance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .converted(to: .miles)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private func searchRow(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AtlasTheme.orange)
                .frame(width: 38, height: 38)
                .background(AtlasTheme.orange.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(AtlasTheme.forest)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AtlasTheme.moss)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private extension KnownOutdoorSearchHit.Kind {
    var label: String {
        switch self {
        case .trail: "Trail · creates route"
        case .trailhead: "Trailhead"
        case .mountain: "Mountain or pass"
        case .outdoorPlace: "Outdoor place"
        }
    }

    var symbol: String {
        switch self {
        case .trail: "point.topleft.down.to.point.bottomright.curvepath"
        case .trailhead: "figure.hiking"
        case .mountain: "mountain.2.fill"
        case .outdoorPlace: "binoculars.fill"
        }
    }
}

struct MapAttributionBadge: View {
    @EnvironmentObject private var state: AppState

    private let openStreetMapURL = URL(string: "https://www.openstreetmap.org/copyright")!
    private let forestServiceURL = URL(string: "https://data.fs.usda.gov/geodata/edw/datasets.php")!
    private let usgsURL = URL(string: "https://www.usgs.gov/programs/national-geospatial-program/national-map")!

    var body: some View {
        HStack(spacing: 5) {
            Link("USGS The National Map", destination: usgsURL)
                .lineLimit(1)

            Menu {
                Link("USGS Topographic Map", destination: usgsURL)
                Link("OpenStreetMap attribution", destination: openStreetMapURL)
                if state.showTrails {
                    Link("USDA Forest Service trails", destination: forestServiceURL)
                }
            } label: {
                Image(systemName: "info.circle")
                    .imageScale(.small)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Map data sources")
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(.thinMaterial, in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
    }
}

struct OfflineSelectionHUD: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lasso")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AtlasTheme.orange)
                    .frame(width: 42, height: 42)
                    .background(AtlasTheme.orange.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Draw an offline area")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(AtlasTheme.forest)
                    Text("Drag a loop around only the map you want to keep.")
                        .font(.caption)
                        .foregroundStyle(AtlasTheme.moss)
                }
                Spacer()
                Button("Cancel") { state.cancelOfflineSelection() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(AtlasPressButtonStyle())
                    .foregroundStyle(AtlasTheme.orange)
            }
            .padding(14)
            .atlasPanel()
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            selectionSummary
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
        }
    }

    @ViewBuilder
    private var selectionSummary: some View {
        if let draft = state.offlineDraft {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.offline.canDownload(draft) ? "Area ready" : "Area is too large")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(AtlasTheme.forest)
                        Text("\(draft.tiles.count.formatted()) tiles · about \(formattedBytes(draft.estimatedBytes))")
                            .font(.subheadline)
                            .foregroundStyle(AtlasTheme.moss)
                    }
                    Spacer()
                    Image(systemName: state.offline.canDownload(draft) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(state.offline.canDownload(draft) ? AtlasTheme.forest : AtlasTheme.orange)
                }

                if !state.offline.canDownload(draft) {
                    Text("Draw a smaller loop to keep the download under 5,000 tiles.")
                        .font(.caption)
                        .foregroundStyle(AtlasTheme.orange)
                }

                HStack(spacing: 10) {
                    Button("Draw again") {
                        state.updateOfflineSelection([])
                    }
                    .buttonStyle(OfflineSecondaryButtonStyle())

                    Button { state.downloadOfflineSelection() } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(OfflinePrimaryButtonStyle())
                    .disabled(!state.offline.canDownload(draft))
                }
            }
            .padding(18)
            .atlasPanel()
        } else {
            Label(
                state.offlineSelectionPoints.isEmpty ? "Touch and drag to begin your lasso" : "Release to calculate the smallest tile set",
                systemImage: "hand.draw.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AtlasTheme.forest)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .atlasPanel()
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct OfflinePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(AtlasTheme.orange, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(AtlasMotion.quick, value: configuration.isPressed)
    }
}

private struct OfflineSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AtlasTheme.forest)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(AtlasTheme.moss.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(AtlasMotion.quick, value: configuration.isPressed)
    }
}

struct MapCommand: Equatable {
    enum Action: Equatable {
        case locate
        case zoom(Double)
        case focus(MapFocusBounds)
    }

    let action: Action
    private let id = UUID()

    static var locate: MapCommand { MapCommand(action: .locate) }
    static func zoom(_ factor: Double) -> MapCommand { MapCommand(action: .zoom(factor)) }
    static func focus(_ bounds: MapFocusBounds) -> MapCommand { MapCommand(action: .focus(bounds)) }
}

struct CompassElevationBar: View {
    @EnvironmentObject private var state: AppState
    var compact = false

    private var heading: Double { state.location.headingDegrees ?? 45 }
    private var elevation: Double {
        let live = state.location.location?.altitude ?? 0
        return live > 100 ? live : 2932
    }

    var body: some View {
        HStack(spacing: compact ? 7 : 12) {
            Image(systemName: "location.north.fill")
                .rotationEffect(.degrees(-heading))
            Text(cardinal(heading))
                .font(.system(size: compact ? 12 : 13, weight: .bold, design: .rounded))
            Divider().frame(height: compact ? 16 : 18)
            Text("\(Int(heading.rounded()))°")
                .monospacedDigit()
                .contentTransition(.numericText())
            Divider().frame(height: compact ? 16 : 18)
            Image(systemName: "mountain.2.fill")
                .foregroundStyle(AtlasTheme.forest)
            Text(Measurement(value: elevation, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .asProvided)))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.system(size: compact ? 12 : 13, weight: .medium))
        .padding(.horizontal, compact ? 11 : 15)
        .frame(height: compact ? 42 : 44)
        .atlasPanel()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heading \(cardinal(heading)), \(Int(heading)) degrees, elevation \(Int(elevation)) meters")
        .animation(AtlasMotion.standard, value: Int(heading.rounded()))
        .animation(AtlasMotion.standard, value: Int(elevation.rounded()))
    }

    private func cardinal(_ degrees: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return points[Int((degrees + 22.5) / 45).quotientAndRemainder(dividingBy: 8).remainder]
    }
}

struct ToolRail: View {
    @EnvironmentObject private var state: AppState
    @Binding var command: MapCommand?

    var body: some View {
        VStack(spacing: 0) {
            ForEach([MapTool.pin, .measure, .route]) { tool in
                toolButton(tool)
                if tool != .route { Divider().padding(.horizontal, 10) }
            }
            Divider().padding(.horizontal, 10)
            Button { command = .locate } label: { Image(systemName: "location.fill") }
                .accessibilityLabel("Show my location")
            Divider().padding(.horizontal, 10)
            Button { command = .zoom(0.55) } label: { Image(systemName: "plus") }
                .accessibilityLabel("Zoom in")
            Divider().padding(.horizontal, 10)
            Button { command = .zoom(1.8) } label: { Image(systemName: "minus") }
                .accessibilityLabel("Zoom out")
        }
        .buttonStyle(RailButtonStyle())
        .frame(width: 46)
        .fixedSize(horizontal: true, vertical: true)
        .atlasPanel()
    }

    private func toolButton(_ tool: MapTool) -> some View {
        Button {
            state.selectedTool = state.selectedTool == tool ? .explore : tool
        } label: {
            Image(systemName: tool.symbol)
                .foregroundStyle(state.selectedTool == tool ? .white : .primary)
                .background {
                    if state.selectedTool == tool {
                        Circle().fill(AtlasTheme.orange).frame(width: 34, height: 34)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .animation(AtlasMotion.quick, value: state.selectedTool)
        .sensoryFeedback(.selection, trigger: state.selectedTool)
        .accessibilityLabel(tool.label)
        .accessibilityHint(toolHint(tool))
    }

    private func toolHint(_ tool: MapTool) -> String {
        switch tool {
        case .route: "Tap the map to add a waypoint, or press and drag to draw the route"
        case .measure: "Tap the map to add a point, or press and drag to draw a measurement"
        default: ""
        }
    }
}

private struct RailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 46, height: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(AtlasMotion.quick, value: configuration.isPressed)
    }
}

struct MeasurementReadout: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "ruler")
            Text(Measurement(value: state.measuredDistance, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                .monospacedDigit().fontWeight(.semibold)
            Button("Clear") { state.clearActiveDrawing() }
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .atlasPanel()
    }
}
