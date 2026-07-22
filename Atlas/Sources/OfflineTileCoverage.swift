import CoreLocation
import Foundation
import MapKit

/// A Web Mercator XYZ tile address.
struct OfflineTile: Codable, Hashable, Sendable {
    let z: Int
    let x: Int
    let y: Int

    init(z: Int, x: Int, y: Int) {
        let clampedZoom = min(max(z, 0), OfflineTileCoverage.maximumZoom)
        let tileCount = 1 << clampedZoom
        self.z = clampedZoom
        self.x = min(max(x, 0), tileCount - 1)
        self.y = min(max(y, 0), tileCount - 1)
    }

    var mapKitPath: MKTileOverlayPath {
        MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 1)
    }
}

/// Computes an exact tile cover for a lasso polygon rather than downloading its
/// entire bounding box.
enum OfflineTileCoverage {
    static let maximumZoom = 30
    static let maximumMercatorLatitude = 85.0511287798066

    /// Returns every XYZ tile whose Web Mercator rectangle intersects `polygon`.
    /// The polygon is implicitly closed and may be clockwise or counter-clockwise.
    static func tiles(
        intersecting coordinates: [CLLocationCoordinate2D],
        zooms: ClosedRange<Int>
    ) -> [OfflineTile] {
        guard coordinates.count >= 3 else { return [] }

        let lowerZoom = max(0, zooms.lowerBound)
        let upperZoom = min(maximumZoom, zooms.upperBound)
        guard lowerZoom <= upperZoom else { return [] }

        var projected = coordinates.map(project)
        guard projected.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }

        // Unwrap a polygon that crosses the antimeridian so its bounding box stays
        // narrow. Candidate X addresses are wrapped back into the XYZ range below.
        if let minX = projected.map(\.x).min(),
           let maxX = projected.map(\.x).max(),
           maxX - minX > 0.5 {
            projected = projected.map { point in
                Point(x: point.x < 0.5 ? point.x + 1 : point.x, y: point.y)
            }
        }

        guard let minX = projected.map(\.x).min(),
              let maxX = projected.map(\.x).max(),
              let minY = projected.map(\.y).min(),
              let maxY = projected.map(\.y).max()
        else { return [] }

        var result = Set<OfflineTile>()
        for zoom in lowerZoom...upperZoom {
            let count = 1 << zoom
            let scale = Double(count)
            let boundaryTolerance = 1e-10
            let firstX = Int(floor(minX * scale + boundaryTolerance))
            // Tiles are half-open on their east/south edges. Using ceil - 1 keeps
            // a lasso that ends exactly on a tile boundary from pulling in the
            // adjacent tile solely because it touches that boundary.
            let lastX = Int(ceil(maxX * scale - boundaryTolerance)) - 1
            let firstY = min(max(Int(floor(minY * scale + boundaryTolerance)), 0), count - 1)
            let lastY = min(max(Int(ceil(maxY * scale - boundaryTolerance)) - 1, 0), count - 1)

            guard firstX <= lastX, firstY <= lastY else { continue }
            for unwrappedX in firstX...lastX {
                let left = Double(unwrappedX) / scale
                let right = Double(unwrappedX + 1) / scale
                for y in firstY...lastY {
                    let top = Double(y) / scale
                    let bottom = Double(y + 1) / scale
                    let rectangle = Rectangle(left: left, top: top, right: right, bottom: bottom)
                    guard polygon(projected, intersects: rectangle) else { continue }

                    let wrappedX = ((unwrappedX % count) + count) % count
                    result.insert(OfflineTile(z: zoom, x: wrappedX, y: y))
                }
            }
        }
        return result.sorted {
            if $0.z != $1.z { return $0.z < $1.z }
            if $0.x != $1.x { return $0.x < $1.x }
            return $0.y < $1.y
        }
    }

    private static func project(_ coordinate: CLLocationCoordinate2D) -> Point {
        let latitude = coordinate.latitude.isFinite
            ? min(max(coordinate.latitude, -maximumMercatorLatitude), maximumMercatorLatitude)
            : 0
        let longitude = coordinate.longitude.isFinite
            ? min(max(coordinate.longitude, -180), 180)
            : 0
        let latitudeRadians = latitude * .pi / 180
        let x = (longitude + 180) / 360
        let y = (1 - asinh(tan(latitudeRadians)) / .pi) / 2
        return Point(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    private static func polygon(_ polygon: [Point], intersects rectangle: Rectangle) -> Bool {
        if polygon.contains(where: rectangle.contains) { return true }
        if rectangle.corners.contains(where: { pointInPolygon($0, polygon: polygon) }) { return true }

        for index in polygon.indices {
            let nextIndex = polygon.index(after: index) == polygon.endIndex
                ? polygon.startIndex
                : polygon.index(after: index)
            let start = polygon[index]
            let end = polygon[nextIndex]
            if rectangle.edges.contains(where: { segmentsIntersect(start, end, $0.0, $0.1) }) {
                return true
            }
        }
        return false
    }

    private static func pointInPolygon(_ point: Point, polygon: [Point]) -> Bool {
        var inside = false
        var previous = polygon[polygon.count - 1]

        for current in polygon {
            if pointOnSegment(point, previous, current) { return true }
            if (current.y > point.y) != (previous.y > point.y) {
                let intersectionX = (previous.x - current.x) * (point.y - current.y)
                    / (previous.y - current.y) + current.x
                if point.x < intersectionX { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private static func segmentsIntersect(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        let o1 = orientation(a, b, c)
        let o2 = orientation(a, b, d)
        let o3 = orientation(c, d, a)
        let o4 = orientation(c, d, b)

        if oppositeSigns(o1, o2), oppositeSigns(o3, o4) { return true }
        return (approximatelyZero(o1) && pointOnSegment(c, a, b))
            || (approximatelyZero(o2) && pointOnSegment(d, a, b))
            || (approximatelyZero(o3) && pointOnSegment(a, c, d))
            || (approximatelyZero(o4) && pointOnSegment(b, c, d))
    }

    private static func orientation(_ a: Point, _ b: Point, _ c: Point) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func oppositeSigns(_ lhs: Double, _ rhs: Double) -> Bool {
        (lhs > 0 && rhs < 0) || (lhs < 0 && rhs > 0)
    }

    private static func approximatelyZero(_ value: Double) -> Bool {
        abs(value) <= 1e-12
    }

    private static func pointOnSegment(_ point: Point, _ a: Point, _ b: Point) -> Bool {
        guard approximatelyZero(orientation(a, b, point)) else { return false }
        return point.x >= min(a.x, b.x) - 1e-12
            && point.x <= max(a.x, b.x) + 1e-12
            && point.y >= min(a.y, b.y) - 1e-12
            && point.y <= max(a.y, b.y) + 1e-12
    }
}

private struct Point {
    let x: Double
    let y: Double
}

private struct Rectangle {
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double

    func contains(_ point: Point) -> Bool {
        point.x >= left && point.x <= right && point.y >= top && point.y <= bottom
    }

    var corners: [Point] {
        [
            Point(x: left, y: top),
            Point(x: right, y: top),
            Point(x: right, y: bottom),
            Point(x: left, y: bottom)
        ]
    }

    var edges: [(Point, Point)] {
        let points = corners
        return [
            (points[0], points[1]),
            (points[1], points[2]),
            (points[2], points[3]),
            (points[3], points[0])
        ]
    }
}
