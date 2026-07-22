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

    init(
        kind: TileKind,
        urlTemplate: String,
        allowsNetwork: Bool = true,
        storesNetworkTiles: Bool = true,
        sourceMaximumZoom: Int? = nil
    ) {
        self.kind = kind
        self.allowsNetwork = allowsNetwork
        self.storesNetworkTiles = storesNetworkTiles
        self.sourceMaximumZoom = sourceMaximumZoom
        super.init(urlTemplate: urlTemplate)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let resultBox = TileResultBox(result)
        let sourcePath = Self.sourcePath(for: path, maximumZoom: sourceMaximumZoom)
        let cached = TileCache.fileURL(kind: kind, z: sourcePath.z, x: sourcePath.x, y: sourcePath.y)
        if let data = try? Data(contentsOf: cached), !data.isEmpty {
            resultBox.call(Self.renderedData(data, sourcePath: sourcePath, requestedPath: path), nil)
            return
        }
        guard allowsNetwork else {
            resultBox.call(nil, nil)
            return
        }
        let remote = url(forTilePath: sourcePath)
        URLSession.shared.dataTask(with: remote) { data, _, error in
            if let data, error == nil, self.storesNetworkTiles {
                try? TileCache.store(data, at: cached)
            }
            let rendered = data.flatMap {
                Self.renderedData($0, sourcePath: sourcePath, requestedPath: path)
            }
            resultBox.call(rendered, error)
        }.resume()
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
