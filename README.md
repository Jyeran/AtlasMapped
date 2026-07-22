# AtlasMapped

Atlas is a map-first SwiftUI hiking navigator for iPhone, iPad, and Mac. The first iteration includes:

- Native MapKit pan, pinch/scroll zoom, scale, and user location
- Pin dropping, freehand measurement, and editable route drawing
- USGS Topo with OSM/USFS-derived hiking trails, trailheads, peaks, and labels
- Freeform lasso downloads that cache only the topographic tiles intersecting a selected area
- A local offline-map library with progress, storage totals, resume, and deletion
- Trail fitting, route undo/redo, named waypoints, notes, reusable pins, and elevation profiles
- Live compass, elevation, route progress, and start/end tracking states
- A local route library shared by the Mac and iOS codebase
- Portable `.atlasroute` export/import for AirDrop, Files, Messages, and email transfers
- A compact phone layout and an adaptive Mac/iPad sidebar layout from the same source

## Open the project

The repository includes both a Swift package and an XcodeGen specification.

1. Install the current full Xcode release and select it as the active developer directory.
2. Open the included `AtlasMapped.xcodeproj`, select `Atlas-iOS` or `Atlas-macOS`, and run.
3. To regenerate the project after changing `project.yml`, install XcodeGen (`brew install xcodegen`) and run `xcodegen generate`.

For a quick Mac-only preview, open `Package.swift` directly in Xcode, or run `swift run` with a compatible macOS SDK. A locally built preview is also available at `Build/Atlas.app`.

## Map data and offline behavior

Atlas uses USGS The National Map topographic tiles as its visual base and adds interactive OSM/USFS trail geometry and outdoor points. USGS publishes native topo imagery through zoom 16; Atlas overzooms the correct parent imagery at closer levels while keeping trail and route geometry sharp. Offline areas download USGS tiles at zoom levels 8–16.

Choose **Offline maps → Select area**, then drag a loop on the map. Atlas intersects the freeform polygon with the Web Mercator tile grid instead of downloading its entire bounding box. Downloads are capped at 5,000 tiles, can resume after interruption, and appear in the local storage library. Deleting an area removes tiles that are not shared by another saved area.

## Route handoff

Choose **Route plans** after drawing a route, give it a name, and save it to the local route library. iCloud synchronization is currently disabled while the local route and transfer workflows are developed.

For manual transfer, export a `.atlasroute` file and send it with AirDrop or save it to Files. The receiving device can import the same file from Route plans. This also provides a recovery path when iCloud is unavailable.

## Validation

The app compiles under Swift 6 strict concurrency. XCTest coverage includes route distance/progress plus exact polygon tile coverage, concave shapes, tile-boundary rounding, polar clamping, and antimeridian wrapping.
