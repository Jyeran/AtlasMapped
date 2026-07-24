@preconcurrency import Foundation
import CoreGraphics
import ImageIO
import MapKit
import UniformTypeIdentifiers

enum TileKind: String, Sendable {
    /// Include the provider/style generation in the disk namespace. Raster
    /// tiles from different providers can share z/x/y coordinates but are not
    /// visually interchangeable.
    case topographic = "usgs-topographic-v1"
    case trails
}

final class CachedTileOverlay: MKTileOverlay, @unchecked Sendable {
    let kind: TileKind
    let allowsNetwork: Bool
    let storesNetworkTiles: Bool
    let sourceMaximumZoom: Int?
    let prefetchRadius: Int

    private let memoryCache = NSCache<NSString, NSData>()
    private let prefetchRegistry = TilePrefetchRegistry()
    private lazy var prefetchSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init(
        kind: TileKind,
        urlTemplate: String,
        allowsNetwork: Bool = true,
        storesNetworkTiles: Bool = true,
        sourceMaximumZoom: Int? = nil,
        prefetchRadius: Int = 0
    ) {
        self.kind = kind
        self.allowsNetwork = allowsNetwork
        self.storesNetworkTiles = storesNetworkTiles
        self.sourceMaximumZoom = sourceMaximumZoom
        self.prefetchRadius = max(0, prefetchRadius)
        super.init(urlTemplate: urlTemplate)
        memoryCache.countLimit = 384
        memoryCache.totalCostLimit = 48 * 1_024 * 1_024
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let resultBox = TileResultBox(result)
        let sourcePath = Self.sourcePath(for: path, maximumZoom: sourceMaximumZoom)
        let key = Self.cacheKey(for: sourcePath)
        prefetchTiles(around: sourcePath)
        if let data = memoryCache.object(forKey: key as NSString) {
            resultBox.call(Self.renderedData(data as Data, sourcePath: sourcePath, requestedPath: path), nil)
            return
        }
        let cached = cacheURL(for: sourcePath)
        if let data = try? Data(contentsOf: cached), !data.isEmpty {
            storeInMemory(data, key: key)
            resultBox.call(Self.renderedData(data, sourcePath: sourcePath, requestedPath: path), nil)
            return
        }
        guard allowsNetwork else {
            resultBox.call(nil, nil)
            return
        }
        let remote = url(forTilePath: sourcePath)
        URLSession.shared.dataTask(with: remote) { data, _, error in
            if let data, error == nil {
                self.storeInMemory(data, key: key)
                if self.storesNetworkTiles {
                    try? TileCache.store(data, at: cached)
                }
            }
            let rendered = data.flatMap {
                Self.renderedData($0, sourcePath: sourcePath, requestedPath: path)
            }
            resultBox.call(rendered, error)
        }.resume()
    }

    private func prefetchTiles(around sourcePath: MKTileOverlayPath) {
        guard allowsNetwork, prefetchRadius > 0 else { return }
        for path in Self.neighboringPaths(around: sourcePath, radius: prefetchRadius) {
            let key = Self.cacheKey(for: path)
            guard memoryCache.object(forKey: key as NSString) == nil else { continue }
            let cached = cacheURL(for: path)
            if let data = try? Data(contentsOf: cached), !data.isEmpty {
                storeInMemory(data, key: key)
                continue
            }
            guard prefetchRegistry.begin(key) else { continue }
            prefetchSession.dataTask(with: url(forTilePath: path)) { [weak self] data, _, _ in
                guard let self else { return }
                defer { self.prefetchRegistry.finish(key) }
                guard let data, !data.isEmpty else { return }
                self.storeInMemory(data, key: key)
                if self.storesNetworkTiles {
                    try? TileCache.store(data, at: cached)
                }
            }.resume()
        }
    }

    private func cacheURL(for path: MKTileOverlayPath) -> URL {
        TileCache.fileURL(kind: kind, z: path.z, x: path.x, y: path.y)
    }

    private func storeInMemory(_ data: Data, key: String) {
        memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }

    static func cacheKey(for path: MKTileOverlayPath) -> String {
        "\(path.z)/\(path.x)/\(path.y)@\(path.contentScaleFactor)"
    }

