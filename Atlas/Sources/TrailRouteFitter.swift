import CoreLocation
import MapKit

enum TrailRouteFitter {
    struct Match: Sendable {
        let coordinates: [CLLocationCoordinate2D]
        let averageAdjustmentMeters: CLLocationDistance
    }

    enum FitError: LocalizedError, Equatable {
        case noNearbyTrails
        case disconnected
        case weakMatch

        var errorDescription: String? {
            switch self {
            case .noNearbyTrails: "No mapped trails were found close enough to this route."
            case .disconnected: "Nearby trail segments do not form a continuous route."
            case .weakMatch: "The nearby trails differ too much from the drawn route to fit confidently."
            }
        }
    }

    private struct NodeKey: Hashable, Sendable {
        let latitude: Int
        let longitude: Int

        init(_ coordinate: CLLocationCoordinate2D) {
            latitude = Int((coordinate.latitude * 100_000).rounded())
            longitude = Int((coordinate.longitude * 100_000).rounded())
        }
    }

    private struct Edge: Sendable {
        let destination: NodeKey
        let distance: CLLocationDistance
        let midpoint: CLLocationCoordinate2D
        let traversalMultiplier: Double
    }

    private struct Candidate {
        let node: NodeKey
        let adjustment: CLLocationDistance
    }

    private struct PathResult {
        let nodes: [NodeKey]
        let end: NodeKey
    }

    private struct BucketKey: Hashable {
        let latitude: Int
        let longitude: Int
    }

    private struct QueueItem {
        let node: NodeKey
        let cost: Double
    }

    private struct MinHeap {
        private var items: [QueueItem] = []

        var isEmpty: Bool { items.isEmpty }

        mutating func push(_ item: QueueItem) {
            items.append(item)
            var child = items.index(before: items.endIndex)
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].cost < items[parent].cost else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func popMinimum() -> QueueItem? {
            guard !items.isEmpty else { return nil }
            if items.count == 1 { return items.removeLast() }
            let minimum = items[0]
            items[0] = items.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var smallest = parent
                if left < items.count, items[left].cost < items[smallest].cost { smallest = left }
                if right < items.count, items[right].cost < items[smallest].cost { smallest = right }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
            return minimum
        }
    }

    static func fit(
        route: [CLLocationCoordinate2D],
        to features: [TrailMapFeature],
        waypointIndices: [Int] = [],
        maximumAdjustmentMeters: CLLocationDistance = 520
    ) throws -> Match {
        do {
            return try fitAttempt(
                route: route,
                to: features,
                waypointIndices: waypointIndices,
                maximumAdjustmentMeters: maximumAdjustmentMeters,
                usesExpandedNetwork: false
            )
        } catch let error as FitError where error != .noNearbyTrails {
            // A straight sketch can cross far inside a long switchback while the
            // correct mapped trail wanders well outside the initial corridor.
            // Retry with the wider fetched network, then split each successful
            // coarse graph leg into internal anchors. These anchors constrain the
            // search but never become user-visible route waypoints.
            return try fitAttempt(
                route: route,
                to: features,
                waypointIndices: waypointIndices,
                maximumAdjustmentMeters: maximumAdjustmentMeters,
                usesExpandedNetwork: true
            )
        }
    }

