import MapKit
import SwiftUI

@MainActor
struct AtlasMapView {
    @EnvironmentObject private var state: AppState
    @Binding var command: MapCommand?

    fileprivate func makeMap(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.setCameraZoomRange(
            MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: 650,
                maxCenterCoordinateDistance: 45_000_000
            ),
            animated: false
        )
        let initialRegion = AppState.storedMapViewport?.region ?? MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
            span: MKCoordinateSpan(latitudeDelta: 18, longitudeDelta: 25)
        )
        map.setRegion(initialRegion, animated: false)
        context.coordinator.installTapGesture(on: map)
        return map
    }

    fileprivate func updateMap(_ map: MKMapView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.applyStyle(
            showTrails: state.showTrails,
            allowsNetwork: state.connectivity.isOnline,
            to: map
        )
        context.coordinator.updateSelectionMode(on: map)
        context.coordinator.updateContent(on: map)
        context.coordinator.updateHeadingIndicator(on: map)

        if let command, command != context.coordinator.lastCommand {
            context.coordinator.lastCommand = command
            switch command.action {
            case .locate:
                if let coordinate = state.location.location?.coordinate {
                    map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1800, longitudinalMeters: 1800), animated: true)
                }
            case .zoom(let factor):
                var region = map.region
                region.span.latitudeDelta = min(170, max(0.0002, region.span.latitudeDelta * factor))
                region.span.longitudeDelta = min(360, max(0.0002, region.span.longitudeDelta * factor))
                map.setRegion(region, animated: true)
            case .focus(let bounds):
                let latitudeSpan = max(0.012, (bounds.north - bounds.south) * 1.32)
                let longitudeSpan = max(0.012, (bounds.east - bounds.west) * 1.32)
                map.setRegion(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: (bounds.north + bounds.south) / 2,
                        longitude: (bounds.east + bounds.west) / 2
                    ),
                    span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
                ), animated: true)
            }
        } else if command == nil {
            context.coordinator.lastCommand = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var owner: AtlasMapView
        var lastCommand: MapCommand?
        private var appliedTrails = false
        private var appliedNetworkAccess: Bool?
        private var trailLoadTask: Task<Void, Never>?
        private var trailLoadGeneration = UUID()
        private var loadedTrailDataset = TrailMapDataset(trails: [], points: [])
        private var hasObservedInitialRegion = false
        private var lassoCoordinates: [CLLocationCoordinate2D] = []
        private var lastDrawingStrokePoint: CGPoint?
        private var headingConeAnnotation: HeadingConeAnnotation?
        #if os(iOS)
        private weak var lassoGesture: UIPanGestureRecognizer?
        private weak var routeDrawGesture: UILongPressGestureRecognizer?
        #else
        private weak var lassoGesture: NSPanGestureRecognizer?
        private weak var routeDrawGesture: NSPanGestureRecognizer?
        #endif

        init(owner: AtlasMapView) { self.owner = owner }

        func applyStyle(showTrails: Bool, allowsNetwork: Bool, to map: MKMapView) {
            guard appliedTrails != showTrails || appliedNetworkAccess != allowsNetwork else { return }
            map.removeOverlays(map.overlays.filter { $0 is CachedTileOverlay })
            map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
            let topo = CachedTileOverlay(
                kind: .topographic,
                urlTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
                allowsNetwork: allowsNetwork,
                storesNetworkTiles: false,
                sourceMaximumZoom: 16
            )
            topo.canReplaceMapContent = true
            topo.minimumZ = 0
            // USGSTopo's cache schema lists higher LOD slots, but its
            // published maxScale (1:9,027) contains native imagery only
            // through z16. CachedTileOverlay crops the correct z16 parent
            // tile for closer views so the basemap never disappears.
            topo.maximumZ = 19
            map.addOverlay(topo, level: .aboveRoads)

            appliedTrails = showTrails
            appliedNetworkAccess = allowsNetwork
            if showTrails {
                scheduleTrailRefresh(on: map)
            } else {
                trailLoadTask?.cancel()
                clearTrailContent(on: map)
            }
        }

        func updateSelectionMode(on map: MKMapView) {
            let isSelecting = owner.state.isSelectingOfflineArea
            map.isScrollEnabled = !isSelecting
            map.isZoomEnabled = !isSelecting
            map.isRotateEnabled = !isSelecting
            map.isPitchEnabled = !isSelecting
            lassoGesture?.isEnabled = isSelecting
            let supportsDrawing = owner.state.selectedTool == .route || owner.state.selectedTool == .measure
            routeDrawGesture?.isEnabled = !isSelecting && supportsDrawing
            #if os(macOS)
            map.isScrollEnabled = !isSelecting && !supportsDrawing
            #endif
        }

        func updateContent(on map: MKMapView) {
            map.removeOverlays(map.overlays.filter { $0 is MKPolyline && !($0 is TrailPolyline) })
            map.removeOverlays(map.overlays.filter { $0 is OfflineSelectionPolygon })
            if owner.state.routePoints.count > 1 {
                map.addOverlay(MKPolyline(coordinates: owner.state.routePoints, count: owner.state.routePoints.count), level: .aboveLabels)
            }
            if owner.state.measurePoints.count > 1 {
                let measurement = MeasurementPolyline(coordinates: owner.state.measurePoints, count: owner.state.measurePoints.count)
                map.addOverlay(measurement, level: .aboveLabels)
            }

            if owner.state.offlineSelectionPoints.count > 2 {
                let polygon = OfflineSelectionPolygon(
                    coordinates: owner.state.offlineSelectionPoints,
                    count: owner.state.offlineSelectionPoints.count
                )
                map.addOverlay(polygon, level: .aboveLabels)
            } else if owner.state.offlineSelectionPoints.count > 1 {
                let line = OfflineSelectionPolyline(
                    coordinates: owner.state.offlineSelectionPoints,
                    count: owner.state.offlineSelectionPoints.count
                )
                map.addOverlay(line, level: .aboveLabels)
            }

            syncUserAnnotations(on: map)
        }

        func updateHeadingIndicator(on map: MKMapView) {
            guard let location = owner.state.location.location else {
                if let headingConeAnnotation {
                    map.removeAnnotation(headingConeAnnotation)
                    self.headingConeAnnotation = nil
                }
                return
            }

            let annotation: HeadingConeAnnotation
            if let existing = headingConeAnnotation {
                annotation = existing
                annotation.coordinate = location.coordinate
            } else {
                annotation = HeadingConeAnnotation(coordinate: location.coordinate)
                headingConeAnnotation = annotation
                map.addAnnotation(annotation)
            }
            annotation.headingDegrees = owner.state.location.headingDegrees
            if let view = map.view(for: annotation) as? HeadingConeView {
                view.setHeading(annotation.headingDegrees)
            }
        }

        private func syncUserAnnotations(on map: MKMapView) {
            let routedPinIDs = Set(owner.state.namedRouteWaypoints.compactMap { waypoint -> UUID? in
                guard waypoint.resolvedKind == .pin,
                      let sourceID = waypoint.sourceID else { return nil }
                return UUID(uuidString: sourceID)
            })
            let desiredPins = owner.state.pins.filter { !routedPinIDs.contains($0.id) }
            let desiredPinIDs = Set(desiredPins.map(\.id))
            let existingPins = map.annotations.compactMap { $0 as? RoutePinAnnotation }
            map.removeAnnotations(existingPins.filter { !desiredPinIDs.contains($0.id) })

            let pinsByID = Dictionary(uniqueKeysWithValues: existingPins.map { ($0.id, $0) })
            for pin in desiredPins {
                if let annotation = pinsByID[pin.id] {
                    annotation.coordinate = pin.coordinate
                    annotation.title = pin.title
                } else {
                    map.addAnnotation(RoutePinAnnotation(
                        id: pin.id,
                        coordinate: pin.coordinate,
                        title: pin.title
                    ))
                }
            }

            let desiredWaypoints = owner.state.routeWaypointIndices.sorted().enumerated().compactMap { sequence, index -> RouteWaypointAnnotation? in
                guard owner.state.routePoints.indices.contains(index) else { return nil }
                let waypoint = owner.state.namedRouteWaypoints.first { $0.routePointIndex == index }
                return RouteWaypointAnnotation(
                    coordinate: owner.state.routePoints[index],
                    sequence: sequence + 1,
                    routePointIndex: index,
                    waypointID: waypoint?.id,
                    kind: waypoint?.resolvedKind ?? .standard
                )
            }
            let existingWaypoints = map.annotations.compactMap { $0 as? RouteWaypointAnnotation }
            var unmatchedExisting = existingWaypoints
            var additions: [RouteWaypointAnnotation] = []

            for desired in desiredWaypoints {
                let matchIndex = unmatchedExisting.firstIndex { existing in
                    if let waypointID = desired.waypointID {
                        return existing.waypointID == waypointID
                    }
                    return existing.waypointID == nil
                        && existing.routePointIndex == desired.routePointIndex
                }
                guard let matchIndex else {
                    additions.append(desired)
                    continue
                }

                let existing = unmatchedExisting.remove(at: matchIndex)
                existing.coordinate = desired.coordinate
                existing.sequence = desired.sequence
                existing.routePointIndex = desired.routePointIndex
                existing.kind = desired.kind
                if let view = map.view(for: existing) as? RouteWaypointView {
                    view.setAppearance(sequence: existing.sequence, kind: existing.kind)
                }
            }

            if !unmatchedExisting.isEmpty {
                map.removeAnnotations(unmatchedExisting)
            }
            if !additions.isEmpty {
                map.addAnnotations(additions)
            }

            let probeSummaries = owner.state.routeElevationProbeSummaries
            let desiredProbeIDs = Set(probeSummaries.map(\.id))
            let existingProbes = map.annotations.compactMap { $0 as? RouteElevationProbeAnnotation }
            map.removeAnnotations(existingProbes.filter { !desiredProbeIDs.contains($0.id) })
            let probesByID = Dictionary(uniqueKeysWithValues: existingProbes.map { ($0.id, $0) })
            for (index, probe) in probeSummaries.enumerated() {
                if let annotation = probesByID[probe.id] {
                    annotation.coordinate = probe.coordinate
                    annotation.label = probe.label
                    annotation.elevationMeters = probe.elevationMeters
                    if let view = map.view(for: annotation) as? MKMarkerAnnotationView {
                        configureElevationProbeView(view, annotation: annotation, index: index)
                    }
                } else {
                    map.addAnnotation(RouteElevationProbeAnnotation(
                        id: probe.id,
                        coordinate: probe.coordinate,
                        label: probe.label,
                        elevationMeters: probe.elevationMeters
                    ))
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let headingCone = annotation as? HeadingConeAnnotation {
                let reuseIdentifier = "atlas-heading-cone"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? HeadingConeView)
                    ?? HeadingConeView(annotation: headingCone, reuseIdentifier: reuseIdentifier)
                view.annotation = headingCone
                view.setHeading(headingCone.headingDegrees)
                return view
            }
            if let contour = annotation as? ContourLabelAnnotation {
                let reuseIdentifier = "atlas-contour-label"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? ContourLabelView)
                    ?? ContourLabelView(annotation: contour, reuseIdentifier: reuseIdentifier)
                view.annotation = contour
                view.setValue(contour.value)
                return view
            }
            if let trailName = annotation as? TrailNameAnnotation {
                let reuseIdentifier = "atlas-trail-name"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? TrailNameView)
                    ?? TrailNameView(annotation: trailName, reuseIdentifier: reuseIdentifier)
                view.annotation = trailName
                view.setTitle(trailName.name)
                view.displayPriority = trailName.importance == .major ? .defaultHigh : .defaultLow
                return view
            }
            if let outdoorPoint = annotation as? OutdoorPointAnnotation,
               let feature = loadedTrailDataset.points.first(where: { $0.id == outdoorPoint.featureID }) {
                let reuseIdentifier = "atlas-outdoor-point"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: outdoorPoint, reuseIdentifier: reuseIdentifier)
                view.annotation = outdoorPoint
                view.markerTintColor = markerColor(for: feature.kind)
                view.glyphImage = PlatformImage.atlasSymbol(named: feature.kind.symbol)
                view.titleVisibility = .visible
                view.canShowCallout = false
                view.displayPriority = feature.kind == .trailhead || feature.kind == .peak ? .defaultHigh : .defaultLow
                return view
            }
            if let pin = annotation as? RoutePinAnnotation {
                let reuseIdentifier = "atlas-route-pin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: reuseIdentifier)
                view.annotation = pin
                view.markerTintColor = PlatformColor(red: 0.08, green: 0.48, blue: 0.96, alpha: 1)
                view.glyphText = "•"
                view.canShowCallout = false
                view.displayPriority = .required
                return view
            }
            if let probe = annotation as? RouteElevationProbeAnnotation {
                let reuseIdentifier = "atlas-elevation-probe"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: probe, reuseIdentifier: reuseIdentifier)
                view.annotation = probe
                let index = owner.state.routeElevationProbeSummaries.firstIndex { $0.id == probe.id } ?? 0
                configureElevationProbeView(view, annotation: probe, index: index)
                return view
            }
            guard let waypoint = annotation as? RouteWaypointAnnotation else { return nil }
            let reuseIdentifier = "atlas-route-waypoint"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? RouteWaypointView)
                ?? RouteWaypointView(annotation: waypoint, reuseIdentifier: reuseIdentifier)
            view.annotation = waypoint
            view.setAppearance(sequence: waypoint.sequence, kind: waypoint.kind)
            view.isDraggable = true
            return view
        }

        private func configureElevationProbeView(
            _ view: MKMarkerAnnotationView,
            annotation: RouteElevationProbeAnnotation,
            index: Int
        ) {
            view.markerTintColor = index == 0
                ? PlatformColor(red: 0.08, green: 0.48, blue: 0.96, alpha: 1)
                : PlatformColor(red: 0.10, green: 0.52, blue: 0.42, alpha: 1)
            view.glyphText = annotation.label
            view.glyphTintColor = .white
            view.canShowCallout = false
            view.displayPriority = .required
        }

        func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            didChange newState: MKAnnotationView.DragState,
            fromOldState oldState: MKAnnotationView.DragState
        ) {
            guard let waypoint = view.annotation as? RouteWaypointAnnotation else { return }
            switch newState {
            case .ending:
                owner.state.moveRouteWaypoint(at: waypoint.routePointIndex, to: waypoint.coordinate)
                view.dragState = .none
            case .canceling:
                view.dragState = .none
            default:
                break
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if owner.state.selectedTool == .route,
               let waypoint = view.annotation as? RouteWaypointAnnotation,
               let waypointID = waypoint.waypointID {
                owner.state.addExistingWaypointToRoute(id: waypointID)
                mapView.deselectAnnotation(waypoint, animated: false)
                return
            }
            if let pin = view.annotation as? RoutePinAnnotation {
                if owner.state.selectedTool == .route {
                    owner.state.addPinToRoute(id: pin.id)
                    mapView.deselectAnnotation(pin, animated: false)
                } else {
                    owner.state.selectPin(id: pin.id)
                }
                return
            }
            if owner.state.selectedTool == .route,
               let annotation = view.annotation as? OutdoorPointAnnotation,
               let point = loadedTrailDataset.points.first(where: { $0.id == annotation.featureID }) {
                owner.state.addOutdoorPointToRoute(point)
                mapView.deselectAnnotation(annotation, animated: false)
                return
            }
            guard owner.state.selectedTool == .explore else { return }
            if let trailName = view.annotation as? TrailNameAnnotation,
               loadedTrailDataset.trails.contains(where: { $0.id == trailName.featureID }) {
                mapView.deselectAnnotation(trailName, animated: false)
            } else if let annotation = view.annotation as? OutdoorPointAnnotation,
                      let point = loadedTrailDataset.points.first(where: { $0.id == annotation.featureID }) {
                owner.state.selectOutdoorPoint(point)
                mapView.deselectAnnotation(annotation, animated: false)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tile) }
            if let trail = overlay as? TrailPolyline {
                let renderer = MKPolylineRenderer(polyline: trail)
                styleTrailRenderer(renderer, for: trail, on: mapView)
                return renderer
            }
            if let waterway = overlay as? WaterwayPolyline {
                let renderer = MKPolylineRenderer(polyline: waterway)
                renderer.strokeColor = PlatformColor(red: 0.32, green: 0.67, blue: 0.76, alpha: 0.9)
                renderer.lineWidth = waterway.kind == "river" ? 2 : 1.2
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            if let contour = overlay as? TerrainContourPolyline {
                let renderer = MKPolylineRenderer(polyline: contour)
                renderer.strokeColor = PlatformColor(
                    red: contour.isIndex ? 0.39 : 0.45,
                    green: contour.isIndex ? 0.36 : 0.42,
                    blue: contour.isIndex ? 0.29 : 0.35,
                    alpha: contour.isIndex ? 0.46 : 0.20
                )
                renderer.lineWidth = contour.isIndex ? 1.05 : 0.5
                return renderer
            }
            if let polygon = overlay as? OfflineSelectionPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = PlatformColor(red: 0.95, green: 0.31, blue: 0.04, alpha: 0.18)
                renderer.strokeColor = PlatformColor(red: 0.95, green: 0.31, blue: 0.04, alpha: 1)
                renderer.lineWidth = 3
                renderer.lineJoin = .round
                return renderer
            }
            if let line = overlay as? OfflineSelectionPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = PlatformColor(red: 0.95, green: 0.31, blue: 0.04, alpha: 1)
                renderer.lineWidth = 3
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            if let line = overlay as? MeasurementPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = PlatformColor.atlasLabel.withAlphaComponent(0.85)
                renderer.lineWidth = 3
                renderer.lineDashPattern = [7, 6]
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let casing = MKPolylineRenderer(polyline: line)
                casing.strokeColor = PlatformColor(red: 0.95, green: 0.31, blue: 0.04, alpha: 1)
                casing.lineWidth = 6
                casing.lineJoin = .round
                casing.lineCap = .round
                return casing
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if hasObservedInitialRegion {
                owner.state.storeMapViewport(mapView.region)
            } else {
                // MKMapView reports the programmatic startup region as a
                // change. Ignore that one so a first-run neutral fallback
                // does not replace the pending current-location focus.
                hasObservedInitialRegion = true
            }
            guard appliedTrails else { return }
            updateTrailRendererScale(on: mapView)
            scheduleTrailRefresh(on: mapView)
        }

        private func updateTrailRendererScale(on map: MKMapView) {
            for case let trail as TrailPolyline in map.overlays {
                guard let renderer = map.renderer(for: trail) as? MKPolylineRenderer else { continue }
                styleTrailRenderer(renderer, for: trail, on: map)
                renderer.setNeedsDisplay()
            }
        }

        private func styleTrailRenderer(
            _ renderer: MKPolylineRenderer,
            for trail: TrailPolyline,
            on map: MKMapView
        ) {
            let color: PlatformColor = switch trail.source {
            case .openStreetMap:
                PlatformColor(red: 0.37, green: 0.30, blue: 0.21, alpha: 1)
            case .forestService:
                PlatformColor(red: 0.31, green: 0.29, blue: 0.20, alpha: 1)
            }
            let visibleSpan = max(
                map.region.span.latitudeDelta,
                map.region.span.longitudeDelta * 0.65
            )
            // Trail widths are expressed in screen points. Without this
            // compensation they appear progressively bolder as the map
            // shrinks beneath them. A gentle power curve keeps them readable
            // while maintaining comparable emphasis across hiking zooms.
            let zoomScale = min(1.08, max(0.38, pow(0.055 / max(visibleSpan, 0.001), 0.38)))
            let opacityScale = 0.82 + 0.18 * zoomScale

            let baseWidth: CGFloat
            let baseAlpha: CGFloat
            let baseDash: [CGFloat]
            switch trail.importance {
            case .minor:
                baseWidth = 1.05
                baseAlpha = 0.42
                baseDash = [1, 4]
            case .standard:
                baseWidth = 1.45
                baseAlpha = 0.58
                baseDash = [4, 4]
            case .major:
                baseWidth = 1.85
                baseAlpha = 0.72
                baseDash = [10, 5]
            }
            renderer.strokeColor = color.withAlphaComponent(baseAlpha * opacityScale)
            renderer.lineWidth = baseWidth * zoomScale
            renderer.lineDashPattern = baseDash.map { NSNumber(value: Double($0 * zoomScale)) }
            renderer.lineJoin = .round
            renderer.lineCap = .round
        }

        private func scheduleTrailRefresh(on map: MKMapView) {
            trailLoadTask?.cancel()
            guard map.region.span.latitudeDelta <= 0.32, map.region.span.longitudeDelta <= 0.48 else {
                clearTrailContent(on: map)
                return
            }

            let region = map.region
            let latitudePadding = region.span.latitudeDelta * 0.35
            let longitudePadding = region.span.longitudeDelta * 0.35
            let rawViewport = TrailViewport(
                south: max(-85, region.center.latitude - region.span.latitudeDelta / 2 - latitudePadding),
                west: max(-180, region.center.longitude - region.span.longitudeDelta / 2 - longitudePadding),
                north: min(85, region.center.latitude + region.span.latitudeDelta / 2 + latitudePadding),
                east: min(180, region.center.longitude + region.span.longitudeDelta / 2 + longitudePadding)
            )
            let largestSpan = max(region.span.latitudeDelta, region.span.longitudeDelta)
            let gridSize = largestSpan <= 0.08 ? 0.04 : (largestSpan <= 0.28 ? 0.10 : 0.25)
            let viewport = rawViewport.alignedToGrid(cellSize: gridSize)
            let generation = UUID()
            trailLoadGeneration = generation
            trailLoadTask = Task { [weak self, weak map] in
                do {
                    try await Task.sleep(for: .milliseconds(280))
                    let dataset = try await TrailDataService.shared.trailFeatures(in: viewport)
                    try Task.checkCancellation()
                    guard let self, let map, self.trailLoadGeneration == generation, self.appliedTrails else { return }
                    self.applyTrailDataset(dataset, on: map)

                    // The national Forest Service service is useful but often
                    // much slower than OSM. Add it when ready instead of making
                    // the user stare at an empty overlay while it responds.
                    if let forestTrails = try? await TrailDataService.shared.forestServiceTrailFeatures(in: viewport),
                       !forestTrails.isEmpty {
                        try Task.checkCancellation()
                        guard self.trailLoadGeneration == generation, self.appliedTrails else { return }
                        self.applyTrailDataset(
                            TrailMapDataset(
                                trails: dataset.trails + forestTrails,
                                points: dataset.points,
                                waterways: dataset.waterways,
                                contours: dataset.contours
                            ),
                            on: map
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }

        private func applyTrailDataset(_ dataset: TrailMapDataset, on map: MKMapView) {
            clearTrailContent(on: map)
            loadedTrailDataset = dataset

            var longestNamedTrail: [String: TrailMapFeature] = [:]
            for feature in dataset.trails {
                let coordinates = feature.coordinates.map(\.coordinate)
                guard coordinates.count > 1 else { continue }
                let polyline = TrailPolyline(coordinates: coordinates, count: coordinates.count)
                polyline.source = feature.source
                polyline.importance = feature.importance ?? .standard
                polyline.featureID = feature.id
                map.addOverlay(polyline, level: .aboveRoads)

                guard let name = feature.name else { continue }
                if feature.coordinates.count > (longestNamedTrail[name]?.coordinates.count ?? 0) {
                    longestNamedTrail[name] = feature
                }
            }

            let names = longestNamedTrail.compactMap { name, feature -> TrailNameAnnotation? in
                let importance = feature.importance ?? .standard
                guard !feature.coordinates.isEmpty, importance != .minor else { return nil }
                return TrailNameAnnotation(
                    coordinate: feature.coordinates[feature.coordinates.count / 2].coordinate,
                    name: name,
                    featureID: feature.id,
                    importance: importance
                )
            }
            map.addAnnotations(names)
            map.addAnnotations(dataset.points.map {
                OutdoorPointAnnotation(feature: $0)
            })
        }

        private func clearTrailContent(on map: MKMapView) {
            map.removeOverlays(map.overlays.filter {
                $0 is TrailPolyline || $0 is WaterwayPolyline || $0 is TerrainContourPolyline
            })
            map.removeAnnotations(map.annotations.filter {
                $0 is TrailNameAnnotation || $0 is OutdoorPointAnnotation || $0 is ContourLabelAnnotation
            })
            loadedTrailDataset = TrailMapDataset(trails: [], points: [])
        }

        private func activate(feature: TrailMapFeature) {
            owner.state.dismissOutdoorPoint()
            let coordinates = TrailRouteBuilder.connectedCoordinates(
                startingWith: feature,
                among: loadedTrailDataset.trails
            )
            owner.state.createRouteFromTrail(named: feature.name, coordinates: coordinates)
        }

        private func activate(trailhead: OutdoorPointFeature) {
            guard let feature = TrailRouteBuilder.nearestFeature(
                to: trailhead.coordinate.coordinate,
                among: loadedTrailDataset.trails
            ) else { return }
            let connected = TrailRouteBuilder.connectedCoordinates(
                startingWith: feature,
                among: loadedTrailDataset.trails
            )
            let coordinates = TrailRouteBuilder.routeStarting(at: trailhead.coordinate.coordinate, along: connected)
            owner.state.createRouteFromTrail(
                named: feature.name ?? trailhead.name,
                coordinates: coordinates,
                startingAt: trailhead.name
            )
        }

        private func activateTrail(at point: CGPoint, on map: MKMapView) -> Bool {
            guard owner.state.selectedTool == .explore || owner.state.selectedTool == .route else { return false }
            let candidate = map.overlays
                .compactMap { $0 as? TrailPolyline }
                .compactMap { polyline -> (TrailPolyline, CGFloat)? in
                    let distance = screenDistance(from: point, to: polyline, on: map)
                    return distance <= 20 ? (polyline, distance) : nil
                }
                .min { $0.1 < $1.1 }?.0
            guard let candidate,
                  let feature = loadedTrailDataset.trails.first(where: { $0.id == candidate.featureID }) else {
                return false
            }
            if owner.state.selectedTool == .route {
                owner.state.addTrailFeatureToRoute(
                    coordinate: map.convert(point, toCoordinateFrom: map),
                    name: feature.name,
                    sourceID: feature.id
                )
            } else {
                activate(feature: feature)
            }
            return true
        }

        private func trailAnnotationConsumesTap(at point: CGPoint, on map: MKMapView) -> Bool {
            guard owner.state.selectedTool == .explore || owner.state.selectedTool == .route else { return false }
            let hit = map.annotations.compactMap { annotation -> (MKAnnotation, CGFloat)? in
                guard annotation is TrailNameAnnotation || annotation is OutdoorPointAnnotation,
                      let view = map.view(for: annotation) else { return nil }
                let frame = view.frame.insetBy(dx: -7, dy: -7)
                guard frame.contains(point) else { return nil }
                return (annotation, hypot(frame.midX - point.x, frame.midY - point.y))
            }
            .min { $0.1 < $1.1 }?.0

            if let annotation = hit as? OutdoorPointAnnotation,
               let feature = loadedTrailDataset.points.first(where: { $0.id == annotation.featureID }) {
                if owner.state.selectedTool == .route {
                    owner.state.addOutdoorPointToRoute(feature)
                } else {
                    owner.state.selectOutdoorPoint(feature)
                    if feature.kind == .trailhead { activate(trailhead: feature) }
                }
                map.deselectAnnotation(annotation, animated: false)
                return true
            }
            if let annotation = hit as? TrailNameAnnotation,
               let feature = loadedTrailDataset.trails.first(where: { $0.id == annotation.featureID }) {
                if owner.state.selectedTool == .route {
                    owner.state.addTrailFeatureToRoute(
                        coordinate: annotation.coordinate,
                        name: feature.name,
                        sourceID: feature.id
                    )
                } else {
                    activate(feature: feature)
                }
                map.deselectAnnotation(annotation, animated: false)
                return true
            }
            return false
        }

        private func screenDistance(from point: CGPoint, to polyline: MKPolyline, on map: MKMapView) -> CGFloat {
            guard polyline.pointCount > 1 else { return .greatestFiniteMagnitude }
            let points = polyline.points()
            var best = CGFloat.greatestFiniteMagnitude
            for index in 1..<polyline.pointCount {
                let start = map.convert(points[index - 1].coordinate, toPointTo: map)
                let end = map.convert(points[index].coordinate, toPointTo: map)
                let dx = end.x - start.x
                let dy = end.y - start.y
                let denominator = dx * dx + dy * dy
                let fraction = denominator > 0
                    ? max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator))
                    : 0
                let closest = CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
                best = min(best, hypot(point.x - closest.x, point.y - closest.y))
            }
            return best
        }

        private func markerColor(for kind: OutdoorPointKind) -> PlatformColor {
            switch kind {
            case .trailhead: PlatformColor(red: 0.10, green: 0.34, blue: 0.20, alpha: 1)
            case .peak, .saddle: PlatformColor(red: 0.35, green: 0.29, blue: 0.20, alpha: 1)
            case .viewpoint: PlatformColor(red: 0.20, green: 0.39, blue: 0.43, alpha: 1)
            case .shelter, .campsite: PlatformColor(red: 0.44, green: 0.34, blue: 0.20, alpha: 1)
            case .water, .spring: PlatformColor(red: 0.08, green: 0.48, blue: 0.76, alpha: 1)
            }
        }

        private func routeWaypointAnnotation(at point: CGPoint, on map: MKMapView) -> RouteWaypointAnnotation? {
            map.annotations
                .compactMap { $0 as? RouteWaypointAnnotation }
                .map { ($0, map.convert($0.coordinate, toPointTo: map)) }
                .filter { hypot($0.1.x - point.x, $0.1.y - point.y) <= 28 }
                .min { lhs, rhs in
                    hypot(lhs.1.x - point.x, lhs.1.y - point.y)
                        < hypot(rhs.1.x - point.x, rhs.1.y - point.y)
                }?.0
        }

        #if os(iOS)
        func installTapGesture(on map: MKMapView) {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            gesture.delegate = self
            map.addGestureRecognizer(gesture)

            let routeDraw = UILongPressGestureRecognizer(target: self, action: #selector(handleRouteDraw(_:)))
            routeDraw.minimumPressDuration = 0.32
            routeDraw.allowableMovement = 14
            routeDraw.cancelsTouchesInView = true
            routeDraw.isEnabled = false
            routeDraw.delegate = self
            map.addGestureRecognizer(routeDraw)
            gesture.require(toFail: routeDraw)
            routeDrawGesture = routeDraw

            let lasso = UIPanGestureRecognizer(target: self, action: #selector(handleLasso(_:)))
            lasso.maximumNumberOfTouches = 1
            lasso.isEnabled = false
            lasso.delegate = self
            map.addGestureRecognizer(lasso)
            lassoGesture = lasso
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            if owner.state.selectedTool == .route,
               let waypointID = routeWaypointAnnotation(at: point, on: map)?.waypointID {
                owner.state.addExistingWaypointToRoute(id: waypointID)
                return
            }
            if let pin = pinAnnotation(at: point, on: map) {
                if owner.state.selectedTool == .route { owner.state.addPinToRoute(id: pin.id) }
                else { owner.state.selectPin(id: pin.id) }
                return
            }
            if trailAnnotationConsumesTap(at: point, on: map) { return }
            if activateTrail(at: point, on: map) { return }
            owner.state.handleMapTap(map.convert(point, toCoordinateFrom: map))
        }

        private func pinAnnotation(at point: CGPoint, on map: MKMapView) -> RoutePinAnnotation? {
            map.annotations
                .compactMap { $0 as? RoutePinAnnotation }
                .map { ($0, map.convert($0.coordinate, toPointTo: map)) }
                .filter { hypot($0.1.x - point.x, $0.1.y - point.y) <= 30 }
                .min { lhs, rhs in
                    hypot(lhs.1.x - point.x, lhs.1.y - point.y) < hypot(rhs.1.x - point.x, rhs.1.y - point.y)
                }?.0
        }

        @objc private func handleLasso(_ gesture: UIPanGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            processLasso(gesture.state, point: gesture.location(in: map), on: map)
        }

        @objc private func handleRouteDraw(_ gesture: UILongPressGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            processDrawingStroke(gesture.state, point: gesture.location(in: map), on: map)
        }
        #else
        func installTapGesture(on map: MKMapView) {
            let gesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            map.addGestureRecognizer(gesture)

            let routeDraw = NSPanGestureRecognizer(target: self, action: #selector(handleRouteDraw(_:)))
            routeDraw.isEnabled = false
            map.addGestureRecognizer(routeDraw)
            routeDrawGesture = routeDraw

            let lasso = NSPanGestureRecognizer(target: self, action: #selector(handleLasso(_:)))
            lasso.isEnabled = false
            map.addGestureRecognizer(lasso)
            lassoGesture = lasso
        }

        @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            if owner.state.selectedTool == .route,
               let waypointID = routeWaypointAnnotation(at: point, on: map)?.waypointID {
                owner.state.addExistingWaypointToRoute(id: waypointID)
                return
            }
            if let pin = pinAnnotation(at: point, on: map) {
                if owner.state.selectedTool == .route { owner.state.addPinToRoute(id: pin.id) }
                else { owner.state.selectPin(id: pin.id) }
                return
            }
            if trailAnnotationConsumesTap(at: point, on: map) { return }
            if activateTrail(at: point, on: map) { return }
            owner.state.handleMapTap(map.convert(point, toCoordinateFrom: map))
        }

        private func pinAnnotation(at point: CGPoint, on map: MKMapView) -> RoutePinAnnotation? {
            map.annotations
                .compactMap { $0 as? RoutePinAnnotation }
                .map { ($0, map.convert($0.coordinate, toPointTo: map)) }
                .filter { hypot($0.1.x - point.x, $0.1.y - point.y) <= 30 }
                .min { lhs, rhs in
                    hypot(lhs.1.x - point.x, lhs.1.y - point.y) < hypot(rhs.1.x - point.x, rhs.1.y - point.y)
                }?.0
        }

        @objc private func handleLasso(_ gesture: NSPanGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            processLasso(gesture.state, point: gesture.location(in: map), on: map)
        }

        @objc private func handleRouteDraw(_ gesture: NSPanGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            processDrawingStroke(gesture.state, point: gesture.location(in: map), on: map)
        }
        #endif

        private func processDrawingStroke(_ gestureState: PlatformGestureState, point: CGPoint, on map: MKMapView) {
            let tool = owner.state.selectedTool
            guard tool == .route || tool == .measure else { return }
            let coordinate = map.convert(point, toCoordinateFrom: map)
            switch gestureState {
            case .began:
                lastDrawingStrokePoint = point
                if tool == .route {
                    owner.state.beginRouteStroke(at: coordinate)
                } else {
                    owner.state.beginMeasurementStroke(at: coordinate)
                }
            case .changed:
                guard let previous = lastDrawingStrokePoint,
                      hypot(previous.x - point.x, previous.y - point.y) >= 6 else { return }
                lastDrawingStrokePoint = point
                if tool == .route {
                    owner.state.continueRouteStroke(to: coordinate)
                } else {
                    owner.state.continueMeasurementStroke(to: coordinate)
                }
            case .ended:
                if tool == .route {
                    owner.state.finishRouteStroke(at: coordinate)
                } else {
                    owner.state.finishMeasurementStroke(at: coordinate)
                }
                lastDrawingStrokePoint = nil
            case .cancelled, .failed:
                lastDrawingStrokePoint = nil
            default:
                break
            }
        }

        private func processLasso(_ gestureState: PlatformGestureState, point: CGPoint, on map: MKMapView) {
            switch gestureState {
            case .began:
                lassoCoordinates = [map.convert(point, toCoordinateFrom: map)]
                owner.state.updateOfflineSelection(lassoCoordinates)
            case .changed:
                let coordinate = map.convert(point, toCoordinateFrom: map)
                if let previous = lassoCoordinates.last {
                    let previousPoint = map.convert(previous, toPointTo: map)
                    guard hypot(previousPoint.x - point.x, previousPoint.y - point.y) >= 5 else { return }
                }
                lassoCoordinates.append(coordinate)
                owner.state.updateOfflineSelection(lassoCoordinates)
            case .ended:
                owner.state.finishOfflineSelection(lassoCoordinates)
            case .cancelled, .failed:
                lassoCoordinates.removeAll()
                owner.state.updateOfflineSelection([])
            default:
                break
            }
        }
    }
}

#if os(iOS)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
typealias PlatformGestureState = UIGestureRecognizer.State

extension UIColor {
    static var atlasLabel: UIColor { .label }
}

extension UIImage {
    static func atlasSymbol(named name: String) -> UIImage? { UIImage(systemName: name) }
}

final class HeadingConeView: MKAnnotationView {
    private let coneLayer = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        backgroundColor = .clear
        isEnabled = false
        canShowCallout = false
        displayPriority = .required
        layer.zPosition = -100

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 36, y: 36))
        path.addLine(to: CGPoint(x: 23, y: 8))
        path.addQuadCurve(to: CGPoint(x: 49, y: 8), control: CGPoint(x: 36, y: 1))
        path.closeSubpath()
        coneLayer.frame = bounds
        coneLayer.path = path
        coneLayer.fillColor = UIColor(red: 0.05, green: 0.48, blue: 0.98, alpha: 0.20).cgColor
        coneLayer.strokeColor = UIColor(red: 0.02, green: 0.40, blue: 0.94, alpha: 0.42).cgColor
        coneLayer.lineWidth = 1
        coneLayer.lineJoin = .round
        layer.addSublayer(coneLayer)
    }

    required init?(coder: NSCoder) { nil }

    func setHeading(_ degrees: Double?) {
        coneLayer.isHidden = degrees == nil
        guard let degrees else { return }
        coneLayer.setAffineTransform(CGAffineTransform(rotationAngle: degrees * .pi / 180))
    }
}

