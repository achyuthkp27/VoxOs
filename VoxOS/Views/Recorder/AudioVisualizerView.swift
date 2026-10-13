import SwiftUI

struct AudioVisualizer: View {
    let audioMeterProvider: () -> AudioMeter
    let color: Color
    let isActive: Bool

    private let barCount: Int
    private let barWidth: CGFloat
    private let barSpacing: CGFloat
    private let minHeight: CGFloat
    private let maxHeight: CGFloat

    private let phases: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        audioMeterProvider: @escaping () -> AudioMeter, color: Color, isActive: Bool,
        barCount: Int = 15, barWidth: CGFloat = 3, barSpacing: CGFloat = 2,
        minHeight: CGFloat = 4, maxHeight: CGFloat = 28
    ) {
        self.audioMeterProvider = audioMeterProvider
        self.color = color
        self.isActive = isActive
        self.barCount = barCount
        self.barWidth = barWidth
        self.barSpacing = barSpacing
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.phases = (0..<barCount).map { Double($0) * 0.9 }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.016)) { context in
            let audioMeter = audioMeterProvider()

            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(color.opacity(0.92))
                        .frame(
                            width: barWidth,
                            height: barHeight(
                                for: index,
                                at: context.date,
                                audioMeter: audioMeter
                            )
                        )
                        // A soft bloom reads as light, not paint, on the black band.
                        .shadow(color: color.opacity(0.5), radius: 2.5)
                }
            }
        }
    }

    private func barHeight(for index: Int, at date: Date, audioMeter: AudioMeter) -> CGFloat {
        guard isActive else { return minHeight }

        let time = date.timeIntervalSince1970
        let amplitude = max(0, min(1, pow(audioMeter.averagePower, 0.7)))  // boosted for visibility
        // A slow swell with a high floor, so the bars breathe with the voice instead of
        // flickering; the centre bars carry the most height, like the resting glyph.
        // With Reduce Motion the bars follow the level only, with no swell.
        let wave = reduceMotion ? 1.0 : 0.65 + 0.35 * (sin(time * 5 + phases[index]) * 0.5 + 0.5)
        let weights = NotchDesign.barWeights
        let weight = Double(weights[index % weights.count] / (weights.max() ?? 1))

        return max(minHeight, minHeight + CGFloat(amplitude * wave * weight) * (maxHeight - minHeight))
    }
}
