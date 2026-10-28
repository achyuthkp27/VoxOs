import Foundation
import Testing

@testable import VoxOS

/// Claude Code in the notch. The costly mistakes are an approval card that stays up after the
/// request was answered in the terminal, an answer written to the wrong request, and a settings
/// file that loses the user's own hooks — so those are what these pin down.
@Suite
@MainActor
struct ClaudeCodeTests {

    // MARK: Fixtures

    private static func payload(
        _ event: String, session: String = "s1", tool: String? = nil, input: [String: Any]? = nil,
        toolUseID: String? = nil, extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "hook_event_name": event, "session_id": session, "cwd": "/Users/me/Projects/VoxOs",
            "transcript_path": "/tmp/t.jsonl", "permission_mode": "default",
        ]
        if let tool { object["tool_name"] = tool }
        if let input { object["tool_input"] = input }
        if let toolUseID { object["tool_use_id"] = toolUseID }
        object.merge(extra) { $1 }
        return object
    }

    private static func event(
        _ name: String, session: String = "s1", tool: String? = nil, input: [String: Any]? = nil,
        toolUseID: String? = nil
    ) -> ClaudeCodeHookEvent {
        ClaudeCodeHookEvent.decode(payload(name, session: session, tool: tool, input: input, toolUseID: toolUseID))!
    }

    private static let mkdir: [String: Any] = ["command": "mkdir probe", "description": "Create a folder"]

    /// A request with a recorder for what was written back to the CLI.
    private final class Answers {
        var values: [ClaudeCodeActivity.Resolution] = []
    }

    private func ask(
        _ activity: ClaudeCodeActivity, session: String = "s1", input: [String: Any] = mkdir, now: Date = Date()
    ) -> (UUID, Answers) {
        let answers = Answers()
        let id = activity.request(
            Self.event("PermissionRequest", session: session, tool: "Bash", input: input), now: now
        ) { answers.values.append($0) }
        return (id, answers)
    }

    // MARK: Decoding

    @Test func decodesTheFieldsTheNotchUses() {
        let event = Self.event("PreToolUse", tool: "Bash", input: Self.mkdir, toolUseID: "toolu_1")
        #expect(event.kind == .preToolUse)
        #expect(event.sessionID == "s1")
        #expect(event.project == "VoxOs")
        #expect(event.toolUseID == "toolu_1")
        #expect(event.summary == ClaudeCodeToolSummary(title: "Run command", detail: "mkdir probe"))
    }

    @Test func unknownEventsAndBrokenBodiesDecodeToNil() {
        #expect(ClaudeCodeHookEvent.decode(Self.payload("SomethingNew")) == nil)
        #expect(ClaudeCodeHookEvent.decode(Data("not json".utf8)) == nil)
        #expect(ClaudeCodeHookEvent.decode(["hook_event_name": "Stop"]) == nil, "no session id")
    }

    @Test func inputKeyIgnoresKeyOrder() {
        let a = ClaudeCodeHookEvent.decode(Self.payload("PreToolUse", tool: "Bash", input: ["a": 1, "b": "x"]))!
        let b = ClaudeCodeHookEvent.decode(Self.payload("PreToolUse", tool: "Bash", input: ["b": "x", "a": 1]))!
        #expect(a.toolInputKey == b.toolInputKey)
    }

    @Test func summariesShowTheDecidingDetail() {
        let cwd = "/Users/me/Projects/VoxOs"
        #expect(
            ClaudeCodeToolSummary(toolName: "Edit", input: ["file_path": cwd + "/VoxOS/A.swift"], cwd: cwd).detail
                == "VoxOS/A.swift", "paths inside the session folder are relative")
        #expect(
            ClaudeCodeToolSummary(toolName: "WebFetch", input: ["url": "https://example.com"], cwd: cwd).detail
                == "https://example.com")
        let mcp = ClaudeCodeToolSummary(toolName: "mcp__claude_ai_Gmail__send", input: ["to": "a"], cwd: cwd)
        #expect(mcp.title == "claude_ai_Gmail · send", "single underscores belong to the server name")
        let longCommand = String(repeating: "x", count: 5000)
        let long = ClaudeCodeToolSummary(toolName: "Bash", input: ["command": longCommand], cwd: cwd)
        #expect(long.detail.count == ClaudeCodeToolSummary.maxDetailLength + 1, "clipped, with an ellipsis")
    }

    // MARK: Activity

    @Test func notchAnswerIsWrittenBackOnce() {
        let activity = ClaudeCodeActivity()
        let (id, answers) = ask(activity)
        #expect(activity.prompts.count == 1)
        activity.decide(id, .allow)
        activity.decide(id, .deny)
        #expect(answers.values == [.decided(.allow)])
        #expect(activity.prompts.isEmpty)
    }

    /// Measured: "Yes" in the terminal leaves the hook's connection open, runs the tool, and
    /// sends PostToolUse with the tool_use_id of the PreToolUse sent just before the request.
    @Test func terminalApprovalClearsTheCardThroughPostToolUse() {
        let activity = ClaudeCodeActivity()
        activity.receive(Self.event("PreToolUse", tool: "Bash", input: Self.mkdir, toolUseID: "toolu_A"))
        let (_, answers) = ask(activity)
        #expect(activity.prompts.first?.toolUseID == "toolu_A")

        activity.receive(Self.event("PostToolUse", tool: "Bash", input: Self.mkdir, toolUseID: "toolu_OTHER"))
        #expect(activity.prompts.count == 1, "another tool finishing does not answer this request")

        activity.receive(Self.event("PostToolUse", tool: "Bash", input: Self.mkdir, toolUseID: "toolu_A"))
        #expect(activity.prompts.isEmpty)
        #expect(answers.values == [.noDecision])
    }

    /// Measured: "No" or Esc in the terminal closes the hook's connection and sends nothing else.
    @Test func terminalDenialClearsTheCardWithoutAnAnswer() {
        let activity = ClaudeCodeActivity()
        let (id, answers) = ask(activity)
        activity.connectionClosed(id)
        #expect(activity.prompts.isEmpty)
        #expect(answers.values.isEmpty, "nothing can be written to a closed connection")
        activity.decide(id, .allow)
        #expect(answers.values.isEmpty, "a late click on a gone request does nothing")
    }

    @Test func endOfTurnSettlesOnlyThatSession() {
        let activity = ClaudeCodeActivity()
        let (_, first) = ask(activity, session: "s1")
        let (_, second) = ask(activity, session: "s2")
        activity.receive(Self.event("Stop", session: "s1"))
        #expect(first.values == [.noDecision])
        #expect(second.values.isEmpty)
        #expect(activity.prompts.map(\.sessionID) == ["s2"])
    }

    @Test func requestsExpireBeforeTheHookGivesUp() {
        let activity = ClaudeCodeActivity()
        let start = Date()
        let (_, answers) = ask(activity, now: start)
        activity.expire(now: start.addingTimeInterval(ClaudeCodeActivity.promptLifetime - 1))
        #expect(answers.values.isEmpty)
        activity.expire(now: start.addingTimeInterval(ClaudeCodeActivity.promptLifetime))
        #expect(answers.values == [.noDecision])
        #expect(ClaudeCodeActivity.promptLifetime < Double(ClaudeCodeHooks.permissionTimeout))
    }

    @Test func statusCountsWorkingSessionsThenShowsDoneBriefly() {
        let activity = ClaudeCodeActivity()
        let start = Date()
        activity.receive(Self.event("UserPromptSubmit", session: "s1"), now: start)
        activity.receive(Self.event("UserPromptSubmit", session: "s2"), now: start)
        #expect(activity.status(now: start) == .init(working: 2, finished: nil))

        activity.receive(Self.event("Stop", session: "s1"), now: start)
        #expect(activity.status(now: start) == .init(working: 1, finished: nil), "working outranks done")

        activity.receive(Self.event("Stop", session: "s2"), now: start)
        #expect(activity.status(now: start) == .init(working: 0, finished: .done))
        #expect(activity.nextStatusChange(after: start) == start.addingTimeInterval(ClaudeCodeActivity.finishedLinger))
        #expect(activity.status(now: start.addingTimeInterval(ClaudeCodeActivity.finishedLinger)).isEmpty)
    }

    @Test func sessionEndForgetsTheSession() {
        let activity = ClaudeCodeActivity()
        activity.receive(Self.event("UserPromptSubmit"))
        activity.receive(Self.event("SessionEnd"))
        #expect(activity.sessions.isEmpty)
        #expect(activity.status().isEmpty)
    }

    // MARK: HTTP

    private static func raw(_ head: String, body: String = "") -> Data {
        Data((head + "\r\n\r\n" + body).utf8)
    }

    @Test func parsesACompleteRequest() {
        let body = #"{"hook_event_name":"Stop"}"#
        let data = Self.raw(
            "POST /voxos/claude-code/hook HTTP/1.1\r\nHost: 127.0.0.1:47317\r\nContent-Length: \(body.utf8.count)\r\nX-VoxOS-Hook: 1",
            body: body)
        guard case .complete(let request) = ClaudeCodeHTTP.parse(data) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == ClaudeCodeHooks.path)
        #expect(request.headers["x-voxos-hook"] == "1", "header names are lowercased")
        #expect(String(decoding: request.body, as: UTF8.self) == body)
    }

    @Test func waitsForTheWholeBody() {
        let data = Self.raw("POST / HTTP/1.1\r\nContent-Length: 10", body: "12345")
        #expect(ClaudeCodeHTTP.parse(data) == .incomplete)
        #expect(ClaudeCodeHTTP.parse(Data("POST / HTTP/1.1\r\nHost: x".utf8)) == .incomplete)
    }

    @Test func refusesWhatItCannotRead() {
        #expect(ClaudeCodeHTTP.parse(Self.raw("garbage")) == .invalid)
        #expect(ClaudeCodeHTTP.parse(Self.raw("POST / HTTP/1.1\r\nTransfer-Encoding: chunked")) == .invalid)
        #expect(ClaudeCodeHTTP.parse(Self.raw("POST / HTTP/1.1\r\nContent-Length: 99999999999")) == .invalid)
    }

    @Test func onlyLoopbackHostsAreAccepted() {
        #expect(ClaudeCodeHTTP.isAllowedHost("127.0.0.1:47317", port: 47317))
        #expect(ClaudeCodeHTTP.isAllowedHost("LOCALHOST:47317", port: 47317))
        #expect(!ClaudeCodeHTTP.isAllowedHost("evil.example:47317", port: 47317), "DNS rebinding")
        #expect(!ClaudeCodeHTTP.isAllowedHost("127.0.0.1:80", port: 47317))
        #expect(!ClaudeCodeHTTP.isAllowedHost(nil, port: 47317))
    }

    private static let bashRequest = ClaudeCodeHookEvent.decode(
        payload(
            "PermissionRequest", tool: "Bash", input: ["command": "rm -rf node_modules"],
            extra: [
                "permission_suggestions": [
                    [
                        "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "rm -rf node_modules"]],
                        "behavior": "allow", "destination": "localSettings",
                    ]
                ]
            ]))!

    private static let question: [String: Any] = [
        "questions": [
            [
                "question": "Which color?", "header": "Color", "multiSelect": false,
                "options": [["label": "Red", "description": "Warm"], ["label": "Blue", "description": "Cool"]],
            ],
            [
                "question": "Which sizes?", "header": "Size", "multiSelect": true,
                "options": [["label": "S", "description": ""], ["label": "M", "description": ""], ["label": "L"]],
            ],
        ]
    ]

    private static func decision(_ body: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let output = object?["hookSpecificOutput"] as? [String: Any]
        #expect(output?["hookEventName"] as? String == "PermissionRequest")
        return output?["decision"] as? [String: Any] ?? [:]
    }

    @Test func allowAndDenyUseTheDocumentedShape() throws {
        let allow = try Self.decision(ClaudeCodeBridge.decisionBody(.allow, for: Self.bashRequest))
        #expect(allow["behavior"] as? String == "allow")
        #expect(allow["updatedPermissions"] == nil, "plain Allow saves no rule")

        let deny = try Self.decision(ClaudeCodeBridge.decisionBody(.deny, for: Self.bashRequest))
        #expect(deny["behavior"] as? String == "deny")
        #expect(deny["message"] is String)
    }

    @Test func alwaysAllowGrantsWhatTheCLISuggested() throws {
        let always = try Self.decision(ClaudeCodeBridge.decisionBody(.allowAlways, for: Self.bashRequest))
        #expect(always["behavior"] as? String == "allow")
        let updates = always["updatedPermissions"] as? [[String: Any]]
        #expect(updates?.first?["type"] as? String == "addRules")
        #expect(
            ClaudeCodeHookEvent.canonicalJSON(updates ?? [])
                == Self.bashRequest.permissionSuggestionsKey, "echoed back exactly")
    }

    @Test func autoModeSwitchesOnlyThisSession() throws {
        let auto = try Self.decision(ClaudeCodeBridge.decisionBody(.allowInAutoMode, for: Self.bashRequest))
        let update = (auto["updatedPermissions"] as? [[String: Any]])?.first
        #expect(update?["type"] as? String == "setMode")
        #expect(update?["mode"] as? String == "auto")
        #expect(update?["destination"] as? String == "session", "never written to a settings file")
    }

    /// Measured: allowing alone does not answer AskUserQuestion; the questions come back with an
    /// `answers` map, and Claude then reads the chosen label.
    @Test func answersEchoTheQuestionsBack() throws {
        let ask = ClaudeCodeHookEvent.decode(
            Self.payload("PermissionRequest", tool: "AskUserQuestion", input: Self.question))!
        let body = try Self.decision(
            ClaudeCodeBridge.decisionBody(.answer(["Which color?": "Blue", "Which sizes?": "S, L"]), for: ask))
        #expect(body["behavior"] as? String == "allow")
        let input = body["updatedInput"] as? [String: Any]
        #expect((input?["questions"] as? [Any])?.count == 2)
        #expect((input?["answers"] as? [String: String]) == ["Which color?": "Blue", "Which sizes?": "S, L"])
    }

    @Test func questionsDecodeAndJoinMultipleAnswersInOptionOrder() {
        let ask = ClaudeCodeHookEvent.decode(
            Self.payload("PermissionRequest", tool: "AskUserQuestion", input: Self.question))!
        let questions = ask.questions ?? []
        #expect(questions.map(\.header) == ["Color", "Size"])
        #expect(questions[1].multiSelect)
        #expect(questions[1].options.map(\.label) == ["S", "M", "L"], "an option without a description still counts")
        #expect(questions[1].answer(choosing: ["L", "S"]) == "S, L")
        #expect(questions[0].options[0].addsToLabel)
        #expect(!ClaudeCodeQuestion.Option(label: "Apple", description: " apple ").addsToLabel, "a repeat says nothing")
        #expect(Self.bashRequest.questions == nil)
    }

    @Test func extraChoicesShowOnlyWhenTheCLIOffersThem() {
        let activity = ClaudeCodeActivity()
        activity.request(Self.bashRequest) { _ in }
        let offered = activity.prompts[0]
        #expect(offered.alwaysAllow == "Don't ask again for rm -rf node_modules")
        #expect(offered.canSwitchToAutoMode, "the fixture is in default mode")

        var plain = Self.payload("PermissionRequest", tool: "Bash", input: ["command": "ls"])
        plain["permission_mode"] = "plan"
        activity.request(ClaudeCodeHookEvent.decode(plain)!) { _ in }
        #expect(activity.prompts[1].alwaysAllow == nil)
        #expect(!activity.prompts[1].canSwitchToAutoMode)

        let ask = ClaudeCodeHookEvent.decode(
            Self.payload("PermissionRequest", tool: "AskUserQuestion", input: Self.question))!
        activity.request(ask) { _ in }
        #expect(activity.prompts[2].questions?.count == 2)
        #expect(!activity.prompts[2].canSwitchToAutoMode, "a question is answered, not allowed")
    }

    @Test func theCardIsAsTallAsItsContent() {
        func prompt(detail: String, questions: [ClaudeCodeQuestion]? = nil) -> ClaudeCodeActivity.PermissionPrompt {
            ClaudeCodeActivity.PermissionPrompt(
                id: UUID(), sessionID: "s1", project: "VoxOs",
                summary: ClaudeCodeToolSummary(title: "Run command", detail: detail), toolUseID: nil,
                received: Date(), questions: questions)
        }
        let oneLine = ClaudeCodeNotch.cardContentHeight(for: prompt(detail: "ls"))
        let threeLines = ClaudeCodeNotch.cardContentHeight(for: prompt(detail: String(repeating: "x", count: 500)))
        #expect(threeLines - oneLine == 2 * ClaudeCodeNotch.Card.detailLineHeight, "capped at three lines")
        #expect(oneLine < 172, "no empty band under a one-line command")

        let ask = ClaudeCodeHookEvent.decode(
            Self.payload("PermissionRequest", tool: "AskUserQuestion", input: Self.question))!
        let questionHeight = ClaudeCodeNotch.cardContentHeight(for: prompt(detail: "", questions: ask.questions))
        let threeRows = 3 * ClaudeCodeNotch.Card.optionHeight + 2 * ClaudeCodeNotch.Card.optionSpacing
        #expect(questionHeight > threeRows + ClaudeCodeNotch.Card.buttonHeight, "the tallest question, and Send")
        #expect(ClaudeCodeNotch.lines(of: "a\nb\nc\nd", perLine: 50, max: 3) == 3)
    }

    // MARK: Hooks installer

    /// The user's real hooks at the time this was written: two command hooks of their own.
    private static var userSettings: [String: Any] {
        [
            "model": "opus",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "osascript -e 'display notification'"]]]],
                "Notification": [
                    ["matcher": "", "hooks": [["type": "command", "command": "notify", "timeout": 10]]]
                ],
            ],
        ]
    }

    private static func commands(_ settings: [String: Any], _ event: String) -> [String] {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        // The user's own commands only; VoxOS's curl hooks are commands too.
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .filter { !ClaudeCodeHooks.isVoxOSHook($0) }
            .compactMap { $0["command"] as? String }
    }

    @Test func installAddsOneGroupPerEventAndKeepsTheUsersHooks() {
        let installed = ClaudeCodeHooks.installing(into: Self.userSettings, port: 47317)
        #expect(ClaudeCodeHooks.state(of: installed, port: 47317) == .installed)
        #expect(Self.commands(installed, "Stop") == ["osascript -e 'display notification'"])
        #expect(Self.commands(installed, "Notification") == ["notify"])
        #expect(installed["model"] as? String == "opus")

        let hooks = installed["hooks"] as? [String: Any] ?? [:]
        for event in ClaudeCodeHooks.events {
            let groups = hooks[event.rawValue] as? [[String: Any]] ?? []
            let ours = groups.flatMap { $0["hooks"] as? [Any] ?? [] }.filter(ClaudeCodeHooks.isVoxOSHook)
            #expect(ours.count == 1, "exactly one VoxOS hook for \(event.rawValue)")
        }
    }

    @Test func installingTwiceDoesNotDuplicate() {
        let once = ClaudeCodeHooks.installing(into: Self.userSettings, port: 47317)
        let twice = ClaudeCodeHooks.installing(into: once, port: 47317)
        #expect(ClaudeCodeHookEvent.canonicalJSON(once) == ClaudeCodeHookEvent.canonicalJSON(twice))
    }

    @Test func removalRestoresTheOriginalSettings() {
        let installed = ClaudeCodeHooks.installing(into: Self.userSettings, port: 47317)
        let removed = ClaudeCodeHooks.removing(from: installed)
        #expect(ClaudeCodeHookEvent.canonicalJSON(removed) == ClaudeCodeHookEvent.canonicalJSON(Self.userSettings))
        #expect(ClaudeCodeHooks.state(of: removed, port: 47317) == .notInstalled)
    }

    @Test func removalKeepsAUserHookThatSharesAGroup() {
        let shared: [String: Any] = [
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": "mine"],
                            ClaudeCodeHooks.hook(for: .stop, port: 47317),
                        ]
                    ]
                ]
            ]
        ]
        #expect(Self.commands(ClaudeCodeHooks.removing(from: shared), "Stop") == ["mine"])
    }

    @Test func aDifferentPortReadsAsOutdated() {
        let installed = ClaudeCodeHooks.installing(into: [:], port: 40000)
        #expect(ClaudeCodeHooks.state(of: installed, port: 47317) == .outdated)
    }

    @Test func fileRoundTripBacksUpAndRefusesBrokenJSON() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("settings.json")

        try ClaudeCodeHooks.install(port: 47317, at: url)
        #expect(try ClaudeCodeHooks.state(at: url, port: 47317) == .installed, "a missing file is created")

        try ClaudeCodeHooks.uninstall(at: url)
        #expect(try ClaudeCodeHooks.state(at: url, port: 47317) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("voxos-backup").path))

        try Data("{ not json".utf8).write(to: url)
        #expect(throws: ClaudeCodeHooks.FileError.self) { try ClaudeCodeHooks.install(port: 47317, at: url) }
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "{ not json", "left untouched")
    }

    // MARK: Notch

    @Test func requestsOutrankStatusAndTheRecorderOutranksBoth() {
        let prompt = ClaudeCodeActivity.PermissionPrompt(
            id: UUID(), sessionID: "s1", project: "VoxOs",
            summary: ClaudeCodeToolSummary(title: "Run command", detail: "ls"), toolUseID: nil, received: Date())
        let busy = ClaudeCodeActivity.Status(working: 1, finished: nil)
        func content(
            prompts: [ClaudeCodeActivity.PermissionPrompt] = [], status: ClaudeCodeActivity.Status = .none,
            enabled: Bool = true, approvals: Bool = true, statusOn: Bool = true, recorder: Bool = false
        ) -> ClaudeCodeNotch.Content {
            ClaudeCodeNotch.content(
                prompts: prompts, status: status, enabled: enabled, approvalsEnabled: approvals,
                statusEnabled: statusOn, recorderVisible: recorder)
        }
        #expect(content(prompts: [prompt, prompt], status: busy) == .approval(prompt, waiting: 2))
        #expect(content(status: busy) == .status(busy))
        #expect(content(prompts: [prompt], status: busy, recorder: true) == .hidden)
        #expect(content(prompts: [prompt], status: busy, enabled: false) == .hidden)
        #expect(content(prompts: [prompt], status: busy, approvals: false) == .status(busy))
        #expect(content(status: busy, statusOn: false) == .hidden)
        #expect(content() == .hidden)
    }

    @Test func theWindowIsNoBiggerThanTheShape() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let busy = ClaudeCodeNotch.Content.status(.init(working: 1, finished: nil))
        let status = ClaudeCodeNotch.size(for: busy, notchWidth: 200, notchHeight: 37)
        #expect(status == CGSize(width: 200 + 2 * ClaudeCodeNotch.wing, height: 37), "beside the notch, not below")
        let frame = ClaudeCodeNotch.frame(for: status, screenFrame: screen)
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY == screen.maxY)
        #expect(frame.size == status)
    }

    /// The glyphs sit on the drawn body, not on the frame: the scooped shoulders and the rounded
    /// bottom corners pull the body in, so a glyph placed by the frame alone hangs outside it.
    @Test func glyphsSitInsideTheDrawnBody() {
        let notchWidth: CGFloat = 185
        let notchHeight: CGFloat = 32
        let prompt = ClaudeCodeActivity.PermissionPrompt(
            id: UUID(), sessionID: "s1", project: "VoxOs",
            summary: ClaudeCodeToolSummary(title: "Run command", detail: "ls"), toolUseID: nil, received: Date())
        let contents: [ClaudeCodeNotch.Content] = [
            .status(.init(working: 2, finished: nil)), .approval(prompt, waiting: 2),
        ]
        for content in contents {
            let size = ClaudeCodeNotch.size(for: content, notchWidth: notchWidth, notchHeight: notchHeight)
            let body = NotchShape(ClaudeCodeNotch.radii(for: content)).path(in: CGRect(origin: .zero, size: size))
            let inset = ClaudeCodeNotch.glyphInset(for: content)
            let glyph = ClaudeCodeNotch.glyphSize
            let y = (notchHeight - glyph) / 2
            let left = CGRect(x: inset, y: y, width: glyph, height: glyph)
            let right = CGRect(x: size.width - inset - glyph, y: y, width: glyph, height: glyph)
            let notch = CGRect(x: (size.width - notchWidth) / 2, y: 0, width: notchWidth, height: notchHeight)
            for rect in [left, right] {
                for corner in [
                    CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                ] {
                    #expect(body.contains(corner), "\(content): glyph corner \(corner) is outside the body")
                }
                #expect(!rect.intersects(notch), "\(content): glyph is under the hardware notch")
            }
        }
    }

    /// A CLI killed outright sends no SessionEnd, and the curl holding its request outlives it.
    @Test func aSessionWhoseCLIDiedLeavesAndItsRequestIsAnswered() {
        let activity = ClaudeCodeActivity()
        var started = Self.event("UserPromptSubmit", session: "dead")
        started.cliPID = 4242
        activity.receive(started)
        let (_, answers) = ask(activity, session: "dead")
        activity.receive(Self.event("UserPromptSubmit", session: "alive"))

        activity.expire(isAlive: { _ in true })
        #expect(activity.sessions.count == 2)

        activity.expire(isAlive: { $0 != 4242 })
        #expect(activity.sessions.keys.sorted() == ["alive"], "a session with no known pid is kept")
        #expect(answers.values == [.noDecision], "the orphaned curl is answered so it exits")
        #expect(activity.prompts.isEmpty)
    }

    @Test func theHookCommandReportsTheCLIProcess() {
        let command = ClaudeCodeHooks.command(for: .preToolUse, port: 47317)
        #expect(command.contains("\"\(ClaudeCodeBridge.pidHeader): $PPID\""), "double quotes, so the shell expands it")
        #expect(command.hasSuffix("|| true"), "a VoxOS that is not running never fails the hook")
    }

    /// Measured: "Yes" in the terminal starts the command at once as a child of the CLI, but
    /// PostToolUse only comes when it finishes. The card must leave when the command starts.
    @Test func bashAllowedInTheTerminalLeavesWhenItsCommandStarts() {
        let activity = ClaudeCodeActivity()
        var children: [ClaudeCodeChildProcess] = [
            .init(pid: 10, arguments: "/bin/sh -c /usr/bin/curl -sf -m 590 … || true")
        ]
        activity.childProcesses = { pid in pid == 777 ? children : [] }
        var started = Self.event("UserPromptSubmit")
        started.cliPID = 777
        activity.receive(started)
        let (_, answers) = ask(activity, input: ["command": "make test"])

        children.append(.init(pid: 11, arguments: "/bin/sh -c /usr/bin/curl -sf -m 4 … || true"))
        activity.noticeStartedCommands()
        #expect(answers.values.isEmpty, "another hook starting is not the command")

        children.append(
            .init(
                pid: 12,
                arguments: "/bin/zsh -c source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh && eval make test"))
        activity.noticeStartedCommands()
        #expect(answers.values == [.noDecision])
        #expect(activity.prompts.isEmpty)
    }

    @Test func aShellThatWasAlreadyRunningIsNotTheApprovedCommand() {
        let activity = ClaudeCodeActivity()
        let background = ClaudeCodeChildProcess(
            pid: 20, arguments: "/bin/zsh -c source /Users/me/.claude/shell-snapshots/s.sh && eval npm run dev")
        activity.childProcesses = { _ in [background] }
        var started = Self.event("UserPromptSubmit")
        started.cliPID = 777
        activity.receive(started)
        let (_, answers) = ask(activity)
        activity.noticeStartedCommands()
        #expect(answers.values.isEmpty, "a background shell from earlier says nothing about this request")
    }

    @Test func readsThisProcesssOwnArguments() {
        let arguments = ClaudeCodeProcesses.arguments(of: getpid())
        #expect(arguments?.isEmpty == false)
    }

    // MARK: First-launch offer

    @Test func theOfferIsMadeOnceAndOnlyWhereItHelps() {
        #expect(
            ClaudeCodeIntegration.shouldOffer(
                enabled: false, answered: false, onboarded: true, claudeCodeInstalled: true))
        #expect(
            !ClaudeCodeIntegration.shouldOffer(
                enabled: true, answered: false, onboarded: true, claudeCodeInstalled: true))
        #expect(
            !ClaudeCodeIntegration.shouldOffer(
                enabled: false, answered: true, onboarded: true, claudeCodeInstalled: true),
            "asked once, either answer is final")
        #expect(
            !ClaudeCodeIntegration.shouldOffer(
                enabled: false, answered: false, onboarded: false, claudeCodeInstalled: true),
            "not in the middle of onboarding")
        #expect(
            !ClaudeCodeIntegration.shouldOffer(
                enabled: false, answered: false, onboarded: true, claudeCodeInstalled: false),
            "no Claude Code, nothing to offer")
    }

    @Test func theOfferShowsWhileOffWaitsForTheRecorderAndGivesWayOnceOn() {
        func content(enabled: Bool, recorder: Bool = false) -> ClaudeCodeNotch.Content {
            ClaudeCodeNotch.content(
                prompts: [], status: .none, enabled: enabled, approvalsEnabled: true, statusEnabled: true,
                recorderVisible: recorder, offering: true)
        }
        #expect(content(enabled: false) == .offer)
        #expect(content(enabled: false, recorder: true) == .hidden)
        #expect(content(enabled: true) == .hidden, "turned on elsewhere, so nothing left to ask")
        let size = ClaudeCodeNotch.size(for: .offer, notchWidth: 185, notchHeight: 32)
        #expect(size.height == 32 + ClaudeCodeNotch.offerContentHeight)
        #expect(ClaudeCodeNotch.Content.offer.isCard)
    }

    /// Esc ends a turn without a Stop event; the idle_prompt notification that follows a minute
    /// later is what tells VoxOS the session stopped working.
    @Test func anIdlePromptEndsWorking() {
        let activity = ClaudeCodeActivity()
        activity.receive(Self.event("UserPromptSubmit"))
        #expect(activity.status().working == 1)
        activity.receive(
            ClaudeCodeHookEvent.decode(Self.payload("Notification", extra: ["notification_type": "permission_prompt"]))!
        )
        #expect(activity.status().working == 1, "a permission notification is not the end of the turn")
        activity.receive(
            ClaudeCodeHookEvent.decode(Self.payload("Notification", extra: ["notification_type": "idle_prompt"]))!)
        #expect(activity.status().isEmpty)
    }
}
