import CoreLocation
import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct RouteWaypoint: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum RouteWaypointKind: String, Codable, Hashable, Sendable {
    case standard
    case pin
    case trailhead
    case peak
    case saddle
    case viewpoint
    case shelter
    case campsite
    case water
    case spring

    var symbol: String {
        switch self {
        case .standard: "circle.fill"
        case .pin: "mappin"
        case .trailhead: "figure.hiking"
        case .peak: "mountain.2.fill"
        case .saddle: "mountain.2"
        case .viewpoint: "binoculars.fill"
        case .shelter: "house.fill"
        case .campsite: "tent.fill"
        case .water: "waterbottle.fill"
        case .spring: "drop.fill"
        }
    }

    init(_ outdoorKind: OutdoorPointKind) {
        switch outdoorKind {
        case .trailhead: self = .trailhead
        case .peak: self = .peak
        case .saddle: self = .saddle
        case .viewpoint: self = .viewpoint
        case .shelter: self = .shelter
        case .campsite: self = .campsite
        case .water: self = .water
        case .spring: self = .spring
        }
    }
}

struct NamedRouteWaypoint: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var routePointIndex: Int
    var name: String
    var note: String?
    var kind: RouteWaypointKind?
    var sourceID: String?

    init(
        id: UUID = UUID(),
        routePointIndex: Int,
        name: String,
        note: String? = nil,
        kind: RouteWaypointKind? = nil,
        sourceID: String? = nil
    ) {
        self.id = id
        self.routePointIndex = routePointIndex
        self.name = name
        self.note = note
        self.kind = kind
        self.sourceID = sourceID
    }

    var resolvedKind: RouteWaypointKind { kind ?? .standard }
    var resolvedNote: String { note ?? "" }
}

enum RoutePinColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue
    case orange
    case forest
    case red
    case purple
    case brown

    var id: String { rawValue }
}

enum RoutePinSymbol: String, Codable, CaseIterable, Identifiable, Sendable {
    case pin
    case water
    case peak
    case trail
    case camp
    case viewpoint
    case caution
    case parking

    var id: String { rawValue }

    var systemName: String {
        switch self {
        case .pin: "mappin"
        case .water: "drop.fill"
        case .peak: "mountain.2.fill"
        case .trail: "figure.hiking"
        case .camp: "tent.fill"
        case .viewpoint: "binoculars.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .parking: "car.fill"
        }
    }

    var title: String {
        switch self {
        case .pin: "Pin"
        case .water: "Water"
        case .peak: "Peak"
        case .trail: "Trail"
        case .camp: "Camp"
        case .viewpoint: "View"
        case .caution: "Caution"
        case .parking: "Parking"
        }
    }
}

struct RoutePin: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var latitude: Double
    var longitude: Double
    var title: String
    var note: String
    var elevationMeters: Double?
    var color: RoutePinColor?
    var symbol: RoutePinSymbol?

    init(
        id: UUID = UUID(),
        coordinate: CLLocationCoordinate2D,
        title: String,
        note: String = "",
        elevationMeters: Double? = nil,
        color: RoutePinColor = .blue,
        symbol: RoutePinSymbol = .pin
    ) {
        self.id = id
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.title = title
        self.note = note
        self.elevationMeters = elevationMeters
        self.color = color
        self.symbol = symbol
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var resolvedColor: RoutePinColor { color ?? .blue }
    var resolvedSymbol: RoutePinSymbol { symbol ?? .pin }
}

struct RoutePlan: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var waypoints: [RouteWaypoint]
    var distanceMeters: Double
    var elevationGainMeters: Double
    var elevationProfileMeters: [Double]?
    var elevationProfileProvider: String?
    var routeWaypointIndices: [Int]?
    var namedWaypoints: [NamedRouteWaypoint]?
    var pins: [RoutePin]?
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        coordinates: [CLLocationCoordinate2D],
        distanceMeters: Double,
        elevationGainMeters: Double,
        elevationProfileMeters: [Double]? = nil,
        elevationProfileProvider: String? = nil,
        routeWaypointIndices: [Int]? = nil,
        namedWaypoints: [NamedRouteWaypoint]? = nil,
        pins: [RoutePin]? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        waypoints = coordinates.map(RouteWaypoint.init)
        self.distanceMeters = distanceMeters
        self.elevationGainMeters = elevationGainMeters
        self.elevationProfileMeters = elevationProfileMeters
        self.elevationProfileProvider = elevationProfileProvider
        self.routeWaypointIndices = routeWaypointIndices
        self.namedWaypoints = namedWaypoints
        self.pins = pins
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    var coordinates: [CLLocationCoordinate2D] { waypoints.map(\.coordinate) }
}

extension UTType {
    static let atlasRoute = UTType(exportedAs: "com.atlasmapped.route", conformingTo: .json)
}

struct AtlasRouteDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.atlasRoute, .json] }
    var plan: RoutePlan

    init(plan: RoutePlan) { self.plan = plan }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        plan = try JSONDecoder.atlas.decode(RoutePlan.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder.atlas.encode(plan))
    }
}

extension JSONEncoder {
    static var atlas: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var atlas: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
