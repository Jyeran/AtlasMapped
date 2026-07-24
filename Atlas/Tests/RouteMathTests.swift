import CoreLocation
import XCTest
@testable import AtlasMapped

final class RouteMathTests: XCTestCase {
    func testUnitSystemFormatsMetricAndImperialValuesConsistently() {
        XCTAssertEqual(AtlasUnitSystem.metric.distance(1_500), "1.5 km")
        XCTAssertEqual(AtlasUnitSystem.imperial.distance(1_609.344), "1 mi")
        XCTAssertEqual(AtlasUnitSystem.metric.elevation(1_234.56), "1,234.6 m")
        XCTAssertEqual(AtlasUnitSystem.imperial.elevation(304.8), "1,000 ft")
        XCTAssertEqual(AtlasUnitSystem.metric.pace(secondsPerMile: 600), "6:13 /km")
        XCTAssertEqual(AtlasUnitSystem.imperial.pace(secondsPerMile: 600), "10:00 /mi")
    }

    @MainActor
    func testElevationUnitTogglePersistsAcrossRelaunch() {
        let defaults = UserDefaults.standard
        let key = "atlas.unitSystem.v1"
        let previous = defaults.string(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key)

        let state = AppState(persistsPreferences: true)
        XCTAssertEqual(state.unitSystem, .metric)
        state.toggleUnitSystem()
        XCTAssertEqual(state.unitSystem, .imperial)
        XCTAssertEqual(AppState(persistsPreferences: true).unitSystem, .imperial)
    }

    func testOSMTrailClassifierRejectsUrbanPedestrianInfrastructureAndRoadTracks() {
        XCTAssertFalse(OSMTrailClassifier.shouldInclude(tags: [
            "highway": "footway",
            "footway": "sidewalk",
            "surface": "concrete"
        ]))
        XCTAssertFalse(OSMTrailClassifier.shouldInclude(tags: [
            "highway": "footway",
            "footway": "crossing",
            "crossing": "marked"
        ]))
        XCTAssertFalse(OSMTrailClassifier.shouldInclude(tags: [
            "highway": "track",
            "name": "County Road 18",
            "surface": "gravel"
        ]))
        XCTAssertFalse(OSMTrailClassifier.shouldInclude(tags: [
            "highway": "track",
            "name": "Forest Road",
            "motor_vehicle": "yes"
        ]))
    }

    func testOSMTrailClassifierKeepsRealHikingGeometry() {
        XCTAssertTrue(OSMTrailClassifier.shouldInclude(tags: [
            "highway": "path",
            "surface": "ground"
        ]))
        XCTAssertTrue(OSMTrailClassifier.shouldInclude(tags: [
            "highway": "footway",
            "name": "Mesa Trail",
            "surface": "compacted"
        ]))
        XCTAssertTrue(OSMTrailClassifier.shouldInclude(tags: [
            "highway": "track",
            "name": "Ridge Trail",
            "foot": "designated",
            "surface": "dirt"
        ]))
        XCTAssertTrue(OSMTrailClassifier.shouldInclude(tags: [
            "highway": "bridleway",
            "surface": "earth"
        ]))
    }

    func testRepeatedZoomPressesCreateDistinctCommands() {
        XCTAssertNotEqual(MapCommand.zoom(0.55), MapCommand.zoom(0.55))
        XCTAssertNotEqual(MapCommand.zoom(1.8), MapCommand.zoom(1.8))
        XCTAssertNotEqual(MapCommand.locate, MapCommand.locate)
    }

    @MainActor
    func testLoadingRouteRequestsMapFocusAroundItsGeometry() {
        let state = AppState()
        let coordinates = [
            CLLocationCoordinate2D(latitude: 39.95, longitude: -105.35),
            CLLocationCoordinate2D(latitude: 40.05, longitude: -105.20)
        ]
        state.loadRoute(RoutePlan(
            name: "Focus route",
            coordinates: coordinates,
            distanceMeters: 1_000,
            elevationGainMeters: 100
        ))

        let bounds = state.mapFocusRequest?.bounds
        XCTAssertNotNil(bounds)
        XCTAssertEqual(bounds?.south ?? 0, 39.95, accuracy: 0.000_001)
        XCTAssertEqual(bounds?.north ?? 0, 40.05, accuracy: 0.000_001)
        XCTAssertEqual(bounds?.west ?? 0, -105.35, accuracy: 0.000_001)
        XCTAssertEqual(bounds?.east ?? 0, -105.20, accuracy: 0.000_001)
    }

