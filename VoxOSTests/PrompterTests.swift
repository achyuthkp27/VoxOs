import CoreGraphics
import Foundation
import Testing

@testable import VoxOS

@Suite
struct PrompterTests {

    private static let text = """
        Good morning everyone, and thank you for joining. [pause]

        Today I want to talk about three things: our launch, the numbers, and what comes next.
        """

    private static func heard(_ phrase: String) -> [String] {
        phrase.split(separator: " ").map { PrompterScript.normalize(String($0)) }
    }

    @Test func notesAreShownButNotListenedFor() {
        let script = PrompterScript(Self.text)
        #expect(script.words.contains { $0.text == "[pause]" && $0.isNote })
        #expect(!script.spokenWords.contains("pause"))
        #expect(script.paragraphCount == 2)
        #expect(script.spokenWords.first == "good")
    }

    @Test func aNoteCanSpanSeveralWords() {
        let script = PrompterScript("Hello [look at the camera] there")
        #expect(script.spokenWords == ["hello", "there"])
        #expect(script.words.filter(\.isNote).count == 4)
    }

    @Test func wordsAreComparedWithoutCaseOrPunctuation() {
        #expect(PrompterScript.normalize("Joining.") == "joining")
        #expect(PrompterScript.normalize("Café,") == "cafe")
        #expect(PrompterScript.normalize("21") == "twentyone")
        #expect(PrompterScript.normalize("3") == "three")
    }

    @Test func readingAloudMovesThePlaceOn() {
        let script = PrompterScript(Self.text).spokenWords
        let place = PrompterAligner.advance(from: 0, script: script, heard: Self.heard("good morning everyone"))
        #expect(place == 3)
    }

    @Test func anAdLibLeavesThePlaceAlone() {
        let script = PrompterScript(Self.text).spokenWords
        let place = PrompterAligner.advance(from: 3, script: script, heard: Self.heard("oh wow what a crowd today"))
        #expect(place == 3)
    }

    @Test func skippingASentenceIsFollowed() {
        let script = PrompterScript(Self.text).spokenWords
        // From the start straight to the second paragraph.
        let place = PrompterAligner.advance(
            from: 0, script: script, heard: Self.heard("i want to talk about three things"))
        #expect(script[place - 1] == "things")
    }

    @Test func goingBackNeedsAClearMatch() {
        let script = PrompterScript(Self.text).spokenWords
        let far = script.firstIndex(of: "next")! + 1
        // One word that also appears earlier does not pull the place back.
        #expect(PrompterAligner.advance(from: far, script: script, heard: ["thank"]) == far)
        // Saying the start again clearly does.
        let back = PrompterAligner.advance(
            from: far, script: script, heard: Self.heard("good morning everyone and thank"))
        #expect(back == 5)
    }

    @Test func aMisheardEndingStillMatches() {
        let script = PrompterScript(Self.text).spokenWords
        let place = PrompterAligner.advance(from: 0, script: script, heard: ["good", "mornings", "everyone"])
        #expect(place == 3)
        #expect(PrompterAligner.similar("numbers", "number"))
        #expect(!PrompterAligner.similar("cat", "car"))
    }

    @Test func aClickedNoteStartsAtTheNextSpokenWord() {
        let script = PrompterScript("one [beat] two")
        #expect(script.spokenPosition(ofWord: 1) == 1)
        #expect(script.wordIndex(atSpoken: 1) == 2)
        #expect(script.wordIndex(atSpoken: 5) == script.words.count)
    }

    @Test func theBandHangsFromTheTopEdgeInTheMiddle() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = PrompterWindow.frame(on: screen, size: CGSize(width: 380, height: 160))
        #expect(frame.midX == 756)
        #expect(frame.maxY == 982)
        #expect(
            PrompterWindow.height(fontSize: 24, lines: 4, notchHeight: 38)
                > PrompterWindow.height(fontSize: 24, lines: 2, notchHeight: 38))
        // The notch row comes on top of the text, not out of it.
        let withNotch = PrompterWindow.height(fontSize: 20, lines: 4, notchHeight: 38)
        let without = PrompterWindow.height(fontSize: 20, lines: 4, notchHeight: 0)
        #expect(withNotch - without == CGFloat(38))
    }

    @Test func theBandIsNeverNarrowerThanTheNotchNorWiderThanTheScreen() {
        let narrowest = PrompterWindow.width(100, notchWidth: 300, screenWidth: 1512)
        #expect(narrowest >= CGFloat(300) + PrompterWindow.shoulder * 2)
        #expect(PrompterWindow.width(2000, notchWidth: 185, screenWidth: 1000) == CGFloat(960))
        #expect(PrompterWindow.width(500, notchWidth: 185, screenWidth: 1512) == CGFloat(500))
    }

    @Test func aDraggedHeightSettlesOnTheNearestWholeLine() {
        for lines in PrompterWindow.linesRange {
            let height = PrompterWindow.height(fontSize: 20, lines: lines, notchHeight: 38)
            #expect(PrompterWindow.lines(forHeight: height + 4, fontSize: 20, notchHeight: 38) == lines)
        }
        #expect(PrompterWindow.lines(forHeight: 10, fontSize: 20, notchHeight: 38) == 2)
        #expect(PrompterWindow.lines(forHeight: 5000, fontSize: 20, notchHeight: 38) == 8)
    }

    @Test func theSteadyPaceKeepsTheFractionOfAWord() {
        var pacer = PrompterPacer()
        // 120 words a minute is two a second: twenty steps of a twentieth of a second.
        let words = (0..<20).reduce(0) { total, _ in total + pacer.step(seconds: 0.05, wordsPerMinute: 120) }
        #expect(words == 2)
        let none = pacer.step(seconds: 0, wordsPerMinute: 120)
        let stopped = pacer.step(seconds: 1, wordsPerMinute: 0)
        #expect(none == 0)
        #expect(stopped == 0)
    }

    @Test func speakingHoldsThroughTheGapsBetweenWords() {
        var gate = PrompterVoiceGate()
        let start = Date(timeIntervalSince1970: 0)
        let silent = gate.hear(level: 0, sensitivity: 0.5, at: start)
        let loud = gate.hear(level: 0.9, sensitivity: 0.5, at: start)
        let gap = gate.hear(level: 0, sensitivity: 0.5, at: start.addingTimeInterval(0.3))
        let after = gate.hear(level: 0, sensitivity: 0.5, at: start.addingTimeInterval(PrompterVoiceGate.hold + 0.1))
        #expect(!silent)
        #expect(loud)
        #expect(gap)
        #expect(!after)
        // More sensitive hears a quieter voice.
        #expect(PrompterVoiceGate.threshold(sensitivity: 1) < PrompterVoiceGate.threshold(sensitivity: 0))
    }

    @Test func theTextColourSurvivesItsSetting() {
        #expect(PrompterTextColor.rgb(hex: "") == nil)
        #expect(PrompterTextColor.rgb(hex: "#zzzzzz") == nil)
        let rgb = PrompterTextColor.rgb(hex: "#FF8000")
        #expect(rgb?.red == 1 && rgb?.blue == 0)
        #expect(PrompterTextColor.hex(PrompterTextColor.color(hex: "#FF8000")) == "#FF8000")
    }
}