final class TrailNameView: MKAnnotationView {
    private let titleLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(red: 0.94, green: 0.93, blue: 0.86, alpha: 0.60)
        layer.cornerRadius = 4
        layer.borderWidth = 0
        collisionMode = .rectangle
        displayPriority = .defaultLow
        centerOffset = CGPoint(x: 0, y: -10)
        titleLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
        titleLabel.textColor = UIColor(red: 0.20, green: 0.25, blue: 0.17, alpha: 0.86)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String) {
        titleLabel.text = title
        let width = min(150, max(38, titleLabel.intrinsicContentSize.width + 10))
        bounds = CGRect(x: 0, y: 0, width: width, height: 20)
        titleLabel.frame = bounds.insetBy(dx: 5, dy: 2)
        accessibilityLabel = "Trail, \(title)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = bounds.insetBy(dx: 5, dy: 2)
    }
}

final class ContourLabelView: MKAnnotationView {
    private let valueLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(red: 0.93, green: 0.92, blue: 0.85, alpha: 0.62)
        layer.cornerRadius = 2
        collisionMode = .rectangle
        displayPriority = .defaultLow
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        valueLabel.textColor = UIColor(red: 0.34, green: 0.32, blue: 0.27, alpha: 0.72)
        valueLabel.textAlignment = .center
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) { nil }

    func setValue(_ value: String) {
        valueLabel.text = value
        let size = valueLabel.intrinsicContentSize
        bounds = CGRect(x: 0, y: 0, width: size.width + 5, height: 13)
        valueLabel.frame = bounds
    }
}

