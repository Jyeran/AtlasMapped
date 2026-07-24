import CoreLocation
import Foundation

struct TrailViewport: Sendable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    var cacheKey: String {
        [south, west, north, east]
            .map { String(format: "%.3f", $0) }
            .joined(separator: ",")
    }

    init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    init?(boundary: [RouteWaypoint]) {
        guard let first = boundary.first else { return nil }
        south = boundary.dropFirst().reduce(first.latitude) { min($0, $1.latitude) }
        west = boundary.dropFirst().reduce(first.longitude) { min($0, $1.longitude) }
        north = boundary.dropFirst().reduce(first.latitude) { max($0, $1.latitude) }
        east = boundary.dropFirst().reduce(first.longitude) { max($0, $1.longitude) }
    }

    func contains(_ coordinate: RouteWaypoint) -> Bool {
        coordinate.latitude >= south && coordinate.latitude <= north
            && coordinate.longitude >= west && coordinate.longitude <= east
    }

    func contains(_ viewport: TrailViewport) -> Bool {
        viewport.south >= south
            && viewport.west >= west
            && viewport.north <= north
            && viewport.east <= east
    }

    func chunks(maximumSpan: Double) -> [TrailViewport] {
        let rows = max(1, Int(ceil((north - south) / maximumSpan)))
        let columns = max(1, Int(ceil((east - west) / maximumSpan)))
        let latitudeStep = (north - south) / Double(rows)
        let longitudeStep = (east - west) / Double(columns)
        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                TrailViewport(
                    south: south + Double(row) * latitudeStep,
                    west: west + Double(column) * longitudeStep,
                    north: row == rows - 1 ? north : south + Double(row + 1) * latitudeStep,
                    east: column == columns - 1 ? east : west + Double(column + 1) * longitudeStep
                )
            }
        }
    }

    /// Snaps roaming map requests to stable cells so small pans reuse cached
    /// data instead of producing a nearly-identical network request each time.
    func alignedToGrid(cellSize: Double) -> TrailViewport {
        TrailViewport(
            south: floor(south / cellSize) * cellSize,
            west: floor(west / cellSize) * cellSize,
            north: ceil(north / cellSize) * cellSize,
            east: ceil(east / cellSize) * cellSize
        )
    }
}

struct TrailMapFeature: Codable, Sendable {
    enum Source: String, Codable, Sendable { case openStreetMap, forestService }
    enum Importance: String, Codable, Sendable { case minor, standard, major }

    let id: String
    let name: String?
    let coordinates: [RouteWaypoint]
    let source: Source
    /// Optional so previously downloaded trail packages remain decodable.
    let importance: Importance?

    init(
        id: String,
        name: String?,
        coordinates: [RouteWaypoint],
        source: Source,
        importance: Importance = .standard
    ) {
        self.id = id
        self.name = name
        self.coordinates = coordinates
        self.source = source
        self.importance = importance
    }
}

enum TrailFeatureIndex {
    static func trailsByID(_ trails: [TrailMapFeature]) -> [String: TrailMapFeature] {
        Dictionary(
            trails.map { ($0.id, $0) },
            uniquingKeysWith: { existing, candidate in
                candidate.coordinates.count > existing.coordinates.count ? candidate : existing
            }
        )
    }

    static func pointsByID(_ points: [OutdoorPointFeature]) -> [String: OutdoorPointFeature] {
        Dictionary(
            points.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
    }
}

enum OSMTrailClassifier {
    static func shouldInclude(tags: [String: String]) -> Bool {
        guard let highway = tags["highway"] else { return false }
        guard tags["access"] != "private",
              tags["access"] != "no",
              tags["area"] != "yes",
              tags["indoor"] != "yes" else { return false }

        let footway = tags["footway"]?.lowercased()
        let surface = tags["surface"]?.lowercased()
        let motorVehicle = tags["motor_vehicle"]?.lowercased()
        let name = [
            tags["name"],
            tags["official_name"],
            tags["loc_name"]
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        let streetFootway = ["sidewalk", "crossing", "traffic_island", "link"].contains(footway)
            || tags["crossing"] != nil
            || tags["sidewalk"] != nil
        let naturalSurface = [
            "unpaved", "compacted", "fine_gravel", "gravel", "pebblestone",
            "dirt", "earth", "ground", "grass", "woodchips", "rock",
            "stone", "sand"
        ].contains(surface)
        let pavedSurface = [
            "paved", "asphalt", "concrete", "concrete:plates", "paving_stones"
        ].contains(surface)
        let trailNamed = ["trail", "path", "greenway", "footpath"].contains {
            name.contains($0)
        }
        let hikingEvidence = tags["sac_scale"] != nil
            || tags["trail_visibility"] != nil
            || tags["osmc:symbol"] != nil
            || tags["route"] == "hiking"
            || tags["hiking"] == "yes"
            || tags["foot"] == "designated"
            || tags["designation"]?.lowercased().contains("footpath") == true
            || trailNamed
        let vehicleOriented = ["yes", "designated"].contains(motorVehicle)

        switch highway {
        case "path", "bridleway":
            return !streetFootway && !vehicleOriented
        case "steps":
            return !streetFootway
        case "footway":
            // OSM uses footway for both hiking paths and ordinary urban
            // pedestrian infrastructure. Keep only outdoor/trail evidence.
            return !streetFootway
                && (hikingEvidence || naturalSurface || (!pavedSurface && !name.isEmpty))
        case "track":
            // A track is ordinarily a vehicle-width road. Only promote it to
            // Atlas's trail overlay when OSM explicitly identifies hiking use.
            return hikingEvidence && !vehicleOriented && !pavedSurface
        default:
            return false
        }
    }
}

struct WaterwayMapFeature: Codable, Sendable {
    let id: String
    let name: String?
    let coordinates: [RouteWaypoint]
    let kind: String
}

struct TerrainContourFeature: Codable, Sendable {
    let id: String
    let elevation: Double
    let units: String
    let isIndex: Bool
    let coordinates: [RouteWaypoint]
}

struct KnownOutdoorSearchHit: Identifiable, Sendable {
    enum Kind: String, Sendable { case trail, trailhead, mountain, outdoorPlace }

