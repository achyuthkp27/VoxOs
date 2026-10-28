import Combine
import CoreWLAN
import Foundation
import IOBluetooth
import Network

/// A short notice in the notch when a Bluetooth device connects or disconnects, Wi-Fi joins or
/// drops, the sound moves to another output, or the power adapter or a low battery needs saying.
///
/// Bluetooth (measured by others before us, and kept here as rules):
/// - IOBluetooth needs NSBluetoothAlwaysUsageDescription (TCC aborts the app without it) and the
///   com.apple.security.device.bluetooth entitlement under the hardened runtime (without it the
///   first call blocks forever). `start` checks the usage key before touching IOBluetooth.
/// - Never call it on the main thread; its callbacks arrive on its own queue.
/// - Registering replays every device already connected, and one connect can fire several
///   times, so the first seconds after registering are ignored and repeats are collapsed.
/// - Battery levels come from undocumented selectors; each is checked before it is asked.
@MainActor
final class NotchDeviceAlerts: ObservableObject {
    static let shared = NotchDeviceAlerts()

    struct Notice: Equatable {
        let symbol: String
        let title: String
        /// Battery, network name, or "Disconnected".
        let detail: String?
        let at: Date
    }

    nonisolated static let noticeLifetime: TimeInterval = 3.5
    nonisolated static let replayWindow: TimeInterval = 3
    nonisolated static let repeatWindow: TimeInterval = 10
    /// macOS moves the sound to a headset a moment after it connects; that headset was announced
    /// already, with its battery.
    nonisolated static let outputAfterConnect: TimeInterval = 10
    /// On battery, a notice as the charge falls to each of these.
    nonisolated static let lowBatteryLevels = [20, 10, 5]

    @Published private(set) var notice: Notice?

    private let bluetooth = BluetoothWatcher()
    private let output = NotchAudioOutput()
    private var lastConnect: (name: String, at: Date)?
    private var batteryWatch: AnyCancellable?
    private var lastBattery: PowerState.Battery?
    private var pathMonitor: NWPathMonitor?
    private var wifiConnected: Bool?
    private var lastNotice: [String: Date] = [:]
    private var clearTask: Task<Void, Never>?
    private var started = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchDeviceAlertsEnabled) }

    func start() {
        guard !started, !ProcessIdentity.isTestHost else { return }
        started = true
        if hasBluetoothUsage {
            bluetooth.start { [weak self] event in
                Task { @MainActor in self?.bluetoothEvent(event) }
            }
        }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in self?.wifiChanged(connected: connected) }
        }
        monitor.start(queue: DispatchQueue(label: "com.achyuthkp.voxos.wifi-alerts"))
        pathMonitor = monitor
        output.start { [weak self] device in
            Task { @MainActor in self?.outputChanged(device) }
        }
        lastBattery = PowerState.shared.battery
        batteryWatch = PowerState.shared.$battery.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] battery in self?.batteryChanged(to: battery) }
    }

    func stop() {
        guard started else { return }
        started = false
        bluetooth.stop()
        pathMonitor?.cancel()
        pathMonitor = nil
        wifiConnected = nil
        output.stop()
        batteryWatch = nil
        lastBattery = nil
    }

    private var hasBluetoothUsage: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    // MARK: Events

    private func bluetoothEvent(_ event: BluetoothWatcher.Event) {
        let detail: String?
        if event.connected {
            lastConnect = (event.name, Date())
            // Many earbuds report no battery; "Connected" keeps the right side from going blank.
            detail = event.battery.map { "\($0)%" } ?? String(localized: "Connected")
        } else {
            detail = String(localized: "Disconnected")
        }
        post(key: "bt-\(event.address)-\(event.connected)", symbol: event.symbol, title: event.name, detail: detail)
    }

    private func wifiChanged(connected: Bool) {
        defer { wifiConnected = connected }
        // The first update is the state at start, not a change.
        guard let previous = wifiConnected, previous != connected else { return }
        if connected {
            let network = CWWiFiClient.shared().interface()?.ssid()
            post(key: "wifi-on", symbol: "wifi", title: network ?? "Wi-Fi", detail: network == nil ? nil : "Wi-Fi")
        } else {
            post(key: "wifi-off", symbol: "wifi.slash", title: "Wi-Fi", detail: String(localized: "Disconnected"))
        }
    }

    private func outputChanged(_ device: NotchAudioOutput.Device) {
        if let lastConnect, lastConnect.name == device.name,
            Date().timeIntervalSince(lastConnect.at) < Self.outputAfterConnect
        {
            return
        }
        let symbol = NotchAudioOutput.symbol(for: device)
        let key = "output-\(device.name)"
        guard device.isBluetooth, hasBluetoothUsage else {
            return post(key: key, symbol: symbol, title: device.name, detail: String(localized: "Output"))
        }
        // A headset that was already connected (AirPods moving over from the phone) gets its
        // battery here, as on connecting.
        bluetooth.battery(named: device.name) { battery in
            Task { @MainActor [weak self] in
                self?.post(
                    key: key, symbol: symbol, title: device.name,
                    detail: battery.map { "\($0)%" } ?? String(localized: "Output"))
            }
        }
    }

    private func batteryChanged(to battery: PowerState.Battery?) {
        defer { lastBattery = battery }
        guard let notice = Self.batteryNotice(from: lastBattery, to: battery) else { return }
        post(key: notice.key, symbol: notice.symbol, title: notice.title, detail: notice.detail)
    }

    /// The adapter going in or out, and the charge falling to a low level while on battery.
    nonisolated static func batteryNotice(
        from old: PowerState.Battery?, to new: PowerState.Battery?
    ) -> (key: String, symbol: String, title: String, detail: String)? {
        guard let old, let new else { return nil }
        let percent = "\(new.percent)%"
        if !old.onAdapter, new.onAdapter {
            return ("power-on", "battery.100percent.bolt", String(localized: "Plugged in"), percent)
        }
        if old.onAdapter, !new.onAdapter {
            return ("power-off", batterySymbol(new.percent), String(localized: "On battery"), percent)
        }
        if !new.onAdapter, let level = lowBatteryLevels.last(where: { old.percent > $0 && new.percent <= $0 }) {
            return ("battery-low-\(level)", batterySymbol(new.percent), String(localized: "Low battery"), percent)
        }
        return nil
    }

    nonisolated static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func post(key: String, symbol: String, title: String, detail: String?, now: Date = Date()) {
        guard Self.shouldShow(key: key, at: now, last: lastNotice[key]) else { return }
        lastNotice[key] = now
        notice = Notice(symbol: symbol, title: title, detail: detail, at: now)
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeLifetime))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// One notice per device and direction within `repeatWindow`: a single connect fires several
    /// callbacks.
    nonisolated static func shouldShow(key: String, at now: Date, last: Date?) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= repeatWindow
    }

    /// The icon comes from the class every Bluetooth device reports (Bluetooth Assigned
    /// Numbers: major 0x04 audio, 0x05 peripheral…); only Apple's earbuds need their product
    /// name, since their class says no more than "headset".
    nonisolated static func symbol(name: String, majorClass: UInt32, minorClass: UInt32) -> String {
        let product = name.lowercased()
        if product.contains("airpods max") { return "airpodsmax" }
        if product.contains("airpods pro") { return "airpodspro" }
        if product.contains("airpods") { return "airpods" }
        switch majorClass {
        case 0x01:
            return "laptopcomputer"
        case 0x02:
            return "iphone"
        case 0x04:
            switch minorClass {
            case 0x01, 0x02: return "earbuds"  // headset, hands-free
            case 0x05: return "hifispeaker.fill"  // loudspeaker
            default: return "headphones"
            }
        case 0x05:
            // Bits 4–5: keyboard, pointing device or both; bits 0–3: joystick, gamepad…
            if minorClass & 0x0F == 0x01 || minorClass & 0x0F == 0x02 { return "gamecontroller" }
            switch minorClass & 0x30 {
            case 0x10, 0x30: return "keyboard"
            case 0x20: return "computermouse"
            default: return "dot.radiowaves.left.and.right"
            }
        default:
            return "dot.radiowaves.left.and.right"
        }
    }
}