final class RouteWaypointView: MKAnnotationView {
    private let numberLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        backgroundColor = UIColor(red: 0.95, green: 0.31, blue: 0.04, alpha: 1)
        layer.cornerRadius = 12
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        collisionMode = .circle
        displayPriority = .required

        numberLabel.bounds = CGRect(origin: .zero, size: bounds.size)
        numberLabel.center = CGPoint(x: bounds.midX + 0.5, y: bounds.midY + 0.5)
        numberLabel.textAlignment = .center
        numberLabel.textColor = .white
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        numberLabel.baselineAdjustment = .alignCenters
        numberLabel.contentMode = .center
        addSubview(numberLabel)
    }

    required init?(coder: NSCoder) { nil }

    func setAppearance(sequence: Int, kind: RouteWaypointKind) {
        numberLabel.text = "\(sequence)"
        backgroundColor = waypointColor(kind)
        setNeedsLayout()
    }

    private func waypointColor(_ kind: RouteWaypointKind) -> UIColor {
        switch kind {
        case .standard: UIColor(red: 0.95, green: 0.31, blue: 0.04, alpha: 1)
        case .pin, .water, .spring: UIColor(red: 0.08, green: 0.48, blue: 0.96, alpha: 1)
        case .trailhead: UIColor(red: 0.10, green: 0.34, blue: 0.20, alpha: 1)
        case .peak, .saddle: UIColor(red: 0.35, green: 0.29, blue: 0.20, alpha: 1)
        case .viewpoint: UIColor(red: 0.20, green: 0.39, blue: 0.43, alpha: 1)
        case .shelter, .campsite: UIColor(red: 0.44, green: 0.34, blue: 0.20, alpha: 1)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        numberLabel.bounds = CGRect(origin: .zero, size: bounds.size)
        numberLabel.center = CGPoint(x: bounds.midX + 0.5, y: bounds.midY + 0.5)
    }
}

