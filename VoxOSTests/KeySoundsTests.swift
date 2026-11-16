import AVFoundation
import Carbon.HIToolbox
import Foundation
import Testing

@testable import VoxOS

@Suite
struct KeySoundsTests {

    private static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(channel[$1])) }
    }

    @Test(arguments: KeySoundSynth.Profile.allCases)
    func everySwitchHasEveryKeyAndStroke(_ profile: KeySoundSynth.Profile) {
        let bank = KeySoundSynth.makeBank(for: profile)
        for keyClass in KeySoundSynth.KeyClass.allCases {
            for stroke in KeySoundSynth.Stroke.allCases {
                let variants = bank[KeySoundSynth.SoundKey(keyClass: keyClass, stroke: stroke)] ?? []
                #expect(variants.count == KeySoundSynth.variantCount)
                for buffer in variants {
                    #expect(buffer.frameLength > 0)
                    // Audible, and never clipping.
                    let loudest = Self.peak(buffer)
                    #expect(loudest > 0.2 && loudest <= 1)
                }
            }
        }
    }

    @Test func aReleaseIsQuieterThanAPress() {
        let bank = KeySoundSynth.makeBank(for: .tactile)
        let down = bank[KeySoundSynth.SoundKey(keyClass: .standard, stroke: .down)]!.map(Self.peak)
        let up = bank[KeySoundSynth.SoundKey(keyClass: .standard, stroke: .up)]!.map(Self.peak)
        #expect(up.max()! < down.min()!)
    }

    @Test func variantsDifferFromOneAnother() {
        let variants = KeySoundSynth.makeBank(for: .creamy)[
            KeySoundSynth.SoundKey(keyClass: .standard, stroke: .down)]!
        let first = variants[0].floatChannelData![0]
        let second = variants[1].floatChannelData![0]
        let count = Int(min(variants[0].frameLength, variants[1].frameLength))
        let difference = (0..<count).reduce(Float(0)) { $0 + abs(first[$1] - second[$1]) }
        #expect(difference > 1)
    }

    @Test func theSameSeedMakesTheSameSound() {
        let one = KeySoundSynth.makeBank(for: .clicky, seed: 7)[
            KeySoundSynth.SoundKey(keyClass: .space, stroke: .down)]![0]
        let two = KeySoundSynth.makeBank(for: .clicky, seed: 7)[
            KeySoundSynth.SoundKey(keyClass: .space, stroke: .down)]![0]
        #expect(one.frameLength == two.frameLength)
        #expect(Self.peak(one) == Self.peak(two))
    }

    @Test func theTypewriterRingsItsBellOnReturn() {
        let bank = KeySoundSynth.makeBank(for: .typewriter)
        let returnKey = bank[KeySoundSynth.SoundKey(keyClass: .returnKey, stroke: .down)]![0]
        let letter = bank[KeySoundSynth.SoundKey(keyClass: .standard, stroke: .down)]![0]
        #expect(returnKey.frameLength > letter.frameLength * 3)
    }

    @Test func keysAreSortedIntoTheirKinds() {
        #expect(KeySoundKeys.keyClass(Int64(kVK_Space)) == .space)
        #expect(KeySoundKeys.keyClass(Int64(kVK_Return)) == .returnKey)
        #expect(KeySoundKeys.keyClass(Int64(kVK_Delete)) == .backspace)
        #expect(KeySoundKeys.keyClass(Int64(kVK_Shift)) == .modifier)
        #expect(KeySoundKeys.keyClass(Int64(kVK_RightCommand)) == .modifier)
        #expect(KeySoundKeys.keyClass(Int64(kVK_ANSI_K)) == .standard)
    }

    @Test func keysSoundFromWhereTheySit() {
        #expect(KeySoundKeys.pan(Int64(kVK_ANSI_A)) < -0.3)
        #expect(KeySoundKeys.pan(Int64(kVK_ANSI_L)) > 0.1)
        #expect(abs(KeySoundKeys.pan(Int64(kVK_Space))) < 0.01)
        #expect(KeySoundKeys.pan(Int64(kVK_Return)) > KeySoundKeys.pan(Int64(kVK_ANSI_L)))
        // Never further than the spread.
        #expect(abs(KeySoundKeys.pan(Int64(kVK_RightArrow))) <= 0.7)
    }

    @Test func settingsAreReadFromTheirKeys() {
        let suite = "KeySoundsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DefaultsKeys.keySoundsEnabled)
        defaults.set("thock", forKey: DefaultsKeys.keySoundsProfile)
        defaults.set(0.25, forKey: DefaultsKeys.keySoundsVolume)
        defaults.set(["com.example.game"], forKey: DefaultsKeys.keySoundsQuietApps)
        let settings = KeySounds.Settings.read(from: defaults)
        #expect(settings.enabled)
        #expect(settings.profile == .thock)
        #expect(settings.volume == 0.25)
        #expect(settings.quietApps == ["com.example.game"])
    }

    @Test func anUnknownSwitchFallsBackToTheFirst() {
        let suite = "KeySoundsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("gone", forKey: DefaultsKeys.keySoundsProfile)
        #expect(KeySounds.Settings.read(from: defaults).profile == .creamy)
    }
}