    private static func fitAttempt(
        route: [CLLocationCoordinate2D],
        to features: [TrailMapFeature],
        waypointIndices: [Int],
        maximumAdjustmentMeters: CLLocationDistance,
        usesExpandedNetwork: Bool
    ) throws -> Match {
        guard route.count > 1 else { throw FitError.weakMatch }
        let routeSamples = sampled(route, maximumCount: 14)
        let searchDistance = usesExpandedNetwork
            ? maximumAdjustmentMeters * 3
            : maximumAdjustmentMeters
        let nearby = features.filter { feature in
            guard feature.coordinates.count > 1 else { return false }
            let coordinates = feature.coordinates.map(\.coordinate)
            return routeSamples.contains { point in
                TrailRouteBuilder.distance(from: point, to: coordinates) <= searchDistance
            }
        }
        guard !nearby.isEmpty else { throw FitError.noNearbyTrails }

        var coordinatesByNode: [NodeKey: CLLocationCoordinate2D] = [:]
        var graph: [NodeKey: [Edge]] = [:]
        var featureEndpoints = Set<NodeKey>()
        var featureMembership: [NodeKey: Set<String>] = [:]
        for feature in nearby {
            let coordinates = densified(feature.coordinates.map(\.coordinate), maximumSpacingMeters: 18)
            if let first = coordinates.first { featureEndpoints.insert(NodeKey(first)) }
            if let last = coordinates.last { featureEndpoints.insert(NodeKey(last)) }
            for coordinate in coordinates {
                featureMembership[NodeKey(coordinate), default: []].insert(feature.id)
            }
            for (start, end) in zip(coordinates, coordinates.dropFirst()) {
                let startKey = NodeKey(start)
                let endKey = NodeKey(end)
                guard startKey != endKey else { continue }
                coordinatesByNode[startKey] = start
                coordinatesByNode[endKey] = end
                let distance = meters(between: start, and: end)
                let midpoint = CLLocationCoordinate2D(
                    latitude: (start.latitude + end.latitude) / 2,
                    longitude: (start.longitude + end.longitude) / 2
                )
                graph[startKey, default: []].append(Edge(
                    destination: endKey,
                    distance: distance,
                    midpoint: midpoint,
                    traversalMultiplier: 1
                ))
                graph[endKey, default: []].append(Edge(
                    destination: startKey,
                    distance: distance,
                    midpoint: midpoint,
                    traversalMultiplier: 1
                ))
            }
        }
        guard graph.count > 1 else { throw FitError.noNearbyTrails }
        bridgeGeometricIntersections(
            in: &graph,
            coordinatesByNode: coordinatesByNode,
            featureMembership: featureMembership
        )
        bridgeSmallDataGaps(
            in: &graph,
            coordinatesByNode: coordinatesByNode,
            featureEndpoints: featureEndpoints
        )

        let guideIndices = orderedGuideIndices(for: route, waypointIndices: waypointIndices)
        guard guideIndices.count > 1 else { throw FitError.weakMatch }
        let maximumAnchorAdjustment = min(maximumAdjustmentMeters, 240)
        let components = connectedComponents(in: graph)
        var candidateSets = guideIndices.map { index in
            nearestCandidates(
                to: route[index],
                in: coordinatesByNode,
                maximumDistance: maximumAnchorAdjustment
            )
        }
        guard candidateSets.allSatisfy({ !$0.isEmpty }) else { throw FitError.weakMatch }
        var sharedComponents = Set(candidateSets[0].compactMap { components[$0.node] })
        for candidates in candidateSets.dropFirst() {
            sharedComponents.formIntersection(candidates.compactMap { components[$0.node] })
        }
        guard let selectedComponent = sharedComponents.min(by: { lhs, rhs in
            componentAdjustmentScore(lhs, candidates: candidateSets, components: components)
                < componentAdjustmentScore(rhs, candidates: candidateSets, components: components)
        }) else { throw FitError.disconnected }
        candidateSets = candidateSets.map { candidates in
            candidates.filter { components[$0.node] == selectedComponent }
        }

        var fittedKeys: [NodeKey] = []
        var previousAnchor: NodeKey?
        for legIndex in 0..<(guideIndices.count - 1) {
            let startIndex = guideIndices[legIndex]
            let endIndex = guideIndices[legIndex + 1]
            let starts: [Candidate]
            if let previousAnchor {
                starts = [Candidate(node: previousAnchor, adjustment: 0)]
            } else {
                starts = candidateSets[legIndex]
            }
            let ends = candidateSets[legIndex + 1]
            guard !starts.isEmpty, !ends.isEmpty else { throw FitError.weakMatch }
            let legGuide = Array(route[min(startIndex, endIndex)...max(startIndex, endIndex)])
            guard var section = shortestPath(
                from: starts,
                to: ends,
                graph: graph,
                guideRoute: legGuide
            ) else { throw FitError.disconnected }
            if usesExpandedNetwork {
                section = pathDecomposedWithHiddenAnchors(
                    section,
                    graph: graph,
                    coordinatesByNode: coordinatesByNode
                ) ?? section
            }
            previousAnchor = section.end
            if fittedKeys.last == section.nodes.first { fittedKeys.append(contentsOf: section.nodes.dropFirst()) }
            else { fittedKeys.append(contentsOf: section.nodes) }
        }
        let fitted = fittedKeys.compactMap { coordinatesByNode[$0] }
        guard fitted.count > 1 else { throw FitError.disconnected }

        let adjustments = sampled(route, maximumCount: 24).map {
            TrailRouteBuilder.distance(from: $0, to: fitted)
        }
        let average = adjustments.reduce(0, +) / Double(max(1, adjustments.count))
        let allowedAverage = maximumAdjustmentMeters * (usesExpandedNetwork ? 1.35 : 0.58)
        guard average <= allowedAverage else { throw FitError.weakMatch }
        return Match(coordinates: removingDuplicates(fitted), averageAdjustmentMeters: average)
    }

