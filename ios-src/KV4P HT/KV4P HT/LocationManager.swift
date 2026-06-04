import Foundation
import CoreLocation

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
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            guard let pm = placemarks?.first else { return }
            let city = pm.locality ?? pm.administrativeArea ?? "Unknown"
            let state = pm.administrativeArea ?? ""
            self?.locality = city == state ? city : "\(city), \(state)"
        }
    }
}