    let id: String
    let name: String
    let kind: Kind
    let coordinate: RouteWaypoint
    let trailCoordinates: [RouteWaypoint]?
    let outdoorPoint: OutdoorPointFeature?
}

enum OutdoorPointKind: String, Codable, Sendable, Equatable {
    case trailhead, peak, saddle, viewpoint, shelter, campsite, water, spring

    var title: String {
        switch self {
        case .trailhead: "Trailhead"
        case .peak: "Peak"
        case .saddle: "Mountain pass"
        case .viewpoint: "Viewpoint"
        case .shelter: "Shelter"
        case .campsite: "Campsite"
        case .water: "Drinking water"
        case .spring: "Spring"
        }
    }

    var symbol: String {
        switch self {
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
}

struct OutdoorPointFact: Codable, Sendable, Equatable {
    let label: String
    let value: String
}

struct OutdoorPointFeature: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    let coordinate: RouteWaypoint
    let kind: OutdoorPointKind
    let elevationMeters: Double?
    let description: String?
    let website: String?
    let facts: [OutdoorPointFact]
}

struct TrailMapDataset: Codable, Sendable {
    let trails: [TrailMapFeature]
    let points: [OutdoorPointFeature]
    let waterways: [WaterwayMapFeature]
    let contours: [TerrainContourFeature]

    init(
        trails: [TrailMapFeature],
        points: [OutdoorPointFeature],
        waterways: [WaterwayMapFeature] = [],
        contours: [TerrainContourFeature] = []
    ) {
        self.trails = trails
        self.points = points
        self.waterways = waterways
        self.contours = contours
    }

    private enum CodingKeys: String, CodingKey { case trails, points, waterways, contours }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trails = try values.decodeIfPresent([TrailMapFeature].self, forKey: .trails) ?? []
        points = try values.decodeIfPresent([OutdoorPointFeature].self, forKey: .points) ?? []
        waterways = try values.decodeIfPresent([WaterwayMapFeature].self, forKey: .waterways) ?? []
        contours = try values.decodeIfPresent([TerrainContourFeature].self, forKey: .contours) ?? []
    }
}

actor TrailDataService {
    static let shared = TrailDataService()

    private struct CacheEntry {
        let date: Date
        let dataset: TrailMapDataset
    }

    private var cache: [String: CacheEntry] = [:]
    private var trailFeatureCache: [String: CacheEntry] = [:]
    private var trailFeatureRequests: [String: Task<TrailMapDataset, Error>] = [:]
    private var forestFeatureCache: [String: (date: Date, trails: [TrailMapFeature])] = [:]
    private var forestFeatureRequests: [String: Task<[TrailMapFeature], Error>] = [:]

    func searchKnownFeatures(matching query: String) -> [KnownOutdoorSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 2 else { return [] }
        var datasets = cache.values.map(\.dataset) + trailFeatureCache.values.map(\.dataset)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: offlineDatasetDirectory,
            includingPropertiesForKeys: nil
        ) {
            datasets.append(contentsOf: files.compactMap { file in
                guard file.pathExtension == "json",
                      let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder.atlas.decode(TrailMapDataset.self, from: data)
            })
        }

        var hits: [KnownOutdoorSearchHit] = []
        var seen = Set<String>()
        for dataset in datasets {
            for trail in dataset.trails {
                guard let name = trail.name,
                      name.lowercased().contains(needle),
                      let midpoint = trail.coordinates.dropFirst(trail.coordinates.count / 2).first,
                      seen.insert("trail|\(name.lowercased())").inserted else { continue }
                hits.append(KnownOutdoorSearchHit(
                    id: "trail|\(trail.id)",
                    name: name,
                    kind: .trail,
                    coordinate: midpoint,
                    trailCoordinates: trail.coordinates,
                    outdoorPoint: nil
                ))
            }
            for point in dataset.points {
                guard point.name.lowercased().contains(needle),
                      seen.insert("point|\(point.id)").inserted else { continue }
                let kind: KnownOutdoorSearchHit.Kind = switch point.kind {
                case .trailhead: .trailhead
                case .peak, .saddle: .mountain
                default: .outdoorPlace
                }
                hits.append(KnownOutdoorSearchHit(
                    id: "point|\(point.id)",
                    name: point.name,
                    kind: kind,
                    coordinate: point.coordinate,
                    trailCoordinates: nil,
                    outdoorPoint: point
                ))
            }
        }
        return Array(hits.prefix(24))
    }

