import AppKit
import Combine
import MediaRemoteAdapter
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import VoxOSNowPlaying
import os

/// The player app's name and icon, for the Music page's label and a track without a cover.
@MainActor
enum NotchHomeApp {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func name(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let name = names[bundleID] { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[bundleID] = name
        return name
    }

    /// Brings the player forward, through Launch Services, which works from a background app.
    static func open(_ bundleID: String?) {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return
        }
        ActivityTrail.mark("notch home player opened")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = icons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

/// The cover as a tile. Without one, the player's own icon on a quiet tile in the cover's colour
/// (a browser playing YouTube has no cover to give).
private struct NotchHomeCover: View {
    let track: NotchTrack
    let size: CGFloat
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        Group {
            if let artwork = track.artwork {
                Image(nsImage: artwork).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [track.tint.opacity(0.28), track.tint.opacity(0.08)], startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                    if let icon = NotchHomeApp.icon(for: track.bundleID) {
                        Image(nsImage: icon).resizable().frame(width: size * 0.46, height: size * 0.46)
                    } else {
                        Image(systemName: "music.note").font(.system(size: size * 0.22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        // A soft glow in the cover's own colour, for real covers only: an app icon on its plain
        // tile would glow white. Drawn once per cover, not per frame.
        .background {
            if track.artwork != nil {
                shape.fill(track.tint.opacity(0.35)).blur(radius: 16).padding(6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The cover on the left; names, a hairline of progress and the controls beside it, top and
/// bottom aligned with the cover. Times show only while the pointer is on the line.
struct NotchHomePlayer: View {
    let track: NotchTrack
    let modes: NotchPlaybackModes.State?
    /// Apple Music's star for this track; nil where the player has none.
    let favorite: Bool?
    /// The format the track plays in, for the badge under the artist.
    let format: NowPlayingQueue.AudioFormat?
    /// The track after this one, for "Up Next" in the last seconds.
    let next: NowPlayingQueue.Item?
    let liveBars: Bool
    /// Timed lines for the track, when lyrics are on and it has them.
    let lyrics: [NotchLyrics.Line]
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    let onFavorite: () -> Void
    let onList: () -> Void
    let onToggleBars: () -> Void

    /// How long before the end the artist line gives way to the next track.
    static let peek: TimeInterval = 10

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            // A click on the cover opens the app that is playing.
            Button {
                NotchHomeApp.open(track.bundleID)
            } label: {
                NotchHomeCover(track: track, size: NotchHome.Card.coverSize)
            }
            .buttonStyle(NotchCoverButtonStyle())
            .help(NotchHomeApp.name(for: track.bundleID).map { "Open \($0)" } ?? "Open the player")
            .accessibilityLabel(Text("Open \(NotchHomeApp.name(for: track.bundleID) ?? "the player")"))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: track.title)
                            .font(.app(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if next != nil, track.duration ?? 0 > Self.peek {
                            NotchTicking(every: 1, while: track.isPlaying) { tick in subtitle(at: tick.date) }
                        } else {
                            subtitle(at: Date())
                        }
                        if !lyrics.isEmpty {
                            // Half a second is close enough to the singing and cheap to draw.
                            NotchTicking(every: 0.5, while: track.isPlaying) { tick in lyric(at: tick.date) }
                        } else if let format {
                            NotchAudioFormatBadge(format: format)
                        }
                    }
                    Spacer(minLength: 0)
                    if track.isPlaying {
                        // A click switches Live Music Bars, so they need not live in Settings to
                        // be tried; ambient bars are dimmer, so the switch shows.
                        Button(action: onToggleBars) {
                            NotchLevelBars(
                                color: track.tint, bars: 4, barWidth: 2.5, spacing: 2, maxHeight: 14,
                                source: liveBars ? .live : .ambient
                            )
                            .opacity(liveBars ? 1 : 0.55)
                            .frame(width: 18, height: 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(liveBars ? "Live music bars: on" : "Live music bars: off")
                        .accessibilityLabel(Text(liveBars ? "Turn live music bars off" : "Turn live music bars on"))
                    }
                }
                .padding(.top, 4)

                Spacer(minLength: 0)

                NotchHomeProgress(track: track) { NotchPlayers.perform(.seek($0), on: track.bundleID) }
                    .frame(height: NotchHome.Card.progressHeight)

                HStack(spacing: 0) {
                    if let favorite {
                        NotchHomeControl(
                            symbol: favorite ? "star.fill" : "star", size: 11,
                            label: favorite ? "Remove from Favorites" : "Favorite", lit: favorite, action: onFavorite)
                        Spacer(minLength: 0)
                    }
                    NotchHomeControl(
                        symbol: "shuffle", size: 11, label: "Shuffle", lit: modes?.shuffle == true, action: onShuffle)
                    Spacer(minLength: 0)
                    NotchHomeControl(symbol: "backward.fill", size: 13, label: "Previous") {
                        NotchPlayers.perform(.previous, on: track.bundleID)
                    }
                    Spacer(minLength: 0)
                    NotchHomeControl(
                        symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 19,
                        label: track.isPlaying ? "Pause" : "Play"
                    ) {
                        NotchPlayers.perform(.toggle, on: track.bundleID)
                    }
                    Spacer(minLength: 0)
                    NotchHomeControl(symbol: "forward.fill", size: 13, label: "Next") {
                        NotchPlayers.perform(.next, on: track.bundleID)
                    }
                    Spacer(minLength: 0)
                    NotchHomeControl(
                        symbol: modes?.repeatMode == .one ? "repeat.1" : "repeat", size: 11, label: "Repeat",
                        lit: modes.map { $0.repeatMode != .off } ?? false, action: onRepeat)
                    Spacer(minLength: 0)
                    NotchHomeControl(symbol: "list.bullet", size: 11, label: "Up Next and Output", action: onList)
                }
                .frame(height: NotchHome.Card.controlsHeight)
                .padding(.top, 4)
            }
            .frame(height: NotchHome.Card.coverSize)
        }
        .padding(.top, NotchHome.Card.top)
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
    }

    /// "Artist — Album"; in the last seconds of a track, the one coming next.
    private func subtitle(at date: Date) -> some View {
        let remaining = (track.duration ?? 0) - (track.position(at: date) ?? 0)
        let peeking = next != nil && track.isPlaying && remaining > 0 && remaining <= Self.peek
        return Group {
            if peeking, let next {
                HStack(spacing: 4) {
                    Image(systemName: "forward.end.alt.fill").font(.system(size: 8, weight: .semibold))
                    Text("Up Next").font(.app(size: 12, weight: .semibold))
                    Text(verbatim: next.title).font(.app(size: 12))
                }
                .foregroundStyle(.white.opacity(0.6))
            } else {
                Text(verbatim: [track.artist, track.album ?? ""].filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.app(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .lineLimit(1)
    }

    private func lyric(at date: Date) -> some View {
        let line = NotchLyrics.line(at: track.position(at: date) ?? 0, in: lyrics)
        return Text(verbatim: line ?? "")
            .font(.app(size: 11, weight: .medium))
            .foregroundStyle(track.tint.opacity(0.9))
            .lineLimit(1)
            .animation(.easeOut(duration: 0.2), value: line)
    }
}

struct NotchHomeArtwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The cover dims a touch under the pointer and when pressed, as a button should.
private struct NotchCoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressable(configuration: configuration)
    }

    /// A view of its own, since a style cannot hold the hover state.
    private struct Pressable: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.75 : hovered ? 0.9 : 1)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}

/// A hairline you can click to jump. The times appear above it only while the pointer is on it;
/// the rest of the time the line says enough.
private struct NotchHomeProgress: View {
    let track: NotchTrack
    let onSeek: (Double) -> Void
    @State private var hovered = false

    var body: some View {
        NotchTicking(every: 1, while: track.isPlaying) { tick in line(at: tick.date) }
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovered = inside } }
    }

    private func line(at date: Date) -> some View {
        let position = track.position(at: date) ?? 0
        let duration = track.duration ?? 0
        return GeometryReader { geo in
            let fraction = duration > 0 ? min(1, position / duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(.white.opacity(hovered ? 0.95 : 0.75)).frame(
                    width: max(3, geo.size.width * fraction))
            }
            .frame(height: hovered ? 4 : 3)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) {
                if hovered, duration > 0 {
                    HStack {
                        Text(verbatim: NotchHome.clock(position))
                        Spacer()
                        Text(verbatim: NotchHome.clock(duration))
                    }
                    .font(.appMono(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .offset(y: -9)
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard duration > 0 else { return }
                onSeek(Double(location.x / max(geo.size.width, 1)) * duration)
            }
        }
    }
}

private struct NotchHomeControl: View {
    let symbol: String
    let size: CGFloat
    let label: LocalizedStringKey
    /// Shuffle and repeat: lit while on.
    var lit: Bool? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: NotchHome.Card.controlsHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(lit == true ? .isSelected : [])
    }

    private var color: Color {
        if let lit { return lit ? AppTheme.Accent.primary : .white.opacity(hovered ? 0.8 : 0.45) }
        return .white.opacity(hovered ? 1 : 0.85)
    }
}

// MARK: - Bars