    func testDistanceAddsSegments() {
        let points = [
            CLLocationCoordinate2D(latitude: 39.0, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 39.001, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 39.002, longitude: -105.0)
        ]

        let distance = RouteMath.distance(along: points)
        XCTAssertGreaterThan(distance, 220)
        XCTAssertLessThan(distance, 225)
    }

    func testProgressProjectsToNearestRouteSegment() {
        let route = [
            CLLocationCoordinate2D(latitude: 39.0, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 39.01, longitude: -105.0)
        ]
        let halfway = CLLocationCoordinate2D(latitude: 39.005, longitude: -105.0001)

        let progress = RouteMath.progress(location: halfway, along: route)
        XCTAssertGreaterThan(progress, 0.49)
        XCTAssertLessThan(progress, 0.51)
    }

    func testPositionIncludesDistanceFromRoute() {
        let route = [
            CLLocationCoordinate2D(latitude: 39.0, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 39.01, longitude: -105.0)
        ]
        let nearby = CLLocationCoordinate2D(latitude: 39.005, longitude: -105.0001)

        let position = RouteMath.position(location: nearby, along: route)
        XCTAssertNotNil(position)
        XCTAssertGreaterThan(position?.distanceFromRoute ?? 0, 8)
        XCTAssertLessThan(position?.distanceFromRoute ?? 100, 10)
    }

    func testEmptyRouteHasZeroDistanceAndProgress() {
        XCTAssertEqual(RouteMath.distance(along: []), 0)
        XCTAssertEqual(RouteMath.progress(location: .init(latitude: 0, longitude: 0), along: []), 0)
    }

    func testCumulativeDistancesAlignWithEveryRoutePoint() {
        let route = [
            CLLocationCoordinate2D(latitude: 39.0, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 39.001, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 39.003, longitude: -105.0)
        ]

        let distances = RouteMath.cumulativeDistances(along: route)
        XCTAssertEqual(distances.count, route.count)
        XCTAssertEqual(distances[0], 0)
        XCTAssertGreaterThan(distances[2], distances[1])
        XCTAssertEqual(distances[2], RouteMath.distance(along: route), accuracy: 0.01)
    }

    func testCoordinateAtProgressFollowsRouteDistance() throws {
        let route = [
            CLLocationCoordinate2D(latitude: 39.0, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 39.001, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 39.003, longitude: -105.0)
        ]

        let halfway = try XCTUnwrap(RouteMath.coordinate(at: 0.5, along: route))
        XCTAssertEqual(halfway.latitude, 39.0015, accuracy: 0.000_02)
        XCTAssertEqual(halfway.longitude, -105.0, accuracy: 0.000_001)
        XCTAssertEqual(RouteMath.coordinate(at: 0, along: route)?.latitude ?? 0, 39.0, accuracy: 0.000_001)
        XCTAssertEqual(RouteMath.coordinate(at: 1, along: route)?.latitude ?? 0, 39.003, accuracy: 0.000_001)
    }

