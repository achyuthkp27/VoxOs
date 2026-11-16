import AppKit
import SwiftUI
import os

/// A row of glass widgets on the lock screen, under macOS's clock: what is playing, the next
/// event today, the weather and the battery, from what Notch Home already knows. Nothing new is
/// fetched for them.
///
/// macOS draws its lock screen above every app window, so the row goes into a Space of its own at
/// the lock screen's level (`SkyLight.showOnLockScreen`, a private call loaded at run time); on a
/// macOS without that call the row is simply not shown. A window moved there once the screen has
/// locked is never drawn (measured on macOS 26), so the row is moved there as soon as it is
/// switched on and stays, fully transparent and never taking a click, until the screen locks;
/// it fades out again on unlock. It is built only while switched on.
@MainActor
final class LockScreenWidgets {
    static let shared = LockScreenWidgets()

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.lockScreenWidgetsEnabled) }

    static let size = CGSize(width: 620, height: 104)

    private var enabled = false
    private var panel: NSPanel?
    private let lockWatch = LockWatch()
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "LockScreenWidgets")

    private init() {}

    func setEnabled(_ on: Bool) {
        let wanted = on && !ProcessIdentity.isTestHost && SkyLight.canShowOnLockScreen
        guard wanted != enabled else { return }
        enabled = wanted
        if wanted {
            prepare()
            lockWatch.start { [weak self] locked in
                if locked { self?.show() } else { self?.hide() }
            }
        } else {
            lockWatch.stop()
            panel?.orderOut(nil)
            panel = nil
        }
    }

    /// Where the row goes on a screen: centred, its top a little below macOS's clock.
    nonisolated static func frame(on screen: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: (screen.midX - size.width / 2).rounded(), y: (screen.minY + screen.height * 0.7 - size.height).rounded(),
            width: size.width, height: size.height)
    }

    /// Puts the row, transparent, in the lock screen's Space ahead of any lock.
    private func prepare() {
        guard panel == nil, let screen = NSScreen.screens.first else { return }
        let panel = makePanel()
        panel.alphaValue = 0
        panel.setFrame(Self.frame(on: screen.frame, size: Self.size), display: true)
        panel.orderFrontRegardless()
        guard SkyLight.showOnLockScreen(panel) else {
            logger.error("Lock screen widgets could not be put above the lock screen")
            panel.orderOut(nil)
            return
        }
        self.panel = panel
    }

    private func show() {
        guard enabled, let panel, let screen = NSScreen.screens.first else { return }
        panel.setFrame(Self.frame(on: screen.frame, size: Self.size), display: true)
        panel.alphaValue = 1
        ActivityTrail.mark("lock screen widgets shown")
    }

    private func hide() {
        panel?.alphaValue = 0
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.canBecomeVisibleWithoutLogin = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: LockScreenWidgetsView())
        return panel
    }
}

/// The screen locking and unlocking. macOS holds distributed notifications back from an app that
/// is not in front until it is, and VoxOS is never in front, so these ask for delivery at once;
/// the block-based observer cannot.
@MainActor
private final class LockWatch: NSObject {
    private var onChange: ((Bool) -> Void)?

    func start(_ onChange: @escaping (Bool) -> Void) {
        stop()
        self.onChange = onChange
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self, selector: #selector(locked), name: .init("com.apple.screenIsLocked"), object: nil,
            suspensionBehavior: .deliverImmediately)
        center.addObserver(
            self, selector: #selector(unlocked), name: .init("com.apple.screenIsUnlocked"), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        onChange = nil
    }

    @objc private func locked() { onChange?(true) }
    @objc private func unlocked() { onChange?(false) }
}

/// The row itself: each widget a small glass tile, shown only when it has something to say.
struct LockScreenWidgetsView: View {
    @ObservedObject private var playback = PlaybackController.shared
    @ObservedObject private var today = NotchToday.shared
    @ObservedObject private var power = PowerState.shared

    var body: some View {
        HStack(spacing: 10) {
            if let payload = playback.nowPlaying, let title = payload.title, !title.isEmpty {
                tile {
                    HStack(spacing: 10) {
                        artwork(payload.artworkDataBase64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(verbatim: payload.artist ?? payload.applicationName ?? "")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: payload.isPlaying == true ? "waveform" : "pause.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: 260)
            }
            if let event = nextEvent {
                tile {
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(verbatim: event.isAllDay ? String(localized: "Today") : timeText(event.start))
                        } icon: {
                            Circle().fill(event.color).frame(width: 7, height: 7)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        Text(verbatim: event.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    }
                }
                .frame(maxWidth: 170)
            }
            if let weather = today.weather {
                tile {
                    VStack(spacing: 4) {
                        Image(systemName: weather.symbol).font(.system(size: 18)).symbolRenderingMode(.multicolor)
                        Text(verbatim: "\(weather.temperature)°").font(.system(size: 15, weight: .semibold))
                    }
                }
                .frame(width: 72)
            }
            if let battery = power.battery {
                tile {
                    VStack(spacing: 4) {
                        Image(
                            systemName: battery.onAdapter
                                ? "battery.100percent.bolt" : NotchDeviceAlerts.batterySymbol(battery.percent)
                        )
                        .font(.system(size: 18))
                        .foregroundStyle(battery.percent <= 10 && !battery.onAdapter ? .red : .white)
                        Text(verbatim: "\(battery.percent)%").font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                .frame(width: 72)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    /// The next timed event still to start today, or an all-day one.
    private var nextEvent: NotchToday.Event? {
        let now = Date()
        let events = today.dayEvents.filter { Calendar.current.isDateInToday($0.start) || $0.isAllDay }
        return events.first { !$0.isAllDay && $0.end > now } ?? events.first { $0.isAllDay }
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder
    private func artwork(_ base64: String?) -> some View {
        if let data = base64.flatMap({ Data(base64Encoded: $0) }), let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.7)))
        }
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}
