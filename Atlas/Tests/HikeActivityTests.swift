import CoreLocation
import XCTest
@testable import AtlasMapped

@MainActor
final class HikeActivityTests: XCTestCase {
    func testPauseExcludesStoppedTimeAndBreaksBreadcrumbDistance() throws {
        let recorder = HikeRecorder()
        let start = Date(timeIntervalSince1970: 1_000)
        recorder.startFreeRecording(at: start)
        recorder.ingest(location(39, -105, altitude: 1_000, at: start))
        recorder.ingest(location(39.001, -105, altitude: 1_010, at: start.addingTimeInterval(60)))
        recorder.pause(at: start.addingTimeInterval(60))
        recorder.resume(at: start.addingTimeInterval(120))
        recorder.ingest(location(40, -106, altitude: 2_000, at: start.addingTimeInterval(120)))
        recorder.ingest(location(40.001, -106, altitude: 2_015, at: start.addingTimeInterval(180)))

        let plan = RoutePlan(name: "Track", coordinates: [], distanceMeters: 0, elevationGainMeters: 0)
        let hike = try XCTUnwrap(recorder.finish(recordedRoute: plan, at: start.addingTimeInterval(180)))

        XCTAssertEqual(hike.activeDuration, 120, accuracy: 0.01)
        XCTAssertEqual(hike.elapsedDuration, 180, accuracy: 0.01)
        XCTAssertEqual(hike.splits.filter { $0.kind == .activeLeg }.count, 2)
        XCTAssertLessThan(hike.distanceMeters, 300, "Paused GPS relocation must not connect into the breadcrumb")
        XCTAssertEqual(hike.elevationGainMeters, 25, accuracy: 0.1)
    }

    func testRepeatedCoordinateWaypointsAreAchievedInRouteOrder() {
        let start = Date(timeIntervalSince1970: 2_000)
        let a = CLLocationCoordinate2D(latitude: 39, longitude: -105)
        let b = CLLocationCoordinate2D(latitude: 39.001, longitude: -105)
        let firstID = UUID(), middleID = UUID(), returnID = UUID()
        let route = RoutePlan(
            name: "Loop",
            coordinates: [a, b, a],
            distanceMeters: RouteMath.distance(along: [a, b, a]),
            elevationGainMeters: 0,
            routeWaypointIndices: [0, 1, 2],
            namedWaypoints: [
                NamedRouteWaypoint(id: firstID, routePointIndex: 0, name: "Start"),
                NamedRouteWaypoint(id: middleID, routePointIndex: 1, name: "Turn"),
                NamedRouteWaypoint(id: returnID, routePointIndex: 2, name: "Finish")
            ]
        )
        let recorder = HikeRecorder()
        recorder.startPlanned(route: route, at: start)
        recorder.ingest(location(a.latitude, a.longitude, at: start))
        XCTAssertEqual(recorder.achievedWaypointIDs, [firstID])
        recorder.ingest(location(b.latitude, b.longitude, at: start.addingTimeInterval(30)))
        XCTAssertEqual(recorder.achievedWaypointIDs, [firstID, middleID])
        recorder.ingest(location(a.latitude, a.longitude, at: start.addingTimeInterval(60)))
        XCTAssertEqual(recorder.achievedWaypointIDs, [firstID, middleID, returnID])
    }

    func testManualSplitCapturesCurrentLegAndCoordinate() throws {
        let start = Date(timeIntervalSince1970: 3_000)
        let recorder = HikeRecorder()
        recorder.startFreeRecording(at: start)
        recorder.ingest(location(39, -105, at: start))
        recorder.ingest(location(39.001, -105, at: start.addingTimeInterval(60)))
        let split = try XCTUnwrap(recorder.addManualSplit(at: start.addingTimeInterval(60)))
        XCTAssertEqual(split.kind, .manual)
        XCTAssertEqual(split.name, "Split 1")
        XCTAssertGreaterThan(split.distanceMeters, 100)
        XCTAssertNotNil(split.coordinate)
    }

    private func location(
        _ latitude: Double,
        _ longitude: Double,
        altitude: Double = 1_000,
        at timestamp: Date
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: timestamp
        )
    }
}
