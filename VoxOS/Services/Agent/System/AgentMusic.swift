import AppKit
import Foundation

/// Music control for Spotify and Apple Music, over each app's AppleScript dictionary.
///
/// Script building and result parsing are pure so they can be tested without a player running.
/// Neither app is launched just to be asked what is playing: a bare `tell application` would
/// start it, so reads check for a running process first.
enum AgentMusic {
    enum Player: String {
        case spotify = "Spotify"
        case music = "Music"

        var bundleIdentifier: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .music: return "com.apple.Music"
            }
        }

        var isRunning: Bool {
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        }
    }

    static let controlActions: [String] = [
        "play", "pause", "toggle", "next", "previous",
        "shuffle_on", "shuffle_off", "repeat_on", "repeat_off", "volume",
    ]

    // MARK: Player choice

    /// An explicit app wins. Otherwise the running player, preferring the one that is playing,
    /// and Apple Music when neither is open (it can start from the library; Spotify cannot).
    static func choosePlayer(requested: String, spotifyRunning: Bool, musicRunning: Bool, spotifyPlaying: Bool)
        -> Player
    {
        switch requested.lowercased().trimmingCharacters(in: .whitespaces) {
        case "spotify": return .spotify
        case "music", "apple music", "applemusic", "itunes": return .music
        default: break
        }
        switch (spotifyRunning, musicRunning) {
        case (true, false): return .spotify
        case (false, true): return .music
        case (true, true): return spotifyPlaying ? .spotify : .music
        case (false, false): return .music
        }
    }

    // MARK: Scripts

    static func nowPlayingScript(_ player: Player) -> String {
        """
        tell application "\(player.rawValue)"
          set stateText to (player state as string)
          try
            set trackName to name of current track
            set artistName to artist of current track
            set albumName to album of current track
          on error
            return stateText & "|||" & "" & "|||" & "" & "|||" & ""
          end try
          return stateText & "|||" & trackName & "|||" & artistName & "|||" & albumName
        end tell
        """
    }

    /// The control script for `action`, or nil when the action or its value is not valid.
    static func controlScript(action: String, value: Int?, player: Player) -> String? {
        let body: String
        switch action {
        case "play": body = "play"
        case "pause": body = "pause"
        case "toggle": body = "playpause"
        case "next": body = "next track"
        case "previous": body = "previous track"
        case "shuffle_on": body = player == .spotify ? "set shuffling to true" : "set shuffle enabled to true"
        case "shuffle_off": body = player == .spotify ? "set shuffling to false" : "set shuffle enabled to false"
        case "repeat_on": body = player == .spotify ? "set repeating to true" : "set song repeat to all"
        case "repeat_off": body = player == .spotify ? "set repeating to false" : "set song repeat to off"
        case "volume":
            guard let value, (0...100).contains(value) else { return nil }
            body = "set sound volume to \(value)"
        default: return nil
        }
        return """
            tell application "\(player.rawValue)"
              \(body)
              return "ok"
            end tell
            """
    }

    /// Searches the Apple Music library and plays the first match.
    static func playLibraryScript(query: String) -> String {
        """
        tell application "Music"
          set found to (search playlist 1 for "\(escape(query))")
          if (count of found) is 0 then return "NOT_FOUND"
          set hit to item 1 of found
          play hit
          return (name of hit) & "|||" & (artist of hit)
        end tell
        """
    }

    /// Spotify cannot start a track by name through AppleScript, so this opens its search.
    static func spotifySearchURL(query: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#&")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else {
            return nil
        }
        return URL(string: "spotify:search:\(encoded)")
    }

    // MARK: Parsing

    static func parseNowPlaying(_ raw: String, player: Player) -> [String: Any] {
        let parts = raw.components(separatedBy: "|||")
        let state = parts.first?.lowercased() ?? "unknown"
        guard parts.count >= 4, !parts[1].isEmpty else {
            return ["app": player.rawValue, "state": state, "playing": false, "track": NSNull()]
        }
        return [
            "app": player.rawValue, "state": state, "playing": state.contains("play"),
            "track": parts[1], "artist": parts[2], "album": parts[3],
        ]
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Tools

    @MainActor
    private static func resolve(_ requested: String) -> Player {
        let spotifyRunning = Player.spotify.isRunning
        let spotifyPlaying =
            spotifyRunning
            && (AgentAppleScript.run(#"tell application "Spotify" to return (player state as string)"#)["result"]
                as? String)?.contains("play") == true
        return choosePlayer(
            requested: requested, spotifyRunning: spotifyRunning, musicRunning: Player.music.isRunning,
            spotifyPlaying: spotifyPlaying)
    }

    @MainActor
    static func nowPlaying() -> [String: Any] {
        var report: [[String: Any]] = []
        for player in [Player.spotify, .music] where player.isRunning {
            let result = AgentAppleScript.run(nowPlayingScript(player))
            if let raw = result["result"] as? String { report.append(parseNowPlaying(raw, player: player)) }
        }
        guard !report.isEmpty else { return ["playing": false, "note": "Neither Spotify nor Music is open."] }
        // Report whichever is actually playing; fall back to the first open player.
        return report.first(where: { ($0["playing"] as? Bool) == true }) ?? report[0]
    }

    @MainActor
    static func control(action: String, value: Int?, app: String) -> [String: Any] {
        let action = action.lowercased().trimmingCharacters(in: .whitespaces)
        guard controlActions.contains(action) else {
            return ["error": "unknown action \(action); use \(controlActions.joined(separator: ", "))"]
        }
        let player = resolve(app)
        guard let script = controlScript(action: action, value: value, player: player) else {
            return ["error": "volume needs a value from 0 to 100"]
        }
        let result = AgentAppleScript.run(script)
        if let error = result["error"] { return ["error": error, "app": player.rawValue] }
        return ["result": "\(action) on \(player.rawValue)"]
    }

    @MainActor
    static func play(query: String, app: String) -> [String: Any] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let player = resolve(app)
        guard !query.isEmpty else {
            return control(action: "play", value: nil, app: player.rawValue)
        }
        switch player {
        case .music:
            let result = AgentAppleScript.run(playLibraryScript(query: query))
            if let error = result["error"] { return ["error": error] }
            let raw = result["result"] as? String ?? ""
            if raw == "NOT_FOUND" {
                return ["error": "Nothing in your Apple Music library matches \"\(query)\"."]
            }
            let parts = raw.components(separatedBy: "|||")
            return ["result": "playing", "track": parts.first ?? raw, "artist": parts.count > 1 ? parts[1] : ""]
        case .spotify:
            guard let url = spotifySearchURL(query: query) else { return ["error": "empty search"] }
            NSWorkspace.shared.open(url)
            return [
                "result": "opened Spotify search for \"\(query)\"",
                "note": "Spotify can't start a track by name from here; the user picks the result.",
            ]
        }
    }
}
