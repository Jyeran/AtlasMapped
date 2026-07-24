import CoreLocation
import MapKit
import XCTest
@testable import AtlasMapped

final class OfflineTileCoverageTests: XCTestCase {
    @MainActor
    func testOfflineAreaRenamePersistsAndRejectsBlankNames() throws {
        let manifestURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("offline-areas.json")
        defer { try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent()) }

        let manager = OfflineRegionManager(manifestURL: manifestURL)
        let draft = OfflineMapDraft(
            boundary: [
                RouteWaypoint(CLLocationCoordinate2D(latitude: 39.9, longitude: -105.2)),
                RouteWaypoint(CLLocationCoordinate2D(latitude: 39.9, longitude: -105.1)),
                RouteWaypoint(CLLocationCoordinate2D(latitude: 40.0, longitude: -105.1))
            ],
            tiles: [OfflineTile(z: 8, x: 53, y: 97)]
        )
        let area = manager.download(draft, named: "Offline area 1")
        manager.cancel(area)

        XCTAssertFalse(manager.rename(area, to: "   "))
        XCTAssertTrue(manager.rename(area, to: "  Buffalo Peaks Loop  "))
        XCTAssertEqual(manager.areas.first?.name, "Buffalo Peaks Loop")

        let reloaded = OfflineRegionManager(manifestURL: manifestURL)
        XCTAssertEqual(reloaded.areas.first?.name, "Buffalo Peaks Loop")
    }

    func testResidentTrailViewportCoversNearbyMapMovement() {
        let resident = TrailViewport(south: 39.8, west: -105.4, north: 40.2, east: -104.9)
        let nearby = TrailViewport(south: 39.9, west: -105.2, north: 40.1, east: -105.0)
        let outside = TrailViewport(south: 40.1, west: -105.2, north: 40.3, east: -105.0)

        XCTAssertTrue(resident.contains(nearby))
        XCTAssertFalse(resident.contains(outside))
    }

    func testDisplayOverlayCanStreamWithoutExpandingOfflineCache() {
        let overlay = CachedTileOverlay(
            kind: .topographic,
            urlTemplate: "https://example.com/{z}/{x}/{y}.png",
            allowsNetwork: true,
            storesNetworkTiles: false
        )

        XCTAssertTrue(overlay.allowsNetwork)
        XCTAssertFalse(overlay.storesNetworkTiles)
    }

    func testUSGSOverzoomUsesTheCorrectNativeParentTile() {
        let requested = MKTileOverlayPath(x: 54_623, y: 99_251, z: 18, contentScaleFactor: 2)

        let source = CachedTileOverlay.sourcePath(for: requested, maximumZoom: 16)

        XCTAssertEqual(source.z, 16)
        XCTAssertEqual(source.x, requested.x >> 2)
        XCTAssertEqual(source.y, requested.y >> 2)
        XCTAssertEqual(source.contentScaleFactor, requested.contentScaleFactor)
    }

    func testNativeUSGSTilePathIsNotChanged() {
        let requested = MKTileOverlayPath(x: 13_653, y: 24_813, z: 16, contentScaleFactor: 1)

        let source = CachedTileOverlay.sourcePath(for: requested, maximumZoom: 16)

        XCTAssertEqual(source.z, requested.z)
        XCTAssertEqual(source.x, requested.x)
        XCTAssertEqual(source.y, requested.y)
    }

    func testTilePrefetchBuildsATwoTileApronWithoutRepeatingCenter() {
        let center = MKTileOverlayPath(x: 8, y: 8, z: 4, contentScaleFactor: 2)

        let neighbors = CachedTileOverlay.neighboringPaths(around: center, radius: 2)

        XCTAssertEqual(neighbors.count, 24)
        XCTAssertFalse(neighbors.contains { $0.x == center.x && $0.y == center.y })
        XCTAssertTrue(neighbors.contains { $0.x == 6 && $0.y == 6 })
        XCTAssertTrue(neighbors.contains { $0.x == 10 && $0.y == 10 })
        XCTAssertTrue(neighbors.allSatisfy { $0.z == center.z && $0.contentScaleFactor == 2 })
    }

    func testTilePrefetchWrapsLongitudeAndClampsAtPoles() {
        let corner = MKTileOverlayPath(x: 0, y: 0, z: 2, contentScaleFactor: 1)

        let neighbors = CachedTileOverlay.neighboringPaths(around: corner, radius: 1)

        XCTAssertEqual(Set(neighbors.map(\.y)), [0, 1])
        XCTAssertTrue(neighbors.contains { $0.x == 3 && $0.y == 0 })
        XCTAssertFalse(neighbors.contains { $0.y < 0 })
    }

    func testTileAddressClampsAndRoundTripsThroughCodable() throws {
        let tile = OfflineTile(z: 2, x: -5, y: 99)
        XCTAssertEqual(tile, OfflineTile(z: 2, x: 0, y: 3))

        let data = try JSONEncoder().encode(tile)
        XCTAssertEqual(try JSONDecoder().decode(OfflineTile.self, from: data), tile)
        XCTAssertEqual(Set([tile, tile]).count, 1)
    }

    func testSmallPolygonInsideOneTileReturnsOnlyThatTile() {
        let polygon = [
            coordinate(x: 0.27, y: 0.27),
            coordinate(x: 0.29, y: 0.27),
            coordinate(x: 0.28, y: 0.29)
        ]

        XCTAssertEqual(OfflineTileCoverage.tiles(intersecting: polygon, zooms: 2...2), [
            OfflineTile(z: 2, x: 1, y: 1)
        ])
    }

    func testPolygonOnExactTileBoundariesDoesNotAddAdjacentTiles() {
        let polygon = [
            coordinate(x: 0.25, y: 0.25),
            coordinate(x: 0.50, y: 0.25),
            coordinate(x: 0.50, y: 0.50),
            coordinate(x: 0.25, y: 0.50)
        ]

        XCTAssertEqual(OfflineTileCoverage.tiles(intersecting: polygon, zooms: 2...2), [
            OfflineTile(z: 2, x: 1, y: 1)
        ])
    }

    func testConciseCoverExcludesTilesOnlyInsideBoundingBox() {
        let triangle = [
            coordinate(x: 0.13, y: 0.13),
            coordinate(x: 0.49, y: 0.13),
            coordinate(x: 0.13, y: 0.49)
        ]

        let tiles = OfflineTileCoverage.tiles(intersecting: triangle, zooms: 3...3)

        XCTAssertTrue(tiles.contains(OfflineTile(z: 3, x: 1, y: 1)))
        XCTAssertTrue(tiles.contains(OfflineTile(z: 3, x: 3, y: 1)))
        XCTAssertTrue(tiles.contains(OfflineTile(z: 3, x: 1, y: 3)))
        XCTAssertFalse(tiles.contains(OfflineTile(z: 3, x: 3, y: 3)))
        XCTAssertLessThan(tiles.count, 9, "A bounding-box cover would contain all nine tiles")
    }

    func testTileWhollyInsidePolygonIsIncluded() {
        let square = [
            coordinate(x: 0.20, y: 0.20),
            coordinate(x: 0.55, y: 0.20),
            coordinate(x: 0.55, y: 0.55),
            coordinate(x: 0.20, y: 0.55)
        ]

        let tiles = OfflineTileCoverage.tiles(intersecting: square, zooms: 3...3)
        XCTAssertTrue(tiles.contains(OfflineTile(z: 3, x: 3, y: 3)))
    }

    func testAntimeridianPolygonUsesWrappedEdgeTiles() {
        let polygon = [
            CLLocationCoordinate2D(latitude: 1, longitude: 179),
            CLLocationCoordinate2D(latitude: 1, longitude: -179),
            CLLocationCoordinate2D(latitude: -1, longitude: -179),
            CLLocationCoordinate2D(latitude: -1, longitude: 179)
        ]

        let tiles = OfflineTileCoverage.tiles(intersecting: polygon, zooms: 3...3)
        XCTAssertEqual(Set(tiles.map(\.x)), [0, 7])
        XCTAssertFalse(tiles.contains(where: { (1...6).contains($0.x) }))
    }

    func testPolarCoordinatesAndResultIndexesAreClamped() {
        let polygon = [
            CLLocationCoordinate2D(latitude: 100, longitude: -200),
            CLLocationCoordinate2D(latitude: 100, longitude: 200),
            CLLocationCoordinate2D(latitude: 80, longitude: 0)
        ]

        let tiles = OfflineTileCoverage.tiles(intersecting: polygon, zooms: 2...2)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertTrue(tiles.allSatisfy { (0..<4).contains($0.x) && (0..<4).contains($0.y) })
    }

    func testDegeneratePolygonReturnsNoTiles() {
        let points = [coordinate(x: 0.2, y: 0.2), coordinate(x: 0.3, y: 0.3)]
        XCTAssertTrue(OfflineTileCoverage.tiles(intersecting: points, zooms: 1...4).isEmpty)
    }

    private func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
        let longitude = x * 360 - 180
        let latitude = atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