/// The IOBluetooth half, off the main actor: registration and callbacks happen on its queue.
private final class BluetoothWatcher: NSObject, @unchecked Sendable {
    struct Event {
        let address: String
        let name: String
        let symbol: String
        let connected: Bool
        let battery: Int?
    }

    private let queue = DispatchQueue(label: "com.achyuthkp.voxos.bluetooth-alerts")
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var registered = Date.distantFuture
    private var onEvent: ((Event) -> Void)?

    func start(onEvent: @escaping (Event) -> Void) {
        queue.async { [self] in
            self.onEvent = onEvent
            registered = Date()
            connectNotification = IOBluetoothDevice.register(
                forConnectNotifications: self, selector: #selector(connected(_:device:)))
        }
    }

    func stop() {
        queue.async { [self] in
            connectNotification?.unregister()
            connectNotification = nil
            disconnectNotifications.values.forEach { $0.unregister() }
            disconnectNotifications = [:]
            onEvent = nil
        }
    }

    /// The battery of a connected device by name, on the Bluetooth queue.
    func battery(named name: String, completion: @escaping @Sendable (Int?) -> Void) {
        queue.async {
            let device = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first {
                $0.isConnected() && $0.name == name
            }
            completion(device.flatMap(Self.battery(of:)))
        }
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        queue.async { [self] in
            guard let address = device.addressString, let name = device.name, !name.isEmpty else { return }
            if disconnectNotifications[address] == nil {
                disconnectNotifications[address] = device.register(
                    forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
            }
            // Devices already connected are replayed at registration: not news.
            guard Date().timeIntervalSince(registered) > NotchDeviceAlerts.replayWindow else { return }
            onEvent?(event(for: device, address: address, name: name, connected: true))
        }
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        queue.async { [self] in
            guard let address = device.addressString, let name = device.name, !name.isEmpty else { return }
            disconnectNotifications.removeValue(forKey: address)?.unregister()
            onEvent?(event(for: device, address: address, name: name, connected: false))
        }
    }

    private func event(for device: IOBluetoothDevice, address: String, name: String, connected: Bool) -> Event {
        Event(
            address: address, name: name,
            symbol: NotchDeviceAlerts.symbol(
                name: name, majorClass: device.deviceClassMajor, minorClass: device.deviceClassMinor),
            connected: connected, battery: connected ? Self.battery(of: device) : nil)
    }

    /// AirPods report left and right; most others a single value. Undocumented, so each selector
    /// is checked before it is asked; the lowest earbud is the one that runs out first.
    private static func battery(of device: IOBluetoothDevice) -> Int? {
        let values = ["batteryPercentSingle", "batteryPercentLeft", "batteryPercentRight"].compactMap { key -> Int? in
            guard device.responds(to: NSSelectorFromString(key)) else { return nil }
            guard let number = device.value(forKey: key) as? NSNumber, number.intValue > 0 else { return nil }
            return number.intValue
        }
        return values.min()
    }
}
