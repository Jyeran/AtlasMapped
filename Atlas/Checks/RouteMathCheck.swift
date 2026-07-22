import CoreLocation
import Foundation

@main
enum RouteMathCheck {
    static func main() {
        let route = [
            CLLocationCoordinate2D(latitude: 39.0, longitude: -105.0),
            CLLocationCoordinate2D(latitude: 39.01, longitude: -105.0)
        ]
        let halfway = CLLocationCoordinate2D(latitude: 39.005, longitude: -105.0001)
        let distance = RouteMath.distance(along: route)
        let progress = RouteMath.progress(location: halfway, along: route)

        precondition(distance > 1_110 && distance < 1_115, "Unexpected route distance: \(distance)")
        precondition(progress > 0.49 && progress < 0.51, "Unexpected route progress: \(progress)")
        precondition(RouteMath.distance(along: []) == 0)
        print("RouteMath checks passed — distance \(Int(distance)) m, progress \(Int(progress * 100))%")
    }
}
