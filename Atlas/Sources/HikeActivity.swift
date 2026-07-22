import CoreLocation
import Foundation
import Combine
import MapKit

enum HikeMode: String, Codable, Sendable {
    case plannedRoute
    case freeRecording
}

enum HikePhase: String, Codable, Sendable {
    case recording
    case paused
}

enum HikeSplitKind: String, Codable, Sendable {
    case activeLeg
    case waypoint
    case manual
}

struct HikeTrackSample: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var coordinate: RouteWaypoint
    var timestamp: Date
    var altitudeMeters: Double
    var horizontalAccuracyMeters: Double
    var beginsSegment: Bool

    init(location: CLLocation, beginsSegment: Bool) {
        coordinate = RouteWaypoint(location.coordinate)
        timestamp = location.timestamp
        altitudeMeters = location.altitude
        horizontalAccuracyMeters = location.horizontalAccuracy
        self.beginsSegment = beginsSegment
    }

    var location: CLLocation {
        CLLocation(
            coordinate: coordinate.coordinate,
            altitude: altitudeMeters,
            horizontalAccuracy: horizontalAccuracyMeters,
            verticalAccuracy: -1,
            timestamp: timestamp
        )
    }
}

struct HikeSplit: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var kind: HikeSplitKind
    var name: String
    var startedAt: Date
    var endedAt: Date
    var distanceMeters: Double
    var elevationGainMeters: Double
    var waypointID: UUID?
    var coordinate: RouteWaypoint?

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

struct RecordedHike: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var mode: HikeMode
    var startedAt: Date
    var endedAt: Date
    var activeDuration: TimeInterval
    var samples: [HikeTrackSample]
    var splits: [HikeSplit]
    var sourceRoute: RoutePlan?
    var recordedRoute: RoutePlan

    var elapsedDuration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    var distanceMeters: Double { HikeMetrics.distance(in: samples) }
    var elevationGainMeters: Double { HikeMetrics.elevationGain(in: samples) }
}

enum HikeMetrics {
    static func distance(in samples: [HikeTrackSample]) -> CLLocationDistance {
        zip(samples, samples.dropFirst()).reduce(0) { total, pair in
            guard !pair.1.beginsSegment else { return total }
            return total + pair.0.location.distance(from: pair.1.location)
        }
    }

    static func elevationGain(in samples: [HikeTrackSample]) -> Double {
        zip(samples, samples.dropFirst()).reduce(0) { total, pair in
            guard !pair.1.beginsSegment else { return total }
            let change = pair.1.altitudeMeters - pair.0.altitudeMeters
            // Suppress the smallest GPS altitude oscillations without hiding
            // genuine climbing over a sequence of samples.
            return total + (change >= 1.5 ? change : 0)
        }
    }

    static func distance(from startIndex: Int, through endIndex: Int, in samples: [HikeTrackSample]) -> Double {
        guard samples.indices.contains(startIndex), samples.indices.contains(endIndex), endIndex >= startIndex else { return 0 }
        return distance(in: Array(samples[startIndex...endIndex]))
    }

    static func elevationGain(from startIndex: Int, through endIndex: Int, in samples: [HikeTrackSample]) -> Double {
        guard samples.indices.contains(startIndex), samples.indices.contains(endIndex), endIndex >= startIndex else { return 0 }
        return elevationGain(in: Array(samples[startIndex...endIndex]))
    }
}

@MainActor
final class HikeRecorder: ObservableObject {
    @Published private(set) var phase: HikePhase?
    @Published private(set) var mode: HikeMode?
    @Published private(set) var samples: [HikeTrackSample] = []
    @Published private(set) var splits: [HikeSplit] = []
    @Published private(set) var achievedWaypointIDs: [UUID] = []
    @Published private(set) var now = Date.now

    private(set) var id = UUID()
    private(set) var name = "Recorded Hike"
    private(set) var startedAt: Date?
    private(set) var sourceRoute: RoutePlan?
    private var activeStartedAt: Date?
    private var completedActiveDuration: TimeInterval = 0
    private var activeLegStartSampleIndex = 0
    private var manualSplitStartSampleIndex = 0
    private var nextWaypointIndex = 0
    private var needsSegmentStart = true
    private var clock: AnyCancellable?

