import Foundation

/// Shuffle and repeat for the notch's player.
///
/// MediaRemote can toggle both for any player, but on current macOS it rarely reports them back,
/// so a button driven by it could not show whether it is on. Music and Spotify answer
/// AppleScript, which both reads and sets them; those two show their real state, and every other
/// player gets the MediaRemote toggle without a lit state.
enum NotchPlaybackModes {
    enum Repeat: String, Equatable {
        case off
        case one
        case all

        /// The order the Music app itself cycles through.
        var next: Repeat {
            switch self {
            case .off: return .all
            case .all: return .one
            case .one: return .off
            }
        }
    }

    struct State: Equatable {
        var shuffle: Bool
        var repeatMode: Repeat
    }

    static let music = "com.apple.Music"
    static let spotify = "com.spotify.client"

    static func canReadState(of bundleID: String?) -> Bool {
        bundleID == music || bundleID == spotify
    }

    // MARK: Parsing osascript's output

    /// Music returns `{shuffle enabled, song repeat}` as "true, all".
    static func parseMusic(_ output: String) -> State? {
        let parts = fields(output)
        guard parts.count == 2, let shuffle = Bool(parts[0]), let repeatMode = Repeat(rawValue: parts[1]) else {
            return nil
        }
        return State(shuffle: shuffle, repeatMode: repeatMode)
    }

    /// Spotify returns `{shuffling, repeating}` as "false, true"; it has no repeat-one.
    static func parseSpotify(_ output: String) -> State? {
        let parts = fields(output)
        guard parts.count == 2, let shuffle = Bool(parts[0]), let repeating = Bool(parts[1]) else { return nil }
        return State(shuffle: shuffle, repeatMode: repeating ? .all : .off)
    }

    private static func fields(_ output: String) -> [String] {
        output.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    // MARK: Scripts

    static func readScript(for bundleID: String) -> String? {
        switch bundleID {
        case music: return #"tell application id "com.apple.Music" to return {shuffle enabled, song repeat}"#
        case spotify: return #"tell application id "com.spotify.client" to return {shuffling, repeating}"#
        default: return nil
        }
    }

    static func shuffleScript(for bundleID: String, to on: Bool) -> String? {
        switch bundleID {
        case music: return #"tell application id "com.apple.Music" to set shuffle enabled to \#(on)"#
        case spotify: return #"tell application id "com.spotify.client" to set shuffling to \#(on)"#
        default: return nil
        }
    }

    static func repeatScript(for bundleID: String, to mode: Repeat) -> String? {
        switch bundleID {
        case music: return #"tell application id "com.apple.Music" to set song repeat to \#(mode.rawValue)"#
        case spotify: return #"tell application id "com.spotify.client" to set repeating to \#(mode != .off)"#
        default: return nil
        }
    }

    // MARK: Running

    /// Never launches a player: only asked about the one that is reporting a track.
    static func read(_ bundleID: String?) async -> State? {
        guard let bundleID, let script = readScript(for: bundleID) else { return nil }
        let output = await AgentAppleScript.runDetached(script, timeout: 3)["result"] as? String ?? ""
        return bundleID == music ? parseMusic(output) : parseSpotify(output)
    }

    /// Flips shuffle and returns the state the player reports afterwards; nil for players whose
    /// state cannot be read, which get the MediaRemote toggle instead.
    static func toggleShuffle(_ bundleID: String?, from state: State?) async -> State? {
        guard let bundleID, let state, let script = shuffleScript(for: bundleID, to: !state.shuffle) else {
            await MainActor.run { PlaybackController.shared.toggleShuffle() }
            return nil
        }
        _ = await AgentAppleScript.runDetached(script, timeout: 3)
        return await read(bundleID)
    }

    // MARK: Favorite

    /// The star: Music's own favourite, which it reads and sets through scripting. Spotify's
    /// scripting has none, and MediaRemote does not report one, so other players show no star.
    static func canFavorite(_ bundleID: String?) -> Bool { bundleID == music }

    static let favoriteReadScript = #"""
        tell application id "com.apple.Music"
            if player state is stopped then return "unknown"
            return (favorited of current track) as text
        end tell
        """#

    /// Sets the star and waits up to three seconds for Music to agree, so the answer read back is
    /// the one it settled on rather than the value from before the change.
    static func favoriteWriteScript(to on: Bool) -> String {
        """
        tell application id "com.apple.Music"
            if player state is stopped then return "unknown"
            set favorited of current track to \(on)
            repeat 10 times
                if (favorited of current track) is \(on) then exit repeat
                delay 0.3
            end repeat
            return (favorited of current track) as text
        end tell
        """
    }

    /// Never launches Music: only asked while Music is the player shown.
    static func readFavorite(_ bundleID: String?) async -> Bool? {
        guard canFavorite(bundleID) else { return nil }
        return parseFavorite(await AgentAppleScript.runDetached(favoriteReadScript, timeout: 3)["result"] as? String)
    }

    static func setFavorite(_ bundleID: String?, to on: Bool) async -> Bool? {
        guard canFavorite(bundleID) else { return nil }
        return parseFavorite(
            await AgentAppleScript.runDetached(favoriteWriteScript(to: on), timeout: 5)["result"] as? String)
    }

    static func parseFavorite(_ output: String?) -> Bool? {
        Bool(output?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }

    static func cycleRepeat(_ bundleID: String?, from state: State?) async -> State? {
        guard let bundleID, let state else {
            await MainActor.run { PlaybackController.shared.toggleRepeat() }
            return nil
        }
        // Spotify has no repeat-one: off and all only.
        let next: Repeat = bundleID == spotify ? (state.repeatMode == .off ? .all : .off) : state.repeatMode.next
        guard let script = repeatScript(for: bundleID, to: next) else { return nil }
        _ = await AgentAppleScript.runDetached(script, timeout: 3)
        return await read(bundleID)
    }
}