    static func neighboringPaths(
        around path: MKTileOverlayPath,
        radius: Int
    ) -> [MKTileOverlayPath] {
        guard radius > 0, path.z >= 0, path.z < Int.bitWidth - 1 else { return [] }
        let tileCount = 1 << path.z
        var neighbors: [MKTileOverlayPath] = []
        neighbors.reserveCapacity((radius * 2 + 1) * (radius * 2 + 1) - 1)
        for yOffset in -radius...radius {
            let y = path.y + yOffset
            guard (0..<tileCount).contains(y) else { continue }
            for xOffset in -radius...radius where xOffset != 0 || yOffset != 0 {
                let unwrappedX = path.x + xOffset
                let x = (unwrappedX % tileCount + tileCount) % tileCount
                neighbors.append(MKTileOverlayPath(
                    x: x,
                    y: y,
                    z: path.z,
                    contentScaleFactor: path.contentScaleFactor
                ))
            }
        }
        return neighbors
    }

    static func sourcePath(
        for requestedPath: MKTileOverlayPath,
        maximumZoom: Int?
    ) -> MKTileOverlayPath {
        guard let maximumZoom, requestedPath.z > maximumZoom else { return requestedPath }
        let zoomDifference = requestedPath.z - maximumZoom
        return MKTileOverlayPath(
            x: requestedPath.x >> zoomDifference,
            y: requestedPath.y >> zoomDifference,
            z: maximumZoom,
            contentScaleFactor: requestedPath.contentScaleFactor
        )
    }

    private static func renderedData(
        _ sourceData: Data,
        sourcePath: MKTileOverlayPath,
        requestedPath: MKTileOverlayPath
    ) -> Data? {
        let zoomDifference = requestedPath.z - sourcePath.z
        guard zoomDifference > 0 else { return sourceData }
        guard zoomDifference < Int.bitWidth - 1,
              let imageSource = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }

        let subdivision = 1 << zoomDifference
        let childX = requestedPath.x - (sourcePath.x << zoomDifference)
        let childY = requestedPath.y - (sourcePath.y << zoomDifference)
        guard childX >= 0, childX < subdivision, childY >= 0, childY < subdivision else { return nil }

        let cropWidth = CGFloat(image.width) / CGFloat(subdivision)
        let cropHeight = CGFloat(image.height) / CGFloat(subdivision)
        let cropRect = CGRect(
            x: CGFloat(childX) * cropWidth,
            y: CGFloat(childY) * cropHeight,
            width: cropWidth,
            height: cropHeight
        ).integral
        guard let cropped = image.cropping(to: cropRect),
              let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rendered = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private final class TileResultBox: @unchecked Sendable {
    private let callback: (Data?, (any Error)?) -> Void
    init(_ callback: @escaping (Data?, (any Error)?) -> Void) { self.callback = callback }
    func call(_ data: Data?, _ error: (any Error)?) { callback(data, error) }
}

private final class TilePrefetchRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var activeKeys = Set<String>()

    func begin(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeKeys.insert(key).inserted
    }

    func finish(_ key: String) {
        lock.lock()
        activeKeys.remove(key)
        lock.unlock()
    }
}

enum TileCache {
    static var root: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AtlasTiles", isDirectory: true)
    }

    static func fileURL(kind: TileKind, z: Int, x: Int, y: Int) -> URL {
        root.appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(String(z), isDirectory: true)
            .appendingPathComponent(String(x), isDirectory: true)
            .appendingPathComponent("\(y).png")
    }

    static func store(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func contains(kind: TileKind, z: Int, x: Int, y: Int) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(kind: kind, z: z, x: x, y: y).path)
    }

    static func remove(kind: TileKind, z: Int, x: Int, y: Int) throws {
        let url = fileURL(kind: kind, z: z, x: x, y: y)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Pre-USGS builds stored OpenTopoMap imagery in a provider-agnostic
    /// `topographic` folder. It must never be composited with USGS tiles.
    static func removeLegacyTopographicTiles() {
        let legacy = root.appendingPathComponent("topographic", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.removeItem(at: legacy)
    }
}