    var isActive: Bool { phase != nil }
    var isPaused: Bool { phase == .paused }
    var distanceMeters: Double { HikeMetrics.distance(in: samples) }
    var elevationGainMeters: Double { HikeMetrics.elevationGain(in: samples) }
    var elapsedDuration: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }
    var activeDuration: TimeInterval {
        completedActiveDuration + (activeStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
    var paceSecondsPerMile: Double? {
        guard distanceMeters >= 20, activeDuration > 0 else { return nil }
        return activeDuration / (distanceMeters / 1_609.344)
    }
    var nextWaypoint: NamedRouteWaypoint? {
        guard let sourceRoute,
              let waypoints = sourceRoute.namedWaypoints?.sorted(by: { $0.routePointIndex < $1.routePointIndex }),
              waypoints.indices.contains(nextWaypointIndex) else { return nil }
        return waypoints[nextWaypointIndex]
    }

    func startPlanned(route: RoutePlan, at date: Date = .now) {
        reset()
        id = UUID()
        mode = .plannedRoute
        phase = .recording
        name = route.name
        sourceRoute = route
        startedAt = date
        activeStartedAt = date
        now = date
        startClock()
    }

    func startFreeRecording(at date: Date = .now) {
        reset()
        id = UUID()
        mode = .freeRecording
        phase = .recording
        name = "Recorded Hike"
        startedAt = date
        activeStartedAt = date
        now = date
        startClock()
    }

    func ingest(_ location: CLLocation) {
        guard phase == .recording,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100 else { return }
        now = max(now, location.timestamp)
        if let previous = samples.last, !needsSegmentStart {
            let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
            let distance = previous.location.distance(from: location)
            guard seconds > 0, distance / seconds < 15 else { return }
        }
        let previous = samples.last
        samples.append(HikeTrackSample(location: location, beginsSegment: needsSegmentStart))
        needsSegmentStart = false
        inferReachedWaypoints(previous: previous, current: location)
    }

    func pause(at date: Date = .now) {
        guard phase == .recording else { return }
        now = date
        closeActiveLeg(at: date)
        phase = .paused
        needsSegmentStart = true
    }

    func resume(at date: Date = .now) {
        guard phase == .paused else { return }
        now = date
        phase = .recording
        activeStartedAt = date
        activeLegStartSampleIndex = max(0, samples.count - 1)
        needsSegmentStart = true
    }

    @discardableResult
    func addManualSplit(named splitName: String? = nil, at date: Date = .now) -> HikeSplit? {
        guard phase != nil, let lastIndex = samples.indices.last else { return nil }
        let startIndex = min(manualSplitStartSampleIndex, lastIndex)
        let split = makeSplit(
            kind: .manual,
            name: splitName ?? "Split \(splits.filter { $0.kind == .manual }.count + 1)",
            startIndex: startIndex,
            endIndex: lastIndex,
            endedAt: date,
            waypointID: nil,
            coordinate: samples[lastIndex].coordinate
        )
        splits.append(split)
        manualSplitStartSampleIndex = lastIndex
        return split
    }

    func finish(recordedRoute: RoutePlan, at date: Date = .now) -> RecordedHike? {
        guard let startedAt, let mode else { return nil }
        now = date
        if phase == .recording { closeActiveLeg(at: date) }
        let result = RecordedHike(
            id: id,
            name: recordedRoute.name,
            mode: mode,
            startedAt: startedAt,
            endedAt: date,
            activeDuration: completedActiveDuration,
            samples: samples,
            splits: splits,
            sourceRoute: sourceRoute,
            recordedRoute: recordedRoute
        )
        reset()
        return result
    }

    func cancel() { reset() }

    private func inferReachedWaypoints(previous: HikeTrackSample?, current: CLLocation) {
        guard let route = sourceRoute,
              let waypoints = route.namedWaypoints?.sorted(by: { $0.routePointIndex < $1.routePointIndex }) else { return }
        // Evaluate only the next ordered stop once per GPS sample. Besides
        // respecting route order, this prevents a loop's future occurrence
        // at the previous coordinate from being consumed while walking away.
        while waypoints.indices.contains(nextWaypointIndex),
              !route.coordinates.indices.contains(waypoints[nextWaypointIndex].routePointIndex) {
            nextWaypointIndex += 1
        }
        guard waypoints.indices.contains(nextWaypointIndex) else { return }
        let waypoint = waypoints[nextWaypointIndex]
        let target = route.coordinates[waypoint.routePointIndex]
        let direct = current.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        let crossed = previous.map {
            Self.distance(target, toSegmentFrom: $0.coordinate.coordinate, to: current.coordinate) <= 35
        } ?? false
        guard direct <= 35 || crossed else { return }
        achievedWaypointIDs.append(waypoint.id)
        let endIndex = max(0, samples.count - 1)
        let priorWaypointSample = splits.last(where: { $0.kind == .waypoint }).flatMap { prior in
            samples.lastIndex(where: { $0.timestamp <= prior.endedAt })
        } ?? 0
        splits.append(makeSplit(
            kind: .waypoint,
            name: waypoint.name,
            startIndex: priorWaypointSample,
            endIndex: endIndex,
            endedAt: current.timestamp,
            waypointID: waypoint.id,
            coordinate: RouteWaypoint(target)
        ))
        nextWaypointIndex += 1
    }

    private func closeActiveLeg(at date: Date) {
        guard let activeStartedAt else { return }
        completedActiveDuration += max(0, date.timeIntervalSince(activeStartedAt))
        if let endIndex = samples.indices.last {
            splits.append(makeSplit(
                kind: .activeLeg,
                name: "Active leg \(splits.filter { $0.kind == .activeLeg }.count + 1)",
                startIndex: min(activeLegStartSampleIndex, endIndex),
                endIndex: endIndex,
                endedAt: date,
                waypointID: nil,
                coordinate: samples[endIndex].coordinate
            ))
        }
        self.activeStartedAt = nil
    }

    private func makeSplit(
        kind: HikeSplitKind,
        name: String,
        startIndex: Int,
        endIndex: Int,
        endedAt: Date,
        waypointID: UUID?,
        coordinate: RouteWaypoint?
    ) -> HikeSplit {
        HikeSplit(
            kind: kind,
            name: name,
            startedAt: samples.indices.contains(startIndex) ? samples[startIndex].timestamp : (startedAt ?? endedAt),
            endedAt: endedAt,
            distanceMeters: HikeMetrics.distance(from: startIndex, through: endIndex, in: samples),
            elevationGainMeters: HikeMetrics.elevationGain(from: startIndex, through: endIndex, in: samples),
            waypointID: waypointID,
            coordinate: coordinate
        )
    }

    private func startClock() {
        clock = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.now = date }
    }

    private func reset() {
        clock?.cancel()
        clock = nil
        phase = nil
        mode = nil
        samples = []
        splits = []
        achievedWaypointIDs = []
        sourceRoute = nil
        startedAt = nil
        activeStartedAt = nil
        completedActiveDuration = 0
        activeLegStartSampleIndex = 0
        manualSplitStartSampleIndex = 0
        nextWaypointIndex = 0
        needsSegmentStart = true
        now = .now
    }

    private static func distance(
        _ point: CLLocationCoordinate2D,
        toSegmentFrom start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let p = MKMapPoint(point), a = MKMapPoint(start), b = MKMapPoint(end)
        let dx = b.x - a.x, dy = b.y - a.y
        let denominator = dx * dx + dy * dy
        let t = denominator == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / denominator))
        return p.distance(to: MKMapPoint(x: a.x + dx * t, y: a.y + dy * t))
    }
}

@MainActor
final class HikeLibrary: ObservableObject {
    @Published private(set) var hikes: [RecordedHike] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
        load()
    }

    func save(_ hike: RecordedHike) {
        hikes.removeAll { $0.id == hike.id }
        hikes.insert(hike, at: 0)
        persist()
    }

    func delete(id: UUID) {
        hikes.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.atlas.decode([RecordedHike].self, from: data) else { return }
        hikes = decoded.sorted { $0.startedAt > $1.startedAt }
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? JSONEncoder.atlas.encode(hikes).write(to: fileURL, options: .atomic)
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AtlasMapped", isDirectory: true)
            .appendingPathComponent("recorded-hikes.json")
    }
}