    /// Searches outdoor-focused OSM geocoding and the Forest Service trail
    /// catalog concurrently. Unlike the former exact-name Overpass request,
    /// this supports partial landmark names and returns promptly.
    func searchRemoteFeatures(matching query: String) async -> [KnownOutdoorSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }
        async let osmHits = searchNominatimFeatures(matching: trimmed)
        async let forestHits = searchForestServiceFeatures(matching: trimmed)
        let osm = await osmHits
        let forest = await forestHits
        return Array((osm + forest).prefix(24))
    }

    func dataset(in viewport: TrailViewport) async throws -> TrailMapDataset {
        if let cached = cache[viewport.cacheKey], Date().timeIntervalSince(cached.date) < 60 * 30 {
            return cached.dataset
        }

        let offline = offlineDataset(in: viewport)
        async let osmResult = try? fetchOpenStreetMap(in: viewport)
        async let forestResult = try? fetchForestService(in: viewport)
        async let contourResult = try? fetchContours(in: viewport)
        let osm = await osmResult ?? TrailMapDataset(trails: [], points: [])
        let forestTrails = await forestResult ?? []
        let contours = await contourResult ?? []
        let dataset = TrailMapDataset(
            trails: deduplicated(offline.trails + osm.trails + forestTrails),
            points: deduplicatedPoints(offline.points + osm.points),
            waterways: deduplicatedWaterways(offline.waterways + osm.waterways),
            contours: deduplicatedContours(offline.contours + contours)
        )
        cache[viewport.cacheKey] = CacheEntry(date: .now, dataset: dataset)
        return dataset
    }

    /// Fetches interactive trails, named outdoor places, and waterways without
    /// waiting for the much larger USGS contour response. The iOS renderer
    /// streams terrain independently so trail parity is not held up by relief.
    func trailFeatures(in viewport: TrailViewport) async throws -> TrailMapDataset {
        if let cached = trailFeatureCache[viewport.cacheKey], Date().timeIntervalSince(cached.date) < 60 * 30 {
            return cached.dataset
        }
        if let request = trailFeatureRequests[viewport.cacheKey] {
            return try await request.value
        }
        let request = Task { [self] in
            let offline = offlineDataset(in: viewport)
            let osm = try? await fetchOpenStreetMap(in: viewport)
            guard osm != nil || !offline.trails.isEmpty else { throw URLError(.cannotLoadFromNetwork) }
            return TrailMapDataset(
                trails: deduplicated(offline.trails + (osm?.trails ?? [])),
                points: deduplicatedPoints(offline.points + (osm?.points ?? [])),
                waterways: deduplicatedWaterways(offline.waterways + (osm?.waterways ?? []))
            )
        }
        trailFeatureRequests[viewport.cacheKey] = request
        do {
            let dataset = try await request.value
            trailFeatureRequests[viewport.cacheKey] = nil
            trailFeatureCache[viewport.cacheKey] = CacheEntry(date: .now, dataset: dataset)
            return dataset
        } catch {
            trailFeatureRequests[viewport.cacheKey] = nil
            throw error
        }
    }

    /// Forest Service geometry is supplemental and must never hold the primary
    /// OSM overlay hostage when its national ArcGIS service is slow.
    func forestServiceTrailFeatures(in viewport: TrailViewport) async throws -> [TrailMapFeature] {
        if let cached = forestFeatureCache[viewport.cacheKey], Date().timeIntervalSince(cached.date) < 60 * 30 {
            return cached.trails
        }
        if let request = forestFeatureRequests[viewport.cacheKey] { return try await request.value }
        let request = Task { try await self.fetchForestService(in: viewport) }
        forestFeatureRequests[viewport.cacheKey] = request
        do {
            let trails = try await request.value
            forestFeatureRequests[viewport.cacheKey] = nil
            forestFeatureCache[viewport.cacheKey] = (date: .now, trails: trails)
            return trails
        } catch {
            forestFeatureRequests[viewport.cacheKey] = nil
            throw error
        }
    }