    private static func pathDecomposedWithHiddenAnchors(
        _ coarsePath: PathResult,
        graph: [NodeKey: [Edge]],
        coordinatesByNode: [NodeKey: CLLocationCoordinate2D],
        maximumAnchorSpacingMeters: CLLocationDistance = 220
    ) -> PathResult? {
        guard coarsePath.nodes.count > 2 else { return coarsePath }
        var anchorIndices = [0]
        var distanceSinceAnchor: CLLocationDistance = 0
        for index in 1..<coarsePath.nodes.count {
            guard let previous = coordinatesByNode[coarsePath.nodes[index - 1]],
                  let current = coordinatesByNode[coarsePath.nodes[index]] else { continue }
            distanceSinceAnchor += meters(between: previous, and: current)
            if distanceSinceAnchor >= maximumAnchorSpacingMeters,
               index < coarsePath.nodes.index(before: coarsePath.nodes.endIndex) {
                anchorIndices.append(index)
                distanceSinceAnchor = 0
            }
        }
        let lastIndex = coarsePath.nodes.index(before: coarsePath.nodes.endIndex)
        if anchorIndices.last != lastIndex { anchorIndices.append(lastIndex) }
        guard anchorIndices.count > 2 else { return coarsePath }

        var result: [NodeKey] = []
        for (startIndex, endIndex) in zip(anchorIndices, anchorIndices.dropFirst()) {
            let start = coarsePath.nodes[startIndex]
            let end = coarsePath.nodes[endIndex]
            let localGuide = coarsePath.nodes[startIndex...endIndex].compactMap { coordinatesByNode[$0] }
            guard let section = shortestPath(
                from: [Candidate(node: start, adjustment: 0)],
                to: [Candidate(node: end, adjustment: 0)],
                graph: graph,
                guideRoute: localGuide
            ) else { return nil }
            if result.last == section.nodes.first { result.append(contentsOf: section.nodes.dropFirst()) }
            else { result.append(contentsOf: section.nodes) }
        }
        guard let end = result.last else { return nil }
        return PathResult(nodes: result, end: end)
    }

    private static func shortestPath(
        from starts: [Candidate],
        to ends: [Candidate],
        graph: [NodeKey: [Edge]],
        guideRoute: [CLLocationCoordinate2D]
    ) -> PathResult? {
        // A waypoint is an intent constraint, not merely a hint. Moving an
        // anchor is deliberately more expensive than following trail length,
        // which prevents a leg from collapsing onto one nearby graph vertex.
        let adjustmentWeight = 8.0
        let endAdjustments = Dictionary(uniqueKeysWithValues: ends.map { ($0.node, $0.adjustment) })
        var costs: [NodeKey: Double] = [:]
        var previous: [NodeKey: NodeKey] = [:]
        var queue = MinHeap()
        for start in starts {
            let initialCost = start.adjustment * adjustmentWeight
            if initialCost < (costs[start.node] ?? .greatestFiniteMagnitude) {
                costs[start.node] = initialCost
                queue.push(QueueItem(node: start.node, cost: initialCost))
            }
        }
        var bestEnd: NodeKey?
        var bestTotalCost = Double.greatestFiniteMagnitude

        while let item = queue.popMinimum() {
            guard item.cost <= (costs[item.node] ?? .greatestFiniteMagnitude) else { continue }
            if item.cost > bestTotalCost { break }
            if let endAdjustment = endAdjustments[item.node] {
                let totalCost = item.cost + endAdjustment * adjustmentWeight
                if totalCost < bestTotalCost {
                    bestTotalCost = totalCost
                    bestEnd = item.node
                }
            }
            for edge in graph[item.node] ?? [] {
                let corridorDistance = TrailRouteBuilder.distance(from: edge.midpoint, to: guideRoute)
                let corridorPenalty = 1 + min(4, corridorDistance / 90) * 0.78
                let cost = item.cost + edge.distance * corridorPenalty * edge.traversalMultiplier
                if cost < (costs[edge.destination] ?? .greatestFiniteMagnitude) {
                    costs[edge.destination] = cost
                    previous[edge.destination] = item.node
                    queue.push(QueueItem(node: edge.destination, cost: cost))
                }
            }
        }
        guard let bestEnd else { return nil }
        var path = [bestEnd]
        var cursor = bestEnd
        while let parent = previous[cursor] {
            path.append(parent)
            cursor = parent
        }
        return PathResult(nodes: path.reversed(), end: bestEnd)
    }