    @MainActor
    func testElevationProbeSelectionAddsTwoThenMovesNearest() {
        let state = AppState()
        state.routePoints = [
            CLLocationCoordinate2D(latitude: 39.0, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 39.01, longitude: -105.0)
        ]
        state.currentElevationProfileProvider = ElevationService.providerID
        state.currentRouteElevationProfileMeters = [100, 200]

        state.selectRouteElevationProbe(at: 0.2)
        state.selectRouteElevationProbe(at: 0.8)
        XCTAssertEqual(state.routeElevationProbeSummaries.map(\.label), ["A", "B"])
        XCTAssertEqual(state.routeElevationProbeSummaries[0].elevationMeters ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(state.routeElevationProbeSummaries[1].elevationMeters ?? 0, 180, accuracy: 0.001)

        state.selectRouteElevationProbe(at: 0.7)
        XCTAssertEqual(state.routeElevationProbeSummaries.count, 2)
        XCTAssertEqual(state.routeElevationProbeSummaries[0].progress, 0.2, accuracy: 0.001)
        XCTAssertEqual(state.routeElevationProbeSummaries[1].progress, 0.7, accuracy: 0.001)
    }

    @MainActor
    func testElevationProbeCanBeDraggedWithoutCrossingTheOtherProbe() throws {
        let state = AppState()
        state.routePoints = [
            CLLocationCoordinate2D(latitude: 39.0, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 39.01, longitude: -105.0)
        ]
        state.currentElevationProfileProvider = ElevationService.providerID
        state.currentRouteElevationProfileMeters = [100, 200]
        state.selectRouteElevationProbe(at: 0.2)
        state.selectRouteElevationProbe(at: 0.8)

        let firstID = try XCTUnwrap(state.routeElevationProbes.first?.id)
        state.moveRouteElevationProbe(id: firstID, to: 0.6)
        XCTAssertEqual(state.routeElevationProbeSummaries[0].progress, 0.6, accuracy: 0.001)
        XCTAssertEqual(state.routeElevationProbeSummaries[0].elevationMeters ?? 0, 160, accuracy: 0.001)

        state.moveRouteElevationProbe(id: firstID, to: 0.95)
        XCTAssertLessThan(state.routeElevationProbeSummaries[0].progress, state.routeElevationProbeSummaries[1].progress)
        XCTAssertEqual(state.routeElevationProbeSummaries[0].progress, 0.798, accuracy: 0.001)
    }

    func testElevationInterpolatesAtRouteProgress() {
        XCTAssertEqual(RouteMath.elevation(at: 0.25, in: [100, 200, 300]), 150)
        XCTAssertEqual(RouteMath.elevation(at: 1, in: [100, 200, 300]), 300)
        XCTAssertNil(RouteMath.elevation(at: 0.5, in: []))
    }

    func testCumulativeElevationGainIgnoresDescents() {
        XCTAssertEqual(RouteMath.cumulativeElevationGain(in: []), [])
        XCTAssertEqual(RouteMath.cumulativeElevationGain(in: [100]), [0])
        XCTAssertEqual(
            RouteMath.cumulativeElevationGain(in: [100, 120, 110, 125, 123]),
            [0, 20, 20, 35, 35]
        )
    }

    @MainActor
    func testDisplayedElevationGainIsDerivedFromProfile() {
        let state = AppState()
        state.currentElevationProfileProvider = ElevationService.providerID
        state.currentRouteElevationProfileMeters = [100, 120, 110, 125]
        state.currentElevationGainMeters = 999

        XCTAssertEqual(state.routeElevationGainMeters, 35)
    }

    @MainActor
    func testTapAndStrokeReleaseCreateWaypointsWhileDragSamplesStayShapePoints() {
        let state = AppState()
        state.clearActiveRoute()
        state.selectedTool = .route

        state.handleMapTap(.init(latitude: 39.0, longitude: -105.0))
        state.beginRouteStroke(at: .init(latitude: 39.001, longitude: -105.0))
        state.continueRouteStroke(to: .init(latitude: 39.002, longitude: -105.0))
        state.finishRouteStroke(at: .init(latitude: 39.002, longitude: -105.0))

        XCTAssertEqual(state.routePoints.count, 3)
        XCTAssertEqual(state.routeWaypointIndices, [0, 2])
        XCTAssertEqual(state.routeWaypointSummaries.count, 2)
        XCTAssertEqual(state.routeWaypointSummaries.first?.name, "Waypoint 1")
        XCTAssertEqual(state.routeWaypointSummaries.last?.name, "Waypoint 2")
    }

    @MainActor
    func testStationaryLongPressCreatesWaypointOnRelease() {
        let state = AppState()
        state.clearActiveRoute()
        state.selectedTool = .route
        let coordinate = CLLocationCoordinate2D(latitude: 39.0, longitude: -105.0)

        state.beginRouteStroke(at: coordinate)
        state.finishRouteStroke(at: coordinate)

        XCTAssertEqual(state.routePoints.count, 1)
        XCTAssertEqual(state.routeWaypointIndices, [0])
        XCTAssertEqual(state.namedRouteWaypoints.first?.routePointIndex, 0)
    }

    @MainActor
    func testMeasurementStrokeAddsDragSamplesAndExactReleasePoint() {
        let state = AppState()
        state.measurePoints.removeAll()
        state.selectedTool = .measure

        state.beginMeasurementStroke(at: .init(latitude: 39.0, longitude: -105.0))
        state.continueMeasurementStroke(to: .init(latitude: 39.001, longitude: -105.0))
        state.finishMeasurementStroke(at: .init(latitude: 39.002, longitude: -105.0))

        XCTAssertEqual(state.measurePoints.count, 3)
        XCTAssertGreaterThan(state.measuredDistance, 220)
        XCTAssertLessThan(state.measuredDistance, 225)
    }

    @MainActor
    func testMultiplePinsRemainSelectedForEditingAndRoundTripWithRoute() throws {
        let state = AppState()
        state.selectedTool = .pin

        state.handleMapTap(.init(latitude: 39.0, longitude: -105.0))
        let firstID = try XCTUnwrap(state.selectedPinID)
        state.setPinTitle(id: firstID, title: "Water source")
        state.setPinNote(id: firstID, note: "Seasonal creek")
        state.handleMapTap(.init(latitude: 39.001, longitude: -105.001))

        XCTAssertEqual(state.selectedTool, .pin)
        XCTAssertEqual(state.pins.count, 2)
        XCTAssertEqual(state.selectedPin?.title, "Pin 2")

        let encoded = try JSONEncoder.atlas.encode(state.currentRoutePlan())
        let decoded = try JSONDecoder.atlas.decode(RoutePlan.self, from: encoded)
        XCTAssertEqual(decoded.pins?.count, 2)
        XCTAssertEqual(decoded.pins?.first?.title, "Water source")
        XCTAssertEqual(decoded.pins?.first?.note, "Seasonal creek")
    }

    @MainActor
    func testRemovingPinClosesItsEditor() throws {
        let state = AppState()
        state.selectedTool = .pin
        state.handleMapTap(.init(latitude: 39.0, longitude: -105.0))
        let pinID = try XCTUnwrap(state.selectedPinID)

        state.removePin(id: pinID)

        XCTAssertTrue(state.pins.isEmpty)
        XCTAssertNil(state.selectedPinID)
    }

    func testNamedTrailSegmentsAreJoinedInEitherDirection() {
        let first = TrailMapFeature(
            id: "first",
            name: "Mesa Trail",
            coordinates: [
                RouteWaypoint(.init(latitude: 39.0, longitude: -105.0)),
                RouteWaypoint(.init(latitude: 39.001, longitude: -105.0))
            ],
            source: .openStreetMap
        )
        let reversedSecond = TrailMapFeature(
            id: "second",
            name: "Mesa Trail",
            coordinates: [
                RouteWaypoint(.init(latitude: 39.002, longitude: -105.0)),
                RouteWaypoint(.init(latitude: 39.001, longitude: -105.0))
            ],
            source: .openStreetMap
        )

        let route = TrailRouteBuilder.connectedCoordinates(
            startingWith: first,
            among: [first, reversedSecond]
        )

        XCTAssertEqual(route.count, 3)
        XCTAssertEqual(route.first?.latitude, 39.0)
        XCTAssertEqual(route.last?.latitude, 39.002)
    }

    func testTrailFeatureIndexMergesDuplicateProviderIDsWithoutCrashing() {
        let short = TrailMapFeature(
            id: "shared-provider-id",
            name: "Short segment",
            coordinates: [
                RouteWaypoint(.init(latitude: 39.0, longitude: -105.0)),
                RouteWaypoint(.init(latitude: 39.001, longitude: -105.0))
            ],
            source: .openStreetMap
        )
        let long = TrailMapFeature(
            id: "shared-provider-id",
            name: "Complete segment",
            coordinates: [
                RouteWaypoint(.init(latitude: 39.0, longitude: -105.0)),
                RouteWaypoint(.init(latitude: 39.001, longitude: -105.0)),
                RouteWaypoint(.init(latitude: 39.002, longitude: -105.0))
            ],
            source: .forestService
        )

        let index = TrailFeatureIndex.trailsByID([short, long])

        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index["shared-provider-id"]?.name, "Complete segment")
        XCTAssertEqual(index["shared-provider-id"]?.coordinates.count, 3)
    }

