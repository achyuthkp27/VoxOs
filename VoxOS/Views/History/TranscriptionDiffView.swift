import SwiftUI

/// Shows what AI enhancement changed, rather than leaving two blocks of prose to compare by eye.
///
/// Both texts are already stored on every enhanced transcription; until now nothing surfaced the
/// relationship between them, which made it hard to tell a good prompt from a bad one.
struct TranscriptionDiffView: View {
    let diff: TranscriptionTextDiff

    /// Removals read as "taken out", additions as "put in"; tinted backgrounds rather than
    /// coloured text so a changed word is findable while scanning without hurting contrast.
    private var removedTint: Color { AppTheme.Status.error.opacity(0.16) }
    private var addedTint: Color { AppTheme.Status.success.opacity(0.18) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            column(
                title: String(localized: "Transcribed"),
                runs: diff.original,
                tint: removedTint,
                icon: "waveform"
            )

            column(
                title: String(localized: "Enhanced"),
                runs: diff.enhanced,
                tint: addedTint,
                icon: "sparkles"
            )
        }
    }

    private func column(title: String, runs: [TranscriptionTextDiff.Run], tint: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.app(size: 10, weight: .medium))
                Text(title)
                    .font(.app(size: 10, weight: .medium))
            }
            .foregroundColor(AppTheme.Text.muted)

            highlighted(runs, tint: tint)
                .font(.app(size: 12))
                .foregroundColor(AppTheme.Text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(AppTheme.Surface.subtle)
                )
        }
    }

    /// Built as one `AttributedString` so the whole thing stays a single wrapping paragraph.
    /// `Text` concatenation cannot carry a background — `.background` does not return `Text` —
    /// and laying the runs out as separate views would break wrapping and lose the spacing the
    /// diff deliberately preserves.
    private func highlighted(_ runs: [TranscriptionTextDiff.Run], tint: Color) -> Text {
        var attributed = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.changed {
                piece.backgroundColor = tint
            }
            attributed.append(piece)
        }
        return Text(attributed)
    }
}