extension AtlasMapView: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ uiView: MKMapView, context: Context) { updateMap(uiView, context: context) }
}

extension AtlasMapView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        owner.state.selectedTool == .explore
    }
}
#else
import AppKit
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
typealias PlatformGestureState = NSGestureRecognizer.State

extension NSColor {
    static var atlasLabel: NSColor { .labelColor }
}

extension NSImage {
    static func atlasSymbol(named name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

final class HeadingConeView: MKAnnotationView {
    private let coneLayer = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        isEnabled = false
        canShowCallout = false
        displayPriority = .required
        layer?.zPosition = -100

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 36, y: 36))
        path.addLine(to: CGPoint(x: 23, y: 64))
        path.addQuadCurve(to: CGPoint(x: 49, y: 64), control: CGPoint(x: 36, y: 71))
        path.closeSubpath()
        coneLayer.frame = bounds
        coneLayer.path = path
        coneLayer.fillColor = NSColor(red: 0.05, green: 0.48, blue: 0.98, alpha: 0.20).cgColor
        coneLayer.strokeColor = NSColor(red: 0.02, green: 0.40, blue: 0.94, alpha: 0.42).cgColor
        coneLayer.lineWidth = 1
        coneLayer.lineJoin = .round
        layer?.addSublayer(coneLayer)
    }

    required init?(coder: NSCoder) { nil }

    func setHeading(_ degrees: Double?) {
        coneLayer.isHidden = degrees == nil
        guard let degrees else { return }
        // AppKit's annotation coordinate system is vertically flipped from UIKit.
        coneLayer.setAffineTransform(CGAffineTransform(rotationAngle: -degrees * .pi / 180))
    }
}