    private static func nearestCandidates(
        to point: CLLocationCoordinate2D,
        in coordinatesByNode: [NodeKey: CLLocationCoordinate2D],
        maximumDistance: CLLocationDistance,
        limit: Int = 12
    ) -> [Candidate] {
        coordinatesByNode.compactMap { node, coordinate -> Candidate? in
            let adjustment = meters(between: point, and: coordinate)
            guard adjustment <= maximumDistance else { return nil }
            return Candidate(node: node, adjustment: adjustment)
        }
        .sorted { $0.adjustment < $1.adjustment }
        .prefix(limit)
        .map { $0 }
    }

    private static func orderedGuideIndices(
        for route: [CLLocationCoordinate2D],
        waypointIndices: [Int]
    ) -> [Int] {
        var indices = Array(Set(waypointIndices.filter(route.indices.contains))).sorted()
        if indices.first != route.startIndex { indices.insert(route.startIndex, at: 0) }
        if indices.last != route.index(before: route.endIndex) {
            indices.append(route.index(before: route.endIndex))
        }
        return indices
    }

    private static func componentAdjustmentScore(
        _ component: Int,
        candidates: [[Candidate]],
        components: [NodeKey: Int]
    ) -> Double {
        candidates.reduce(0) { total, candidatesAtWaypoint in
            total + (candidatesAtWaypoint
                .filter { components[$0.node] == component }
                .map(\.adjustment)
                .min() ?? 100_000)
        }
    }

    private static func connectedComponents(
        in graph: [NodeKey: [Edge]]
    ) -> [NodeKey: Int] {
        var result: [NodeKey: Int] = [:]
        var component = 0
        for start in graph.keys where result[start] == nil {
            var stack = [start]
            result[start] = component
            while let node = stack.popLast() {
                for edge in graph[node] ?? [] where result[edge.destination] == nil {
                    result[edge.destination] = component
                    stack.append(edge.destination)
                }
            }
            component += 1
        }
        return result
    }

