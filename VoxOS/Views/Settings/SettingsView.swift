import SwiftUI

/// Which page of settings: the voice assistant's, the notch's, the app switcher's, or the rest.
enum SettingsScope: Equatable {
    case voice
    case notch
    case appSwitcher
    case general
}

/// The sidebar's settings pages. Each is its own view, so a page holds and watches only what it
/// shows rather than every setting in the app.
struct SettingsView: View {
    var scope: SettingsScope = .general

    var body: some View {
        switch scope {
        case .voice: VoiceSettingsPage()
        case .notch: NotchSettingsPage()
        case .appSwitcher: AppSwitcherSettingsPage()
        case .general: GeneralSettingsPage()
        }
    }
}

/// A settings page's frame: the search field, a note when nothing on the page matches, then the
/// page's sections.
struct SettingsForm<Content: View>: View {
    @Binding var query: String
    var hasMatches: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Section { searchField }

            if !hasMatches {
                Section {
                    Text("No settings match your search").foregroundStyle(.secondary)
                }
            }

            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("", text: $query, prompt: Text("Search settings"))
                .textFieldStyle(.plain)
                .labelsHidden()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
    }
}

extension Text {
    /// A settings caption or footer: the app's caption font in the secondary color.
    func settingsCaption() -> some View {
        font(.app(.caption)).foregroundStyle(.secondary)
    }
}
