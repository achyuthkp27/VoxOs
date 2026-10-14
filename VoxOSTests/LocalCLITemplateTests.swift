import Foundation
import Testing

@testable import VoxOS

/// The Claude template trades Claude Code's start-up extras for speed; these keep the parts
/// that make it work at all from being reordered away.
@Suite
struct LocalCLITemplateTests {

    @Test func claudeTemplateKeepsThePromptBeforeTheVariadicToolsFlag() {
        let command = LocalCLITemplate.claude.commandTemplate
        guard let prompt = command.range(of: "\"$VOXOS_FULL_PROMPT\""), let tools = command.range(of: "--tools")
        else {
            Issue.record("template lost the prompt or the tools flag: \(command)")
            return
        }
        #expect(prompt.upperBound <= tools.lowerBound, "--tools takes every argument after it as a tool name")
        #expect(command.hasSuffix("--tools \"\""))
    }

    @Test func claudeTemplateSkipsTheSlowStartUp() {
        let command = LocalCLITemplate.claude.commandTemplate
        for flag in ["--model haiku", "--strict-mcp-config", "--setting-sources \"\"", "--no-session-persistence"] {
            #expect(command.contains(flag), "\(flag) missing")
        }
    }

    @Test func theOldClaudeTemplateIsUpgradedButEditedCommandsAreNot() {
        #expect(
            LocalCLIService.upgradedTemplates["claude -p \"$VOXOS_FULL_PROMPT\""]
                == LocalCLITemplate.claude.commandTemplate)
        #expect(LocalCLIService.upgradedTemplates["claude -p \"$VOXOS_FULL_PROMPT\" --model opus"] == nil)
    }

    // MARK: Warm Claude

    @Test func onlyTheBuiltInClaudeTemplateRunsWarm() {
        #expect(LocalCLIWarmClaude.isEligible(command: LocalCLITemplate.claude.commandTemplate))
        #expect(!LocalCLIWarmClaude.isEligible(command: "claude -p \"$VOXOS_FULL_PROMPT\" --model opus"))
        #expect(!LocalCLIWarmClaude.isEligible(command: LocalCLITemplate.codex.commandTemplate))
    }

    @Test func warmCommandUsesTheTemplatesFlagsInStreamForm() {
        let warm = LocalCLIWarmClaude.streamingCommand
        #expect(warm.hasPrefix("exec claude -p "), "exec makes the process Claude itself, so it ends with its stdin")
        #expect(warm.contains("--input-format stream-json") && warm.contains("--output-format stream-json"))
        #expect(warm.hasSuffix("--tools \"\""))
        for flag in ["--model haiku", "--strict-mcp-config", "--setting-sources \"\"", "--no-session-persistence"] {
            #expect(warm.contains(flag), "\(flag) missing")
        }
    }

    @Test func requestIsOneStreamJSONUserLine() throws {
        let line = try #require(LocalCLIWarmClaude.userMessageLine("say \"hi\"\nnow"))
        #expect(line.hasSuffix("\n"))
        #expect(line.dropLast().contains("\n") == false, "one request must be exactly one line")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let message = try #require(object["message"] as? [String: Any])
        #expect(object["type"] as? String == "user")
        #expect(message["content"] as? String == "say \"hi\"\nnow")
    }

    @Test func onlyTheResultEventAnswers() {
        #expect(LocalCLIWarmClaude.result(fromLine: #"{"type":"system","subtype":"init"}"#) == nil)
        #expect(LocalCLIWarmClaude.result(fromLine: "not json") == nil)
        let ok = LocalCLIWarmClaude.result(fromLine: #"{"type":"result","is_error":false,"result":" Hello. \n"}"#)
        #expect((try? ok?.get()) == "Hello.")
        let failed = LocalCLIWarmClaude.result(fromLine: #"{"type":"result","is_error":true,"result":"Not logged in"}"#)
        #expect((try? failed?.get()) == nil)
        #expect(failed != nil)
    }

    @Test func spareIsWantedOnlyWhileLocalCLIIsChosen() {
        let groq = AIModelChoice(provider: .groq, model: nil)
        let cli = AIModelChoice(provider: .localCLI, model: nil)
        #expect(!LocalCLIWarmClaude.isLocalCLIInUse(main: nil, fallback: nil, modes: []))
        #expect(!LocalCLIWarmClaude.isLocalCLIInUse(main: groq, fallback: groq, modes: []))
        #expect(LocalCLIWarmClaude.isLocalCLIInUse(main: cli, fallback: nil, modes: []))
        #expect(LocalCLIWarmClaude.isLocalCLIInUse(main: groq, fallback: cli, modes: []))
    }
}
