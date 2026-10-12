import Foundation
import Testing

@testable import VoxOS

/// Closing the panel hides the reply, so the costly mistakes are closing one the user needed to
/// read (an error, a question, a result) or one they had already started answering. These pin
/// down that only a run made of successful launches ever closes itself.
@Suite(.serialized)
struct AgentAutoCloseTests {

    private func fresh() { AgentAutoClose.beginRun() }

    @Test func quickOpenClosesThePanel() {
        fresh()
        AgentAutoClose.recordQuickLaunch()
        #expect(AgentAutoClose.consume())
    }

    @Test func aSuccessfulOpenToolClosesThePanel() {
        fresh()
        AgentAutoClose.record(tool: "open_app", result: ["result": "opened"])
        #expect(AgentAutoClose.consume())
    }

    @Test func severalLaunchesStillClose() {
        fresh()
        AgentAutoClose.record(tool: "open_app", result: ["result": "ok"])
        AgentAutoClose.record(tool: "open_url", result: ["result": "ok"])
        #expect(AgentAutoClose.consume())
    }

    @Test func waitingBetweenLaunchesIsAllowed() {
        fresh()
        AgentAutoClose.record(tool: "open_app", result: ["result": "ok"])
        AgentAutoClose.record(tool: "wait", result: ["result": "waited"])
        #expect(AgentAutoClose.consume())
    }

    @Test func waitingAloneDoesNotCount() {
        fresh()
        AgentAutoClose.record(tool: "wait", result: ["result": "waited"])
        #expect(!AgentAutoClose.consume(), "nothing was launched")
    }

    @Test func aRunWithNoToolsNeverCloses() {
        fresh()
        #expect(!AgentAutoClose.consume(), "a plain answer is for reading")
    }

    @Test func aFailedLaunchStaysOpenSoTheErrorIsSeen() {
        fresh()
        AgentAutoClose.record(tool: "open_app", result: ["error": "app not found"])
        #expect(!AgentAutoClose.consume())
    }

    @Test func anyOtherActionKeepsThePanelOpen() {
        for tool in [
            "click_element", "read_screen", "type_text", "run_shell", "reminders_add", "gmail_search", "slack_send",
        ] {
            fresh()
            AgentAutoClose.record(tool: "open_app", result: ["result": "ok"])
            AgentAutoClose.record(tool: tool, result: ["result": "ok"])
            #expect(!AgentAutoClose.consume(), "\(tool) after an open must keep the panel up")
        }
    }

    @Test func aConfirmationOrQuestionKeepsThePanelOpen() {
        fresh()
        AgentAutoClose.record(tool: "open_url", result: ["confirm_required": "Open this?"])
        #expect(!AgentAutoClose.consume())
        fresh()
        AgentAutoClose.record(tool: "open_app", result: ["question": "Which one?"])
        #expect(!AgentAutoClose.consume())
    }

    @Test func aFailureAfterASuccessStillKeepsThePanelOpen() {
        fresh()
        AgentAutoClose.record(tool: "open_app", result: ["result": "ok"])
        AgentAutoClose.record(tool: "open_url", result: ["error": "bad url"])
        #expect(!AgentAutoClose.consume())
    }

    @Test func consumingClearsTheRecord() {
        fresh()
        AgentAutoClose.recordQuickLaunch()
        #expect(AgentAutoClose.consume())
        #expect(!AgentAutoClose.consume(), "the next reply must not inherit this run")
    }

    @Test func aNewRunForgetsThePreviousOne() {
        fresh()
        AgentAutoClose.record(tool: "click_element", result: ["result": "ok"])
        fresh()
        AgentAutoClose.recordQuickLaunch()
        #expect(AgentAutoClose.consume(), "a disqualified run must not poison the next request")
    }

    @Test func backgroundTasksNeverTouchTheRecord() async {
        fresh()
        await AgentRunScope.$isBackground.withValue(true) {
            AgentAutoClose.record(tool: "click_element", result: ["result": "ok"])
            AgentAutoClose.recordQuickLaunch()
        }
        #expect(!AgentAutoClose.consume(), "a detached task has no panel and must not arm or block one")
    }

    // MARK: Dismiss decision

    @Test func dismissesOnlyWhenEverythingStillHolds() {
        #expect(
            AgentAutoClose.shouldDismiss(armed: true, settingEnabled: true, recorderIdle: true, sessionUnchanged: true))
        #expect(
            !AgentAutoClose.shouldDismiss(
                armed: false, settingEnabled: true, recorderIdle: true, sessionUnchanged: true))
        #expect(
            !AgentAutoClose.shouldDismiss(
                armed: true, settingEnabled: false, recorderIdle: true, sessionUnchanged: true))
        #expect(
            !AgentAutoClose.shouldDismiss(
                armed: true, settingEnabled: true, recorderIdle: false, sessionUnchanged: true),
            "the user started talking again")
        #expect(
            !AgentAutoClose.shouldDismiss(
                armed: true, settingEnabled: true, recorderIdle: true, sessionUnchanged: false),
            "the reply was replaced")
    }

    @Test func onByDefaultAndRegistered() {
        #expect(AgentAutoClose.delay > 0.5 && AgentAutoClose.delay < 3, "readable but not stuck")
        #expect(AgentAutoClose.launchTools.contains("open_app"))
        #expect(!AgentAutoClose.launchTools.contains("click_element"))
    }
}
