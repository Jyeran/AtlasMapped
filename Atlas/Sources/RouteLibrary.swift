import Combine
import Foundation

private struct RouteLibrarySnapshot: Codable, Equatable {
    var version = 2
    var routes: [RoutePlan]
    var tombstones: [UUID: Date]
}

@MainActor
final class RouteLibrary: ObservableObject {
    @Published private(set) var routes: [RoutePlan] = []

    private var tombstones: [UUID: Date] = [:]

    init() {
        routes = loadLocal()
    }

    func save(_ plan: RoutePlan) {
        var updated = plan
        updated.modifiedAt = .now
        if let index = routes.firstIndex(where: { $0.id == updated.id }) {
            routes[index] = updated
        } else {
            routes.append(updated)
        }
        tombstones.removeValue(forKey: updated.id)
        sortAndPersist()
    }

    func importPlan(_ plan: RoutePlan) {
        var imported = plan
        if routes.contains(where: { $0.id == imported.id }) { imported.id = UUID() }
        imported.modifiedAt = .now
        routes.append(imported)
        sortAndPersist()
    }

    func delete(_ plan: RoutePlan) {
        routes.removeAll { $0.id == plan.id }
        tombstones[plan.id] = .now
        sortAndPersist()
    }

    private func sortAndPersist() {
        routes.sort { $0.modifiedAt > $1.modifiedAt }
        persistLocal()
    }

    private func persistLocal() {
        guard let data = try? JSONEncoder.atlas.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: localURL, options: .atomic)
    }

    private func loadLocal() -> [RoutePlan] {
        guard let data = try? Data(contentsOf: localURL) else { return [] }
        if let stored = decodeSnapshot(data) {
            tombstones = stored.tombstones
            return stored.routes
        }
        return []
    }

    private var snapshot: RouteLibrarySnapshot {
        RouteLibrarySnapshot(routes: routes, tombstones: tombstones)
    }

    private func decodeSnapshot(_ data: Data) -> RouteLibrarySnapshot? {
        if let snapshot = try? JSONDecoder.atlas.decode(RouteLibrarySnapshot.self, from: data) {
            return snapshot
        }
        if let legacyRoutes = try? JSONDecoder.atlas.decode([RoutePlan].self, from: data) {
            return RouteLibrarySnapshot(routes: legacyRoutes, tombstones: [:])
        }
        return nil
    }

    private var localURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AtlasMapped", isDirectory: true)
            .appendingPathComponent("routes.json")
    }
}
