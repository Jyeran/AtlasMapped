import Combine
import Foundation
import MapKit

struct OfflineMapArea: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var boundary: [RouteWaypoint]
    var tiles: [OfflineTile]
    var createdAt: Date
    var byteCount: Int64
    /// Optional for backward-compatible decoding of raster-only downloads.
    var trailDataVersion: Int?

    var coordinates: [CLLocationCoordinate2D] { boundary.map(\.coordinate) }
}

struct OfflineMapDraft: Equatable, Sendable {
    var boundary: [RouteWaypoint]
    var tiles: [OfflineTile]

    var estimatedBytes: Int64 { Int64(tiles.count) * 38_000 }
    var coordinates: [CLLocationCoordinate2D] { boundary.map(\.coordinate) }
}

@MainActor
final class OfflineRegionManager: ObservableObject {
    // Version 5 gives USGS raster tiles their own provider-specific cache
    // namespace so legacy OpenTopoMap squares cannot leak into this style.
    private static let currentTrailDataVersion = 5
    @Published private(set) var areas: [OfflineMapArea] = []
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var errors: [UUID: String] = [:]

    private let zooms = 8...16
    private let maximumTileCount = 5_000
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init() {
        TileCache.removeLegacyTopographicTiles()
        areas = loadManifest()
    }

    var totalBytes: Int64 {
        let uniqueTiles = Set(areas.flatMap(\.tiles))
        return uniqueTiles.reduce(into: Int64(0)) { total, tile in
            let url = TileCache.fileURL(kind: .topographic, z: tile.z, x: tile.x, y: tile.y)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
    }

    var hasCompleteAreas: Bool {
        areas.contains(where: isComplete)
    }

    func draft(for boundary: [CLLocationCoordinate2D]) -> OfflineMapDraft? {
        guard boundary.count >= 3 else { return nil }
        let tiles = OfflineTileCoverage.tiles(intersecting: boundary, zooms: zooms)
        guard !tiles.isEmpty else { return nil }
        return OfflineMapDraft(boundary: boundary.map(RouteWaypoint.init), tiles: tiles)
    }

    func canDownload(_ draft: OfflineMapDraft) -> Bool {
        draft.tiles.count <= maximumTileCount
    }

    @discardableResult
    func download(_ draft: OfflineMapDraft, named name: String? = nil) -> OfflineMapArea {
        let sequence = areas.count + 1
        let area = OfflineMapArea(
            id: UUID(),
            name: name ?? "Offline area \(sequence)",
            boundary: draft.boundary,
            tiles: draft.tiles,
            createdAt: .now,
            byteCount: 0,
            trailDataVersion: nil
        )
        areas.insert(area, at: 0)
        persistManifest()
        startDownload(area)
        return area
    }

    func resume(_ area: OfflineMapArea) {
        guard tasks[area.id] == nil else { return }
        startDownload(area)
    }

    func cancel(_ area: OfflineMapArea) {
        tasks[area.id]?.cancel()
        tasks[area.id] = nil
        progress[area.id] = nil
    }

    func delete(_ area: OfflineMapArea) {
        cancel(area)
        areas.removeAll { $0.id == area.id }
        let stillReferenced = Set(areas.flatMap(\.tiles))
        for tile in area.tiles where !stillReferenced.contains(tile) {
            try? TileCache.remove(kind: .topographic, z: tile.z, x: tile.x, y: tile.y)
        }
        errors[area.id] = nil
        Task { await TrailDataService.shared.removeOfflineDataset(for: area.id) }
        persistManifest()
    }

    func isComplete(_ area: OfflineMapArea) -> Bool {
        area.byteCount > 0 && area.trailDataVersion == Self.currentTrailDataVersion
    }

    private func startDownload(_ area: OfflineMapArea) {
        guard tasks[area.id] == nil else { return }
        errors[area.id] = nil
        progress[area.id] = 0
        tasks[area.id] = Task {
            do {
                let tileBytes = try await downloadTiles(for: area)
                progress[area.id] = 0.94
                let trailBytes = try await TrailDataService.shared.storeOfflineDataset(
                    for: area.id,
                    boundary: area.boundary
                )
                if let index = areas.firstIndex(where: { $0.id == area.id }) {
                    areas[index].byteCount = tileBytes + trailBytes
                    areas[index].trailDataVersion = Self.currentTrailDataVersion
                    progress[area.id] = 1
                    persistManifest()
                }
            } catch is CancellationError {
                progress[area.id] = nil
            } catch {
                progress[area.id] = nil
                errors[area.id] = "Map or trail download paused. Tap resume when you’re back online."
            }
            tasks[area.id] = nil
        }
    }

    private func downloadTiles(for area: OfflineMapArea) async throws -> Int64 {
        let total = max(1, area.tiles.count)
        var completed = 0
        var storedBytes: Int64 = 0

        for tile in area.tiles {
            try Task.checkCancellation()
            let destination = TileCache.fileURL(kind: .topographic, z: tile.z, x: tile.x, y: tile.y)
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try? destination.resourceValues(forKeys: [.fileSizeKey])
                storedBytes += Int64(values?.fileSize ?? 0)
                completed += 1
                progress[area.id] = 0.9 * Double(completed) / Double(total)
                continue
            }

            let address = "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/\(tile.z)/\(tile.y)/\(tile.x)"
            guard let url = URL(string: address) else { continue }
            var request = URLRequest(url: url)
            request.setValue("AtlasMapped/0.1 (offline USGS topographic map)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                throw URLError(.badServerResponse)
            }
            try TileCache.store(data, at: destination)
            storedBytes += Int64(data.count)
            completed += 1
            progress[area.id] = 0.9 * Double(completed) / Double(total)
        }
        return storedBytes
    }

    private func persistManifest() {
        guard let data = try? JSONEncoder.atlas.encode(areas) else { return }
        try? FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func loadManifest() -> [OfflineMapArea] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        return (try? JSONDecoder.atlas.decode([OfflineMapArea].self, from: data)) ?? []
    }

    private var manifestURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AtlasMapped", isDirectory: true)
            .appendingPathComponent("offline-areas.json")
    }
}
