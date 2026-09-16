import Foundation
import Testing

@testable import VoxOS

/// The paste method decides how transcribed text reaches another app, and the legacy migration
/// runs on every launch. Getting it wrong silently changes how every dictation is delivered, so
/// these pin down the upgrade path and the fallbacks rather than the happy case alone.
@Suite
struct PasteMethodTests {

    /// An isolated defaults domain, so these never read or disturb the real preferences.
    private func makeDefaults() -> UserDefaults {
        let suite = "com.achyuthkp.voxos.tests.paste.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aFreshInstallUsesTheStandardMethod() {
        #expect(PasteMethod.current(in: makeDefaults()) == .standard)
    }

    @Test func anExplicitChoiceIsReadBack() {
        let defaults = makeDefaults()
        PasteMethod.setCurrent(.appleScript, in: defaults)
        #expect(PasteMethod.current(in: defaults) == .appleScript)

        PasteMethod.setCurrent(.standard, in: defaults)
        #expect(PasteMethod.current(in: defaults) == .standard)
    }

    @Test func theLegacyFlagIsHonouredBeforeAnyChoiceIsStored() {
        // Someone who turned on AppleScript pasting under the old boolean setting must keep it
        // after upgrading, or their paste behaviour changes under them without warning.
        let defaults = makeDefaults()
        defaults.set(true, forKey: PasteMethod.legacyAppleScriptPasteKey)
        #expect(PasteMethod.current(in: defaults) == .appleScript)
    }

    @Test func migrationCarriesTheLegacyFlagForward() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: PasteMethod.legacyAppleScriptPasteKey)

        PasteMethod.migrateLegacyUserDefaultIfNeeded(in: defaults)

        #expect(defaults.string(forKey: PasteMethod.userDefaultsKey) == PasteMethod.appleScript.rawValue)
        #expect(PasteMethod.current(in: defaults) == .appleScript)
    }

    @Test func migrationLeavesAnExistingChoiceAlone() {
        // The legacy flag is stale here. Re-running migration at every launch must not let it
        // overwrite the choice the user has since made.
        let defaults = makeDefaults()
        PasteMethod.setCurrent(.standard, in: defaults)
        defaults.set(true, forKey: PasteMethod.legacyAppleScriptPasteKey)

        PasteMethod.migrateLegacyUserDefaultIfNeeded(in: defaults)

        #expect(PasteMethod.current(in: defaults) == .standard)
    }

    @Test func migrationIsSafeToRunRepeatedly() {
        // It runs on every launch, so it has to be idempotent.
        let defaults = makeDefaults()
        defaults.set(true, forKey: PasteMethod.legacyAppleScriptPasteKey)

        for _ in 0..<5 {
            PasteMethod.migrateLegacyUserDefaultIfNeeded(in: defaults)
        }
        #expect(PasteMethod.current(in: defaults) == .appleScript)
    }

    @Test func setCurrentKeepsTheLegacyFlagInStep() {
        // Older builds and anything still reading the boolean must not see a stale value.
        let defaults = makeDefaults()

        PasteMethod.setCurrent(.appleScript, in: defaults)
        #expect(defaults.bool(forKey: PasteMethod.legacyAppleScriptPasteKey))

        PasteMethod.setCurrent(.standard, in: defaults)
        #expect(!defaults.bool(forKey: PasteMethod.legacyAppleScriptPasteKey))
    }

    @Test func anUnrecognisedStoredValueFallsBackRatherThanFailing() {
        // A downgrade, or a hand-edited plist, must not leave pasting broken.
        let defaults = makeDefaults()
        defaults.set("some-method-from-the-future", forKey: PasteMethod.userDefaultsKey)
        #expect(PasteMethod.current(in: defaults) == .standard)

        // ...and migration should repair it rather than leave the bad value in place.
        PasteMethod.migrateLegacyUserDefaultIfNeeded(in: defaults)
        #expect(PasteMethod.current(in: defaults) == .standard)
        #expect(PasteMethod(rawValue: defaults.string(forKey: PasteMethod.userDefaultsKey) ?? "") != nil)
    }

    @Test func everyCaseHasADistinctDisplayNameAndStableRawValue() {
        // Raw values are persisted, so renaming one silently resets a user's choice.
        #expect(PasteMethod.standard.rawValue == "default")
        #expect(PasteMethod.appleScript.rawValue == "appleScript")
        #expect(Set(PasteMethod.allCases.map(\.displayName)).count == PasteMethod.allCases.count)
    }
}
