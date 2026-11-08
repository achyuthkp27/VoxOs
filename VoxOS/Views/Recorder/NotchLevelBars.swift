import AppKit
import Combine
import MediaRemoteAdapter
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import VoxOSNowPlaying
import os

/// Bars driven by SystemAudioLevels, drawn as plain CALayers updated by a timer (see
/// `LevelBarsNSView.interval`). A SwiftUI TimelineView or Canvas doing the same costs far more CPU
/// for five rectangles.
struct NotchLevelBars: NSViewRepresentable {
    enum Source {
        /// The Mac's real output, from SystemAudioLevels.
        case live
        /// A slow, organic motion that only says "playing": nothing is listened to.
        case ambient
    }

    let color: Color
    let bars: Int
    let barWidth: CGFloat
    let spacing: CGFloat
    let maxHeight: CGFloat
    var source: Source = .live

    func makeNSView(context: Context) -> LevelBarsNSView {
        LevelBarsNSView(bars: bars, barWidth: barWidth, spacing: spacing, maxHeight: maxHeight)
    }

    func updateNSView(_ view: LevelBarsNSView, context: Context) {
        view.color = NSColor(color)
        view.source = source
    }

    /// Each bar drifts on two slow sines at its own pace, so the bars never move in step and never
    /// repeat in a way the eye catches. 0.15…1.
    static func ambientLevels(count: Int, at time: TimeInterval) -> [Float] {
        (0..<count).map { index in
            let i = Double(index)
            let value =
                0.55 + 0.28 * sin(time * (5.1 + i * 1.3) + i * 1.7) + 0.17 * sin(time * (8.3 + i * 0.9) + i * 2.9)
            return Float(min(1, max(0.15, value)))
        }
    }
}

final class LevelBarsNSView: NSView {
    var color: NSColor = .white {
        didSet { bars.forEach { $0.backgroundColor = color.cgColor } }
    }
    var source: NotchLevelBars.Source = .live {
        didSet { if source != oldValue { schedule() } }
    }
    private let bars: [CALayer]
    private let barWidth: CGFloat
    private let spacing: CGFloat
    private let maxHeight: CGFloat
    private var timer: Timer?
    var isTicking: Bool { timer?.isValid == true }
    private var occlusionWatch: NSObjectProtocol?
    private var awayWatch: AnyCancellable?

    init(bars count: Int, barWidth: CGFloat, spacing: CGFloat, maxHeight: CGFloat) {
        self.barWidth = barWidth
        self.spacing = spacing
        self.maxHeight = maxHeight
        bars = (0..<count).map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        for bar in bars {
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = color.cgColor
            layer?.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    deinit {
        if let occlusionWatch { NotificationCenter.default.removeObserver(occlusionWatch) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionWatch { NotificationCenter.default.removeObserver(occlusionWatch) }
        occlusionWatch = nil
        awayWatch = nil
        if let window {
            occlusionWatch = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.schedule() }
            awayWatch = PowerState.shared.$isAway.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.schedule() }
        }
        schedule()
    }

    /// Live bars follow the music at 30 frames a second; ambient motion is slow enough for 20.
    static func interval(for source: NotchLevelBars.Source) -> TimeInterval {
        source == .live ? 1.0 / 30 : 1.0 / 20
    }

    /// Ticks only while the bars can be seen: in a window that is on screen, with the displays
    /// awake and the screen unlocked.
    private func schedule() {
        let visible =
            window?.occlusionState.contains(.visible) == true && !PowerState.shared.isAway
        guard visible else {
            timer?.invalidate()
            timer = nil
            return
        }
        let interval = Self.interval(for: source)
        if let timer, timer.isValid, timer.timeInterval == interval { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        // A little slack lets macOS fold these wake-ups into the display's own.
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Levels come in band order, bass first; with fewer bars than bands the highest band is
    /// dropped, since it is the one most songs barely move.
    private func tick() {
        let levels =
            source == .live
            ? SystemAudioLevels.shared.levels
            : NotchLevelBars.ambientLevels(count: bars.count, at: CACurrentMediaTime())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * spacing
        var x = (bounds.width - total) / 2
        for (index, bar) in bars.enumerated() {
            let level = index < levels.count ? CGFloat(levels[index]) : 0
            let height = max(barWidth, maxHeight * level)
            bar.frame = CGRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            x += barWidth + spacing
        }
        CATransaction.commit()
    }
}

// MARK: - Panel
