import Foundation
import Testing

@testable import VoxOS

/// What VoxOS reads from or writes into other tools (Claude Code's status line, Codex's config),
/// and the smaller notch pieces. The costly mistakes are a user's own status line or notify not
/// coming back exactly, and a password kept from the clipboard.
@Suite
@MainActor
struct NotchExtrasTests {

    // MARK: Status line relay

    @Test func theUsersStatusLineComesBackExactly() throws {
        let original: [String: Any] = ["type": "command", "command": "bash ~/.claude/my-line.sh", "padding": 1]
        let settings: [String: Any] = ["statusLine": original, "model": "opus"]
        let installed = try #require(ClaudeCodeStatusRelay.installing(into: settings, port: 47317))
        let line = installed.settings["statusLine"] as? [String: Any]
        let command = line?["command"] as? String ?? ""
        #expect(command.contains("| bash ~/.claude/my-line.sh"), "the user's command still draws the line")
        #expect(command.contains(ClaudeCodeStatusRelay.path))
        #expect(line?["padding"] as? Int == 1, "the rest of the status line is kept")
        #expect(ClaudeCodeStatusRelay.installing(into: installed.settings, port: 47317) == nil, "never wrapped twice")

        let restored = ClaudeCodeStatusRelay.removing(from: installed.settings, original: installed.original)
        #expect(ClaudeCodeHookEvent.canonicalJSON(restored) == ClaudeCodeHookEvent.canonicalJSON(settings))
    }

    @Test func withoutAStatusLineTheRelayPrintsNothingAndLeavesNone() throws {
        let installed = try #require(ClaudeCodeStatusRelay.installing(into: ["model": "opus"], port: 47317))
        #expect((installed.settings["statusLine"] as? [String: Any])?["command"] as? String != nil)
        #expect(ClaudeCodeStatusRelay.command(wrapping: nil, port: 47317).hasSuffix(" true"))
        let restored = ClaudeCodeStatusRelay.removing(from: installed.settings, original: nil)
        #expect(restored["statusLine"] == nil)
    }

    @Test func usageAndCostAreReadFromTheStatusLinesInput() {
        let reading = ClaudeCodeUsage.reading(from: [
            "session_id": "s1",
            "rate_limits": [
                "five_hour": ["used_percentage": 82.5, "resets_at": 1_800_000_000],
                "seven_day": ["used_percentage": 30, "resets_at": 1_800_500_000],
            ],
            "cost": ["total_cost_usd": 1.25],
        ])
        #expect(reading.fiveHour?.percent == 82.5)
        #expect(reading.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_800_500_000))
        #expect(reading.costUSD == 1.25)
        #expect(ClaudeCodeUsage.reading(from: ["session_id": "s1"]).fiveHour == nil, "no plan, no limits")
        #expect(ClaudeCodeUsage.crossed(from: 70, to: 81) == 80)
        #expect(ClaudeCodeUsage.crossed(from: 81, to: 90) == nil, "said once per level")
        #expect(ClaudeCodeUsage.crossed(from: nil, to: 96) == 95)
    }

    // MARK: Codex

    @Test func codexsOwnNotifyIsNeverReplacedAndOursComesOffCleanly() throws {
        let plain = "model = \"o4\"\n[profiles.fast]\nmodel = \"mini\"\n"
        let installed = try #require(CodexNotify.installing(into: plain, port: 47317))
        #expect(installed.hasPrefix("notify = [\"/usr/bin/curl\""), "top-level keys come before any table")
        #expect(installed.contains("\"--data-binary\"]"), "the event lands as the body")
        #expect(CodexNotify.installing(into: installed, port: 47317) == nil, "never twice")
        #expect(CodexNotify.removing(from: installed) == plain)

        let theirs = "notify = [\"terminal-notifier\"]\nmodel = \"o4\"\n"
        #expect(CodexNotify.hasOwnNotify(theirs))
        #expect(CodexNotify.installing(into: theirs, port: 47317) == nil)
        #expect(!CodexNotify.hasOwnNotify("[tui]\nnotify = true\n"), "a notify inside a table is not the program")

        #expect(CodexActivity.turnEnd(from: ["type": "agent-turn-complete", "cwd": "/Users/me/app"])?.project == "app")
        #expect(CodexActivity.turnEnd(from: ["type": "something-else"]) == nil)
    }

    // MARK: Replies

    @Test func aFinishedTurnsReplyShowsOnlyWhenAskedFor() {
        let activity = ClaudeCodeActivity()
        activity.showsReplies = { true }
        let stop = ClaudeCodeHookEvent.decode([
            "hook_event_name": "Stop", "session_id": "s1", "cwd": "/Users/me/Projects/app",
            "last_assistant_message": "  Done: tests pass.  ",
        ])!
        #expect(stop.reply == "Done: tests pass.")
        activity.receive(stop)
        #expect(activity.reply?.text == "Done: tests pass.")
        #expect(activity.reply?.project == "app")
        activity.receive(
            ClaudeCodeHookEvent.decode(["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/x/app"])!)
        #expect(activity.reply == nil, "a new prompt in that session puts it away")

        activity.showsReplies = { false }
        activity.receive(stop)
        #expect(activity.reply == nil)
    }

