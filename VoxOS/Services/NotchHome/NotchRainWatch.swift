import Combine
import CoreLocation
import Foundation

/// "Rain in 15 min": a passing notice when rain is about to start where the Mac is.
///
/// Open-Meteo's 15-minute precipitation (through the Agent's weather lookup) is read every half
/// hour, only while Notch Home shows notices and location access was already granted (the
/// Weather page asks for it; this never does). One notice per spell of rain: it is said again
/// only after a dry reading.
@MainActor
final class NotchRainWatch: ObservableObject {
    static let shared = NotchRainWatch()

    static let interval: TimeInterval = 30 * 60
    /// Rain further off than this is not "soon".
    nonisolated static let horizonMinutes = 45
    static let noticeLifetime: TimeInterval = 5

    @Published private(set) var notice: NotchHome.Notice?
    private var timer: Timer?
    private var warned = false
    private var clearTask: Task<Void, Never>?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchRainEnabled) }

    static var locationAllowed: Bool {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorized: return true
        default: return false
        }
    }

    private init() {}

    func setActive(_ active: Bool) {
        guard active != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard active, !ProcessIdentity.isTestHost else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { @MainActor [weak self] in await self?.check() }
    }

    private func check() async {
        let summary = await AgentWeather.current()
        guard summary["error"] == nil else { return }
        let rainIn = summary["rain_in_minutes"] as? Int
        guard let minutes = rainIn, minutes > 0, minutes <= Self.horizonMinutes else {
            // Dry, or raining already: the next spell may be said again.
            if rainIn == nil { warned = false }
            return
        }
        guard !warned else { return }
        warned = true
        notice = NotchHome.Notice(
            symbol: "cloud.rain.fill", title: String(localized: "Rain soon"),
            detail: String(localized: "in \(minutes) min"))
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeLifetime))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
