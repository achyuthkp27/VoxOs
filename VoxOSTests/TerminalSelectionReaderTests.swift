import Testing

@testable import VoxOS

struct TerminalSelectionReaderTests {
    @Test func selectionBodyFollowsTheKindHeader() {
        let output = "Kind: terminal\n\nmake this sentence better\n"
        #expect(TerminalSelectionReader.parseCmuxSelection(output) == "make this sentence better")
    }

    @Test func multiLineSelectionIsKeptIntact() {
        let output = "Kind: terminal\n\nfirst line\nsecond line\n"
        #expect(TerminalSelectionReader.parseCmuxSelection(output) == "first line\nsecond line")
    }

    @Test func noSelectionReadsAsNil() {
        #expect(TerminalSelectionReader.parseCmuxSelection("Kind: terminal\n\nHas selection: false\n") == nil)
        #expect(TerminalSelectionReader.parseCmuxSelection("") == nil)
    }
}