final class TrailNameView: MKAnnotationView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.94, green: 0.93, blue: 0.86, alpha: 0.60).cgColor
        layer?.cornerRadius = 4
        layer?.borderWidth = 0
        collisionMode = .rectangle
        displayPriority = .defaultLow
        centerOffset = CGPoint(x: 0, y: 10)
        titleLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
        titleLabel.textColor = NSColor(red: 0.20, green: 0.25, blue: 0.17, alpha: 0.86)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
        titleLabel.sizeToFit()
        let width = min(150, max(38, titleLabel.frame.width + 10))
        bounds = CGRect(x: 0, y: 0, width: width, height: 20)
        titleLabel.frame = bounds.insetBy(dx: 5, dy: 2)
        setAccessibilityLabel("Trail, \(title)")
    }

    override func layout() {
        super.layout()
        titleLabel.frame = bounds.insetBy(dx: 5, dy: 2)
    }
}

final class ContourLabelView: MKAnnotationView {
    private let valueLabel = NSTextField(labelWithString: "")

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.93, green: 0.92, blue: 0.85, alpha: 0.62).cgColor
        layer?.cornerRadius = 2
        collisionMode = .rectangle
        displayPriority = .defaultLow
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        valueLabel.textColor = NSColor(red: 0.34, green: 0.32, blue: 0.27, alpha: 0.72)
        valueLabel.alignment = .center
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) { nil }

    func setValue(_ value: String) {
        valueLabel.stringValue = value
        valueLabel.sizeToFit()
        bounds = CGRect(x: 0, y: 0, width: valueLabel.frame.width + 5, height: 13)
        valueLabel.frame = bounds
    }
}

