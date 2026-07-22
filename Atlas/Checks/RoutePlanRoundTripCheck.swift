import CoreLocation
import Foundation

@main
enum RoutePlanRoundTripCheck {
    static func main() throws {
        let id = UUID(uuidString: "17B832A2-A5E6-4D24-9355-5F2D23E0A8B1")!
        let createdAt = Date(timeIntervalSince1970: 1_720_000_000)
        let modifiedAt = Date(timeIntervalSince1970: 1_720_003_600)
        let plan = RoutePlan(
            id: id,
            name: "Bear Peak loop",
            coordinates: [
                CLLocationCoordinate2D(latitude: 39.9784, longitude: -105.2947),
                CLLocationCoordinate2D(latitude: 39.9712, longitude: -105.2920),
                CLLocationCoordinate2D(latitude: 39.9648, longitude: -105.2874)
            ],
            distanceMeters: 8_472.35,
            elevationGainMeters: 613.8,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )

        // This is the exact JSON payload stored in a portable .atlasroute file.
        let atlasRouteJSON = try JSONEncoder.atlas.encode(plan)
        let decoded = try JSONDecoder.atlas.decode(RoutePlan.self, from: atlasRouteJSON)

        precondition(decoded.id == plan.id, "Route id did not survive .atlasroute round trip")
        precondition(decoded.name == plan.name, "Route name did not survive .atlasroute round trip")
        precondition(decoded.waypoints == plan.waypoints, "Route coordinates did not survive .atlasroute round trip")
        precondition(decoded.distanceMeters == plan.distanceMeters, "Route distance did not survive .atlasroute round trip")
        precondition(decoded.elevationGainMeters == plan.elevationGainMeters, "Route elevation did not survive .atlasroute round trip")
        precondition(decoded.createdAt == plan.createdAt, "Route creation date did not survive .atlasroute round trip")
        precondition(decoded.modifiedAt == plan.modifiedAt, "Route modification date did not survive .atlasroute round trip")

        print("RoutePlan .atlasroute round-trip check passed")
    }
}
