import Foundation
import CoreLocation

/// Current location for the weather widget. macOS asks for permission the first time.
final class LocationModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationModel()

    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var placeName: String?
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastGeocoded: CLLocation?
    private var started = false

    private override init() {
        super.init()
        status = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 1000 // only care when you move about a kilometer
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    private var isAuthorized: Bool {
        !isDenied && status != .notDetermined
    }

    /// Ask for permission if needed, then keep the location up to date.
    func start() {
        started = true
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func stop() {
        started = false
        manager.stopUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
        if started && isAuthorized { manager.startUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        coordinate = loc.coordinate

        // Look up the town name, but not for every tiny move.
        if let last = lastGeocoded, last.distance(from: loc) < 2000, placeName != nil { return }
        lastGeocoded = loc
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(loc) { [weak self] marks, _ in
            guard let mark = marks?.first else { return }
            DispatchQueue.main.async {
                self?.placeName = mark.locality ?? mark.subAdministrativeArea ?? mark.name
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Temporary failures are normal (no Wi-Fi etc.); keep the last known location.
    }
}
