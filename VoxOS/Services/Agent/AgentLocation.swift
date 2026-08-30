import CoreLocation
import Foundation

/// One-shot current-location lookup for the `location_now` agent tool.
enum AgentLocation {
    @MainActor
    static func current() async -> [String: Any] {
        let fetcher = LocationFetcher()
        return await fetcher.fetch()
    }
}

@MainActor
private final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<[String: Any], Never>?

    func fetch() async -> [String: Any] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self

            switch manager.authorizationStatus {
            case .denied, .restricted:
                finish(["error": "Location access is denied. Enable it in System Settings > Privacy > Location Services."])
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            default:
                manager.requestLocation()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            manager.requestLocation()
        case .denied, .restricted:
            finish(["error": "Location access is denied. Enable it in System Settings > Privacy > Location Services."])
        default:
            break
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            await self.resolve(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(["error": "Could not determine location: \(error.localizedDescription)"])
        }
    }

    private func resolve(_ location: CLLocation) async {
        let coordinate = location.coordinate
        var result: [String: Any] = [
            "latitude": coordinate.latitude,
            "longitude": coordinate.longitude,
        ]

        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            let parts = [placemark.locality, placemark.administrativeArea, placemark.country]
                .compactMap { $0 }
            if !parts.isEmpty {
                result["place"] = parts.joined(separator: ", ")
            }
        }

        finish(result)
    }

    private func finish(_ result: [String: Any]) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}