    /// Returns terrain context independently of the slower comprehensive OSM
    /// trail query so contour lines can appear immediately while trail cells
    /// and metadata continue loading.
    func terrainContext(in viewport: TrailViewport) async -> TrailMapDataset {
        let offline = offlineDataset(in: viewport)
        let liveContours = (try? await fetchContours(in: viewport)) ?? []
        return TrailMapDataset(
            trails: [],
            points: offline.points,
            waterways: offline.waterways,
            contours: deduplicatedContours(offline.contours + liveContours)
        )
    }

    /// Persists the same detailed vector content used online alongside an
    /// offline topographic region. Raster tiles alone cannot preserve trail
    /// names, selectable geometry, trailheads, or outdoor metadata.
    func storeOfflineDataset(for areaID: UUID, boundary: [RouteWaypoint]) async throws -> Int64 {
        guard let viewport = TrailViewport(boundary: boundary) else { throw URLError(.badURL) }
        async let osmResult = try? fetchOpenStreetMap(in: viewport)
        async let forestResult = try? fetchForestService(in: viewport)
        let osm = await osmResult
        let forestTrails = await forestResult
        guard osm != nil || forestTrails != nil else { throw URLError(.cannotLoadFromNetwork) }

        let dataset = TrailMapDataset(
            trails: deduplicated((osm?.trails ?? []) + (forestTrails ?? [])),
            points: deduplicatedPoints(osm?.points ?? []),
            waterways: [],
            contours: []
        )
        let data = try JSONEncoder.atlas.encode(dataset)
        let destination = offlineDatasetURL(for: areaID)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        cache.removeAll()
        trailFeatureCache.removeAll()
        return Int64(data.count)
    }

    func removeOfflineDataset(for areaID: UUID) {
        try? FileManager.default.removeItem(at: offlineDatasetURL(for: areaID))
        cache.removeAll()
        trailFeatureCache.removeAll()
    }

    private func fetchOpenStreetMap(in viewport: TrailViewport) async throws -> TrailMapDataset {
        let chunks = viewport.chunks(maximumSpan: 0.12)
        var successfulChunks = 0
        var trails: [TrailMapFeature] = []
        var points: [OutdoorPointFeature] = []
        var waterways: [WaterwayMapFeature] = []

        await withTaskGroup(of: TrailMapDataset?.self) { group in
            for chunk in chunks {
                group.addTask { try? await self.fetchOpenStreetMapChunk(in: chunk) }
            }
            for await dataset in group {
                guard let dataset else { continue }
                successfulChunks += 1
                trails.append(contentsOf: dataset.trails)
                points.append(contentsOf: dataset.points)
                waterways.append(contentsOf: dataset.waterways)
            }
        }
        guard successfulChunks > 0 else { throw URLError(.cannotLoadFromNetwork) }
        return TrailMapDataset(
            trails: deduplicated(trails),
            points: deduplicatedPoints(points),
            waterways: deduplicatedWaterways(waterways)
        )
    }

