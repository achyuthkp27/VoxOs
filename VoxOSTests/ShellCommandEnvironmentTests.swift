import Foundation
import Testing

@testable import VoxOS

/// CLI providers and custom commands only work when the command is on PATH, and a GUI app's
/// own PATH is bare. These pin down how the discovered PATHs are combined.
@Suite
struct ShellCommandEnvironmentTests {

    @Test func interactiveShellEntriesComeFirst() {
        let merged = ShellCommandEnvironment.mergedPATH(
            discovered: ["/Users/me/.local/bin:/usr/bin", "/opt/homebrew/bin:/usr/bin", "/usr/bin:/bin"],
            knownDirectories: [])
        #expect(merged == "/Users/me/.local/bin:/usr/bin:/opt/homebrew/bin:/bin")
    }

    @Test func aFolderOnlyTheInteractiveShellAddsIsKept() {
        // ~/.local/bin added only in .zshrc: the login shell alone never sees it.
        let merged = ShellCommandEnvironment.mergedPATH(
            discovered: [nil, "/usr/bin:/bin"], knownDirectories: ["/Users/me/.local/bin"])
        #expect(merged.split(separator: ":").contains("/Users/me/.local/bin"))
    }

    @Test func knownFoldersAreAddedOnceAfterDiscoveredOnes() {
        let merged = ShellCommandEnvironment.mergedPATH(
            discovered: ["/opt/homebrew/bin:/usr/bin"], knownDirectories: ["/usr/bin", "/Users/me/.bun/bin"])
        #expect(merged == "/opt/homebrew/bin:/usr/bin:/Users/me/.bun/bin")
    }

    @Test func emptyEntriesAndFailedDiscoveriesAreIgnored() {
        let merged = ShellCommandEnvironment.mergedPATH(
            discovered: [nil, "", "::/usr/bin::", nil], knownDirectories: [])
        #expect(merged == "/usr/bin")
    }

    @Test func resultAlwaysHasTheSystemFolders() {
        let path = ShellCommandEnvironment.preferredPATH(fallback: nil)
        for folder in ["/usr/bin", "/bin"] {
            #expect(path.split(separator: ":").contains(Substring(folder)), "\(folder) missing")
        }
    }
}