final class RouteWaypointView: MKAnnotationView {
    private let numberLabel = NSTextField(labelWithString: "")

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.95, green: 0.31, blue: 0.04, alpha: 1).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.white.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        displayPriority = .required

        numberLabel.frame = bounds
        numberLabel.alignment = .center
        numberLabel.textColor = .white
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        numberLabel.isBezeled = false
        numberLabel.drawsBackground = false
        numberLabel.maximumNumberOfLines = 1
        addSubview(numberLabel)
    }

    required init?(coder: NSCoder) { nil }

    func setAppearance(sequence: Int, kind: RouteWaypointKind) {
        numberLabel.stringValue = "\(sequence)"
        layer?.backgroundColor = waypointColor(kind).cgColor
        needsLayout = true
    }

    private func waypointColor(_ kind: RouteWaypointKind) -> NSColor {
        switch kind {
        case .standard: NSColor(red: 0.95, green: 0.31, blue: 0.04, alpha: 1)
        case .pin, .water, .spring: NSColor(red: 0.08, green: 0.48, blue: 0.96, alpha: 1)
        case .trailhead: NSColor(red: 0.10, green: 0.34, blue: 0.20, alpha: 1)
        case .peak, .saddle: NSColor(red: 0.35, green: 0.29, blue: 0.20, alpha: 1)
        case .viewpoint: NSColor(red: 0.20, green: 0.39, blue: 0.43, alpha: 1)
        case .shelter, .campsite: NSColor(red: 0.44, green: 0.34, blue: 0.20, alpha: 1)
        }
    }

    override func layout() {
        super.layout()
        numberLabel.sizeToFit()
        numberLabel.frame.origin = CGPoint(
            x: ((bounds.width - numberLabel.frame.width) / 2) + 0.5,
            y: (bounds.height - numberLabel.frame.height) / 2
        )
    }
}

