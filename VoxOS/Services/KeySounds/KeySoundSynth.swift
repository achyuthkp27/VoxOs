import AVFoundation
import Foundation

/// The sounds Key Sounds plays, made in code rather than recorded: each press is a short burst of
/// filtered noise (the keycap striking) and a few decaying resonances (the plate, the case and the
/// switch housing), with a second, brighter strike before it for a clicky switch and a rattle for
/// the stabilised keys. Every sound comes in several variants made with slightly different pitch
/// and loudness, so a run of the same key never sounds like one sample played again.
enum KeySoundSynth {
    static let sampleRate: Double = 48_000
    /// Variants made of each key and stroke; one is picked at random per press.
    static let variantCount = 6

    /// A switch, by the sound it makes.
    enum Profile: String, CaseIterable, Identifiable {
        case creamy
        case tactile
        case clicky
        case thock
        case typewriter
        case laptop

        var id: String { rawValue }

        var title: String {
            switch self {
            case .creamy: return String(localized: "Creamy Linear")
            case .tactile: return String(localized: "Tactile Bump")
            case .clicky: return String(localized: "Crisp Clicky")
            case .thock: return String(localized: "Deep Thock")
            case .typewriter: return String(localized: "Typewriter")
            case .laptop: return String(localized: "Soft Laptop")
            }
        }

        var detail: String {
            switch self {
            case .creamy: return String(localized: "Smooth and muted, like lubed linear switches.")
            case .tactile: return String(localized: "A soft bump before a rounded bottom-out.")
            case .clicky: return String(localized: "A bright click on every press and release.")
            case .thock: return String(localized: "Low and heavy, like a thick case with foam.")
            case .typewriter: return String(localized: "Typebars striking paper, with a bell on Return.")
            case .laptop: return String(localized: "Quiet scissor keys, for late nights.")
            }
        }
    }

    /// Keys that sound different from the letters.
    enum KeyClass: CaseIterable, Hashable {
        case standard
        case space
        case returnKey
        case backspace
        case modifier
    }

    enum Stroke: CaseIterable, Hashable {
        case down
        case up
    }

    struct SoundKey: Hashable {
        let keyClass: KeyClass
        let stroke: Stroke
    }

    /// One resonance: frequency in Hz, amplitude, and the time in seconds it takes to fall to 1/e.
    struct Mode {
        var frequency: Double
        var amplitude: Double
        var decay: Double
    }

    /// One strike: when it starts, its noise burst, and its resonances.
    struct Strike {
        var offset: Double
        var gain: Double
        var noiseCenter: Double
        var noiseWidth: Double
        var noiseDecay: Double
        var noiseLevel: Double
        var modes: [Mode]
    }

    /// The sound's strikes and how long it lasts.
    struct Recipe {
        var strikes: [Strike]
        var duration: Double
        var room: Double
    }

    // MARK: Making the buffers

    /// Every variant of every key and stroke of `profile`.
    static func makeBank(for profile: Profile, seed: UInt64 = 0x5EED) -> [SoundKey: [AVAudioPCMBuffer]] {
        var rng = SplitMix(seed: seed ^ profile.rawValue.stableHash)
        var bank: [SoundKey: [AVAudioPCMBuffer]] = [:]
        for keyClass in KeyClass.allCases {
            for stroke in Stroke.allCases {
                let key = SoundKey(keyClass: keyClass, stroke: stroke)
                let peak = loudness(keyClass, stroke)
                bank[key] = (0..<variantCount).compactMap { _ in
                    let samples = render(recipe(profile, keyClass, stroke, rng: &rng), rng: &rng, peak: peak)
                    return buffer(from: samples)
                }
            }
        }
        return bank
    }

    /// How loud a key and stroke peak: a release is about half a press, a modifier a little under
    /// a letter, and the space bar the loudest.
    static func loudness(_ keyClass: KeyClass, _ stroke: Stroke) -> Float {
        let press: Float
        switch keyClass {
        case .space: press = 0.85
        case .returnKey, .backspace: press = 0.8
        case .standard: press = 0.72
        case .modifier: press = 0.55
        }
        return stroke == .up ? press * 0.5 : press
    }

