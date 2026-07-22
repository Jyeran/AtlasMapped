import Foundation
import MapKit

struct ElevationProfileResult: Sendable {
    let elevationsMeters: [Double]
    let gainMeters: Double
}

enum ElevationServiceError: LocalizedError {
    case insufficientRoute
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .insufficientRoute: "Add at least two route points to sample terrain."
        case .invalidResponse: "The terrain service returned an unreadable elevation."
        case .unavailable: "Terrain elevation is temporarily unavailable."
        }
    }
}

actor ElevationService {
    static let providerID = "usgs-3dep-v1"

    func elevation(at coordinate: CLLocationCoordinate2D) async throws -> Double {
        try await Self.fetchElevation(at: coordinate)
    }

    func profile(for route: [RouteWaypoint]) async throws -> ElevationProfileResult {
        guard route.count > 1 else { throw ElevationServiceError.insufficientRoute }
        let sampleCount = min(48, max(16, Int(RouteMath.distance(along: route.map(\.coordinate)) / 75)))
        let samples = Self.evenlySpacedCoordinates(along: route.map(\.coordinate), count: sampleCount)
        var elevations = Array(repeating: 0.0, count: samples.count)

        // Small concurrent batches keep the route responsive without hammering the public service.
        for batchStart in stride(from: 0, to: samples.count, by: 8) {
            try Task.checkCancellation()
            let batchEnd = min(samples.count, batchStart + 8)
            try await withThrowingTaskGroup(of: (Int, Double).self) { group in
                for index in batchStart..<batchEnd {
                    let coordinate = samples[index]
                    group.addTask {
                        (index, try await Self.fetchElevation(at: coordinate))
                    }
                }
                for try await (index, elevation) in group {
                    elevations[index] = elevation
                }
            }
        }

        let gain = RouteMath.cumulativeElevationGain(in: elevations).last ?? 0
        return ElevationProfileResult(elevationsMeters: elevations, gainMeters: gain)
    }

    private static func fetchElevation(at coordinate: CLLocationCoordinate2D) async throws -> Double {
        var components = URLComponents(string: "https://epqs.nationalmap.gov/v1/json")
        components?.queryItems = [
            URLQueryItem(name: "x", value: String(coordinate.longitude)),
            URLQueryItem(name: "y", value: String(coordinate.latitude)),
            URLQueryItem(name: "units", value: "Meters"),
            URLQueryItem(name: "wkid", value: "4326"),
            URLQueryItem(name: "includeDate", value: "false")
        ]
        guard let url = components?.url else { throw ElevationServiceError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.setValue("AtlasMapped/0.1 (trail elevation profile)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ElevationServiceError.unavailable
        }
        let payload = try JSONDecoder().decode(ElevationPointResponse.self, from: data)
        guard let value = Double(payload.value), value > -10_000 else {
            throw ElevationServiceError.invalidResponse
        }
        return value
    }

    private static func evenlySpacedCoordinates(
        along route: [CLLocationCoordinate2D],
        count: Int
    ) -> [CLLocationCoordinate2D] {
        let points = route.map(MKMapPoint.init)
        let cumulative = RouteMath.cumulativeDistances(along: route)
        guard let total = cumulative.last, total > 0, count > 1 else { return route }
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(count)
        var segment = 0

        for sample in 0..<count {
            let target = total * Double(sample) / Double(count - 1)
            while segment + 1 < cumulative.count - 1, cumulative[segment + 1] < target {
                segment += 1
            }
            let segmentLength = max(1, cumulative[segment + 1] - cumulative[segment])
            let fraction = min(1, max(0, (target - cumulative[segment]) / segmentLength))
            let start = points[segment]
            let end = points[segment + 1]
            result.append(MKMapPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            ).coordinate)
        }
        return result
    }
}

private struct ElevationPointResponse: Decodable {
    let value: String
}
