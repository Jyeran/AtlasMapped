import CoreLocation
import Foundation
import MapKit

enum RouteMath {
    struct Position: Equatable {
        let progress: Double
        let distanceFromRoute: CLLocationDistance
    }

    static func distance(along coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    static func cumulativeDistances(along coordinates: [CLLocationCoordinate2D]) -> [CLLocationDistance] {
        guard !coordinates.isEmpty else { return [] }
        var result: [CLLocationDistance] = [0]
        result.reserveCapacity(coordinates.count)
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            let segment = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            result.append((result.last ?? 0) + segment)
        }
        return result
    }

    static func coordinate(
        at progress: Double,
        along coordinates: [CLLocationCoordinate2D]
    ) -> CLLocationCoordinate2D? {
        guard let first = coordinates.first else { return nil }
        guard coordinates.count > 1 else { return first }

        let cumulative = cumulativeDistances(along: coordinates)
        guard let total = cumulative.last, total > 0 else { return first }
        let target = min(1, max(0, progress)) * total

        for index in 1..<coordinates.count where cumulative[index] >= target {
            let segmentStart = cumulative[index - 1]
            let segmentLength = cumulative[index] - segmentStart
            let fraction = segmentLength > 0 ? (target - segmentStart) / segmentLength : 0
            let start = MKMapPoint(coordinates[index - 1])
            let end = MKMapPoint(coordinates[index])
            return MKMapPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            ).coordinate
        }

        return coordinates.last
    }

    static func elevation(at progress: Double, in profile: [Double]) -> Double? {
        guard profile.count > 1 else { return nil }
        let clamped = min(1, max(0, progress))
        let scaled = clamped * Double(profile.count - 1)
        let lower = min(profile.count - 1, Int(scaled.rounded(.down)))
        let upper = min(profile.count - 1, lower + 1)
        let fraction = scaled - Double(lower)
        return profile[lower] + (profile[upper] - profile[lower]) * fraction
    }

    static func cumulativeElevationGain(in profile: [Double]) -> [Double] {
        guard !profile.isEmpty else { return [] }
        var totalGain = 0.0
        var result = [0.0]
        result.reserveCapacity(profile.count)

        for (previous, current) in zip(profile, profile.dropFirst()) {
            totalGain += max(0, current - previous)
            result.append(totalGain)
        }
        return result
    }

    static func progress(location: CLLocationCoordinate2D, along route: [CLLocationCoordinate2D]) -> Double {
        position(location: location, along: route)?.progress ?? 0
    }

    static func position(location: CLLocationCoordinate2D, along route: [CLLocationCoordinate2D]) -> Position? {
        guard route.count > 1 else { return nil }
        let user = MKMapPoint(location)
        var bestDistance = Double.greatestFiniteMagnitude
        var completedAtBest = 0.0
        var completed = 0.0

        for (startCoordinate, endCoordinate) in zip(route, route.dropFirst()) {
            let start = MKMapPoint(startCoordinate)
            let end = MKMapPoint(endCoordinate)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : max(0, min(1, ((user.x - start.x) * dx + (user.y - start.y) * dy) / lengthSquared))
            let nearest = MKMapPoint(x: start.x + dx * t, y: start.y + dy * t)
            let distance = user.distance(to: nearest)
            let segment = start.distance(to: end)
            if distance < bestDistance {
                bestDistance = distance
                completedAtBest = completed + segment * t
            }
            completed += segment
        }
        let progress = completed > 0 ? min(1, max(0, completedAtBest / completed)) : 0
        return Position(progress: progress, distanceFromRoute: bestDistance)
    }
}