    func testFitToTrailFollowsConnectedGeometryInsteadOfSketchShortcut() throws {
        let trail = TrailMapFeature(
            id: "l-shaped-trail",
            name: "Switchback Trail",
            coordinates: [
                RouteWaypoint(.init(latitude: 40.0000, longitude: -105.0000)),
                RouteWaypoint(.init(latitude: 40.0030, longitude: -105.0000)),
                RouteWaypoint(.init(latitude: 40.0030, longitude: -104.9970))
            ],
            source: .openStreetMap
        )
        let sketch = [
            CLLocationCoordinate2D(latitude: 40.0000, longitude: -105.0001),
            CLLocationCoordinate2D(latitude: 40.0015, longitude: -104.9985),
            CLLocationCoordinate2D(latitude: 40.0031, longitude: -104.9970)
        ]

        let match = try TrailRouteFitter.fit(route: sketch, to: [trail])

        XCTAssertGreaterThan(match.coordinates.count, 3)
        XCTAssertTrue(match.coordinates.contains {
            abs($0.latitude - 40.0030) < 0.000_001
                && abs($0.longitude - -105.0000) < 0.000_001
        })
        XCTAssertLessThan(match.averageAdjustmentMeters, 250)
    }

    func testFitToTrailRejectsDistantGeometry() {
        let distantTrail = TrailMapFeature(
            id: "distant",
            name: nil,
            coordinates: [
                RouteWaypoint(.init(latitude: 41.0, longitude: -106.0)),
                RouteWaypoint(.init(latitude: 41.01, longitude: -106.0))
            ],
            source: .openStreetMap
        )
        let sketch = [
            CLLocationCoordinate2D(latitude: 40.0, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 40.01, longitude: -105.0)
        ]

        XCTAssertThrowsError(try TrailRouteFitter.fit(route: sketch, to: [distantTrail])) { error in
            XCTAssertEqual(error as? TrailRouteFitter.FitError, .noNearbyTrails)
        }
    }

