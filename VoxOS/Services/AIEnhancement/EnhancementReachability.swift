import Foundation
import Network

/// Decides whether an enhancement request can possibly succeed before one is sent.
///
/// Without this, dictating while offline on a cloud provider costs the full enhancement timeout
/// on every single recording — the request cannot succeed, but the text only lands once the
/// timeout expires. On a plane or bad wifi that is every recording. Knowing the request is
/// hopeless lets the raw transcript paste immediately instead.
enum EnhancementReachability {

    /// Hosts that never leave the machine, so a dropped internet connection is irrelevant.
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

    /// Whether this provider has to reach the internet to answer.
    ///
    /// `ollama` and `custom` are decided by their configured address rather than assumed: Ollama
    /// usually runs on localhost but can be pointed at another machine, and a custom provider is
    /// whatever the user typed. Getting this wrong in the strict direction would refuse to
    /// enhance on a perfectly working local model.
    static func requiresInternet(provider: AIProvider, baseURL: String?) -> Bool {
        switch provider {
        case .voxOSRefine, .localCLI:
            // On-device and local-process: no network at all.
            return false
        case .ollama, .custom:
            return !isLocalAddress(baseURL)
        default:
            return true
        }
    }

    /// True when the address is on this machine or this LAN.
    ///
    /// A `.local` name or a private-range address is still reachable with the internet down, so
    /// treating those as needing internet would break a self-hosted model on the same network.
    static func isLocalAddress(_ urlString: String?) -> Bool {
        guard let urlString, !urlString.trimmingCharacters(in: .whitespaces).isEmpty else {
            // No address configured: nothing to send to, so this is not the check that should
            // reject it — let the normal "not configured" path report that.
            return true
        }
        guard let host = URL(string: urlString.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else {
            // Unparseable: assume local so a malformed address is not reported as an outage.
            return true
        }
        if localHosts.contains(host) || host.hasSuffix(".local") { return true }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }
        // 172.16.0.0 – 172.31.255.255
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }
}

/// Publishes whether the machine currently has a usable route to the internet.
///
/// Fails open in every ambiguous case: an enhancement that is merely slow is a far better
/// outcome than one refused because the monitor had not reported yet.
final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.achyuthkp.voxos.reachability")
    private let lock = NSLock()
    private var status: NWPath.Status?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock { self.status = path.status }
        }
        monitor.start(queue: queue)
    }

    /// Only true when the monitor has actually reported an unsatisfied path. Before the first
    /// report, or in any other state, this is false so nothing is refused on a guess.
    var isDefinitelyOffline: Bool {
        lock.withLock { status == .unsatisfied }
    }
}
