import Foundation
import CoreLocation
import MapKit

@Observable
class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    var location: CLLocation?
    var locality: String?
    var authStatus: CLAuthorizationStatus = .notDetermined
    var isLoading: Bool = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        authStatus = manager.authorizationStatus
    }

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            isLoading = true
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        authStatus = status
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            isLoading = true
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        location = loc
        isLoading = false
        reverseGeocode(loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isLoading = false
    }

    private func reverseGeocode(_ loc: CLLocation) {
        guard let request = MKReverseGeocodingRequest(location: loc) else { return }
        Task { [weak self] in
            guard let item = try? await request.mapItems.first else { return }
            self?.locality = item.addressRepresentations?.cityWithContext(.automatic)
        }
    }
}