    func testFitToTrailRejectsDisconnectedSegments() {
        let first = TrailMapFeature(
            id: "first-network",
            name: nil,
            coordinates: [
                RouteWaypoint(.init(latitude: 40.000, longitude: -105.000)),
                RouteWaypoint(.init(latitude: 40.001, longitude: -105.000))
            ],
            source: .openStreetMap
        )
        let second = TrailMapFeature(
            id: "second-network",
            name: nil,
            coordinates: [
                RouteWaypoint(.init(latitude: 40.003, longitude: -105.000)),
                RouteWaypoint(.init(latitude: 40.004, longitude: -105.000))
            ],
            source: .openStreetMap
        )
        let sketch = [
            CLLocationCoordinate2D(latitude: 40.000, longitude: -105.000),
            CLLocationCoordinate2D(latitude: 40.004, longitude: -105.000)
        ]

        XCTAssertThrowsError(try TrailRouteFitter.fit(route: sketch, to: [first, second])) { error in
            XCTAssertEqual(error as? TrailRouteFitter.FitError, .disconnected)
        }
    }

    func testFitToTrailBridgesSmallProviderGapsAndKeepsTrailBends() throws {
        let first = TrailMapFeature(
            id: "provider-a",
            name: "Creek Trail",
            coordinates: [
                RouteWaypoint(.init(latitude: 40.0000, longitude: -105.0000)),
                RouteWaypoint(.init(latitude: 40.0010, longitude: -105.0000)),
                RouteWaypoint(.init(latitude: 40.0020, longitude: -104.9992))
            ],
            source: .openStreetMap
        )
        let second = TrailMapFeature(
            id: "provider-b",
            name: "Creek Trail",
            coordinates: [
                RouteWaypoint(.init(latitude: 40.0021, longitude: -104.9991)),
                RouteWaypoint(.init(latitude: 40.0030, longitude: -104.9982)),
                RouteWaypoint(.init(latitude: 40.0040, longitude: -104.9982))
            ],
            source: .forestService
        )
        let sketch = [
            CLLocationCoordinate2D(latitude: 40.0000, longitude: -105.0001),
            CLLocationCoordinate2D(latitude: 40.0020, longitude: -104.9990),
            CLLocationCoordinate2D(latitude: 40.0040, longitude: -104.9981)
        ]

        let match = try TrailRouteFitter.fit(
            route: sketch,
            to: [first, second],
            waypointIndices: [0, 1, 2]
        )

        XCTAssertGreaterThanOrEqual(match.coordinates.count, 6)
        XCTAssertEqual(try XCTUnwrap(match.coordinates.first).latitude, 40.0000, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(match.coordinates.last).latitude, 40.0040, accuracy: 0.000_001)
    }

    func testFitToTrailConnectsCrossingFeaturesBetweenRecordedVertices() throws {
        let eastWest = TrailMapFeature(
            id: "east-west",
            name: "Ridge Trail",
            coordinates: [
                RouteWaypoint(.init(latitude: 40.0000, longitude: -105.0020)),
                RouteWaypoint(.init(latitude: 40.0000, longitude: -104.9980))
            ],
            source: .openStreetMap
        )
        let northSouth = TrailMapFeature(
            id: "north-south",
            name: "Creek Trail",
            coordinates: [
                RouteWaypoint(.init(latitude: 39.9980, longitude: -105.0000)),
                RouteWaypoint(.init(latitude: 40.0020, longitude: -105.0000))
            ],
            source: .forestService
        )
        let sketch = [
            CLLocationCoordinate2D(latitude: 40.0000, longitude: -105.0019),
            CLLocationCoordinate2D(latitude: 40.0000, longitude: -105.0000),
            CLLocationCoordinate2D(latitude: 40.0019, longitude: -105.0000)
        ]

        let match = try TrailRouteFitter.fit(
            route: sketch,
            to: [eastWest, northSouth],
            waypointIndices: [0, 1, 2]
        )

        XCTAssertGreaterThan(match.coordinates.count, 10)
        XCTAssertLessThan(match.averageAdjustmentMeters, 30)
    }