    private static func densified(
        _ coordinates: [CLLocationCoordinate2D],
        maximumSpacingMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first else { return [] }
        var result = [first]
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            let startPoint = MKMapPoint(start)
            let endPoint = MKMapPoint(end)
            let distance = startPoint.distance(to: endPoint)
            let divisions = max(1, Int(ceil(distance / maximumSpacingMeters)))
            for step in 1...divisions {
                let fraction = Double(step) / Double(divisions)
                result.append(MKMapPoint(
                    x: startPoint.x + (endPoint.x - startPoint.x) * fraction,
                    y: startPoint.y + (endPoint.y - startPoint.y) * fraction
                ).coordinate)
            }
        }
        return result
    }

    /// Connects different source features where their rendered geometry meets
    /// between recorded vertices. The small radius and high traversal penalty
    /// preserve nearby switchbacks instead of shortcutting across them.
    private static func bridgeGeometricIntersections(
        in graph: inout [NodeKey: [Edge]],
        coordinatesByNode: [NodeKey: CLLocationCoordinate2D],
        featureMembership: [NodeKey: Set<String>],
        maximumGapMeters: CLLocationDistance = 15
    ) {
        let bucketSize = 18
        var buckets: [BucketKey: [NodeKey]] = [:]
        for node in coordinatesByNode.keys {
            buckets[BucketKey(
                latitude: node.latitude / bucketSize,
                longitude: node.longitude / bucketSize
            ), default: []].append(node)
        }

        for node in coordinatesByNode.keys {
            guard let start = coordinatesByNode[node] else { continue }
            let bucket = BucketKey(
                latitude: node.latitude / bucketSize,
                longitude: node.longitude / bucketSize
            )
            let nearby = (-2...2).flatMap { latitudeOffset in
                (-2...2).flatMap { longitudeOffset in
                    buckets[BucketKey(
                        latitude: bucket.latitude + latitudeOffset,
                        longitude: bucket.longitude + longitudeOffset
                    )] ?? []
                }
            }
            .filter { candidate in
                guard candidate != node,
                      !(graph[node] ?? []).contains(where: { $0.destination == candidate }) else { return false }
                let lhs = featureMembership[node] ?? []
                let rhs = featureMembership[candidate] ?? []
                return lhs.isDisjoint(with: rhs)
            }
            .compactMap { candidate -> (NodeKey, CLLocationDistance)? in
                guard let end = coordinatesByNode[candidate] else { return nil }
                let distance = meters(between: start, and: end)
                guard distance > 1.2, distance <= maximumGapMeters else { return nil }
                return (candidate, distance)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(2)

            for (destination, distance) in nearby {
                guard let end = coordinatesByNode[destination] else { continue }
                let midpoint = CLLocationCoordinate2D(
                    latitude: (start.latitude + end.latitude) / 2,
                    longitude: (start.longitude + end.longitude) / 2
                )
                let forward = Edge(
                    destination: destination,
                    distance: distance,
                    midpoint: midpoint,
                    traversalMultiplier: 4.6
                )
                let backward = Edge(
                    destination: node,
                    distance: distance,
                    midpoint: midpoint,
                    traversalMultiplier: 4.6
                )
                graph[node, default: []].append(forward)
                if !(graph[destination] ?? []).contains(where: { $0.destination == node }) {
                    graph[destination, default: []].append(backward)
                }
            }
        }
    }

    /// Trail providers often split the same physical trail a few metres apart.
    /// Bridging only dangling feature endpoints keeps the graph continuous while
    /// avoiding broad shortcuts between parallel trails.
    private static func bridgeSmallDataGaps(
        in graph: inout [NodeKey: [Edge]],
        coordinatesByNode: [NodeKey: CLLocationCoordinate2D],
        featureEndpoints: Set<NodeKey>,
        maximumGapMeters: CLLocationDistance = 34
    ) {
        let bucketSize = 24
        var buckets: [BucketKey: [NodeKey]] = [:]
        for node in coordinatesByNode.keys {
            buckets[BucketKey(
                latitude: node.latitude / bucketSize,
                longitude: node.longitude / bucketSize
            ), default: []].append(node)
        }

        for endpoint in featureEndpoints {
            guard let start = coordinatesByNode[endpoint] else { continue }
            let bucket = BucketKey(
                latitude: endpoint.latitude / bucketSize,
                longitude: endpoint.longitude / bucketSize
            )
            let candidates = (-2...2).flatMap { latitudeOffset in
                (-2...2).flatMap { longitudeOffset in
                    buckets[BucketKey(
                        latitude: bucket.latitude + latitudeOffset,
                        longitude: bucket.longitude + longitudeOffset
                    )] ?? []
                }
            }
            .filter { candidate in
                candidate != endpoint
                    && !(graph[endpoint] ?? []).contains(where: { $0.destination == candidate })
            }
            .compactMap { destination -> (NodeKey, CLLocationDistance)? in
                guard let end = coordinatesByNode[destination] else { return nil }
                let distance = meters(between: start, and: end)
                guard distance > 1.5, distance <= maximumGapMeters else { return nil }
                return (destination, distance)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(3)

            for (destination, distance) in candidates {
                guard let end = coordinatesByNode[destination] else { continue }
                let midpoint = CLLocationCoordinate2D(
                    latitude: (start.latitude + end.latitude) / 2,
                    longitude: (start.longitude + end.longitude) / 2
                )
                let forward = Edge(
                    destination: destination,
                    distance: distance,
                    midpoint: midpoint,
                    traversalMultiplier: 3.8
                )
                let backward = Edge(
                    destination: endpoint,
                    distance: distance,
                    midpoint: midpoint,
                    traversalMultiplier: 3.8
                )
                if !(graph[endpoint] ?? []).contains(where: { $0.destination == destination }) {
                    graph[endpoint, default: []].append(forward)
                }
                if !(graph[destination] ?? []).contains(where: { $0.destination == endpoint }) {
                    graph[destination, default: []].append(backward)
                }
            }
        }
    }

    private static func sampled(
        _ coordinates: [CLLocationCoordinate2D],
        maximumCount: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximumCount else { return coordinates }
        let step = Double(coordinates.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { coordinates[Int((Double($0) * step).rounded())] }
    }

    private static func removingDuplicates(
        _ coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        coordinates.reduce(into: []) { result, coordinate in
            if let last = result.last, meters(between: last, and: coordinate) < 0.5 { return }
            result.append(coordinate)
        }
    }

    private static func meters(
        between lhs: CLLocationCoordinate2D,
        and rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        MKMapPoint(lhs).distance(to: MKMapPoint(rhs))
    }
}
