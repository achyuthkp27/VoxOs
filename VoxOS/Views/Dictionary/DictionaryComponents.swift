import SwiftUI

/// The one input on each Dictionary tab: a quiet field set into the page with a plain Add
/// button, instead of a stock bordered field whose blue focus ring was the loudest thing on screen.
struct DictionaryComposer<Fields: View>: View {
    let canAdd: Bool
    let addTitle: LocalizedStringKey
    let onAdd: () -> Void
    @ViewBuilder let fields: () -> Fields

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(width: 16)

            fields()

            Button(action: onAdd) {
                Text(addTitle)
                    .font(.app(size: 12, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.Accent.primary)
            .controlSize(.small)
            .disabled(!canAdd)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.Surface.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.Border.card, lineWidth: 1)
        )
    }
}

/// A borderless text field for use inside `DictionaryComposer`.
struct DictionaryComposerField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt).foregroundColor(AppTheme.Text.secondary))
            .textFieldStyle(.plain)
            .font(.app(size: 14, weight: .regular))
            .labelsHidden()
            .onSubmit(onSubmit)
    }
}

/// What an empty tab is for, with real examples rather than a blank canvas.
struct DictionaryEmptyState: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let examples: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primary)
            Text(detail)
                .font(.app(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(examples, id: \.self) { example in
                    Text(example)
                        .font(.app(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Text.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .overlay(
                            Capsule().strokeBorder(
                                AppTheme.Border.control, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                }
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small, quiet header above a list: what it holds and how it is sorted.
struct DictionaryListHeader: View {
    let title: String
    let sortLabel: String
    let onToggleSort: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.app(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
            Button(action: onToggleSort) {
                HStack(spacing: 4) {
                    Text(sortLabel)
                    Image(systemName: "arrow.up.arrow.down")
                }
                .font(.app(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
            }
            .buttonStyle(.plain)
            .help("Change sort order")
        }
    }
}