    func testFitToTrailFallsBackAcrossSwitchbackSegmentsOutsideStraightSketchCorridor() throws {
        let lower = TrailMapFeature(
            id: "switchback-lower",
            name: "Willow Trail",
            coordinates: [
                RouteWaypoint(.init(latitude: 40.0000, longitude: -105.0000)),
                RouteWaypoint(.init(latitude: 40.0020, longitude: -104.9990)),
                RouteWaypoint(.init(latitude: 40.0035, longitude: -104.9930))
            ],
            source: .openStreetMap
        )
        let remoteMiddle = TrailMapFeature(
            id: "switchback-middle",
            name: "Willow Trail",
            coordinates: [
                RouteWaypoint(.init(latitude: 40.0035, longitude: -104.9930)),
                RouteWaypoint(.init(latitude: 40.0050, longitude: -104.9915)),
                RouteWaypoint(.init(latitude: 40.0065, longitude: -104.9930))
            ],
            source: .forestService
        )
        let upper = TrailMapFeature(
            id: "switchback-upper",
            name: "Willow Trail",
            coordinates: [
                RouteWaypoint(.init(latitude: 40.0065, longitude: -104.9930)),
                RouteWaypoint(.init(latitude: 40.0080, longitude: -104.9990)),
                RouteWaypoint(.init(latitude: 40.0100, longitude: -105.0000))
            ],
            source: .openStreetMap
        )
        let sketch = [
            CLLocationCoordinate2D(latitude: 40.0000, longitude: -105.0000),
            CLLocationCoordinate2D(latitude: 40.0100, longitude: -105.0000)
        ]

        let match = try TrailRouteFitter.fit(
            route: sketch,
            to: [lower, remoteMiddle, upper],
            waypointIndices: [0, 1]
        )

        XCTAssertGreaterThan(match.coordinates.count, 20)
        XCTAssertTrue(match.coordinates.contains {
            abs($0.latitude - 40.0050) < 0.000_01
                && abs($0.longitude - -104.9915) < 0.000_01
        })
    }

    @MainActor
    func testCreatingRouteFromTrailReplacesTheActiveRoute() {
        let state = AppState()
        state.pins = [RoutePin(coordinate: .init(latitude: 39, longitude: -105), title: "Old pin")]
        let trail = [
            CLLocationCoordinate2D(latitude: 40.0, longitude: -105.3),
            CLLocationCoordinate2D(latitude: 40.01, longitude: -105.3),
            CLLocationCoordinate2D(latitude: 40.02, longitude: -105.3)
        ]

        state.createRouteFromTrail(named: "Mesa Trail", coordinates: trail, startingAt: "Mesa Trailhead")

        XCTAssertEqual(state.currentRouteName, "Mesa Trail")
        XCTAssertEqual(state.routePoints.count, 3)
        XCTAssertEqual(state.routeWaypointIndices, [0, 2])
        XCTAssertEqual(state.namedRouteWaypoints.first?.name, "Mesa Trailhead")
        XCTAssertEqual(state.namedRouteWaypoints.last?.name, "End")
        XCTAssertEqual(state.pins.first?.title, "Old pin", "Saved pins should outlive the active route")
        XCTAssertEqual(state.selectedTool, .explore)
    }

    @MainActor
    func testPinAppearanceAndElevationRoundTrip() throws {
        let original = RoutePin(
            coordinate: .init(latitude: 39.985, longitude: -105.294),
            title: "Water cache",
            note: "Reliable in summer",
            elevationMeters: 2_134,
            color: .forest,
            symbol: .water
        )

        let data = try JSONEncoder.atlas.encode(original)
        let decoded = try JSONDecoder.atlas.decode(RoutePin.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.resolvedColor, .forest)
        XCTAssertEqual(decoded.resolvedSymbol, .water)
        XCTAssertEqual(decoded.elevationMeters, 2_134)
    }

    @MainActor
    func testConfirmedPinPersistsAcrossAppStateRelaunch() throws {
        let defaults = UserDefaults.standard
        let key = "atlas.savedPins.v1"
        let previous = defaults.data(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key)

        let firstState = AppState(persistsPins: true)
        let pin = RoutePin(
            coordinate: .init(latitude: 39.985, longitude: -105.294),
            title: "Draft"
        )
        firstState.pins = [pin]
        firstState.updatePin(
            id: pin.id,
            title: "Camp",
            note: "Flat bench",
            color: .orange,
            symbol: .camp
        )

        let relaunchedState = AppState(persistsPins: true)
        let restored = try XCTUnwrap(relaunchedState.pins.first)
        XCTAssertEqual(restored.title, "Camp")
        XCTAssertEqual(restored.note, "Flat bench")
        XCTAssertEqual(restored.resolvedColor, .orange)
        XCTAssertEqual(restored.resolvedSymbol, .camp)
    }

