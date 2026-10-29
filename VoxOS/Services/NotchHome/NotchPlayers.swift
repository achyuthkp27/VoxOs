import AppKit
import Combine
import Foundation

/// Every player the notch can show at once.
///
/// MediaRemote names only one "now playing" app, so YouTube in a browser and the Music app could
/// never both appear. Music and Spotify announce their own state on distributed notifications
/// (`com.apple.Music.playerInfo`, `com.spotify.client.PlaybackStateChanged`) and answer AppleScript
/// for what those leave out (position, cover, controls), so they are followed directly; the
/// MediaRemote player, usually a browser, is added by NotchHomeManager.
///
/// Nothing here ever launches a player: AppleScript is only sent to one that is already running.
@MainActor
final class NotchPlayers: ObservableObject {
    static let shared = NotchPlayers()

    nonisolated static let music = NotchPlaybackModes.music
    nonisolated static let spotify = NotchPlaybackModes.spotify
    nonisolated static let scriptable: [String] = [music, spotify]
    /// ASCII unit separator: titles can hold commas, so AppleScript output is split on this.
    nonisolated static let separator = "\u{1F}"

    struct Entry: Equatable {
        let bundleID: String
        let title: String
        let artist: String
        let isPlaying: Bool
        let duration: Double?
        /// Position at `stamp`.
        let position: Double?
        let stamp: Date
        var artwork: NSImage?
        var artworkKey: String?
        /// From the player's notification; nil where it did not say.
        var album: String? = nil

