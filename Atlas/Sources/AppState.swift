import Foundation
import MapKit
import Combine

enum BaseMapStyle: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case satellite = "Satellite"
    case topographic = "Topographic"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .standard: "map"
        case .satellite: "globe.americas.fill"
        case .topographic: "mountain.2"
        }
    }
}

enum MapTool: String, CaseIterable, Identifiable {
    case explore, pin, measure, route
    var id: Self { self }
    var symbol: String {
        switch self {
        case .explore: "hand.draw"
        case .pin: "mappin"
        case .measure: "ruler"
        case .route: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
    var label: String { rawValue.capitalized }
}

struct RouteWaypointSummary: Identifiable, Equatable {
    let id: UUID
    let sequence: Int
    let name: String
    let note: String
    let kind: RouteWaypointKind
    let elevationMeters: Double?
    let distanceAlongMeters: CLLocationDistance
    let distanceToNextMeters: CLLocationDistance?
    let progress: Double
}

struct RouteElevationProbe: Identifiable, Equatable {
    let id: UUID
    var progress: Double

    init(id: UUID = UUID(), progress: Double) {
        self.id = id
        self.progress = min(1, max(0, progress))
    }
}

struct RouteElevationProbeSummary: Identifiable {
    let id: UUID
    let label: String
    let progress: Double
    let coordinate: CLLocationCoordinate2D
    let elevationMeters: Double?
    let distanceAlongMeters: CLLocationDistance
}

struct MapFocusBounds: Equatable, Sendable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    init(coordinates: [CLLocationCoordinate2D], minimumSpan: Double = 0.012) {
        let first = coordinates.first ?? CLLocationCoordinate2D(latitude: 39.9854, longitude: -105.2944)
        let rawSouth = coordinates.dropFirst().reduce(first.latitude) { min($0, $1.latitude) }
        let rawWest = coordinates.dropFirst().reduce(first.longitude) { min($0, $1.longitude) }
        let rawNorth = coordinates.dropFirst().reduce(first.latitude) { max($0, $1.latitude) }
        let rawEast = coordinates.dropFirst().reduce(first.longitude) { max($0, $1.longitude) }
        let latitudeCenter = (rawNorth + rawSouth) / 2
        let longitudeCenter = (rawEast + rawWest) / 2
        let latitudeSpan = max(minimumSpan, rawNorth - rawSouth)
        let longitudeSpan = max(minimumSpan, rawEast - rawWest)
        south = latitudeCenter - latitudeSpan / 2
        west = longitudeCenter - longitudeSpan / 2
        north = latitudeCenter + latitudeSpan / 2
        east = longitudeCenter + longitudeSpan / 2
    }

    init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }
}

struct MapFocusRequest: Equatable, Sendable {
    let id = UUID()
    let bounds: MapFocusBounds
}

