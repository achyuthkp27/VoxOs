import Accelerate
import Foundation

/// Turns the audio the Mac is playing into a handful of bar heights, so the notch's music bars
/// move with the song instead of a canned animation.
///
/// Pure and single-threaded: feed it mono samples, read `levels`. Tested with tones: a sine at a
/// band's frequency must light that band and leave the others low.
struct SpectrumAnalyzer {
    /// Band edges in Hz: bass, low-mid, mid, presence, air.
    static let bandEdges: [Float] = [40, 160, 500, 1_600, 5_000, 14_000]
    static let fftSize = 1024
    /// The quietest level that still shows; anything below reads as zero.
    static let floorDecibels: Float = -64
    /// Bars jump up at once and fall back gently, the way a meter is read.
    static let release: Float = 0.82

    let sampleRate: Float
    private(set) var levels: [Float]
    private var pending: [Float] = []
    private let window: [Float]
    private let setup: vDSP.FFT<DSPSplitComplex>?

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        levels = Array(repeating: 0, count: Self.bandEdges.count - 1)
        window = vDSP.window(
            ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
        setup = vDSP.FFT(log2n: vDSP_Length(log2(Float(Self.fftSize))), radix: .radix2, ofType: DSPSplitComplex.self)
        pending.reserveCapacity(Self.fftSize * 2)
    }

    /// Adds samples; every full block of `fftSize` updates `levels`.
    mutating func feed(_ samples: UnsafeBufferPointer<Float>) {
        pending.append(contentsOf: samples)
        while pending.count >= Self.fftSize {
            analyze(Array(pending.prefix(Self.fftSize)))
            pending.removeFirst(Self.fftSize)
        }
    }

    mutating func feed(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { feed($0) }
    }

    /// Silence: let the bars fall instead of freezing where they were.
    mutating func decay() {
        levels = levels.map { $0 * Self.release }
    }

    private mutating func analyze(_ block: [Float]) {
        guard let setup else { return }
        let half = Self.fftSize / 2
        let windowed = vDSP.multiply(block, window)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                setup.forward(input: split, output: &split)
                vDSP.absolute(split, result: &magnitudes)
            }
        }

        let binWidth = sampleRate / Float(Self.fftSize)
        for band in 0..<levels.count {
            let low = max(1, Int(Self.bandEdges[band] / binWidth))
            let high = min(half - 1, max(low + 1, Int(Self.bandEdges[band + 1] / binWidth)))
            guard low < high else { continue }
            // The loudest bin in the band: an average drowns a single note in the empty bins
            // around it.
            let peak = magnitudes[low..<high].max() ?? 0
            // vDSP's forward FFT scales by 2, and the Hann window halves the amplitude: a
            // full-scale sine comes out near fftSize / 2.
            let amplitude = peak / Float(Self.fftSize / 2)
            let decibels = 20 * log10(max(amplitude, 1e-7))
            let target = max(0, min(1, (decibels - Self.floorDecibels) / -Self.floorDecibels))
            levels[band] = target > levels[band] ? target : max(target, levels[band] * Self.release)
        }
    }
}