    private func fetchOpenStreetMapChunk(in viewport: TrailViewport) async throws -> TrailMapDataset {
        guard let url = URL(string: "https://api.ohsome.org/v1/elements/geometry") else {
            throw URLError(.badURL)
        }
        let filter = """
        (highway in (path,footway,bridleway,steps,track) and type:way) or \
        (highway=trailhead and type:node) or (information=trailhead and type:node) or \
        (natural in (peak,saddle,spring) and type:node) or \
        (tourism in (viewpoint,alpine_hut,wilderness_hut,camp_site) and type:node) or \
        (amenity in (shelter,drinking_water) and type:node)
        """
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "bboxes", value: "\(viewport.west),\(viewport.south),\(viewport.east),\(viewport.north)"),
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "properties", value: "tags")
        ]
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("AtlasMapped/0.1 (detailed OSM trail map)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }

        var trails: [TrailMapFeature] = []
        var points: [OutdoorPointFeature] = []
        for feature in features {
            let rawProperties = feature["properties"] as? [String: Any] ?? [:]
            let tags = rawProperties.reduce(into: [String: String]()) { result, entry in
                guard !entry.key.hasPrefix("@") else { return }
                if let value = entry.value as? String { result[entry.key] = value }
                else if let value = entry.value as? NSNumber { result[entry.key] = value.stringValue }
            }
            let osmID = String(describing: rawProperties["@osmId"] ?? UUID().uuidString)
            guard tags["access"] != "private", tags["access"] != "no",
                  let geometry = feature["geometry"] as? [String: Any],
                  let geometryType = geometry["type"] as? String else { continue }
            if geometryType == "Point",
               let raw = geometry["coordinates"] as? [Double], raw.count >= 2,
               let kind = pointKind(from: tags) {
                points.append(outdoorPoint(
                    id: "osm-point-\(osmID)",
                    kind: kind,
                    coordinate: CLLocationCoordinate2D(latitude: raw[1], longitude: raw[0]),
                    tags: tags
                ))
            } else {
                guard OSMTrailClassifier.shouldInclude(tags: tags) else { continue }
                for (index, coordinates) in coordinateLines(from: geometry).enumerated() {
                    trails.append(TrailMapFeature(
                        id: "osm-way-\(osmID)-\(index)",
                        name: osmName(from: tags),
                        coordinates: coordinates,
                        source: .openStreetMap,
                        importance: trailImportance(from: tags, isRoute: false)
                    ))
                }
            }
        }
        return TrailMapDataset(trails: trails, points: points)
    }

    private func fetchForestService(in viewport: TrailViewport) async throws -> [TrailMapFeature] {
        var components = URLComponents(string: "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_TrailNFSPublish_01/MapServer/0/query")
        components?.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "geometry", value: "\(viewport.west),\(viewport.south),\(viewport.east),\(viewport.north)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: "objectid,trail_name,trail_no,trail_class,national_trail_designation"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "resultRecordCount", value: "2000"),
            URLQueryItem(name: "f", value: "geojson")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 24)
        request.setValue("AtlasMapped/0.1 (USDA Forest Service trails)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }

        return features.flatMap { feature -> [TrailMapFeature] in
            let properties = feature["properties"] as? [String: Any] ?? [:]
            let objectID = properties["objectid"] ?? properties["OBJECTID"] ?? UUID().uuidString
            let name = cleanName(properties["trail_name"] as? String ?? properties["TRAIL_NAME"] as? String)
                ?? cleanName(properties["trail_no"] as? String ?? properties["TRAIL_NO"] as? String)
            let trailClass = properties["trail_class"] as? String ?? properties["TRAIL_CLASS"] as? String
            let nationalDesignation = properties["national_trail_designation"] as? Int
                ?? properties["NATIONAL_TRAIL_DESIGNATION"] as? Int
            let importance: TrailMapFeature.Importance = if (nationalDesignation ?? 0) > 0 {
                .major
            } else {
                switch Int(trailClass ?? "") ?? 3 {
                case ...2: .minor
                case 4...: .major
                default: .standard
                }
            }
            guard let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String,
                  let rawCoordinates = geometry["coordinates"] else { return [] }

            let lines: [[[Double]]]
            if type == "LineString", let line = rawCoordinates as? [[Double]] {
                lines = [line]
            } else if type == "MultiLineString", let multiLine = rawCoordinates as? [[[Double]]] {
                lines = multiLine
            } else {
                return []
            }

            return lines.enumerated().compactMap { index, line in
                let coordinates = line.compactMap { point -> RouteWaypoint? in
                    guard point.count >= 2 else { return nil }
                    return RouteWaypoint(CLLocationCoordinate2D(latitude: point[1], longitude: point[0]))
                }
                guard coordinates.count > 1 else { return nil }
                return TrailMapFeature(
                    id: "usfs-\(objectID)-\(index)",
                    name: name,
                    coordinates: coordinates,
                    source: .forestService,
                    importance: importance
                )
            }
        }
    }

    private func searchNominatimFeatures(matching query: String) async -> [KnownOutdoorSearchHit] {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "addressdetails", value: "0"),
            URLQueryItem(name: "extratags", value: "1")
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("AtlasMapped/0.1 (user-initiated outdoor search)", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        guard let response = try? await URLSession.shared.data(for: request),
              (response.1 as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: response.0) as? [[String: Any]] else { return [] }

        let outdoorTypes: Set<String> = [
            "peak", "saddle", "volcano", "ridge", "cliff", "spring",
            "trailhead", "path", "footway", "bridleway", "track", "hiking",
            "viewpoint", "alpine_hut", "wilderness_hut", "camp_site", "shelter",
            "nature_reserve", "protected_area", "waterfall", "cave_entrance"
        ]
        return rows.compactMap { row in
            guard let latitude = (row["lat"] as? String).flatMap(Double.init),
                  let longitude = (row["lon"] as? String).flatMap(Double.init),
                  let displayName = cleanName(row["display_name"] as? String) else { return nil }
            let type = (row["type"] as? String)?.lowercased() ?? ""
            let category = (row["category"] as? String ?? row["class"] as? String)?.lowercased() ?? ""
            guard outdoorTypes.contains(type)
                    || ["natural", "tourism", "leisure", "highway"].contains(category) else { return nil }
            let name = cleanName(row["name"] as? String)
                ?? cleanName(displayName.components(separatedBy: ",").first)
                ?? displayName
            let kind: KnownOutdoorSearchHit.Kind
            if type == "trailhead" { kind = .trailhead }
            else if ["peak", "saddle", "volcano", "ridge", "cliff"].contains(type) { kind = .mountain }
            else if ["path", "footway", "bridleway", "track", "hiking"].contains(type) { kind = .trail }
            else { kind = .outdoorPlace }

            let coordinate = RouteWaypoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            return KnownOutdoorSearchHit(
                id: "nominatim|\(row["osm_type"] ?? "")|\(row["osm_id"] ?? UUID().uuidString)",
                name: name,
                kind: kind,
                coordinate: coordinate,
                trailCoordinates: nil,
                outdoorPoint: nil
            )
        }
    }

    private func searchForestServiceFeatures(matching query: String) async -> [KnownOutdoorSearchHit] {
        let escaped = query.uppercased().replacingOccurrences(of: "'", with: "''")
        var components = URLComponents(
            string: "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_TrailNFSPublish_01/MapServer/0/query"
        )
        components?.queryItems = [
            URLQueryItem(
                name: "where",
                value: "UPPER(trail_name) LIKE '%\(escaped)%' OR UPPER(trail_no) LIKE '%\(escaped)%'"
            ),
            URLQueryItem(name: "outFields", value: "objectid,trail_name,trail_no"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "resultRecordCount", value: "40"),
            URLQueryItem(name: "f", value: "geojson")
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.setValue("AtlasMapped/0.1 (user-initiated Forest Service trail search)", forHTTPHeaderField: "User-Agent")
        guard let response = try? await URLSession.shared.data(for: request),
              (response.1 as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }

        return features.compactMap { feature in
            let properties = feature["properties"] as? [String: Any] ?? [:]
            let objectID = properties["objectid"] ?? properties["OBJECTID"] ?? UUID().uuidString
            guard let name = cleanName(properties["trail_name"] as? String ?? properties["TRAIL_NAME"] as? String)
                    ?? cleanName(properties["trail_no"] as? String ?? properties["TRAIL_NO"] as? String),
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String,
                  let raw = geometry["coordinates"] else { return nil }
            let rawLine: [[Double]]
            if type == "LineString", let line = raw as? [[Double]] {
                rawLine = line
            } else if type == "MultiLineString", let lines = raw as? [[[Double]]] {
                rawLine = lines.max(by: { $0.count < $1.count }) ?? []
            } else {
                return nil
            }
            let coordinates = rawLine.compactMap { point -> RouteWaypoint? in
                guard point.count >= 2 else { return nil }
                return RouteWaypoint(CLLocationCoordinate2D(latitude: point[1], longitude: point[0]))
            }
            guard coordinates.count > 1 else { return nil }
            return KnownOutdoorSearchHit(
                id: "remote-usfs|\(objectID)",
                name: name,
                kind: .trail,
                coordinate: coordinates[coordinates.count / 2],
                trailCoordinates: coordinates,
                outdoorPoint: nil
            )
        }
    }

    private func fetchContours(in viewport: TrailViewport) async throws -> [TerrainContourFeature] {
        let span = max(viewport.north - viewport.south, viewport.east - viewport.west)
        let layerIDs: [Int]
        let chunkSpan: Double
        if span > 0.6 {
            return []
        } else if span > 0.18 {
            layerIDs = [11]
            chunkSpan = 0.18
        } else if span > 0.06 {
            layerIDs = [16, 18]
            chunkSpan = 0.08
        } else {
            layerIDs = [25, 26]
            chunkSpan = 0.04
        }

        var contours: [TerrainContourFeature] = []
        var successfulQueries = 0
        await withTaskGroup(of: [TerrainContourFeature]?.self) { group in
            for chunk in viewport.chunks(maximumSpan: chunkSpan) {
                for layerID in layerIDs {
                    group.addTask { try? await self.fetchContourChunk(in: chunk, layerID: layerID) }
                }
            }
            for await result in group {
                guard let result else { continue }
                successfulQueries += 1
                contours.append(contentsOf: result)
            }
        }
        guard successfulQueries > 0 else { throw URLError(.cannotLoadFromNetwork) }
        return deduplicatedContours(contours)
    }

    private func fetchContourChunk(
        in viewport: TrailViewport,
        layerID: Int
    ) async throws -> [TerrainContourFeature] {
        var components = URLComponents(
            string: "https://carto.nationalmap.gov/arcgis/rest/services/contours/MapServer/\(layerID)/query"
        )
        components?.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "geometry", value: "\(viewport.west),\(viewport.south),\(viewport.east),\(viewport.north)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: "*"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "resultRecordCount", value: "2000"),
            URLQueryItem(name: "maxAllowableOffset", value: "0.00012"),
            URLQueryItem(name: "resultType", value: "tile"),
            URLQueryItem(name: "f", value: "geojson")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("AtlasMapped/0.1 (USGS contour map)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }

        let indexLayer = [11, 16, 25].contains(layerID)
        return features.flatMap { feature -> [TerrainContourFeature] in
            let properties = feature["properties"] as? [String: Any] ?? [:]
            let objectID = properties["objectid"] ?? properties["OBJECTID"] ?? UUID().uuidString
            let elevation = (properties["ContourElevation"] as? NSNumber)?.doubleValue
                ?? (properties["contourelevation"] as? NSNumber)?.doubleValue
                ?? (properties["CONTOURELEVATION"] as? NSNumber)?.doubleValue
                ?? 0
            let unitCode = (properties["ContourUnits"] as? NSNumber)?.intValue
                ?? (properties["contourunits"] as? NSNumber)?.intValue
                ?? (properties["CONTOURUNITS"] as? NSNumber)?.intValue
                ?? 1
            guard let geometry = feature["geometry"] as? [String: Any] else { return [] }
            return coordinateLines(from: geometry).enumerated().map { index, coordinates in
                TerrainContourFeature(
                    id: "usgs-contour-\(layerID)-\(objectID)-\(index)",
                    elevation: elevation,
                    units: unitCode == 2 ? "m" : "ft",
                    isIndex: indexLayer,
                    coordinates: coordinates
                )
            }
        }
    }

    private func coordinateLines(from geometry: [String: Any]) -> [[RouteWaypoint]] {
        let type = geometry["type"] as? String
        let rawCoordinates = geometry["coordinates"]
        let lines: [[[Double]]]
        if type == "LineString", let line = rawCoordinates as? [[Double]] {
            lines = [line]
        } else if type == "MultiLineString", let multiLine = rawCoordinates as? [[[Double]]] {
            lines = multiLine
        } else {
            return []
        }
        return lines.compactMap { line in
            let coordinates = line.compactMap { point -> RouteWaypoint? in
                guard point.count >= 2 else { return nil }
                return RouteWaypoint(CLLocationCoordinate2D(latitude: point[1], longitude: point[0]))
            }
            return coordinates.count > 1 ? coordinates : nil
        }
    }

    private func deduplicated(_ trails: [TrailMapFeature]) -> [TrailMapFeature] {
        var keys = Set<String>()
        return trails.filter { trail in
            guard let first = trail.coordinates.first, let last = trail.coordinates.last else { return false }
            let endpoints = [first, last]
                .map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
                .sorted()
                .joined(separator: "|")
            return keys.insert("\(trail.name ?? "")|\(endpoints)").inserted
        }
    }

    private func deduplicatedPoints(_ points: [OutdoorPointFeature]) -> [OutdoorPointFeature] {
        var ids = Set<String>()
        return points.filter { ids.insert($0.id).inserted }
    }

    private func deduplicatedWaterways(_ waterways: [WaterwayMapFeature]) -> [WaterwayMapFeature] {
        var ids = Set<String>()
        return waterways.filter { ids.insert($0.id).inserted }
    }

    private func deduplicatedContours(_ contours: [TerrainContourFeature]) -> [TerrainContourFeature] {
        var ids = Set<String>()
        return contours.filter { ids.insert($0.id).inserted }
    }

    private func offlineDataset(in viewport: TrailViewport) -> TrailMapDataset {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: offlineDatasetDirectory,
            includingPropertiesForKeys: nil
        ) else { return TrailMapDataset(trails: [], points: []) }

        var trails: [TrailMapFeature] = []
        var points: [OutdoorPointFeature] = []
        var waterways: [WaterwayMapFeature] = []
        var contours: [TerrainContourFeature] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let dataset = try? JSONDecoder.atlas.decode(TrailMapDataset.self, from: data) else { continue }
            trails.append(contentsOf: dataset.trails.filter { trailIntersects($0, viewport: viewport) })
            points.append(contentsOf: dataset.points.filter { viewport.contains($0.coordinate) })
            waterways.append(contentsOf: dataset.waterways.filter {
                lineIntersects($0.coordinates, viewport: viewport)
            })
            contours.append(contentsOf: dataset.contours.filter {
                lineIntersects($0.coordinates, viewport: viewport)
            })
        }
        return TrailMapDataset(
            trails: deduplicated(trails),
            points: deduplicatedPoints(points),
            waterways: deduplicatedWaterways(waterways),
            contours: deduplicatedContours(contours)
        )
    }

    private func trailIntersects(_ trail: TrailMapFeature, viewport: TrailViewport) -> Bool {
        lineIntersects(trail.coordinates, viewport: viewport)
    }

    private func lineIntersects(_ coordinates: [RouteWaypoint], viewport: TrailViewport) -> Bool {
        guard let first = coordinates.first else { return false }
        var south = first.latitude
        var west = first.longitude
        var north = first.latitude
        var east = first.longitude
        for coordinate in coordinates.dropFirst() {
            south = min(south, coordinate.latitude)
            west = min(west, coordinate.longitude)
            north = max(north, coordinate.latitude)
            east = max(east, coordinate.longitude)
        }
        return south <= viewport.north && north >= viewport.south
            && west <= viewport.east && east >= viewport.west
    }

    private var offlineDatasetDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AtlasMapped", isDirectory: true)
            .appendingPathComponent("OfflineTrails", isDirectory: true)
    }

    private func offlineDatasetURL(for areaID: UUID) -> URL {
        offlineDatasetDirectory.appendingPathComponent("\(areaID.uuidString).json")
    }

    private func cleanName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.lowercased() != "no name",
              trimmed.lowercased() != "unnamed" else { return nil }
        return trimmed
    }

    private func osmName(from tags: [String: String]?) -> String? {
        cleanName(tags?["name"])
            ?? cleanName(tags?["official_name"])
            ?? cleanName(tags?["loc_name"])
            ?? cleanName(tags?["ref"])
    }

    private func pointKind(from tags: [String: String]?) -> OutdoorPointKind? {
        if tags?["highway"] == "trailhead" || tags?["information"] == "trailhead" { return .trailhead }
        switch tags?["natural"] {
        case "peak": return .peak
        case "saddle": return .saddle
        case "spring": return .spring
        default: break
        }
        switch tags?["tourism"] {
        case "viewpoint": return .viewpoint
        case "alpine_hut", "wilderness_hut": return .shelter
        case "camp_site": return .campsite
        default: break
        }
        switch tags?["amenity"] {
        case "shelter": return .shelter
        case "drinking_water": return .water
        default: return nil
        }
    }

    private func trailImportance(
        from tags: [String: String]?,
        isRoute: Bool
    ) -> TrailMapFeature.Importance {
        if isRoute, let network = tags?["network"], ["iwn", "nwn", "rwn"].contains(network) {
            return .major
        }
        let poorVisibility = tags?["trail_visibility"].map {
            ["bad", "horrible", "no"].contains($0)
        } ?? false
        if tags?["informal"] == "yes"
            || poorVisibility
            || (!isRoute && osmName(from: tags) == nil) {
            return .minor
        }
        if isRoute || tags?["trail_visibility"] == "excellent" { return .major }
        return .standard
    }

    private func outdoorPoint(
        id: String,
        kind: OutdoorPointKind,
        coordinate: CLLocationCoordinate2D,
        tags: [String: String]?
    ) -> OutdoorPointFeature {
        let name = osmName(from: tags) ?? kind.title
        let elevation = tags?["ele"].flatMap(parseMeters)
        let factKeys: [(String, String)] = [
            ("operator", "Managed by"),
            ("access", "Access"),
            ("ref", "Reference"),
            ("prominence", "Prominence"),
            ("fee", "Fee"),
            ("parking", "Parking"),
            ("toilets", "Toilets"),
            ("drinking_water", "Drinking water"),
            ("wheelchair", "Wheelchair access"),
            ("informal", "Informal access"),
            ("summit:register", "Summit register"),
            ("cairn", "Cairn"),
            ("shelter_type", "Shelter type"),
            ("surface", "Surface")
        ]
        let facts = factKeys.compactMap { key, label -> OutdoorPointFact? in
            guard let value = cleanName(tags?[key]) else { return nil }
            return OutdoorPointFact(label: label, value: humanized(value))
        }
        return OutdoorPointFeature(
            id: id,
            name: name,
            coordinate: RouteWaypoint(coordinate),
            kind: kind,
            elevationMeters: elevation,
            description: cleanName(tags?["description"]),
            website: cleanName(tags?["website"]) ?? wikipediaURL(from: tags?["wikipedia"]),
            facts: facts
        )
    }

    private func parseMeters(_ value: String) -> Double? {
        let normalized = value.lowercased().replacingOccurrences(of: "metres", with: "")
            .replacingOccurrences(of: "meters", with: "")
            .replacingOccurrences(of: "m", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    private func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func wikipediaURL(from value: String?) -> String? {
        guard let value = cleanName(value),
              let separator = value.firstIndex(of: ":") else { return nil }
        let language = String(value[..<separator])
        let title = String(value[value.index(after: separator)...]).replacingOccurrences(of: " ", with: "_")
        guard !language.isEmpty,
              let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return "https://\(language).wikipedia.org/wiki/\(encodedTitle)"
    }
}

private struct OSMResponse: Decodable {
    let elements: [OSMElement]
}

private struct OSMElement: Decodable {
    let type: String
    let id: Int64
    let lat: Double?
    let lon: Double?
    let tags: [String: String]?
    let geometry: [OSMPoint]?
    let members: [OSMMember]?
}

private struct OSMMember: Decodable {
    let type: String
    let geometry: [OSMPoint]?
}

private struct OSMPoint: Decodable {
    let lat: Double
    let lon: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
