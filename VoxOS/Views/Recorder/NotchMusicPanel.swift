import CoreAudio
import SwiftUI
import VoxOSNowPlaying

/// The Music page's list, in place of the player: Up Next — the queue after the playing track,
/// read from MediaRemote — and Output, where the sound goes. One height for both tabs, so turning
/// between them never moves the card's edge.
struct NotchMusicPanel: View {
    enum Tab: Equatable {
        case upNext
        case output
    }

    let tab: Tab
    /// The queue, playing track first; nil until it has been read, empty when there is none.
    let queue: [NowPlayingQueue.Item]?
    /// The player's speed, for the chip beside the tabs when it is not 1×.
    let rate: Double
    let onTab: (Tab) -> Void
    let onPlay: (_ offset: Int, _ item: NowPlayingQueue.Item) -> Void
    let onClose: () -> Void

    enum Layout {
        static let header: CGFloat = 22
        static let row: CGFloat = 36
        static let rows = 4

        /// Four rows under the header, whatever the tab; more scroll.
        static var cardHeight: CGFloat {
            let list: CGFloat = CGFloat(rows) * row + CGFloat(rows - 1) * 2
            return NotchHome.Card.top + 4 + header + 6 + list + NotchHome.Card.bottom + 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch tab {
            case .upNext: NotchUpNextList(queue: queue, onPlay: onPlay)
            case .output: NotchOutputList()
            }
            Spacer(minLength: 0)
        }
        .padding(.top, NotchHome.Card.top + 4)
        .padding(.horizontal, AgentComposer.panelInset + 6)
        .padding(.bottom, NotchHome.Card.bottom)
    }

    private var header: some View {
        HStack(spacing: 6) {
            tabButton("Up Next", .upNext)
            tabButton("Output", .output)
            if rate > 0, abs(rate - 1) > 0.01 {
                Text(verbatim: "\(rate.formatted(.number.precision(.fractionLength(0...2))))×")
                    .font(.app(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule().fill(.white.opacity(0.1)))
                    .accessibilityLabel(Text("Playing at \(rate.formatted()) times speed"))
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: Layout.header, height: Layout.header)
                    .background(Circle().fill(.white.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Back to the Player"))
        }
    }

    private func tabButton(_ title: LocalizedStringKey, _ value: Tab) -> some View {
        let selected = tab == value
        return Button {
            onTab(value)
        } label: {
            Text(title)
                .font(.app(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
                .padding(.horizontal, 10)
                .frame(height: Layout.header)
                .background(Capsule().fill(.white.opacity(selected ? 0.12 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The queue: the playing track with a speaker, then the ones after it, numbered. A double-click
/// plays one; a single click does nothing, so a pass of the pointer cannot change the music.
private struct NotchUpNextList: View {
    let queue: [NowPlayingQueue.Item]?
    let onPlay: (_ offset: Int, _ item: NowPlayingQueue.Item) -> Void

    var body: some View {
        if let queue, !queue.isEmpty {
            ScrollView(.vertical, showsIndicators: queue.count > NotchMusicPanel.Layout.rows) {
                VStack(spacing: 2) {
                    ForEach(Array(queue.enumerated()), id: \.offset) { offset, item in
                        row(offset, item)
                    }
                }
            }
        } else {
            Text(queue == nil ? "Reading the queue…" : "Nothing queued")
                .font(.app(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 8)
        }
    }

    private func row(_ offset: Int, _ item: NowPlayingQueue.Item) -> some View {
        let playing = offset == 0
        return HStack(spacing: 10) {
            Group {
                if playing {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(verbatim: "\(offset)").font(.app(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title)
                    .font(.app(size: 12, weight: playing ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(playing ? 1 : 0.9))
                    .lineLimit(1)
                if let artist = item.artist {
                    Text(verbatim: artist)
                        .font(.app(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let duration = item.duration {
                Text(verbatim: NotchHome.clock(duration))
                    .font(.app(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: NotchMusicPanel.Layout.row)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !playing { onPlay(offset, item) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(playing ? [] : .isButton)
        .accessibilityAction { if !playing { onPlay(offset, item) } }
    }
}

/// Where the sound goes: every output device, the current one ticked; a click moves the Mac's
/// sound there. Read when shown and after each choice; nothing is polled.
private struct NotchOutputList: View {
    @State private var devices: [NotchAudioOutput.Device] = []
    @State private var current = AudioObjectID(kAudioObjectUnknown)

    var body: some View {
        Group {
            if devices.isEmpty {
                Text("No output devices")
                    .font(.app(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 8)
            } else {
                ScrollView(.vertical, showsIndicators: devices.count > NotchMusicPanel.Layout.rows) {
                    VStack(spacing: 2) {
                        ForEach(devices, id: \.id) { device in row(device) }
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func row(_ device: NotchAudioOutput.Device) -> some View {
        let selected = device.id == current
        return Button {
            current = device.id
            Task.detached(priority: .userInitiated) {
                NotchAudioOutput.makeDefaultOutput(device.id)
                await MainActor.run { reload() }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: NotchAudioOutput.pickerSymbol(for: device))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
                    .frame(width: 22)
                Text(verbatim: device.name)
                    .font(.app(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: NotchMusicPanel.Layout.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func reload() {
        devices = NotchAudioOutput.outputDevices()
        current = NotchAudioOutput.defaultOutput()
    }
}

/// "Lossless", "Hi-Res Lossless", "Dolby Atmos" or "Multichannel" under the artist, in VoxOS's own
/// glyphs, for the track the player says is playing in one.
struct NotchAudioFormatBadge: View {
    let format: NowPlayingQueue.AudioFormat

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(title).font(.app(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.45))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch format {
        case .lossless: return "waveform"
        case .hiResLossless: return "waveform.badge.plus"
        case .dolbyAtmos: return "dot.radiowaves.left.and.right"
        case .multichannel: return "hifispeaker.2"
        }
    }

    private var title: LocalizedStringKey {
        switch format {
        case .lossless: return "Lossless"
        case .hiResLossless: return "Hi-Res Lossless"
        case .dolbyAtmos: return "Dolby Atmos"
        case .multichannel: return "Multichannel"
        }
    }
}