    @Test func repliesAreSpokenWithoutTheirMarkdown() {
        let spoken = ClaudeCodeSpeech.spoken(
            "## Done\n- **Fixed** the `bar`\n```swift\nlet x = 1\n```\nSee [the docs](https://x.y).")
        #expect(spoken.contains("Done"))
        #expect(spoken.contains("Fixed the bar"))
        #expect(!spoken.contains("let x"), "code is for the eye")
        #expect(spoken.contains("See the docs."))
    }

    // MARK: Clipboard

    @Test func secretsAreNeverKeptAndRepeatsMoveUp() {
        #expect(!NotchClipboard.mayKeep(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(!NotchClipboard.mayKeep(["org.nspasteboard.TransientType"]))
        #expect(NotchClipboard.mayKeep(["public.utf8-plain-text"]))
        let clipboard = NotchClipboard.shared
        clipboard.stop()
        defer { clipboard.stop() }
        clipboard.add("one")
        clipboard.add("two")
        clipboard.add("one")
        #expect(clipboard.items.map(\.text) == ["one", "two"])
        for index in 0..<(NotchClipboard.limit + 3) { clipboard.add("item \(index)") }
        #expect(clipboard.items.count == NotchClipboard.limit)
        clipboard.add("   ")
        #expect(clipboard.items.first?.text != "", "blank copies are ignored")
    }

    // MARK: Lyrics, shelf

    @Test func timedLyricsAreReadAndFollowed() {
        let lines = NotchLyrics.parse("[00:01.50] First\n[00:04.00][00:20.00] Chorus\nnot timed\n[00:10.00]")
        #expect(lines.map(\.time) == [1.5, 4, 10, 20])
        #expect(NotchLyrics.line(at: 0.5, in: lines) == nil, "before the first line")
        #expect(NotchLyrics.line(at: 5, in: lines) == "Chorus")
        #expect(NotchLyrics.line(at: 12, in: lines) == nil, "an instrumental gap")
        #expect(NotchLyrics.line(at: 25, in: lines) == "Chorus")
    }

    @Test func aZipNeverOverwritesAnother() {
        let source = URL(fileURLWithPath: "/tmp/Report.pdf")
        let taken: Set<String> = ["/tmp/Report.pdf.zip", "/tmp/Report.pdf 2.zip"]
        #expect(NotchShelf.zipURL(for: source, exists: { taken.contains($0.path) }).path == "/tmp/Report.pdf 3.zip")
        #expect(NotchShelf.zipURL(for: source, exists: { _ in false }).lastPathComponent == "Report.pdf.zip")
    }

    // MARK: Pushes, rain, unread, shortcuts

    @Test func onlyARealPushStartsACIWatch() {
        #expect(ClaudeCodeCIWatch.isPush("git push"))
        #expect(ClaudeCodeCIWatch.isPush("git push origin main"))
        #expect(ClaudeCodeCIWatch.isPush("make test && git push -q origin main"))
        #expect(ClaudeCodeCIWatch.isPush("git -C repo push"))
        #expect(!ClaudeCodeCIWatch.isPush("echo 'git push later'"), "words in a string")
        #expect(!ClaudeCodeCIWatch.isPush("git pushd"))
        #expect(!ClaudeCodeCIWatch.isPush("git status"))
    }

    @Test func aCIRunIsReadFromGitHubsCLI() {
        let done = Data(#"[{"status":"completed","conclusion":"failure","createdAt":"2026-10-28T15:25:44Z"}]"#.utf8)
        let run = ClaudeCodeCIWatch.run(fromJSON: done)
        #expect(run?.completed == true)
        #expect(run?.conclusion == "failure")
        let going = Data(#"[{"status":"in_progress","conclusion":"","createdAt":"2026-10-28T15:25:44Z"}]"#.utf8)
        #expect(ClaudeCodeCIWatch.run(fromJSON: going)?.conclusion == nil)
        #expect(ClaudeCodeCIWatch.run(fromJSON: Data("[]".utf8)) == nil)
    }

    @Test func rainSoonIsReadInQuarterHours() {
        let json: [String: Any] = [
            "current": ["temperature_2m": 20.0, "weather_code": 2],
            "minutely_15": ["precipitation": [0.0, 0.0, 0.4, 1.2]],
        ]
        #expect(AgentWeather.summarize(json)?["rain_in_minutes"] as? Int == 30)
        let dry: [String: Any] = [
            "current": ["temperature_2m": 20.0, "weather_code": 0], "minutely_15": ["precipitation": [0.0, 0.0]],
        ]
        #expect(AgentWeather.summarize(dry)?["rain_in_minutes"] == nil)
    }

    @Test func onlyACountThatRoseIsNews() {
        #expect(NotchUnread.risen(from: ["Mail": 2], to: ["Mail": 4])?.0 == "Mail")
        #expect(NotchUnread.risen(from: ["Mail": 4], to: ["Mail": 1]) == nil, "read some: nothing to say")
        #expect(NotchUnread.risen(from: [:], to: ["Messages": 1])?.1 == 1)
        #expect(NotchUnread.risen(from: ["Mail": 1, "Messages": 1], to: ["Mail": 2, "Messages": 5])?.0 == "Messages")
    }

    @Test func shortcutsAreListedOnePerLine() {
        #expect(NotchShortcuts.names(from: "Focus Mode\n  Send ETA \n\n") == ["Focus Mode", "Send ETA"])
    }
}
