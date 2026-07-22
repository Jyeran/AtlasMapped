import CoreLocation
import MapKit

enum TrailRouteBuilder {
    static func connectedCoordinates(
        startingWith selected: TrailMapFeature,
        among features: [TrailMapFeature],
        connectionToleranceMeters: CLLocationDistance = 35
    ) -> [CLLocationCoordinate2D] {
        var route = selected.coordinates.map(\.coordinate)
        guard let name = selected.name, route.count > 1 else { return route }

        var remaining = features.filter {
            $0.id != selected.id && $0.name == name && $0.coordinates.count > 1
        }

        while let match = bestConnection(to: route, among: remaining),
              match.distance <= connectionToleranceMeters {
            let segment = remaining.remove(at: match.index).coordinates.map(\.coordinate)
            route = attach(segment, to: route, using: match.kind)
        }
        return removingConsecutiveDuplicates(from: route)
    }

    static func nearestFeature(
        to coordinate: CLLocationCoordinate2D,
        among features: [TrailMapFeature],
        maximumDistanceMeters: CLLocationDistance = 500
    ) -> TrailMapFeature? {
        features
            .compactMap { feature -> (TrailMapFeature, CLLocationDistance)? in
                let distance = distance(from: coordinate, to: feature.coordinates.map(\.coordinate))
                return distance <= maximumDistanceMeters ? (feature, distance) : nil
            }
            .min { $0.1 < $1.1 }?.0
    }

    static func routeStarting(
        at start: CLLocationCoordinate2D,
        along coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        let nearestIndex = coordinates.indices.min {
            meters(between: start, and: coordinates[$0]) < meters(between: start, and: coordinates[$1])
        } ?? coordinates.startIndex

        let prefix = Array(coordinates[...nearestIndex].reversed())
        let suffix = Array(coordinates[nearestIndex...])
        var route = length(of: prefix) > length(of: suffix) ? prefix : suffix
        if let first = route.first, meters(between: start, and: first) > 2 {
            route.insert(start, at: 0)
        } else if !route.isEmpty {
            route[0] = start
        }
        return removingConsecutiveDuplicates(from: route)
    }

    static func distance(
        from coordinate: CLLocationCoordinate2D,
        to line: [CLLocationCoordinate2D]
    ) -> CLLocationDistance {
        guard let first = line.first else { return .greatestFiniteMagnitude }
        guard line.count > 1 else { return meters(between: coordinate, and: first) }

        let point = MKMapPoint(coordinate)
        var best = Double.greatestFiniteMagnitude
        for index in 1..<line.count {
            let start = MKMapPoint(line[index - 1])
            let end = MKMapPoint(line[index])
            let dx = end.x - start.x
            let dy = end.y - start.y
            let denominator = dx * dx + dy * dy
            let fraction = denominator > 0
                ? max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator))
                : 0
            let closest = MKMapPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
            best = min(best, point.distance(to: closest))
        }
        return best
    }

    private enum ConnectionKind { case appendForward, appendReversed, prependForward, prependReversed }

    private struct Connection {
        let index: Int
        let distance: CLLocationDistance
        let kind: ConnectionKind
    }

    private static func bestConnection(
        to route: [CLLocationCoordinate2D],
        among features: [TrailMapFeature]
    ) -> Connection? {
        guard let routeStart = route.first, let routeEnd = route.last else { return nil }
        var best: Connection?
        for (index, feature) in features.enumerated() {
            guard let featureStart = feature.coordinates.first?.coordinate,
                  let featureEnd = feature.coordinates.last?.coordinate else { continue }
            let candidates = [
                Connection(index: index, distance: meters(between: routeEnd, and: featureStart), kind: .appendForward),
                Connection(index: index, distance: meters(between: routeEnd, and: featureEnd), kind: .appendReversed),
                Connection(index: index, distance: meters(between: routeStart, and: featureEnd), kind: .prependForward),
                Connection(index: index, distance: meters(between: routeStart, and: featureStart), kind: .prependReversed)
            ]
            for candidate in candidates where best == nil || candidate.distance < best!.distance {
                best = candidate
            }
        }
        return best
    }

    private static func attach(
        _ segment: [CLLocationCoordinate2D],
        to route: [CLLocationCoordinate2D],
        using kind: ConnectionKind
    ) -> [CLLocationCoordinate2D] {
        switch kind {
        case .appendForward: route + segment
        case .appendReversed: route + Array(segment.reversed())
        case .prependForward: segment + route
        case .prependReversed: Array(segment.reversed()) + route
        }
    }

    private static func removingConsecutiveDuplicates(
        from coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        coordinates.reduce(into: []) { result, coordinate in
            if let last = result.last, meters(between: last, and: coordinate) < 0.5 { return }
            result.append(coordinate)
        }
    }

    private static func length(of coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count > 1 else { return 0 }
        return zip(coordinates, coordinates.dropFirst()).reduce(0) {
            $0 + meters(between: $1.0, and: $1.1)
        }
    }

    private static func meters(
        between lhs: CLLocationCoordinate2D,
        and rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }
}
