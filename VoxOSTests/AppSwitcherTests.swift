import Foundation
import Testing

@testable import VoxOS

/// The app switcher: which app a letter reaches, and which keys it takes.
@Suite
struct AppSwitcherTests {
    private let mail = AppSwitcher.App(id: "com.apple.mail", name: "Mail")
    private let music = AppSwitcher.App(id: "com.apple.Music", name: "Music")
    private let terminal = AppSwitcher.App(id: "com.apple.Terminal", name: "Terminal")
    private let calculator = "com.apple.calculator"

    @Test func aLetterIsTheFirstOfTheName() {
        #expect(AppSwitcher.letter(of: "Xcode") == "x")
        #expect(AppSwitcher.letter(of: "  Éclair") == "e", "accents and spaces dropped")
        #expect(AppSwitcher.letter(of: "1Password") == nil)
        #expect(AppSwitcher.letter(of: "") == nil)
    }

    @Test func aLetterBringsTheAppForward() {
        let action = AppSwitcher.action(
            for: "t", frontmost: mail.id, running: [mail, terminal], assignments: [:], recent: [])
        #expect(action == .activate(terminal.id))
    }

    @Test func theSameLetterHidesTheOnlyApp() {
        let action = AppSwitcher.action(
            for: "t", frontmost: terminal.id, running: [mail, terminal], assignments: [:], recent: [])
        #expect(action == .hide(terminal.id))
    }

    @Test func theSameLetterMovesOnWhenAppsShareIt() {
        let running = [mail, music, terminal]
        #expect(
            AppSwitcher.action(for: "m", frontmost: mail.id, running: running, assignments: [:], recent: [])
                == .activate(music.id))
        #expect(
            AppSwitcher.action(for: "m", frontmost: music.id, running: running, assignments: [:], recent: [])
                == .activate(mail.id), "and wraps around")
    }

    @Test func fromElsewhereTheAppUsedLastComesFirst() {
        let action = AppSwitcher.action(
            for: "m", frontmost: terminal.id, running: [mail, music, terminal], assignments: [:],
            recent: [terminal.id, music.id, mail.id])
        #expect(action == .activate(music.id))
    }

    @Test func aGivenLetterLaunchesItsApp() {
        let action = AppSwitcher.action(
            for: "c", frontmost: mail.id, running: [mail], assignments: ["c": calculator], recent: [])
        #expect(action == .launch(calculator))
    }

    @Test func anAppGivenAnotherLetterAnswersOnlyToThat() {
        let assignments = ["k": terminal.id]
        #expect(
            AppSwitcher.action(
                for: "t", frontmost: mail.id, running: [mail, terminal], assignments: assignments, recent: [])
                == .nothing)
        #expect(
            AppSwitcher.action(
                for: "k", frontmost: mail.id, running: [mail, terminal], assignments: assignments, recent: [])
                == .activate(terminal.id))
    }

    @Test func anAppHoldsOneLetter() {
        let next = AppSwitcher.assigning("c", to: calculator, in: ["x": calculator, "m": mail.id])
        #expect(next == ["c": calculator, "m": mail.id])
    }

    @Test func onlyRightCommandWithABareLetterIsTaken() {
        let letters: [Int64: String] = [0: "a"]
        let right = LetterKeyTap.rightCommand
        #expect(LetterKeyTap.letter(code: 0, flags: right, shiftOrControl: false, letters: letters) == "a")
        #expect(
            LetterKeyTap.letter(
                code: 0, flags: right | LetterKeyTap.rightOption, shiftOrControl: false, letters: letters)
                == "a", "Right Option gives the letter")
        #expect(
            LetterKeyTap.letter(code: 0, flags: LetterKeyTap.leftCommand, shiftOrControl: false, letters: letters)
                == nil)
        #expect(
            LetterKeyTap.letter(
                code: 0, flags: right | LetterKeyTap.leftCommand, shiftOrControl: false, letters: letters)
                == nil, "both Commands is a shortcut")
        #expect(LetterKeyTap.letter(code: 0, flags: right, shiftOrControl: true, letters: letters) == nil)
        #expect(
            LetterKeyTap.letter(code: 18, flags: right, shiftOrControl: false, letters: letters) == nil, "not a letter")
    }

    @Test func anAddedAppTakesItsOwnLetterWhenFree() {
        #expect(AppSwitcher.freeLetter(preferring: "c", in: [:]) == "c")
        #expect(AppSwitcher.freeLetter(preferring: "c", in: ["c": "x", "a": "y"]) == "b", "else the first free")
        #expect(AppSwitcher.freeLetter(preferring: nil, in: [:]) == "a")
        let full = Dictionary(uniqueKeysWithValues: AppSwitcher.alphabet.map { ($0, $0) })
        #expect(AppSwitcher.freeLetter(preferring: "c", in: full) == nil)
    }

    @Test func rightOptionCanBeTheKeyInstead() {
        let keys = AppSwitcher.Trigger.rightOption.keys
        let letters: [Int64: String] = [0: "a"]
        #expect(
            LetterKeyTap.letter(
                code: 0, flags: LetterKeyTap.rightOption, shiftOrControl: false, letters: letters, keys: keys) == "a")
        #expect(
            LetterKeyTap.letter(
                code: 0, flags: LetterKeyTap.rightCommand, shiftOrControl: false, letters: letters, keys: keys) == nil)
        #expect(
            LetterKeyTap.letter(
                code: 0, flags: LetterKeyTap.rightOption | LetterKeyTap.leftOption, shiftOrControl: false,
                letters: letters, keys: keys) == nil, "both Options is typing")
    }
}