    @MainActor
    func testUndoRemovesLastAddedWaypointAndRedoRestoresIt() {
        let state = AppState()
        let coordinate = CLLocationCoordinate2D(latitude: 39.95, longitude: -105.18)

        state.addRouteWaypoint(coordinate)
        XCTAssertEqual(state.routePoints.count, 1)
        XCTAssertEqual(state.routeWaypointIndices, [0])
        XCTAssertTrue(state.canUndoRouteEdit)

        state.undoRouteEdit()
        XCTAssertTrue(state.routePoints.isEmpty)
        XCTAssertTrue(state.routeWaypointIndices.isEmpty)
        XCTAssertTrue(state.canRedoRouteEdit)

        state.redoRouteEdit()
        XCTAssertEqual(state.routePoints.count, 1)
        XCTAssertEqual(state.routeWaypointIndices, [0])
        XCTAssertEqual(state.routePoints[0].latitude, coordinate.latitude)
    }

    @MainActor
    func testDrawnStrokeIsOneUndoableRouteEdit() {
        let state = AppState()
        state.selectedTool = .route
        state.beginRouteStroke(at: .init(latitude: 39.950, longitude: -105.180))
        state.continueRouteStroke(to: .init(latitude: 39.951, longitude: -105.181))
        state.continueRouteStroke(to: .init(latitude: 39.952, longitude: -105.182))
        state.finishRouteStroke(at: .init(latitude: 39.953, longitude: -105.183))
        let drawnPointCount = state.routePoints.count

        XCTAssertGreaterThan(drawnPointCount, 2)
        state.undoRouteEdit()
        XCTAssertTrue(state.routePoints.isEmpty)

        state.redoRouteEdit()
        XCTAssertEqual(state.routePoints.count, drawnPointCount)
        XCTAssertEqual(state.routeWaypointIndices.count, 1)
    }

    @MainActor
    func testMovingWaypointIsUndoableAndPreservesWaypointMetadata() {
        let state = AppState()
        let original = CLLocationCoordinate2D(latitude: 39.950, longitude: -105.180)
        let moved = CLLocationCoordinate2D(latitude: 39.955, longitude: -105.175)
        state.addRouteWaypoint(original)

        state.moveRouteWaypoint(at: 0, to: moved)

        XCTAssertEqual(state.routePoints[0].latitude, moved.latitude)
        XCTAssertEqual(state.routePoints[0].longitude, moved.longitude)
        XCTAssertEqual(state.routeWaypointIndices, [0])
        XCTAssertEqual(state.namedRouteWaypoints.first?.name, "Waypoint 1")

        state.undoRouteEdit()
        XCTAssertEqual(state.routePoints[0].latitude, original.latitude)
        XCTAssertEqual(state.routePoints[0].longitude, original.longitude)

        state.redoRouteEdit()
        XCTAssertEqual(state.routePoints[0].latitude, moved.latitude)
        XCTAssertEqual(state.routePoints[0].longitude, moved.longitude)
    }

    @MainActor
    func testRemovingInteriorWaypointPreservesRouteShape() {
        let state = AppState()
        state.addRouteWaypoint(.init(latitude: 40.000, longitude: -105.000))
        state.addRouteWaypoint(.init(latitude: 40.001, longitude: -105.001))
        state.addRouteWaypoint(.init(latitude: 40.002, longitude: -105.002))
        let originalShape = state.routePoints.map(RouteWaypoint.init)
        let middleID = state.routeWaypointSummaries[1].id

        state.removeWaypoint(id: middleID)

        XCTAssertEqual(state.routePoints.map(RouteWaypoint.init), originalShape)
        XCTAssertEqual(state.routeWaypointSummaries.count, 2)
        XCTAssertEqual(state.routeWaypointIndices, [0, 2])
    }

    @MainActor
    func testRemovingEdgeWaypointTrimsRouteToNextStop() {
        let state = AppState()
        let first = CLLocationCoordinate2D(latitude: 40.000, longitude: -105.000)
        let second = CLLocationCoordinate2D(latitude: 40.001, longitude: -105.001)
        let third = CLLocationCoordinate2D(latitude: 40.002, longitude: -105.002)
        state.addRouteWaypoint(first)
        state.addRouteWaypoint(second)
        state.addRouteWaypoint(third)

        state.removeWaypoint(id: state.routeWaypointSummaries[0].id)

        XCTAssertEqual(state.routePoints.count, 2)
        XCTAssertEqual(state.routePoints[0].latitude, second.latitude)
        XCTAssertEqual(state.routeWaypointIndices, [0, 1])
        XCTAssertEqual(state.routeWaypointSummaries.map(\.name), ["Waypoint 2", "Waypoint 3"])
    }

