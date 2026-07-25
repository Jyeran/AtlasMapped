#if canImport(ActivityKit)
import ActivityKit
import Foundation

struct AtlasTrackingAttributes: ActivityAttributes, Sendable {
    enum Mode: String, Codable, Hashable, Sendable {
        case plannedRoute
        case freeRecording
    }

    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case recording
            case paused
        }

        var phase: Phase
        var usesMetricUnits: Bool
        var progress: Double
        var distanceMeters: Double
        var remainingMeters: Double?
        var nextWaypointName: String?
        var nextWaypointRemainingMeters: Double?
        var paceSecondsPerMile: Double?
        var eta: Date?
        var elevationMeters: Double?
        var elevationGainMeters: Double
        var distanceFromRouteMeters: Double?
        var activeDuration: TimeInterval
        var elevationProfileMeters: [Double]
        var updatedAt: Date
    }

    var hikeID: UUID
    var routeName: String
    var mode: Mode
    var startedAt: Date
}
#endif
