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

    func testPaceTrackBreaksAtPausedSegmentsAndRetainsPace() {
        let start = Date(timeIntervalSince1970: 4_000)
        let samples = [
            HikeTrackSample(location: location(39, -105, at: start), beginsSegment: true),
            HikeTrackSample(location: location(39.001, -105, at: start.addingTimeInterval(60)), beginsSegment: false),
            HikeTrackSample(location: location(40, -106, at: start.addingTimeInterval(120)), beginsSegment: true),
            HikeTrackSample(location: location(40.001, -106, at: start.addingTimeInterval(180)), beginsSegment: false)
        ]

        let segments = HikePaceTrackBuilder.segments(from: samples)

        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.allSatisfy { $0.coordinates.count == 2 })
        XCTAssertTrue(segments.allSatisfy { $0.secondsPerMile != nil })
        XCTAssertFalse(segments.contains {
            $0.coordinates.first?.latitude == 39.001 && $0.coordinates.last?.latitude == 40
        })
    }

    func testPaceTrackCapsRenderSegmentsForLongRecordings() {
        let start = Date(timeIntervalSince1970: 5_000)
        let samples = (0..<1_001).map { index in
            HikeTrackSample(
                location: location(
                    39 + Double(index) * 0.00001,
                    -105,
                    at: start.addingTimeInterval(Double(index) * 2)
                ),
                beginsSegment: index == 0
            )
        }

        let segments = HikePaceTrackBuilder.segments(from: samples, targetSegmentCount: 100)

        XCTAssertLessThanOrEqual(segments.count, 100)
        XCTAssertEqual(segments.first?.coordinates.first?.latitude ?? 0, 39, accuracy: 0.000_001)
        XCTAssertEqual(segments.last?.coordinates.last?.latitude ?? 0, 39.01, accuracy: 0.000_001)
    }

    func testHikeLibraryCanSaveReopenAndDeleteFullTrack() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-hike-library-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let start = Date(timeIntervalSince1970: 6_000)
        let sample = HikeTrackSample(location: location(39, -105, at: start), beginsSegment: true)
        let route = RoutePlan(
            name: "Archived track",
            coordinates: [sample.coordinate.coordinate],
            distanceMeters: 0,
            elevationGainMeters: 0
        )
        let hike = RecordedHike(
            id: UUID(),
            name: "Archived track",
            mode: .freeRecording,
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            activeDuration: 60,
            samples: [sample],
            splits: [],
            sourceRoute: nil,
            recordedRoute: route
        )

        let library = HikeLibrary(fileURL: fileURL)
        library.save(hike)
        let reopened = try XCTUnwrap(HikeLibrary(fileURL: fileURL).hikes.first)
        XCTAssertEqual(reopened.id, hike.id)
        XCTAssertEqual(reopened.samples, hike.samples)
        XCTAssertEqual(reopened.recordedRoute.waypoints, hike.recordedRoute.waypoints)
        XCTAssertEqual(reopened.activeDuration, hike.activeDuration)

        library.delete(id: hike.id)
        XCTAssertTrue(HikeLibrary(fileURL: fileURL).hikes.isEmpty)
    }

    func testEndingHikeCreatesUnsavedReviewInsteadOfAutoArchive() throws {
        let state = AppState()
        let start = Date(timeIntervalSince1970: 7_000)
        let existingIDs = Set(state.hikes.hikes.map(\.id))
        state.routePoints = [
            CLLocationCoordinate2D(latitude: 39, longitude: -105),
            CLLocationCoordinate2D(latitude: 39.001, longitude: -105)
        ]
        state.hikeRecorder.startFreeRecording(at: start)
        state.hikeRecorder.ingest(location(39, -105, at: start))
        state.hikeRecorder.ingest(location(39.001, -105, at: start.addingTimeInterval(60)))

        state.endRouteTracking()

        let pending = try XCTUnwrap(state.completedHike)
        XCTAssertFalse(state.hikes.hikes.contains { $0.id == pending.id })
        XCTAssertEqual(Set(state.hikes.hikes.map(\.id)), existingIDs)
        state.discardCompletedHike()
        XCTAssertNil(state.completedHike)
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
