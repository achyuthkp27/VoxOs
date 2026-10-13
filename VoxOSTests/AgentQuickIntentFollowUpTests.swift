import Foundation
import Testing

@testable import VoxOS

/// "Did you mean …?" is only useful if the suggestions are real and "yes" does what it says. The
/// failure these guard against: offering unrelated apps, then handing the user's "yes" to a model
/// that never saw the offer and answers with an invented how-to.
@Suite(.serialized)
struct AgentQuickIntentFollowUpTests {

    private let macApps = [
        "Stocks", "App Store", "Audio MIDI Setup", "Safari", "Calendar", "Notes", "Google Chrome", "Claude", "Cursor",
        "System Settings", "Terminal", "Photos", "Spotify",
    ]

    // MARK: Suggestions

    @Test func slackIsNotSuggestedAnythingUnrelated() {
        // The reported case: nothing here is close to "slack".
        #expect(AgentQuickIntents.suggestions(for: "slack", in: macApps).isEmpty)
    }

    @Test func nearMissesStillGetTheRightName() {
        #expect(AgentQuickIntents.suggestions(for: "slak", in: macApps + ["Slack"]) == ["Slack"])
        #expect(AgentQuickIntents.suggestions(for: "claud", in: macApps) == ["Claude"])
        #expect(AgentQuickIntents.suggestions(for: "spotfy", in: macApps) == ["Spotify"])
        #expect(AgentQuickIntents.suggestions(for: "chrom", in: macApps) == ["Google Chrome"])
    }

    @Test func aWrongFirstLetterStillMatchesWhenOtherwiseClose() {
        #expect(AgentQuickIntents.suggestions(for: "black", in: ["Slack", "Stocks"]) == ["Slack"])
    }

    @Test func shortNamesOnlyTolerateOneSlip() {
        #expect(AgentQuickIntents.suggestions(for: "crew", in: macApps).isEmpty)
        #expect(AgentQuickIntents.suggestions(for: "note", in: macApps) == ["Notes"])
    }

    @Test func neverMoreThanThreeSuggestions() {
        let many = ["Slack", "Slick", "Slock", "Black", "Flack"]
        #expect(AgentQuickIntents.suggestions(for: "slack", in: many).count <= 3)
    }

    @Test func aNotFoundWithNoCloseNameSaysSoAndOffersNothing() {
        guard
            case .notFound(let query, let suggestions) = AgentQuickIntents.appRequest(
                in: "open slack", installed: macApps)
        else {
            Issue.record("expected a local not-found answer")
            return
        }
        #expect(query == "slack")
        #expect(suggestions.isEmpty)
    }

    // MARK: Follow-up

    @Test func yesToASingleOfferOpensIt() {
        #expect(AgentQuickIntents.followUp(reply: "yes", suggestions: ["Slack"]) == .open("Slack"))
        #expect(AgentQuickIntents.followUp(reply: "Yeah.", suggestions: ["Slack"]) == .open("Slack"))
        #expect(AgentQuickIntents.followUp(reply: "  Sure! ", suggestions: ["Slack"]) == .open("Slack"))
        #expect(AgentQuickIntents.followUp(reply: "yes please", suggestions: ["Slack"]) == .open("Slack"))
    }

    @Test func yesToSeveralOffersAsksWhichInsteadOfGuessing() {
        let result = AgentQuickIntents.followUp(reply: "yes", suggestions: ["Stocks", "App Store", "Audio MIDI Setup"])
        #expect(
            result
                == .ask(
                    question: "Which one: Stocks, App Store or Audio MIDI Setup?",
                    suggestions: ["Stocks", "App Store", "Audio MIDI Setup"]))
    }

    @Test func namingOneOfTheOffersOpensIt() {
        let offers = ["Stocks", "App Store", "Audio MIDI Setup"]
        #expect(AgentQuickIntents.followUp(reply: "App Store", suggestions: offers) == .open("App Store"))
        #expect(AgentQuickIntents.followUp(reply: "open stocks", suggestions: offers) == .open("Stocks"))
        #expect(
            AgentQuickIntents.followUp(reply: "the audio midi setup", suggestions: offers) == .open("Audio MIDI Setup"))
    }

    @Test func anythingElseGoesToTheModel() {
        let offers = ["Slack"]
        for reply in [
            "no", "nope", "never mind", "what's the weather", "open chrome instead", "yes but also open safari today",
            "how do I install it", "",
        ] {
            #expect(AgentQuickIntents.followUp(reply: reply, suggestions: offers) == nil, "\"\(reply)\"")
        }
    }

    @Test func selfGuardKnowsItsOwnWindowsAndNothingElse() {
        let frames = [CGRect(x: 100, y: 0, width: 200, height: 50)]
        #expect(AgentSelfGuard.contains(CGPoint(x: 150, y: 10), in: frames))
        #expect(!AgentSelfGuard.contains(CGPoint(x: 10, y: 10), in: frames))
        #expect(!AgentSelfGuard.pointIsInOwnWindow(CGPoint(x: -99_999, y: -99_999)), "nothing lives off-screen")
        #expect(AgentSelfGuard.ownPID == ProcessInfo.processInfo.processIdentifier)
    }

    @Test func withNothingOfferedAYesIsNotInterpreted() {
        #expect(AgentQuickIntents.followUp(reply: "yes", suggestions: []) == nil)
    }

    @Test func theOfferIsForgottenOnceTaken() {
        AgentQuickIntents.setPendingSuggestions(["Slack"])
        #expect(AgentQuickIntents.takePendingSuggestions() == ["Slack"])
        #expect(AgentQuickIntents.takePendingSuggestions().isEmpty, "a later 'yes' must not open it")
    }

    @Test func aNewRequestClearsAStaleOffer() async {
        AgentQuickIntents.setPendingSuggestions(["Slack"])
        _ = await AgentQuickIntents.handle("what time is it")
        #expect(AgentQuickIntents.takePendingSuggestions().isEmpty)
    }

    @Test func askingWhichKeepsTheOffersForTheAnswer() async {
        let reply = await AgentQuickIntents.perform(.ask(question: "Which one: A or B?", suggestions: ["A", "B"]))
        #expect(reply == "Which one: A or B?")
        #expect(AgentQuickIntents.takePendingSuggestions() == ["A", "B"])
    }
}