    static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        return buffer
    }

    /// The samples of one sound, peaking at `peak`.
    static func render(_ recipe: Recipe, rng: inout SplitMix, peak: Float = 0.8) -> [Float] {
        let count = Int(recipe.duration * sampleRate)
        var out = [Double](repeating: 0, count: count)
        for strike in recipe.strikes {
            add(strike, to: &out, rng: &rng)
        }
        addRoom(recipe.room, to: &out)
        // A few samples of fade at each end, so no sound starts or stops with a click of its own.
        let fade = min(48, count / 4)
        for index in 0..<fade {
            let gain = Double(index) / Double(fade)
            out[count - 1 - index] *= gain
        }
        let loudest = out.reduce(0) { max($0, abs($1)) }
        guard loudest > 0 else { return [Float](repeating: 0, count: count) }
        let scale = Double(peak) / loudest
        return out.map { Float($0 * scale) }
    }

    private static func add(_ strike: Strike, to out: inout [Double], rng: inout SplitMix) {
        let start = Int(strike.offset * sampleRate)
        guard start < out.count else { return }
        let attack = 0.0004 * sampleRate
        // Band-passed noise for the strike itself.
        var filter = Biquad.bandPass(center: strike.noiseCenter, q: strike.noiseCenter / strike.noiseWidth)
        let noiseLength = min(out.count - start, Int(strike.noiseDecay * 8 * sampleRate))
        for index in 0..<noiseLength {
            let t = Double(index) / sampleRate
            let envelope = min(1, Double(index) / attack) * exp(-t / strike.noiseDecay)
            out[start + index] += filter.process(rng.nextSigned()) * envelope * strike.noiseLevel * strike.gain
        }
        // The resonances it sets ringing.
        for mode in strike.modes {
            let phase = rng.nextUnit() * 2 * .pi
            let length = min(out.count - start, Int(mode.decay * 7 * sampleRate))
            let step = 2 * Double.pi * mode.frequency / sampleRate
            for index in 0..<length {
                let t = Double(index) / sampleRate
                let envelope = min(1, Double(index) / attack) * exp(-t / mode.decay)
                out[start + index] += sin(phase + step * Double(index)) * envelope * mode.amplitude * strike.gain
            }
        }
    }

    /// A small room: three soft, darker echoes a few milliseconds behind, which give the sound a
    /// desk to sit on instead of playing inside the head.
    private static func addRoom(_ amount: Double, to out: inout [Double]) {
        guard amount > 0 else { return }
        let dry = out
        let taps: [(delay: Double, gain: Double)] = [(0.0071, 0.5), (0.0113, 0.32), (0.0179, 0.2)]
        for tap in taps {
            var lowPass = Biquad.lowPass(cutoff: 3_200, q: 0.7)
            let delay = Int(tap.delay * sampleRate)
            for index in delay..<out.count {
                out[index] += lowPass.process(dry[index - delay]) * tap.gain * amount
            }
        }
    }

    // MARK: Recipes

    /// The strikes of one key and stroke on a switch, with a little random detune and loudness so
    /// each variant differs.
    static func recipe(_ profile: Profile, _ keyClass: KeyClass, _ stroke: Stroke, rng: inout SplitMix) -> Recipe {
        let detune = 1 + (rng.nextUnit() - 0.5) * 0.09
        let level = 1 + (rng.nextUnit() - 0.5) * 0.2
        // Bigger keys are longer, lower and carry a stabiliser.
        let size: Double
        switch keyClass {
        case .space: size = 0.62
        case .returnKey, .backspace: size = 0.8
        case .modifier: size = 0.9
        case .standard: size = 1
        }
        let base = voice(profile)
        var strikes: [Strike] = []
        let pitch = detune * size

        if stroke == .down {
            if profile == .clicky {
                // The click jacket snaps before the stem bottoms out.
                strikes.append(click(at: 0, pitch: detune, gain: 0.85 * level))
            }
            if profile == .tactile {
                // The bump: a faint tick as the leg passes it.
                strikes.append(click(at: 0, pitch: detune * 0.7, gain: 0.18 * level))
            }
            let bottom = (profile == .clicky ? 0.011 : profile == .tactile ? 0.008 : 0.0) + rng.nextUnit() * 0.0015
            strikes.append(base.strike(at: bottom, pitch: pitch, gain: level))
            if keyClass != .standard, keyClass != .modifier {
                strikes.append(contentsOf: rattle(after: bottom, pitch: pitch, profile: profile, rng: &rng))
            }
            if profile == .typewriter, keyClass == .returnKey {
                strikes.append(bell(at: 0.06, pitch: detune))
            }
        } else {
            // Coming back up is quieter and higher: the stem hitting the top of the housing.
            if profile == .clicky {
                strikes.append(click(at: 0, pitch: detune * 1.1, gain: 0.5 * level))
            }
            var up = base.strike(at: 0.002, pitch: pitch * 1.35, gain: level * base.upLevel)
            up.modes = up.modes.map { Mode(frequency: $0.frequency, amplitude: $0.amplitude, decay: $0.decay * 0.6) }
            strikes.append(up)
        }
        let length = (keyClass == .space ? 0.2 : 0.14) + (profile == .typewriter && keyClass == .returnKey ? 0.6 : 0)
        return Recipe(strikes: strikes, duration: length, room: base.room)
    }

    /// The character of a switch: where its strike sits and which resonances it rings.
    struct Voice {
        var noiseCenter: Double
        var noiseWidth: Double
        var noiseDecay: Double
        var noiseLevel: Double
        var modes: [Mode]
        var upLevel: Double
        var room: Double

        func strike(at offset: Double, pitch: Double, gain: Double) -> Strike {
            Strike(
                offset: offset, gain: gain, noiseCenter: noiseCenter * pitch, noiseWidth: noiseWidth * pitch,
                noiseDecay: noiseDecay, noiseLevel: noiseLevel,
                modes: modes.map { Mode(frequency: $0.frequency * pitch, amplitude: $0.amplitude, decay: $0.decay) })
        }
    }

    static func voice(_ profile: Profile) -> Voice {
        switch profile {
        case .creamy:
            return Voice(
                noiseCenter: 1_900, noiseWidth: 1_800, noiseDecay: 0.0035, noiseLevel: 0.9,
                modes: [
                    Mode(frequency: 420, amplitude: 0.55, decay: 0.012),
                    Mode(frequency: 1_150, amplitude: 0.35, decay: 0.008),
                    Mode(frequency: 2_600, amplitude: 0.12, decay: 0.004),
                ], upLevel: 0.35, room: 0.35)
        case .tactile:
            return Voice(
                noiseCenter: 2_300, noiseWidth: 2_000, noiseDecay: 0.003, noiseLevel: 1,
                modes: [
                    Mode(frequency: 520, amplitude: 0.45, decay: 0.01),
                    Mode(frequency: 1_500, amplitude: 0.4, decay: 0.007),
                    Mode(frequency: 3_300, amplitude: 0.15, decay: 0.003),
                ], upLevel: 0.4, room: 0.3)
        case .clicky:
            return Voice(
                noiseCenter: 2_800, noiseWidth: 2_400, noiseDecay: 0.0028, noiseLevel: 0.9,
                modes: [
                    Mode(frequency: 600, amplitude: 0.35, decay: 0.009),
                    Mode(frequency: 1_800, amplitude: 0.35, decay: 0.006),
                    Mode(frequency: 3_900, amplitude: 0.2, decay: 0.003),
                ], upLevel: 0.45, room: 0.3)
        case .thock:
            return Voice(
                noiseCenter: 1_200, noiseWidth: 1_100, noiseDecay: 0.0045, noiseLevel: 0.8,
                modes: [
                    Mode(frequency: 230, amplitude: 0.8, decay: 0.02),
                    Mode(frequency: 640, amplitude: 0.4, decay: 0.012),
                    Mode(frequency: 1_700, amplitude: 0.12, decay: 0.005),
                ], upLevel: 0.3, room: 0.45)
        case .typewriter:
            return Voice(
                noiseCenter: 3_200, noiseWidth: 3_000, noiseDecay: 0.006, noiseLevel: 1.1,
                modes: [
                    Mode(frequency: 310, amplitude: 0.45, decay: 0.03),
                    Mode(frequency: 1_250, amplitude: 0.35, decay: 0.015),
                    Mode(frequency: 2_950, amplitude: 0.3, decay: 0.009),
                    Mode(frequency: 5_100, amplitude: 0.12, decay: 0.004),
                ], upLevel: 0.25, room: 0.55)
        case .laptop:
            return Voice(
                noiseCenter: 3_600, noiseWidth: 3_000, noiseDecay: 0.0018, noiseLevel: 0.7,
                modes: [
                    Mode(frequency: 900, amplitude: 0.25, decay: 0.005),
                    Mode(frequency: 2_400, amplitude: 0.2, decay: 0.003),
                ], upLevel: 0.5, room: 0.15)
        }
    }

    /// A short, bright snap: a click jacket, or the tactile leg passing its bump.
    static func click(at offset: Double, pitch: Double, gain: Double) -> Strike {
        Strike(
            offset: offset, gain: gain, noiseCenter: 5_200 * pitch, noiseWidth: 3_000 * pitch, noiseDecay: 0.0012,
            noiseLevel: 1.2,
            modes: [
                Mode(frequency: 4_300 * pitch, amplitude: 0.4, decay: 0.0018),
                Mode(frequency: 6_800 * pitch, amplitude: 0.2, decay: 0.001),
            ])
    }

    /// The stabiliser wire settling: two or three small metallic ticks after the bottom-out.
    static func rattle(after offset: Double, pitch: Double, profile: Profile, rng: inout SplitMix) -> [Strike] {
        let level = profile == .laptop ? 0.08 : 0.2
        return (0..<2).map { index in
            Strike(
                offset: offset + 0.004 + Double(index) * (0.004 + rng.nextUnit() * 0.003),
                gain: level / Double(index + 1), noiseCenter: 2_700 * pitch, noiseWidth: 1_200, noiseDecay: 0.0015,
                noiseLevel: 0.6, modes: [Mode(frequency: 2_250 * pitch, amplitude: 0.3, decay: 0.006)])
        }
    }

    /// The carriage-return bell.
    static func bell(at offset: Double, pitch: Double) -> Strike {
        Strike(
            offset: offset, gain: 0.55, noiseCenter: 4_000, noiseWidth: 2_000, noiseDecay: 0.001, noiseLevel: 0.2,
            modes: [
                Mode(frequency: 2_093 * pitch, amplitude: 0.6, decay: 0.18),
                Mode(frequency: 5_440 * pitch, amplitude: 0.25, decay: 0.08),
                Mode(frequency: 8_120 * pitch, amplitude: 0.1, decay: 0.04),
            ])
    }
}

