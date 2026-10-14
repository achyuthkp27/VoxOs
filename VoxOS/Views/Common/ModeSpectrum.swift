import SwiftUI

/// The colour of a mode everywhere it appears (Modes, History, Dashboard): the default mode is
/// the white beam of raw voice, and the others take bands of the spectrum in list order.
enum ModeSpectrum {
    static func color(for mode: ModeConfig, in modes: [ModeConfig] = ModeManager.shared.configurations) -> Color {
        let others = modes.filter { !$0.isDefault }
        let index = others.firstIndex { $0.id == mode.id } ?? 0
        return AppTheme.Spectrum.color(forModeAt: index, count: others.count + 1, isDefault: mode.isDefault)
    }

    /// History stores the mode's name, not its id; an unknown or deleted mode gets the beam.
    static func color(forModeNamed name: String?, in modes: [ModeConfig] = ModeManager.shared.configurations) -> Color {
        guard let name, let mode = modes.first(where: { $0.name == name }) else { return AppTheme.Spectrum.beam }
        return color(for: mode, in: modes)
    }
}