        var trackKey: String { "\(bundleID)|\(title)|\(artist)" }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.trackKey == rhs.trackKey && lhs.isPlaying == rhs.isPlaying && lhs.position == rhs.position
                && lhs.stamp == rhs.stamp && lhs.artwork === rhs.artwork
        }
    }

    enum Action {
        case toggle
        case next
        case previous
        case seek(Double)
    }

    @Published private(set) var entries: [String: Entry] = [:]
    private var observers: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started, !ProcessIdentity.isTestHost else { return }
        started = true
        let center = DistributedNotificationCenter.default()
        observers = [
            center.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) {
                note in
                let info = note.userInfo ?? [:]
                Task { @MainActor in NotchPlayers.shared.received(Self.parseMusic(info, now: Date()), for: Self.music) }
            },
            center.addObserver(
                forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
            ) { note in
                let info = note.userInfo ?? [:]
                Task { @MainActor in
                    NotchPlayers.shared.received(Self.parseSpotify(info, now: Date()), for: Self.spotify)
                }
            },
        ]
        for bundleID in Self.scriptable where Self.isRunning(bundleID) { refresh(bundleID) }
    }

    func stop() {
        guard started else { return }
        started = false
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
        entries = [:]
    }

    // MARK: Updates

    /// A notification says what changed but not where in the track it is (Music) or what the
    /// cover looks like: those are asked for once per change.
    private func received(_ entry: Entry?, for bundleID: String) {
        guard let entry else {
            entries[bundleID] = nil
            return
        }
        var updated = entry
        if let previous = entries[bundleID], previous.trackKey == entry.trackKey {
            updated.artwork = previous.artwork
            updated.artworkKey = previous.artworkKey
        }
        entries[bundleID] = updated
        refresh(bundleID)
    }

    private func refresh(_ bundleID: String) {
        guard Self.isRunning(bundleID), let script = Self.stateScript(for: bundleID) else { return }
        Task { @MainActor in
            let output = await AgentAppleScript.runDetached(script, timeout: 3)["result"] as? String ?? ""
            guard var entry = Self.parseState(output, bundleID: bundleID, now: Date()) else {
                if output.trimmingCharacters(in: .whitespacesAndNewlines) == "stopped" { entries[bundleID] = nil }
                return
            }
            if let previous = entries[bundleID], previous.trackKey == entry.trackKey {
                entry.artwork = previous.artwork
                entry.artworkKey = previous.artworkKey
            }
            entries[bundleID] = entry
            if entry.artworkKey != entry.trackKey { loadArtwork(for: entry) }
        }
    }

    private func loadArtwork(for entry: Entry) {
        Task { @MainActor in
            let image: NSImage?
            if entry.bundleID == Self.spotify {
                let script = #"tell application id "com.spotify.client" to return artwork url of current track"#
                let address = (await AgentAppleScript.runDetached(script, timeout: 3)["result"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: address), url.scheme == "https",
                    let (data, _) = try? await URLSession.shared.data(from: url)
                {
                    image = NSImage(data: data)
                } else {
                    image = nil
                }
            } else {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("voxos-music-cover")
                _ = await AgentAppleScript.runDetached(Self.musicArtworkScript(writingTo: file.path), timeout: 4)
                image = (try? Data(contentsOf: file)).flatMap(NSImage.init(data:))
                try? FileManager.default.removeItem(at: file)
            }
            guard var current = entries[entry.bundleID], current.trackKey == entry.trackKey else { return }
            current.artwork = image
            current.artworkKey = entry.trackKey
            entries[entry.bundleID] = current
        }
    }

    // MARK: Controls

    /// Music and Spotify are driven directly, so the button acts on the player shown rather than
    /// on whichever app MediaRemote happens to name.
    static func perform(_ action: Action, on bundleID: String?) {
        guard let bundleID, scriptable.contains(bundleID), isRunning(bundleID) else {
            let playback = PlaybackController.shared
            switch action {
            case .toggle: playback.performAgentMediaAction("toggle")
            case .next: playback.performAgentMediaAction("next")
            case .previous: playback.performAgentMediaAction("previous")
            case .seek(let seconds): playback.seek(to: seconds)
            }
            return
        }
        let verb: String
        switch action {
        case .toggle: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        case .seek(let seconds): verb = "set player position to \(Int(seconds))"
        }
        Task {
            _ = await AgentAppleScript.runDetached(#"tell application id "\#(bundleID)" to \#(verb)"#, timeout: 3)
        }
    }

    nonisolated static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: Parsing

    /// Music's playerInfo: Name, Artist, Player State, Total Time (ms). No position.
    nonisolated static func parseMusic(_ info: [AnyHashable: Any], now: Date) -> Entry? {
        guard let state = info["Player State"] as? String, state != "Stopped",
            let title = info["Name"] as? String, !title.isEmpty
        else { return nil }
        return Entry(
            bundleID: music, title: title, artist: info["Artist"] as? String ?? "", isPlaying: state == "Playing",
            duration: number(info["Total Time"]).map { $0 / 1000 }, position: nil, stamp: now,
            album: info["Album"] as? String)
    }

    /// Spotify's PlaybackStateChanged: Name, Artist, Player State, Duration (ms), Playback
    /// Position (seconds).
    nonisolated static func parseSpotify(_ info: [AnyHashable: Any], now: Date) -> Entry? {
        guard let state = info["Player State"] as? String, state != "Stopped",
            let title = info["Name"] as? String, !title.isEmpty
        else { return nil }
        return Entry(
            bundleID: spotify, title: title, artist: info["Artist"] as? String ?? "", isPlaying: state == "Playing",
            duration: number(info["Duration"]).map { $0 / 1000 }, position: number(info["Playback Position"]),
            stamp: now, album: info["Album"] as? String)
    }

    /// "title␟artist␟playing␟duration␟position"; durations are seconds for Music, milliseconds
    /// for Spotify. A player that has stopped answers "stopped".
    nonisolated static func parseState(_ output: String, bundleID: String, now: Date) -> Entry? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: separator)
        guard fields.count == 5, !fields[0].isEmpty else { return nil }
        let state = fields[2].lowercased()
        guard state == "playing" || state == "paused" else { return nil }
        var duration = Double(fields[3].replacingOccurrences(of: ",", with: "."))
        if bundleID == spotify { duration = duration.map { $0 / 1000 } }
        return Entry(
            bundleID: bundleID, title: fields[0], artist: fields[1], isPlaying: state == "playing", duration: duration,
            position: Double(fields[4].replacingOccurrences(of: ",", with: ".")), stamp: now)
    }

    nonisolated static func stateScript(for bundleID: String) -> String? {
        guard scriptable.contains(bundleID) else { return nil }
        return """
            tell application id "\(bundleID)"
                if player state is stopped then return "stopped"
                set sep to ASCII character 31
                return (name of current track) & sep & (artist of current track) & sep & (player state as string) & sep & (duration of current track) & sep & (player position)
            end tell
            """
    }

    nonisolated static func musicArtworkScript(writingTo path: String) -> String {
        """
        tell application id "com.apple.Music"
            if (count of artworks of current track) is 0 then return "none"
            set cover to raw data of artwork 1 of current track
        end tell
        set handle to open for access (POSIX file "\(path)") with write permission
        set eof handle to 0
        write cover to handle
        close access handle
        return "ok"
        """
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
