import Foundation
import Testing

@testable import VoxOS

/// Music and Notes build AppleScript from model-supplied text, so the risks are a script that
/// breaks on a quote, a tool that launches a player nobody asked for, and docs that bloat the
/// prompt every agent step re-sends. These pin those down without needing either app running.
@Suite
struct AgentMusicNotesTests {

    // MARK: Player choice

    @Test func explicitAppAlwaysWins() {
        #expect(
            AgentMusic.choosePlayer(
                requested: "Spotify", spotifyRunning: false, musicRunning: true, spotifyPlaying: false)
                == .spotify)
        #expect(
            AgentMusic.choosePlayer(
                requested: "apple music", spotifyRunning: true, musicRunning: false, spotifyPlaying: true)
                == .music)
    }

    @Test func runningPlayerIsChosenWhenNoneRequested() {
        #expect(
            AgentMusic.choosePlayer(requested: "", spotifyRunning: true, musicRunning: false, spotifyPlaying: false)
                == .spotify)
        #expect(
            AgentMusic.choosePlayer(requested: "", spotifyRunning: false, musicRunning: true, spotifyPlaying: false)
                == .music)
    }

    @Test func whenBothAreOpenThePlayingOneWins() {
        #expect(
            AgentMusic.choosePlayer(requested: "", spotifyRunning: true, musicRunning: true, spotifyPlaying: true)
                == .spotify)
        #expect(
            AgentMusic.choosePlayer(requested: "", spotifyRunning: true, musicRunning: true, spotifyPlaying: false)
                == .music)
    }

    @Test func appleMusicIsTheDefaultWhenNothingIsOpen() {
        #expect(
            AgentMusic.choosePlayer(requested: "", spotifyRunning: false, musicRunning: false, spotifyPlaying: false)
                == .music)
    }

    // MARK: Control scripts

    @Test func everyDocumentedActionBuildsAScriptForBothPlayers() {
        for action in AgentMusic.controlActions where action != "volume" {
            for player in [AgentMusic.Player.spotify, .music] {
                let script = AgentMusic.controlScript(action: action, value: nil, player: player)
                #expect(script?.contains("tell application \"\(player.rawValue)\"") == true, "\(action) on \(player)")
            }
        }
    }

    @Test func shuffleAndRepeatUseEachPlayersOwnVocabulary() {
        #expect(
            AgentMusic.controlScript(action: "shuffle_on", value: nil, player: .spotify)?.contains(
                "set shuffling to true") == true)
        #expect(
            AgentMusic.controlScript(action: "shuffle_on", value: nil, player: .music)?.contains(
                "set shuffle enabled to true") == true)
        #expect(
            AgentMusic.controlScript(action: "repeat_on", value: nil, player: .music)?.contains(
                "set song repeat to all") == true)
        #expect(
            AgentMusic.controlScript(action: "repeat_off", value: nil, player: .spotify)?.contains(
                "set repeating to false") == true)
    }

    @Test func volumeNeedsAValueInRange() {
        #expect(AgentMusic.controlScript(action: "volume", value: nil, player: .music) == nil)
        #expect(AgentMusic.controlScript(action: "volume", value: -1, player: .music) == nil)
        #expect(AgentMusic.controlScript(action: "volume", value: 101, player: .music) == nil)
        #expect(
            AgentMusic.controlScript(action: "volume", value: 40, player: .music)?.contains("set sound volume to 40")
                == true)
    }

    @Test func unknownActionsBuildNothing() {
        #expect(AgentMusic.controlScript(action: "explode", value: nil, player: .music) == nil)
    }

    // MARK: Compiles against the real app dictionaries
    //
    // String checks can't catch AppleScript that is well-formed text but not valid script: a
    // variable named after one of the app's own properties (`body` in Notes) or a reserved word
    // (`a`, `st`) fails only when compiled against the app's terminology. Spotify is skipped
    // because compiling against a missing app makes macOS ask where it is.

    private static func compiles(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return "could not create script" }
        _ = script.compileAndReturnError(&error)
        return error?[NSAppleScript.errorMessage] as? String
    }

    private static let notesInstalled = FileManager.default.fileExists(atPath: "/System/Applications/Notes.app")
    private static let musicInstalled = FileManager.default.fileExists(atPath: "/System/Applications/Music.app")

    @Test(.enabled(if: notesInstalled)) func notesScriptsCompile() {
        #expect(Self.compiles(AgentNotes.searchScript(query: "tax \"2024\"", limit: 5)) == nil)
        #expect(Self.compiles(AgentNotes.readScript(title: "Shopping list")) == nil)
    }

    @Test(.enabled(if: musicInstalled)) func appleMusicScriptsCompile() {
        #expect(Self.compiles(AgentMusic.nowPlayingScript(.music)) == nil)
        #expect(Self.compiles(AgentMusic.playLibraryScript(query: "hello \"world\"")) == nil)
        for action in AgentMusic.controlActions {
            let script = AgentMusic.controlScript(action: action, value: 30, player: .music)
            #expect(script.flatMap(Self.compiles) == nil, "\(action)")
        }
    }

    // MARK: Quoting

    @Test func searchTextCannotBreakOutOfTheScript() {
        let script = AgentMusic.playLibraryScript(query: #"x" & (do shell script "id") & ""#)
        #expect(script.contains(#"x\" & (do shell script \"id\") & \""#), "quotes must be escaped")
        #expect(!script.contains(#"search playlist 1 for "x" &"#))
        #expect(AgentNotes.searchScript(query: #"a"b\"#, limit: 5).contains(#"a\"b\\"#))
        #expect(AgentNotes.readScript(title: #"t"x"#).contains(#"t\"x"#))
    }

    @Test func spotifySearchEncodesTheQuery() {
        #expect(
            AgentMusic.spotifySearchURL(query: "daft punk & friends")?.absoluteString
                == "spotify:search:daft%20punk%20%26%20friends")
        #expect(AgentMusic.spotifySearchURL(query: "") == nil)
    }

    // MARK: Parsing

    @Test func nowPlayingParsesATrack() {
        let info = AgentMusic.parseNowPlaying("playing|||Song|||Artist|||Album", player: .spotify)
        #expect(info["track"] as? String == "Song")
        #expect(info["artist"] as? String == "Artist")
        #expect(info["playing"] as? Bool == true)
        #expect(info["app"] as? String == "Spotify")
    }

    @Test func nowPlayingHandlesNoTrack() {
        let info = AgentMusic.parseNowPlaying("stopped|||||||||", player: .music)
        #expect(info["playing"] as? Bool == false)
        #expect(info["track"] is NSNull)
    }

    @Test func pausedIsNotPlaying() {
        let info = AgentMusic.parseNowPlaying("paused|||Song|||A|||B", player: .music)
        #expect(info["playing"] as? Bool == false)
        #expect(info["state"] as? String == "paused")
    }

    @Test func notesSearchParsesRecords() {
        let raw = "Groceries|||milk\neggs|||Monday 1 January<<<END>>>Ideas|||app thing|||Tuesday 2 January<<<END>>>"
        let notes = AgentNotes.parseSearch(raw)
        #expect(notes.count == 2)
        #expect(notes[0]["title"] as? String == "Groceries")
        #expect(notes[0]["snippet"] as? String == "milk eggs", "newlines flatten to spaces")
        #expect(notes[1]["modified"] as? String == "Tuesday 2 January")
    }

    @Test func notesSearchOfNothingIsEmpty() {
        #expect(AgentNotes.parseSearch("").isEmpty)
    }

    @Test func notesReadKeepsPipesInsideTheBodyAndCapsLength() {
        let note = AgentNotes.parseRead("Title|||a|||b|||c|||Monday")
        #expect(note?["title"] as? String == "Title")
        #expect(note?["body"] as? String == "a|||b|||c")
        #expect(note?["truncated"] as? Bool == false)

        let long = String(repeating: "x", count: AgentNotes.maxBodyLength + 500)
        let capped = AgentNotes.parseRead("T|||\(long)|||Monday")
        #expect((capped?["body"] as? String)?.count == AgentNotes.maxBodyLength)
        #expect(capped?["truncated"] as? Bool == true)
    }

    @Test func missingNoteIsNil() {
        #expect(AgentNotes.parseRead("NOT_FOUND") == nil)
    }

    // MARK: Prompt budget and gating

    @Test func onDemandDocsAppearOnlyWhenTheRequestMentionsThem() {
        #expect(AgentToolCatalog.onDemandSection(for: "open Safari") == nil)
        #expect(AgentToolCatalog.onDemandSection(for: "what's the weather") == nil)
        #expect(AgentToolCatalog.onDemandSection(for: "play some jazz")?.contains("music_play") == true)
        #expect(AgentToolCatalog.onDemandSection(for: "skip this song")?.contains("music_control") == true)
        #expect(
            AgentToolCatalog.onDemandSection(for: "what's playing right now")?.contains("music_now_playing") == true)
        #expect(AgentToolCatalog.onDemandSection(for: "find my note about taxes")?.contains("notes_search") == true)
    }

    @Test func keywordsMatchWholeWordsNotFragments() {
        // "playground" and "denote" must not pull in the music or notes docs.
        #expect(AgentToolCatalog.onDemandSection(for: "open the playground") == nil)
        #expect(AgentToolCatalog.onDemandSection(for: "denote the change") == nil)
    }

    @Test func bothAreaDocsCanApplyToOneRequest() {
        let section = AgentToolCatalog.onDemandSection(for: "play music and read my notes")
        #expect(section?.contains("music_play") == true)
        #expect(section?.contains("notes_read") == true)
    }

    @Test func eachOnDemandBlockStaysSmall() {
        for entry in AgentToolCatalog.onDemand {
            #expect(entry.docs.count < 600, "\(entry.name) docs are re-sent every step of a request that mentions them")
        }
    }

    @Test func privateReadsAndActionsAreGatedByControlMode() {
        for tool in ["music_play", "music_control", "notes_search", "notes_read"] {
            #expect(AgentControlMode.isMutating(tool), "\(tool) must not run in observe-only")
        }
        #expect(!AgentControlMode.isMutating("music_now_playing"))
    }
}