extension AtlasMapView: NSViewRepresentable {
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ nsView: MKMapView, context: Context) { updateMap(nsView, context: context) }
}
#endif

final class MeasurementPolyline: MKPolyline {}
final class TrailPolyline: MKPolyline {
    var source: TrailMapFeature.Source = .openStreetMap
    var importance: TrailMapFeature.Importance = .standard
    var featureID = ""
}
final class WaterwayPolyline: MKPolyline { var kind = "stream" }
final class TerrainContourPolyline: MKPolyline { var isIndex = false }
final class OfflineSelectionPolyline: MKPolyline {}
final class OfflineSelectionPolygon: MKPolygon {}

final class RouteWaypointAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var sequence: Int
    var routePointIndex: Int
    let waypointID: UUID?
    var kind: RouteWaypointKind

    init(
        coordinate: CLLocationCoordinate2D,
        sequence: Int,
        routePointIndex: Int,
        waypointID: UUID?,
        kind: RouteWaypointKind
    ) {
        self.coordinate = coordinate
        self.sequence = sequence
        self.routePointIndex = routePointIndex
        self.waypointID = waypointID
        self.kind = kind
    }
}

final class RouteElevationProbeAnnotation: NSObject, MKAnnotation {
    let id: UUID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var label: String
    var elevationMeters: Double?
    var title: String? { accessibilityDescription }

