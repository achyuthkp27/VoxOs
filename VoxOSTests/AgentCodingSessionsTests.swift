import Foundation
import Testing

@testable import VoxOS

/// Session titles come from files the Claude Code CLI writes, so the parser must pick the user's
/// first real prompt and skip the machinery around it. Pure functions plus one temp file.
@Suite
struct AgentCodingSessionsTests {

    private let lines = [
        #"{"type":"last-prompt","sessionId":"abc"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]},"cwd":"/tmp/p"}"#,
        #"{"type":"user","message":{"role":"user","content":"<system-reminder>injected</system-reminder>"},"cwd":"/tmp/p"}"#,
        #"{"type":"user","message":{"role":"user","content":"  fix the login bug\nmore detail  "},"cwd":"/Users/me/app"}"#,
        #"{"type":"user","message":{"role":"user","content":"second prompt"},"cwd":"/Users/me/app"}"#,
    ]

    @Test func titleIsTheFirstRealPromptFirstLine() throws {
        let info = try #require(AgentCodingSessions.title(fromLines: lines))
        #expect(info.title == "fix the login bug")
        #expect(info.cwd == "/Users/me/app")
    }

    @Test func noUserPromptMeansNoTitle() {
        #expect(AgentCodingSessions.title(fromLines: [lines[0], lines[1], lines[2]]) == nil)
        #expect(AgentCodingSessions.title(fromLines: ["not json"]) == nil)
    }

    @Test func longPromptsAreClipped() throws {
        let long =
            #"{"type":"user","message":{"role":"user","content":""# + String(repeating: "a", count: 300) + #""}}"#
        let info = try #require(AgentCodingSessions.title(fromLines: [long]))
        #expect(info.title.count == 80)
    }

    @Test func projectFolderNamesDecodeToPaths() {
        #expect(AgentCodingSessions.decodeProjectFolder("-Users-me-app") == "/Users/me/app")
        #expect(AgentCodingSessions.decodeProjectFolder("plain") == "plain")
    }

    @Test func onlyTheHeadOfAFileIsRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString).jsonl")
        let body = (0..<2_000).map { _ in lines[3] }.joined(separator: "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let head = AgentCodingSessions.headLines(of: url, maxBytes: 4_000)
        #expect(head.count < 2_000 && head.count > 10)
        #expect(AgentCodingSessions.title(fromLines: head)?.title == "fix the login bug")
    }

    @Test @MainActor func resumeRefusesIdsThatAreNotSessionIds() {
        #expect(AgentCodingSessions.resume(id: "; rm -rf ~")["error"] != nil)
        #expect(AgentCodingSessions.resume(id: "")["error"] != nil)
    }
}
