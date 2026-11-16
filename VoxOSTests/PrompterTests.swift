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

    @Test func theCardHangsUnderTheMenuBarInTheMiddle() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = PrompterWindow.frame(on: screen, topInset: 38, size: CGSize(width: 600, height: 160))
        #expect(frame.midX == 756)
        #expect(frame.maxY == CGFloat(982 - 38 - 6))
        #expect(PrompterWindow.height(fontSize: 24, lines: 4) > PrompterWindow.height(fontSize: 24, lines: 2))
    }
}