    var accessibilityDescription: String {
        guard let elevationMeters else { return "Elevation comparison point \(label)" }
        return "Elevation comparison point \(label), \(elevationMeters.rounded().formatted()) meters"
    }

    init(
        id: UUID,
        coordinate: CLLocationCoordinate2D,
        label: String,
        elevationMeters: Double?
    ) {
        self.id = id
        self.coordinate = coordinate
        self.label = label
        self.elevationMeters = elevationMeters
    }
}

final class HeadingConeAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var headingDegrees: Double?

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

final class TrailNameAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let name: String
    let featureID: String
    let importance: TrailMapFeature.Importance

    init(
        coordinate: CLLocationCoordinate2D,
        name: String,
        featureID: String,
        importance: TrailMapFeature.Importance
    ) {
        self.coordinate = coordinate
        self.name = name
        self.featureID = featureID
        self.importance = importance
    }
}

final class OutdoorPointAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let featureID: String
    let name: String
    var title: String? { name }

    init(feature: OutdoorPointFeature) {
        coordinate = feature.coordinate.coordinate
        featureID = feature.id
        name = feature.name
    }
}

final class ContourLabelAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let value: String

    init(coordinate: CLLocationCoordinate2D, value: String) {
        self.coordinate = coordinate
        self.value = value
    }
}

final class RoutePinAnnotation: NSObject, MKAnnotation {
    let id: UUID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?

    init(id: UUID, coordinate: CLLocationCoordinate2D, title: String) {
        self.id = id
        self.coordinate = coordinate
        self.title = title
    }
}