struct StoredMapViewport: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double

    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var baseMap: BaseMapStyle = .topographic
    @Published var showTrails = true
    @Published var unitSystem: AtlasUnitSystem
    @Published var selectedTool: MapTool = .explore
    @Published var pins: [RoutePin] = []
    @Published var selectedPinID: UUID?
    @Published var selectedOutdoorPoint: OutdoorPointFeature?
    @Published var measurePoints: [CLLocationCoordinate2D] = []
    @Published var routePoints: [CLLocationCoordinate2D] = []
    @Published var routeElevationProbes: [RouteElevationProbe] = []
    @Published var routeWaypointIndices: Set<Int> = []
    @Published var namedRouteWaypoints: [NamedRouteWaypoint] = []
    @Published var isTracking = false
    @Published var showHikeHistory = false
    @Published var completedHike: RecordedHike?
    @Published var showLayers = false
    @Published var showOfflineMaps = false
    @Published var isSelectingOfflineArea = false
    @Published var offlineSelectionPoints: [CLLocationCoordinate2D] = []
    @Published var offlineDraft: OfflineMapDraft?
    @Published var showRouteTransfer = false
    @Published var showSidebar = true
    @Published var routeProgress = 0.0
    @Published var distanceFromRouteMeters: CLLocationDistance?
    @Published var currentRouteName = "Untitled Route"
    @Published var currentRouteID = UUID()
    @Published var currentRouteCreatedAt = Date.now
    @Published var currentElevationGainMeters = 0.0
    @Published var currentRouteElevationProfileMeters: [Double]?
    @Published var currentElevationProfileProvider: String?
    @Published var isLoadingElevationProfile = false
    @Published var elevationProfileError: String?
    @Published var mapFocusRequest: MapFocusRequest?
    @Published var isFittingRoute = false
    @Published var canUndoRouteEdit = false
    @Published var canRedoRouteEdit = false
    @Published var isRouteFitted = false
    @Published var routeFitError: String?
    let location = LocationService()
    let connectivity = ConnectivityMonitor()
    let offline = OfflineRegionManager()
    let routes = RouteLibrary()
    let hikeRecorder = HikeRecorder()
    let hikes = HikeLibrary()
    private let elevationService = ElevationService()
    private var subscriptions: Set<AnyCancellable> = []
    private var elevationTask: Task<Void, Never>?
    private var routeFitTask: Task<Void, Never>?
    private var pinElevationTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var routeRevision = UUID()
    private(set) var measurementRevision = UUID()
    private(set) var offlineSelectionRevision = UUID()
    private(set) var annotationRevision = UUID()
    private static let mapViewportDefaultsKey = "atlas.lastMapViewport.v1"
    private static let pinsDefaultsKey = "atlas.savedPins.v1"
    private static let unitSystemDefaultsKey = "atlas.unitSystem.v1"
    private let persistsPins: Bool
    private let persistsPreferences: Bool
    private var shouldFocusFirstLocation: Bool
    private struct RouteGeometrySnapshot {
        let points: [CLLocationCoordinate2D]
        let waypointIndices: Set<Int>
        let namedWaypoints: [NamedRouteWaypoint]
        let isFitted: Bool
    }
    private var routeUndoHistory: [RouteGeometrySnapshot] = []
    private var routeRedoHistory: [RouteGeometrySnapshot] = []
    private var cachedRouteMetrics: (revision: UUID, cumulative: [CLLocationDistance])?
    private var cachedMeasurementMetrics: (revision: UUID, distance: CLLocationDistance)?

    init(persistsPins: Bool = false, persistsPreferences: Bool = false) {
        self.persistsPins = persistsPins
        self.persistsPreferences = persistsPreferences
        unitSystem = persistsPreferences
            ? AtlasUnitSystem(rawValue: UserDefaults.standard.string(forKey: Self.unitSystemDefaultsKey) ?? "") ?? .metric
            : .metric
        shouldFocusFirstLocation = Self.storedMapViewport == nil
        if persistsPins {
            pins = Self.loadPersistedPins()
        }
        location.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        connectivity.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        offline.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        routes.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        hikeRecorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        hikes.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        location.onLocationUpdate = { [weak self] newLocation in
            guard let self else { return }
            if self.shouldFocusFirstLocation {
                self.shouldFocusFirstLocation = false
                self.mapFocusRequest = MapFocusRequest(bounds: MapFocusBounds(
                    coordinates: [newLocation.coordinate],
                    minimumSpan: 0.018
                ))
            }
            if self.isTracking {
                let priorSampleCount = self.hikeRecorder.samples.count
                self.hikeRecorder.ingest(newLocation)
                if self.hikeRecorder.mode == .freeRecording,
                   self.hikeRecorder.samples.count > priorSampleCount {
                    self.appendRecordedRoutePoint(newLocation.coordinate)
                }
                if !self.hikeRecorder.isPaused {
                    self.updateTrackingPosition(newLocation)
                }
            }
        }
    }

    static var storedMapViewport: StoredMapViewport? {
        guard let data = UserDefaults.standard.data(forKey: mapViewportDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(StoredMapViewport.self, from: data)
    }

    func storeMapViewport(_ region: MKCoordinateRegion) {
        guard region.center.latitude.isFinite,
              region.center.longitude.isFinite,
              region.span.latitudeDelta.isFinite,
              region.span.longitudeDelta.isFinite,
              region.span.latitudeDelta > 0,
              region.span.longitudeDelta > 0 else { return }
        let viewport = StoredMapViewport(
            latitude: region.center.latitude,
            longitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta
        )
        guard let data = try? JSONEncoder().encode(viewport) else { return }
        UserDefaults.standard.set(data, forKey: Self.mapViewportDefaultsKey)
    }

    private static func loadPersistedPins() -> [RoutePin] {
        guard let data = UserDefaults.standard.data(forKey: pinsDefaultsKey) else { return [] }
        return (try? JSONDecoder.atlas.decode([RoutePin].self, from: data)) ?? []
    }

    private func persistPins() {
        guard persistsPins,
              let data = try? JSONEncoder.atlas.encode(pins) else { return }
        UserDefaults.standard.set(data, forKey: Self.pinsDefaultsKey)
    }

    func toggleUnitSystem() {
        unitSystem = unitSystem == .metric ? .imperial : .metric
        if persistsPreferences {
            UserDefaults.standard.set(unitSystem.rawValue, forKey: Self.unitSystemDefaultsKey)
        }
    }

    var measuredDistance: CLLocationDistance {
        if let cachedMeasurementMetrics,
           cachedMeasurementMetrics.revision == measurementRevision {
            return cachedMeasurementMetrics.distance
        }
        let distance = RouteMath.distance(along: measurePoints)
        cachedMeasurementMetrics = (measurementRevision, distance)
        return distance
    }

    var routeDistance: CLLocationDistance {
        routeCumulativeDistances.last ?? 0
    }

    var hasActiveRoute: Bool { routePoints.count > 1 }
    var hasActiveHike: Bool { hikeRecorder.isActive }
    var isTrackingPaused: Bool { hikeRecorder.isPaused }
    var trackingDistanceMeters: Double { hikeRecorder.distanceMeters }
    var trackingElapsedDuration: TimeInterval { hikeRecorder.elapsedDuration }
    var trackingActiveDuration: TimeInterval { hikeRecorder.activeDuration }
    var trackingPaceSecondsPerMile: Double? { hikeRecorder.paceSecondsPerMile }
    var trackingElevationGainMeters: Double { hikeRecorder.elevationGainMeters }
    var trackingRemainingMeters: Double? {
        guard hikeRecorder.mode == .plannedRoute else { return nil }
        return max(0, routeDistance * (1 - routeProgress))
    }
    var trackingETA: Date? {
        guard let remaining = trackingRemainingMeters,
              let pace = trackingPaceSecondsPerMile else { return nil }
        return hikeRecorder.now.addingTimeInterval((remaining / 1_609.344) * pace)
    }
    var trackingNextWaypointName: String? { hikeRecorder.nextWaypoint?.name }
    var trackingNextWaypointRemainingMeters: Double? {
        guard let next = hikeRecorder.nextWaypoint,
              routePoints.indices.contains(next.routePointIndex) else { return nil }
        let cumulative = RouteMath.cumulativeDistances(along: routePoints)
        let routePosition = routeDistance * routeProgress
        return max(0, cumulative[next.routePointIndex] - routePosition)
    }

    var routeElevationProfile: [Double] {
        guard currentElevationProfileProvider == ElevationService.providerID,
              let profile = currentRouteElevationProfileMeters,
              profile.count > 1 else { return [] }
        return profile
    }

    var routeElevationGainMeters: Double {
        RouteMath.cumulativeElevationGain(in: routeElevationProfile).last
            ?? currentElevationGainMeters
    }

    var currentRouteElevationMeters: Double? {
        if isTracking, let altitude = location.location?.altitude, altitude > 100 { return altitude }
        return RouteMath.elevation(at: routeProgress, in: routeElevationProfile)
    }

    var routeWaypointSummaries: [RouteWaypointSummary] {
        let cumulative = routeCumulativeDistances
        let total = cumulative.last ?? 0
        let sorted = namedRouteWaypoints
            .filter { routePoints.indices.contains($0.routePointIndex) }
            .sorted { $0.routePointIndex < $1.routePointIndex }

        return sorted.enumerated().map { sequence, waypoint in
            let index = waypoint.routePointIndex
            let distanceAlong = cumulative[index]
            let nextDistance: CLLocationDistance?
            if sorted.indices.contains(sequence + 1) {
                nextDistance = cumulative[sorted[sequence + 1].routePointIndex] - distanceAlong
            } else {
                nextDistance = total > distanceAlong ? total - distanceAlong : nil
            }
            let progress = total > 0 ? distanceAlong / total : 0
            return RouteWaypointSummary(
                id: waypoint.id,
                sequence: sequence + 1,
                name: waypoint.name,
                note: waypoint.resolvedNote,
                kind: waypoint.resolvedKind,
                elevationMeters: RouteMath.elevation(at: progress, in: routeElevationProfile),
                distanceAlongMeters: distanceAlong,
                distanceToNextMeters: nextDistance,
                progress: progress
            )
        }
    }

    var routeElevationProbeSummaries: [RouteElevationProbeSummary] {
        let cumulative = routeCumulativeDistances
        return routeElevationProbes
            .sorted { $0.progress < $1.progress }
            .enumerated()
            .compactMap { index, probe in
                guard let coordinate = RouteMath.coordinate(
                    at: probe.progress,
                    along: routePoints,
                    cumulativeDistances: cumulative
                ) else {
                    return nil
                }
                return RouteElevationProbeSummary(
                    id: probe.id,
                    label: index == 0 ? "A" : "B",
                    progress: probe.progress,
                    coordinate: coordinate,
                    elevationMeters: RouteMath.elevation(at: probe.progress, in: routeElevationProfile),
                    distanceAlongMeters: routeDistance * probe.progress
                )
            }
    }

    private var routeCumulativeDistances: [CLLocationDistance] {
        if let cachedRouteMetrics, cachedRouteMetrics.revision == routeRevision {
            return cachedRouteMetrics.cumulative
        }
        let cumulative = RouteMath.cumulativeDistances(along: routePoints)
        cachedRouteMetrics = (routeRevision, cumulative)
        return cumulative
    }

    func selectRouteElevationProbe(at progress: Double) {
        guard hasActiveRoute, routeElevationProfile.count > 1 else { return }
        let clamped = min(1, max(0, progress))
        if routeElevationProbes.count < 2 {
            routeElevationProbes.append(RouteElevationProbe(progress: clamped))
        } else {
            let nearestIndex = routeElevationProbes.indices.min {
                abs(routeElevationProbes[$0].progress - clamped)
                    < abs(routeElevationProbes[$1].progress - clamped)
            } ?? routeElevationProbes.startIndex
            routeElevationProbes[nearestIndex].progress = clamped
        }
        routeElevationProbes.sort { $0.progress < $1.progress }
        annotationRevision = UUID()
    }

    func moveRouteElevationProbe(id: UUID, to progress: Double) {
        guard let index = routeElevationProbes.firstIndex(where: { $0.id == id }) else { return }
        var clamped = min(1, max(0, progress))
        if routeElevationProbes.count == 2,
           let other = routeElevationProbes.first(where: { $0.id != id }) {
            let minimumSeparation = 0.002
            if routeElevationProbes[index].progress <= other.progress {
                clamped = min(clamped, max(0, other.progress - minimumSeparation))
            } else {
                clamped = max(clamped, min(1, other.progress + minimumSeparation))
            }
        }
        guard abs(routeElevationProbes[index].progress - clamped) > 0.0001 else { return }
        routeElevationProbes[index].progress = clamped
        routeElevationProbes.sort { $0.progress < $1.progress }
        annotationRevision = UUID()
    }

    func clearRouteElevationProbes() {
        routeElevationProbes.removeAll()
        annotationRevision = UUID()
    }

    func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        guard !isSelectingOfflineArea else { return }
        switch selectedTool {
        case .explore:
            selectedPinID = nil
            selectedOutdoorPoint = nil
        case .pin:
            let pin = RoutePin(coordinate: coordinate, title: "Pin \(pins.count + 1)")
            pins.append(pin)
            annotationRevision = UUID()
            selectedPinID = pin.id
            persistPins()
            refreshPinElevation(id: pin.id)
            persistCurrentRouteIfSaved()
        case .measure:
            selectedPinID = nil
            measurePoints.append(coordinate)
            measurementRevision = UUID()
        case .route:
            selectedPinID = nil
            addRouteWaypoint(coordinate)
        }
    }

    func addRouteWaypoint(_ coordinate: CLLocationCoordinate2D) {
        prepareRouteForEditing()
        addRouteStop(
            coordinate,
            name: "Waypoint \(namedRouteWaypoints.count + 1)",
            kind: .standard
        )
    }

    func addPinToRoute(id: UUID) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        addRouteStop(
            pin.coordinate,
            name: pin.title,
            note: pin.note,
            kind: .pin,
            sourceID: pin.id.uuidString
        )
        selectedPinID = nil
    }

    func addOutdoorPointToRoute(_ point: OutdoorPointFeature) {
        addRouteStop(
            point.coordinate.coordinate,
            name: point.name,
            note: point.description ?? "",
            kind: RouteWaypointKind(point.kind),
            sourceID: point.id
        )
        selectedOutdoorPoint = nil
    }

    func addTrailFeatureToRoute(
        coordinate: CLLocationCoordinate2D,
        name: String?,
        sourceID: String
    ) {
        addRouteStop(
            coordinate,
            name: name?.nilIfEmpty ?? "Trail waypoint",
            kind: .standard,
            sourceID: sourceID
        )
    }

    func addExistingWaypointToRoute(id: UUID) {
        guard let waypoint = namedRouteWaypoints.first(where: { $0.id == id }),
              routePoints.indices.contains(waypoint.routePointIndex) else { return }
        addRouteStop(
            routePoints[waypoint.routePointIndex],
            name: waypoint.name,
            note: waypoint.resolvedNote,
            kind: waypoint.resolvedKind,
            sourceID: waypoint.sourceID
        )
    }

    private func addRouteStop(
        _ coordinate: CLLocationCoordinate2D,
        name: String,
        note: String = "",
        kind: RouteWaypointKind,
        sourceID: String? = nil
    ) {
        prepareRouteForEditing()
        if let last = routePoints.last {
            let distance = CLLocation(latitude: last.latitude, longitude: last.longitude).distance(
                from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            // Prevent one physical tap from being handled by both MapKit's
            // selection callback and Atlas's tap recognizer. A waypoint can
            // still be reused after any intervening route leg.
            guard distance > 0.25 else { return }
        }
        recordRouteEdit()
        let routePointIndex = routePoints.count
        routeWaypointIndices.insert(routePointIndex)
        namedRouteWaypoints.append(NamedRouteWaypoint(
            routePointIndex: routePointIndex,
            name: name,
            note: note.isEmpty ? nil : note,
            kind: kind,
            sourceID: sourceID
        ))
        routePoints.append(coordinate)
        routeGeometryDidChange()
    }

    func moveRouteWaypoint(at routePointIndex: Int, to coordinate: CLLocationCoordinate2D) {
        guard routeWaypointIndices.contains(routePointIndex),
              routePoints.indices.contains(routePointIndex) else { return }
        let previous = routePoints[routePointIndex]
        guard previous.latitude != coordinate.latitude || previous.longitude != coordinate.longitude else { return }

        cancelActiveHike()
        recordRouteEdit()
        routePoints[routePointIndex] = coordinate
        routeGeometryDidChange()
        persistCurrentRouteIfSaved()
    }

    func beginRouteStroke(at coordinate: CLLocationCoordinate2D) {
        prepareRouteForEditing()
        recordRouteEdit()
        routePoints.append(coordinate)
        routeGeometryDidChange(shouldRefresh: false, isLiveEdit: true)
    }

    func continueRouteStroke(to coordinate: CLLocationCoordinate2D) {
        guard selectedTool == .route else { return }
        routePoints.append(coordinate)
        routeGeometryDidChange(shouldRefresh: false, isLiveEdit: true)
    }

    func finishRouteStroke(at coordinate: CLLocationCoordinate2D) {
        guard selectedTool == .route, let lastCoordinate = routePoints.last else { return }
        let releaseDistance = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        if releaseDistance > 0.25 {
            routePoints.append(coordinate)
        }

        guard let endpointIndex = routePoints.indices.last else { return }
        if routeWaypointIndices.insert(endpointIndex).inserted {
            namedRouteWaypoints.append(NamedRouteWaypoint(
                routePointIndex: endpointIndex,
                name: "Waypoint \(namedRouteWaypoints.count + 1)"
            ))
        }
        routeGeometryDidChange()
    }

    func beginMeasurementStroke(at coordinate: CLLocationCoordinate2D) {
        guard selectedTool == .measure else { return }
        measurePoints.append(coordinate)
        measurementRevision = UUID()
    }

    func continueMeasurementStroke(to coordinate: CLLocationCoordinate2D) {
        guard selectedTool == .measure else { return }
        measurePoints.append(coordinate)
        measurementRevision = UUID()
    }

    func finishMeasurementStroke(at coordinate: CLLocationCoordinate2D) {
        guard selectedTool == .measure, let lastCoordinate = measurePoints.last else { return }
        let releaseDistance = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        if releaseDistance > 0.25 {
            measurePoints.append(coordinate)
        }
        measurementRevision = UUID()
    }

    private func prepareRouteForEditing() {
        cancelActiveHike()
        if routePoints.isEmpty {
            currentRouteID = UUID()
            currentRouteCreatedAt = .now
            currentRouteName = "Untitled Route"
        }
        routeProgress = 0
    }

    func clearActiveDrawing() {
        switch selectedTool {
        case .measure:
            measurePoints.removeAll()
            measurementRevision = UUID()
        case .route:
            guard !routePoints.isEmpty else { return }
            recordRouteEdit()
            routePoints.removeAll()
            routeWaypointIndices.removeAll()
            namedRouteWaypoints.removeAll()
            routeGeometryDidChange(shouldRefresh: false)
        default: break
        }
    }

    func beginOfflineSelection() {
        showOfflineMaps = false
        showLayers = false
        selectedTool = .explore
        isSelectingOfflineArea = true
        offlineSelectionPoints.removeAll()
        offlineSelectionRevision = UUID()
        offlineDraft = nil
    }

    func updateOfflineSelection(_ points: [CLLocationCoordinate2D]) {
        guard isSelectingOfflineArea else { return }
        offlineSelectionPoints = points
        offlineSelectionRevision = UUID()
        offlineDraft = nil
    }

    func finishOfflineSelection(_ points: [CLLocationCoordinate2D]) {
        guard isSelectingOfflineArea else { return }
        offlineSelectionPoints = points
        offlineSelectionRevision = UUID()
        offlineDraft = offline.draft(for: points)
    }

    func cancelOfflineSelection() {
        isSelectingOfflineArea = false
        offlineSelectionPoints.removeAll()
        offlineSelectionRevision = UUID()
        offlineDraft = nil
    }

    func downloadOfflineSelection() {
        guard let offlineDraft, offline.canDownload(offlineDraft) else { return }
        offline.download(offlineDraft)
        cancelOfflineSelection()
        showOfflineMaps = true
    }

    func currentRoutePlan(named name: String? = nil) -> RoutePlan {
        RoutePlan(
            id: currentRouteID,
            name: name ?? currentRouteName,
            coordinates: routePoints,
            distanceMeters: routeDistance,
            elevationGainMeters: routeElevationGainMeters,
            elevationProfileMeters: routeElevationProfile.isEmpty ? nil : routeElevationProfile,
            elevationProfileProvider: currentElevationProfileProvider,
            routeWaypointIndices: routeWaypointIndices.sorted(),
            namedWaypoints: namedRouteWaypoints,
            pins: pins,
            createdAt: currentRouteCreatedAt
        )
    }

    @discardableResult
    func saveCurrentRoute(named name: String? = nil) -> RoutePlan {
        let requestedName = name ?? currentRouteName
        let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = currentRoutePlan(named: trimmedName.isEmpty ? "Untitled Route" : trimmedName)
        currentRouteName = plan.name
        routes.save(plan)
        return plan
    }

    func normalizeCurrentRouteName() {
        let trimmedName = currentRouteName.trimmingCharacters(in: .whitespacesAndNewlines)
        currentRouteName = trimmedName.isEmpty ? "Untitled Route" : trimmedName
    }

    func loadRoute(_ plan: RoutePlan) {
        cancelActiveHike()
        routeFitTask?.cancel()
        isFittingRoute = false
        resetRouteEditHistory()
        isRouteFitted = false
        routeFitError = nil
        currentRouteName = plan.name
        currentRouteID = plan.id
        currentRouteCreatedAt = plan.createdAt
        routePoints = plan.coordinates
        routeElevationProbes.removeAll()
        currentElevationGainMeters = plan.elevationGainMeters
        currentRouteElevationProfileMeters = plan.elevationProfileMeters
        currentElevationProfileProvider = plan.elevationProfileProvider
        routeWaypointIndices = Set(plan.routeWaypointIndices ?? plan.coordinates.indices.map { $0 })
        namedRouteWaypoints = plan.namedWaypoints?.filter { plan.coordinates.indices.contains($0.routePointIndex) }
            ?? routeWaypointIndices.sorted().enumerated().map {
                NamedRouteWaypoint(routePointIndex: $0.element, name: "Waypoint \($0.offset + 1)")
            }
        if let routePins = plan.pins {
            pins = Dictionary(
                (pins + routePins).map { ($0.id, $0) },
                uniquingKeysWith: { savedPin, _ in savedPin }
            ).values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            persistPins()
        }
        selectedPinID = nil
        routeProgress = 0
        distanceFromRouteMeters = nil
        selectedTool = .explore
        routeRevision = UUID()
        annotationRevision = UUID()
        focusMap(on: plan.coordinates)
        refreshElevationProfileIfNeeded()
    }

    func createRouteFromTrail(
        named name: String?,
        coordinates: [CLLocationCoordinate2D],
        startingAt startName: String? = nil
    ) {
        guard coordinates.count > 1 else { return }
        resetRouteEditHistory()
        isRouteFitted = false
        cancelActiveHike()
        elevationTask?.cancel()
        currentRouteID = UUID()
        currentRouteCreatedAt = .now
        currentRouteName = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Trail Route"
        routePoints = coordinates
        routeWaypointIndices = [coordinates.startIndex, coordinates.index(before: coordinates.endIndex)]
        namedRouteWaypoints = [
            NamedRouteWaypoint(
                routePointIndex: coordinates.startIndex,
                name: startName ?? "Start",
                kind: startName == nil ? .standard : .trailhead
            ),
            NamedRouteWaypoint(routePointIndex: coordinates.index(before: coordinates.endIndex), name: "End")
        ]
        annotationRevision = UUID()
        selectedPinID = nil
        routeProgress = 0
        distanceFromRouteMeters = nil
        selectedTool = .explore
        focusMap(on: coordinates)
        routeGeometryDidChange()
    }

    func fitCurrentRouteToTrails() {
        guard hasActiveRoute, !isFittingRoute else { return }
        routeFitTask?.cancel()
        let originalRoute = routePoints
        let originalRevision = routeRevision
        let originalNamedWaypoints = namedRouteWaypoints
        let originalWaypointIndices = routeWaypointIndices
        let originalWasFitted = isRouteFitted
        let boundary = originalRoute.map(RouteWaypoint.init)
        guard let bounds = TrailViewport(boundary: boundary) else { return }
        // Fit-to-trail may need geometry well outside a straight sketch to
        // capture switchbacks. This wider request is used only on explicit fit.
        let latitudePadding = max(0.012, (bounds.north - bounds.south) * 0.35)
        let longitudePadding = max(0.012, (bounds.east - bounds.west) * 0.35)
        let viewport = TrailViewport(
            south: max(-85, bounds.south - latitudePadding),
            west: max(-180, bounds.west - longitudePadding),
            north: min(85, bounds.north + latitudePadding),
            east: min(180, bounds.east + longitudePadding)
        )

        isFittingRoute = true
        routeFitError = nil
        routeFitTask = Task { [weak self] in
            async let primaryRequest = try? TrailDataService.shared.trailFeatures(in: viewport)
            async let forestRequest = try? TrailDataService.shared.forestServiceTrailFeatures(in: viewport)
            let (primary, forest) = await (primaryRequest, forestRequest)
            do {
                try Task.checkCancellation()
                let features = (primary?.trails ?? []) + (forest ?? [])
                let match = try await Task.detached(priority: .userInitiated) {
                    try TrailRouteFitter.fit(
                        route: originalRoute,
                        to: features,
                        waypointIndices: originalWaypointIndices.sorted()
                    )
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                guard self.routeRevision == originalRevision else {
                    self.isFittingRoute = false
                    return
                }

                let snapshot = RouteGeometrySnapshot(
                    points: originalRoute,
                    waypointIndices: originalWaypointIndices,
                    namedWaypoints: originalNamedWaypoints,
                    isFitted: originalWasFitted
                )
                let originalWaypoints = Dictionary(uniqueKeysWithValues: originalNamedWaypoints.map {
                    ($0.routePointIndex, $0)
                })
                let waypointCoordinates = originalWaypointIndices.compactMap { index -> (Int, CLLocationCoordinate2D)? in
                    guard originalRoute.indices.contains(index) else { return nil }
                    return (index, originalRoute[index])
                }
                var usedIndices = Set<Int>()
                let remappedWaypoints = waypointCoordinates.compactMap { originalIndex, coordinate -> NamedRouteWaypoint? in
                    let availableIndices = match.coordinates.indices.filter { candidateIndex in
                        !usedIndices.contains(candidateIndex)
                    }
                    guard let index = availableIndices.min(by: { lhs, rhs in
                        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(
                            from: CLLocation(
                                latitude: match.coordinates[lhs].latitude,
                                longitude: match.coordinates[lhs].longitude
                            )
                        ) < CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(
                            from: CLLocation(
                                latitude: match.coordinates[rhs].latitude,
                                longitude: match.coordinates[rhs].longitude
                            )
                        )
                    }), usedIndices.insert(index).inserted else { return nil }
                    var waypoint = originalWaypoints[originalIndex]
                        ?? NamedRouteWaypoint(routePointIndex: originalIndex, name: "Waypoint")
                    waypoint.routePointIndex = index
                    return waypoint
                }

                self.pushRouteUndoSnapshot(snapshot)
                self.routePoints = match.coordinates
                self.routeWaypointIndices = Set(remappedWaypoints.map(\.routePointIndex))
                self.namedRouteWaypoints = remappedWaypoints
                if self.routeWaypointIndices.isEmpty {
                    self.routeWaypointIndices = [match.coordinates.startIndex, match.coordinates.index(before: match.coordinates.endIndex)]
                    self.namedRouteWaypoints = [
                        NamedRouteWaypoint(routePointIndex: match.coordinates.startIndex, name: "Start"),
                        NamedRouteWaypoint(routePointIndex: match.coordinates.index(before: match.coordinates.endIndex), name: "End")
                    ]
                }
                self.routeGeometryDidChange()
                self.isRouteFitted = true
                self.persistCurrentRouteIfSaved()
                self.focusMap(on: match.coordinates)
                self.isFittingRoute = false
            } catch is CancellationError {
                self?.isFittingRoute = false
            } catch {
                guard let self else { return }
                guard self.routeRevision == originalRevision else {
                    self.isFittingRoute = false
                    return
                }
                self.isFittingRoute = false
                self.routeFitError = error.localizedDescription
            }
        }
    }

    func undoRouteEdit() {
        guard let snapshot = routeUndoHistory.popLast() else { return }
        routeRedoHistory.append(currentRouteGeometrySnapshot())
        restoreRouteGeometry(snapshot)
        updateRouteHistoryAvailability()
        persistCurrentRouteIfSaved()
        focusMap(on: routePoints)
    }

    func redoRouteEdit() {
        guard let snapshot = routeRedoHistory.popLast() else { return }
        routeUndoHistory.append(currentRouteGeometrySnapshot())
        restoreRouteGeometry(snapshot)
        updateRouteHistoryAvailability()
        persistCurrentRouteIfSaved()
        focusMap(on: routePoints)
    }

    func focusMap(on coordinates: [CLLocationCoordinate2D], minimumSpan: Double = 0.012) {
        guard !coordinates.isEmpty else { return }
        mapFocusRequest = MapFocusRequest(bounds: MapFocusBounds(
            coordinates: coordinates,
            minimumSpan: minimumSpan
        ))
    }

    func startRouteTracking() {
        guard hasActiveRoute else { return }
        guard !hikeRecorder.isActive else {
            if hikeRecorder.isPaused { resumeHikeTracking() }
            return
        }
        hikeRecorder.startPlanned(route: currentRoutePlan())
        isTracking = true
        location.beginHikeTracking()
        if let location = location.location {
            hikeRecorder.ingest(location)
            updateTrackingPosition(location)
        }
    }

    func startFreeRecording() {
        guard !hikeRecorder.isActive else { return }
        routeFitTask?.cancel()
        elevationTask?.cancel()
        resetRouteEditHistory()
        routePoints.removeAll()
        routeWaypointIndices.removeAll()
        namedRouteWaypoints.removeAll()
        routeRevision = UUID()
        annotationRevision = UUID()
        currentRouteID = UUID()
        currentRouteCreatedAt = .now
        currentRouteName = "Recorded Hike"
        currentRouteElevationProfileMeters = nil
        currentElevationProfileProvider = nil
        routeProgress = 0
        distanceFromRouteMeters = nil
        selectedTool = .explore
        hikeRecorder.startFreeRecording()
        isTracking = true
        location.beginHikeTracking()
        if let current = location.location {
            hikeRecorder.ingest(current)
            appendRecordedRoutePoint(current.coordinate)
        }
    }

    func pauseHikeTracking() {
        guard hikeRecorder.isActive, !hikeRecorder.isPaused else { return }
        hikeRecorder.pause()
    }

    func resumeHikeTracking() {
        guard hikeRecorder.isPaused else { return }
        hikeRecorder.resume()
    }

    func addTrackingSplit() {
        guard let split = hikeRecorder.addManualSplit(),
              let coordinate = split.coordinate?.coordinate else { return }
        if hikeRecorder.mode == .freeRecording {
            if routePoints.isEmpty { routePoints.append(coordinate) }
            let index = max(0, routePoints.count - 1)
            routeWaypointIndices.insert(index)
            namedRouteWaypoints.append(NamedRouteWaypoint(
                routePointIndex: index,
                name: split.name,
                kind: .standard
            ))
            routeRevision = UUID()
            annotationRevision = UUID()
        }
    }

    func endRouteTracking() {
        guard hikeRecorder.isActive else {
            isTracking = false
            distanceFromRouteMeters = nil
            return
        }
        let recordedPlan: RoutePlan
        if hikeRecorder.mode == .freeRecording {
            if let lastIndex = routePoints.indices.last,
               !routeWaypointIndices.contains(lastIndex) {
                routeWaypointIndices.insert(lastIndex)
                namedRouteWaypoints.append(NamedRouteWaypoint(routePointIndex: lastIndex, name: "Finish"))
                annotationRevision = UUID()
            }
            normalizeCurrentRouteName()
            recordedPlan = currentRoutePlan()
        } else {
            recordedPlan = currentRoutePlan()
        }
        if let hike = hikeRecorder.finish(recordedRoute: recordedPlan) {
            completedHike = hike
        }
        location.endHikeTracking()
        isTracking = false
        distanceFromRouteMeters = nil
    }

    func saveCompletedHike() {
        guard let completedHike else { return }
        hikes.save(completedHike)
        self.completedHike = nil
    }

    func discardCompletedHike() {
        completedHike = nil
    }

    func cancelActiveHike() {
        hikeRecorder.cancel()
        location.endHikeTracking()
        isTracking = false
        distanceFromRouteMeters = nil
    }

    func clearActiveRoute() {
        cancelActiveHike()
        routeFitTask?.cancel()
        isFittingRoute = false
        resetRouteEditHistory()
        isRouteFitted = false
        routeFitError = nil
        routePoints.removeAll()
        routeElevationProbes.removeAll()
        routeWaypointIndices.removeAll()
        namedRouteWaypoints.removeAll()
        routeRevision = UUID()
        annotationRevision = UUID()
        selectedPinID = nil
        currentRouteName = "No active route"
        currentRouteID = UUID()
        currentRouteCreatedAt = .now
        currentElevationGainMeters = 0
        currentRouteElevationProfileMeters = nil
        currentElevationProfileProvider = nil
        elevationProfileError = nil
        isLoadingElevationProfile = false
        elevationTask?.cancel()
        routeProgress = 0
        selectedTool = .explore
    }

    private func updateTrackingPosition(_ location: CLLocation) {
        guard hikeRecorder.mode == .plannedRoute,
              let position = RouteMath.position(location: location.coordinate, along: routePoints) else {
            distanceFromRouteMeters = nil
            return
        }
        routeProgress = max(routeProgress, position.progress)
        distanceFromRouteMeters = position.distanceFromRoute
    }

    private func appendRecordedRoutePoint(_ coordinate: CLLocationCoordinate2D) {
        if routePoints.isEmpty {
            routePoints.append(coordinate)
            routeWaypointIndices.insert(0)
            namedRouteWaypoints.append(NamedRouteWaypoint(routePointIndex: 0, name: "Start"))
        } else {
            routePoints.append(coordinate)
        }
        routeRevision = UUID()
        annotationRevision = UUID()
    }

    func setWaypointName(id: UUID, name: String) {
        guard let index = namedRouteWaypoints.firstIndex(where: { $0.id == id }) else { return }
        namedRouteWaypoints[index].name = name
        persistCurrentRouteIfSaved()
    }

    func normalizeWaypointName(id: UUID) {
        guard let index = namedRouteWaypoints.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = namedRouteWaypoints[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let orderedIndex = namedRouteWaypoints.sorted { $0.routePointIndex < $1.routePointIndex }
                .firstIndex(where: { $0.id == id }) ?? index
            namedRouteWaypoints[index].name = "Waypoint \(orderedIndex + 1)"
        } else {
            namedRouteWaypoints[index].name = trimmed
        }
        persistCurrentRouteIfSaved()
    }

    func setWaypointNote(id: UUID, note: String) {
        guard let index = namedRouteWaypoints.firstIndex(where: { $0.id == id }) else { return }
        namedRouteWaypoints[index].note = note.isEmpty ? nil : note
        persistCurrentRouteIfSaved()
    }

    func removeWaypoint(id: UUID) {
        let ordered = namedRouteWaypoints
            .filter { routePoints.indices.contains($0.routePointIndex) }
            .sorted { $0.routePointIndex < $1.routePointIndex }
        guard let position = ordered.firstIndex(where: { $0.id == id }),
              let storedIndex = namedRouteWaypoints.firstIndex(where: { $0.id == id }) else { return }

        recordRouteEdit()
        namedRouteWaypoints.remove(at: storedIndex)
        routeWaypointIndices.remove(ordered[position].routePointIndex)

        if ordered.count > 1, position == ordered.startIndex {
            let newStart = ordered[position + 1].routePointIndex
            routePoints.removeFirst(newStart)
            for index in namedRouteWaypoints.indices {
                namedRouteWaypoints[index].routePointIndex -= newStart
            }
        } else if ordered.count > 1, position == ordered.index(before: ordered.endIndex) {
            let newEnd = ordered[position - 1].routePointIndex
            routePoints.removeSubrange(routePoints.index(after: newEnd)..<routePoints.endIndex)
        }

        routeWaypointIndices = Set(namedRouteWaypoints.compactMap {
            routePoints.indices.contains($0.routePointIndex) ? $0.routePointIndex : nil
        })
        routeGeometryDidChange()
        persistCurrentRouteIfSaved()
    }

    func reverseRoute() {
        guard routePoints.count > 1 else { return }
        recordRouteEdit()
        let lastIndex = routePoints.index(before: routePoints.endIndex)
        routePoints.reverse()
        for index in namedRouteWaypoints.indices {
            namedRouteWaypoints[index].routePointIndex = lastIndex - namedRouteWaypoints[index].routePointIndex
        }
        routeWaypointIndices = Set(namedRouteWaypoints.map(\.routePointIndex))
        routeGeometryDidChange()
        persistCurrentRouteIfSaved()
        focusMap(on: routePoints)
    }

    var selectedPin: RoutePin? {
        guard let selectedPinID else { return nil }
        return pins.first { $0.id == selectedPinID }
    }

    func selectPin(id: UUID) {
        guard pins.contains(where: { $0.id == id }) else { return }
        selectedOutdoorPoint = nil
        selectedPinID = id
        refreshPinElevation(id: id)
    }

    func selectOutdoorPoint(_ point: OutdoorPointFeature) {
        selectedPinID = nil
        selectedOutdoorPoint = point
    }

    func dismissOutdoorPoint() {
        selectedOutdoorPoint = nil
    }

    func setPinTitle(id: UUID, title: String) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[index].title = title
        annotationRevision = UUID()
        for waypointIndex in namedRouteWaypoints.indices
        where namedRouteWaypoints[waypointIndex].resolvedKind == .pin
            && namedRouteWaypoints[waypointIndex].sourceID == id.uuidString {
            namedRouteWaypoints[waypointIndex].name = title
        }
        persistPins()
        persistCurrentRouteIfSaved()
    }

    func normalizePinTitle(id: UUID) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = pins[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
        setPinTitle(id: id, title: trimmed.isEmpty ? "Untitled Pin" : trimmed)
    }

    func setPinNote(id: UUID, note: String) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[index].note = note
        for waypointIndex in namedRouteWaypoints.indices
        where namedRouteWaypoints[waypointIndex].resolvedKind == .pin
            && namedRouteWaypoints[waypointIndex].sourceID == id.uuidString {
            namedRouteWaypoints[waypointIndex].note = note.isEmpty ? nil : note
        }
        persistPins()
        persistCurrentRouteIfSaved()
    }

    func updatePin(
        id: UUID,
        title: String,
        note: String,
        color: RoutePinColor,
        symbol: RoutePinSymbol
    ) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        pins[index].title = resolvedTitle.isEmpty ? "Untitled Pin" : resolvedTitle
        pins[index].note = note
        pins[index].color = color
        pins[index].symbol = symbol
        for waypointIndex in namedRouteWaypoints.indices
        where namedRouteWaypoints[waypointIndex].resolvedKind == .pin
            && namedRouteWaypoints[waypointIndex].sourceID == id.uuidString {
            namedRouteWaypoints[waypointIndex].name = pins[index].title
            namedRouteWaypoints[waypointIndex].note = note.isEmpty ? nil : note
        }
        annotationRevision = UUID()
        persistPins()
        persistCurrentRouteIfSaved()
    }

    func refreshPinElevation(id: UUID) {
        guard let pin = pins.first(where: { $0.id == id }),
              pin.elevationMeters == nil,
              pinElevationTasks[id] == nil else { return }
        objectWillChange.send()
        pinElevationTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.objectWillChange.send()
                self.pinElevationTasks[id] = nil
            }
            guard let elevation = try? await self.elevationService.elevation(at: pin.coordinate),
                  !Task.isCancelled,
                  let index = self.pins.firstIndex(where: { $0.id == id }) else { return }
            self.pins[index].elevationMeters = elevation
            self.annotationRevision = UUID()
            self.persistPins()
            self.persistCurrentRouteIfSaved()
        }
    }

    func isLoadingPinElevation(id: UUID) -> Bool {
        pinElevationTasks[id] != nil
    }

    func removePin(id: UUID) {
        pinElevationTasks[id]?.cancel()
        pinElevationTasks[id] = nil
        pins.removeAll { $0.id == id }
        annotationRevision = UUID()
        if selectedPinID == id { selectedPinID = nil }
        persistPins()
        persistCurrentRouteIfSaved()
    }

    func dismissPinEditor() {
        if let selectedPinID { normalizePinTitle(id: selectedPinID) }
        self.selectedPinID = nil
    }

    func refreshElevationProfileIfNeeded() {
        guard hasActiveRoute else { return }
        guard currentElevationProfileProvider != ElevationService.providerID || routeElevationProfile.isEmpty else { return }
        refreshElevationProfile()
    }

    func refreshElevationProfile() {
        scheduleElevationRefresh(delayNanoseconds: 0)
    }

    private func routeGeometryDidChange(
        shouldRefresh: Bool = true,
        isLiveEdit: Bool = false
    ) {
        routeFitTask?.cancel()
        if isFittingRoute { isFittingRoute = false }
        if isRouteFitted { isRouteFitted = false }
        routeRevision = UUID()
        if !isLiveEdit { annotationRevision = UUID() }
        if !routeElevationProbes.isEmpty { routeElevationProbes.removeAll() }
        if currentElevationGainMeters != 0 { currentElevationGainMeters = 0 }
        if currentRouteElevationProfileMeters != nil { currentRouteElevationProfileMeters = nil }
        if currentElevationProfileProvider != nil { currentElevationProfileProvider = nil }
        if elevationProfileError != nil { elevationProfileError = nil }
        if isLiveEdit {
            elevationTask?.cancel()
            if isLoadingElevationProfile { isLoadingElevationProfile = false }
        }
        if shouldRefresh, hasActiveRoute {
            scheduleElevationRefresh(delayNanoseconds: 650_000_000)
        }
    }

    private func currentRouteGeometrySnapshot() -> RouteGeometrySnapshot {
        RouteGeometrySnapshot(
            points: routePoints,
            waypointIndices: routeWaypointIndices,
            namedWaypoints: namedRouteWaypoints,
            isFitted: isRouteFitted
        )
    }

    private func recordRouteEdit() {
        pushRouteUndoSnapshot(currentRouteGeometrySnapshot())
    }

    private func pushRouteUndoSnapshot(_ snapshot: RouteGeometrySnapshot) {
        routeUndoHistory.append(snapshot)
        if routeUndoHistory.count > 50 {
            routeUndoHistory.removeFirst(routeUndoHistory.count - 50)
        }
        routeRedoHistory.removeAll()
        updateRouteHistoryAvailability()
    }

    private func restoreRouteGeometry(_ snapshot: RouteGeometrySnapshot) {
        routePoints = snapshot.points
        routeWaypointIndices = snapshot.waypointIndices
        namedRouteWaypoints = snapshot.namedWaypoints
        routeGeometryDidChange()
        isRouteFitted = snapshot.isFitted
    }

    private func resetRouteEditHistory() {
        routeUndoHistory.removeAll()
        routeRedoHistory.removeAll()
        updateRouteHistoryAvailability()
    }

    private func updateRouteHistoryAvailability() {
        canUndoRouteEdit = !routeUndoHistory.isEmpty
        canRedoRouteEdit = !routeRedoHistory.isEmpty
    }

    private func persistCurrentRouteIfSaved() {
        guard routes.routes.contains(where: { $0.id == currentRouteID }) else { return }
        routes.save(currentRoutePlan())
    }

    private func scheduleElevationRefresh(delayNanoseconds: UInt64) {
        elevationTask?.cancel()
        guard hasActiveRoute else {
            isLoadingElevationProfile = false
            return
        }
        let revision = routeRevision
        let route = routePoints.map(RouteWaypoint.init)
        isLoadingElevationProfile = true
        elevationProfileError = nil
        elevationTask = Task { [weak self, elevationService] in
            do {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                let result = try await elevationService.profile(for: route)
                try Task.checkCancellation()
                guard let self, self.routeRevision == revision else { return }
                self.currentRouteElevationProfileMeters = result.elevationsMeters
                self.currentElevationGainMeters = result.gainMeters
                self.currentElevationProfileProvider = ElevationService.providerID
                self.isLoadingElevationProfile = false
                self.elevationProfileError = nil
                self.annotationRevision = UUID()
                if self.routes.routes.contains(where: { $0.id == self.currentRouteID }) {
                    self.routes.save(self.currentRoutePlan())
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.routeRevision == revision else { return }
                self.isLoadingElevationProfile = false
                self.elevationProfileError = error.localizedDescription
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
