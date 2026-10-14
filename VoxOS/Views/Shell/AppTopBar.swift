import SwiftUI

/// The slim bar above every page: jump to any page by typing its name (⌘K), and a reminder of
/// the key that starts dictation.
struct AppTopBar: View {
    static let height: CGFloat = 44

    @Binding var selectedView: ViewType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @State private var query = ""
    @State private var highlightedIndex = 0
    @State private var dictationKey = AppTopBar.currentDictationKey()

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var matches: [ViewType] {
        guard !trimmedQuery.isEmpty else { return [] }
        return ViewType.navigationItems.filter { viewType in
            viewType.title.localizedStandardContains(trimmedQuery)
                || viewType.searchKeywords.contains { $0.localizedStandardContains(trimmedQuery) }
        }
    }

    private var showsResults: Bool { isSearchFocused && !trimmedQuery.isEmpty }

    var body: some View {
        HStack(spacing: 12) {
            searchField
            if let dictationKey {
                dictationKeyChip(dictationKey)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: Self.height)
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { _ in
            dictationKey = Self.currentDictationKey()
        }
        .onChange(of: query) { _, _ in highlightedIndex = 0 }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.app(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.Text.muted)
                .accessibilityHidden(true)

            TextField("Search pages…", text: $query)
                .textFieldStyle(.plain)
                .font(.app(size: 13))
                .foregroundStyle(AppTheme.Text.primary)
                .focused($isSearchFocused)
                .onSubmit(openHighlighted)
                .onKeyPress(.downArrow) {
                    guard !matches.isEmpty else { return .ignored }
                    highlightedIndex = min(highlightedIndex + 1, matches.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !matches.isEmpty else { return .ignored }
                    highlightedIndex = max(highlightedIndex - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismissSearch()
                    return .handled
                }
                .accessibilityLabel("Search pages")

            Button {
                isSearchFocused = true
            } label: {
                Text(verbatim: "⌘K")
                    .font(.appMono(size: 10.5, weight: .medium))
                    .foregroundStyle(AppTheme.Text.muted)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(AppTheme.Border.control, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .keyboardShortcut("k", modifiers: .command)
            .help("Search pages (⌘K)")
            .opacity(isSearchFocused ? 0 : 1)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppTheme.Surface.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSearchFocused ? AppTheme.Accent.border : AppTheme.Border.control, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            if showsResults {
                results
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: 36)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsResults)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 2) {
            if matches.isEmpty {
                Text("No page matches “\(trimmedQuery)”")
                    .font(.app(size: 12.5))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
            } else {
                ForEach(Array(matches.enumerated()), id: \.element) { index, viewType in
                    resultRow(viewType, isHighlighted: index == highlightedIndex)
                        .onHover { if $0 { highlightedIndex = index } }
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.Surface.window)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.Border.card, lineWidth: 1)
        )
    }

    private func resultRow(_ viewType: ViewType, isHighlighted: Bool) -> some View {
        Button {
            open(viewType)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: viewType.icon)
                    .font(.app(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isHighlighted ? AppTheme.Accent.primary : AppTheme.Text.secondary)
                    .frame(width: 18)
                Text(verbatim: viewType.title)
                    .font(.app(size: 13, weight: isHighlighted ? .semibold : .regular))
                    .foregroundStyle(AppTheme.Text.primary)
                Spacer(minLength: 8)
                if let shortcutLabel = viewType.shortcutLabel {
                    Text(verbatim: shortcutLabel)
                        .font(.appMono(size: 10.5, weight: .medium))
                        .foregroundStyle(AppTheme.Text.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppTheme.Accent.fill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("Open \(viewType.title)")
    }

    private func dictationKeyChip(_ key: String) -> some View {
        Text(verbatim: key)
            .font(.appMono(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.Text.primary)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(minWidth: 30, minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.Surface.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AppTheme.Border.control, lineWidth: 1)
            )
            .help("Hold \(key) to dictate")
            .accessibilityLabel("Hold \(key) to dictate")
    }

    private func openHighlighted() {
        guard matches.indices.contains(highlightedIndex) else { return }
        open(matches[highlightedIndex])
    }

    private func open(_ viewType: ViewType) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { selectedView = viewType }
        dismissSearch()
    }

    private func dismissSearch() {
        query = ""
        isSearchFocused = false
    }

    private static func currentDictationKey() -> String? {
        ShortcutStore.shortcut(for: .primaryRecording)?.displayString
    }
}