// MARK: - Small DSP helpers

/// A two-pole filter (RBJ cookbook), run one sample at a time.
struct Biquad {
    private var b0 = 0.0
    private var b1 = 0.0
    private var b2 = 0.0
    private var a1 = 0.0
    private var a2 = 0.0
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    static func bandPass(center: Double, q: Double, sampleRate: Double = KeySoundSynth.sampleRate) -> Biquad {
        let w = 2 * Double.pi * min(center, sampleRate * 0.45) / sampleRate
        let alpha = sin(w) / (2 * max(q, 0.1))
        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = alpha / a0
        filter.b1 = 0
        filter.b2 = -alpha / a0
        filter.a1 = -2 * cos(w) / a0
        filter.a2 = (1 - alpha) / a0
        return filter
    }

    static func lowPass(cutoff: Double, q: Double, sampleRate: Double = KeySoundSynth.sampleRate) -> Biquad {
        let w = 2 * Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = (1 - cos(w)) / 2 / a0
        filter.b1 = (1 - cos(w)) / a0
        filter.b2 = (1 - cos(w)) / 2 / a0
        filter.a1 = -2 * cos(w) / a0
        filter.a2 = (1 - alpha) / a0
        return filter
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}

/// A small, seedable random source, so the same seed makes the same sounds (and tests can check
/// them) while variants still differ from one another.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// In 0..<1.
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// In -1..<1.
    mutating func nextSigned() -> Double { nextUnit() * 2 - 1 }
}

extension String {
    /// A hash that stays the same from one launch to the next (`hashValue` does not): FNV-1a.
    var stableHash: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