    @MainActor
    func testReverseRouteReversesStopsAndPreservesNotesAndKinds() {
        let state = AppState()
        state.pins = [RoutePin(
            coordinate: .init(latitude: 40.000, longitude: -105.000),
            title: "Water cache",
            note: "Behind the sign"
        )]
        state.addPinToRoute(id: state.pins[0].id)
        state.addRouteWaypoint(.init(latitude: 40.002, longitude: -105.002))

        state.reverseRoute()

        XCTAssertEqual(state.routeWaypointSummaries.map(\.name), ["Waypoint 2", "Water cache"])
        XCTAssertEqual(state.routeWaypointSummaries.last?.note, "Behind the sign")
        XCTAssertEqual(state.routeWaypointSummaries.last?.kind, .pin)
    }

    @MainActor
    func testPinAndOutdoorPointBecomeTypedRouteStops() {
        let state = AppState()
        let pin = RoutePin(
            coordinate: .init(latitude: 40.000, longitude: -105.000),
            title: "Creek crossing",
            note: "May be high"
        )
        state.pins = [pin]
        state.addPinToRoute(id: pin.id)
        let peak = OutdoorPointFeature(
            id: "node/peak",
            name: "Summit",
            coordinate: RouteWaypoint(.init(latitude: 40.010, longitude: -105.010)),
            kind: .peak,
            elevationMeters: 3_100,
            description: "Open summit",
            website: nil,
            facts: []
        )
        state.addOutdoorPointToRoute(peak)

        XCTAssertEqual(state.routeWaypointSummaries.map(\.kind), [.pin, .peak])
        XCTAssertEqual(state.routeWaypointSummaries.map(\.name), ["Creek crossing", "Summit"])
        XCTAssertEqual(state.routeWaypointSummaries.first?.note, "May be high")
        XCTAssertEqual(state.currentRoutePlan().namedWaypoints?.last?.sourceID, "node/peak")
    }

    @MainActor
    func testFreshAppStartsWithoutSampleRoute() {
        let state = AppState()

        XCTAssertFalse(state.hasActiveRoute)
        XCTAssertTrue(state.routePoints.isEmpty)
        XCTAssertTrue(state.routeWaypointSummaries.isEmpty)
        XCTAssertEqual(state.currentRouteName, "Untitled Route")
        XCTAssertEqual(state.routeProgress, 0)
    }

    @MainActor
    func testWaypointCanBeReusedAfterAnInterveningRouteLeg() {
        let state = AppState()
        let loopLocation = CLLocationCoordinate2D(latitude: 40.000, longitude: -105.000)
        state.addRouteWaypoint(loopLocation)
        let original = try! XCTUnwrap(state.routeWaypointSummaries.first)
        state.setWaypointName(id: original.id, name: "Loop junction")
        state.setWaypointNote(id: original.id, note: "Pass twice")
        state.addRouteWaypoint(.init(latitude: 40.010, longitude: -105.010))

        state.addExistingWaypointToRoute(id: original.id)

        XCTAssertEqual(state.routeWaypointSummaries.count, 3)
        XCTAssertEqual(state.routeWaypointSummaries.map(\.name), ["Loop junction", "Waypoint 2", "Loop junction"])
        XCTAssertEqual(state.routeWaypointSummaries.last?.note, "Pass twice")
        XCTAssertNotEqual(state.routeWaypointSummaries.first?.id, state.routeWaypointSummaries.last?.id)
        XCTAssertEqual(state.routePoints.last?.latitude, loopLocation.latitude)
        XCTAssertEqual(state.routePoints.last?.longitude, loopLocation.longitude)
    }

    @MainActor
    func testPinCanAppearMultipleTimesInRouteSequence() {
        let state = AppState()
        let pin = RoutePin(
            coordinate: .init(latitude: 40.000, longitude: -105.000),
            title: "Trail junction"
        )
        state.pins = [pin]
        state.addPinToRoute(id: pin.id)
        state.addRouteWaypoint(.init(latitude: 40.010, longitude: -105.010))
        state.addPinToRoute(id: pin.id)

        XCTAssertEqual(state.routeWaypointSummaries.map(\.kind), [.pin, .standard, .pin])
        XCTAssertEqual(state.routeWaypointSummaries.filter { $0.name == "Trail junction" }.count, 2)
        XCTAssertEqual(state.currentRoutePlan().namedWaypoints?.filter { $0.sourceID == pin.id.uuidString }.count, 2)
    }
}
