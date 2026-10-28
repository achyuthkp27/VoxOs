import AppKit
import SwiftData
import SwiftUI

/// The app's navigation: a glass column that names every page under what it is for, or, when
/// collapsed, an icon rail that gives the page the width. The selected row is a quiet violet
/// tint that slides between rows.
struct AppSidebar: View {
    static let expandedWidth: CGFloat = 200
    static let collapsedWidth: CGFloat = 64
    private static let collapsedKey = "AppSidebarCollapsed"

    @Binding var selectedView: ViewType
    @AppStorage(Self.collapsedKey) private var isCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Namespace private var selection
    @Query private var vocabularyWords: [VocabularyWord]
    @Query private var wordReplacements: [WordReplacement]
    @ObservedObject private var modeManager = ModeManager.shared
    /// Counted, not fetched: History can hold thousands of records.
    @State private var historyCount: Int?

    /// Light counts beside the pages that hold lists, as native Mac sidebars show them.
    private func count(for viewType: ViewType) -> Int? {
        switch viewType {
        case .modes: return modeManager.configurations.count
        case .history: return historyCount
        case .dictionary: return vocabularyWords.count + wordReplacements.count
        default: return nil
        }
    }

    private func refreshHistoryCount() {
        historyCount = try? modelContext.fetchCount(FetchDescriptor<Transcription>())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                // Clears the traffic lights, which sit over the sidebar's top edge.
                .padding(.top, 34)
                .padding(.bottom, 18)

            LiquidGlassContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: isCollapsed ? 10 : 16) {
                    ForEach(NavigationSection.allCases) { section in
                        if section == .preferences {
                            Spacer(minLength: 12)
                        }
                        sectionView(section)
                    }
                }
            }

            SidebarProfileFooter(isCollapsed: isCollapsed)
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .frame(width: isCollapsed ? Self.collapsedWidth : Self.expandedWidth)
        .frame(maxHeight: .infinity)
        .liquidGlass(cornerRadius: 24)
        .padding(.leading, 10)
        .padding(.vertical, 10)
        .onAppear {
            ViewType.assertSidebarItemsCoverAllCases()
            refreshHistoryCount()
        }
        // Recount after any save, so a new dictation or a deleted one shows at once.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            refreshHistoryCount()
        }
    }

    @ViewBuilder
    private var header: some View {
        if isCollapsed {
            // No separate toggle button: the app icon collapses and expands the sidebar, the
            // one thing at its top a person reaches for in either state.
            Button(action: toggleCollapsed) {
                appIcon
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help(Text("Expand sidebar (⌃⌘S)"))
            .accessibilityLabel(Text("Expand sidebar"))
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 10) {
                Button(action: toggleCollapsed) {
                    appIcon
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .keyboardShortcut("s", modifiers: [.control, .command])
                .help(Text("Collapse sidebar (⌃⌘S)"))
                .accessibilityLabel(Text("Collapse sidebar"))

                Text(verbatim: "VoxOS")
                    .font(.app(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
    }

    private func toggleCollapsed() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { isCollapsed.toggle() }
    }

    @ViewBuilder
    private func sectionView(_ section: NavigationSection) -> some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: 2) {
            if isCollapsed {
                if section != .main {
                    Rectangle()
                        .fill(AppTheme.Border.card)
                        .frame(width: 20, height: 1)
                        .padding(.bottom, 8)
                }
            } else {
                Text(section.title)
                    .font(.appMono(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(section.items) { viewType in
                SidebarItemButton(
                    viewType: viewType,
                    isSelected: selectedView == viewType,
                    isCollapsed: isCollapsed,
                    count: count(for: viewType),
                    namespace: selection
                ) {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { selectedView = viewType }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
        .padding(.horizontal, isCollapsed ? 10 : 12)
    }
}

/// Grouped by what the page is for: everyday use, the engines behind it, and preferences.
enum NavigationSection: CaseIterable, Identifiable {
    case main
    case aiTools
    case preferences

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .main: return "Main"
        case .aiTools: return "AI tools"
        case .preferences: return "Preferences"
        }
    }

    var items: [ViewType] {
        switch self {
        case .main: return [.dashboard, .modes, .transcribeAudio, .history, .dictionary]
        case .aiTools: return [.models, .audio]
        case .preferences: return [.voiceAssistant, .notch, .settings]
        }
    }
}

extension ViewType {
    /// Every page the sidebar lists, in sidebar order (which is also ⌘1…⌘7 order).
    static var navigationItems: [ViewType] { NavigationSection.allCases.flatMap(\.items) }

    /// Reachable by navigation but deliberately absent from the sidebar (personal build: no licensing).
    fileprivate static let hiddenItems: [ViewType] = [.license]

    fileprivate static func assertSidebarItemsCoverAllCases() {
        #if DEBUG
            let sidebarItems = navigationItems + hiddenItems
            assert(Set(sidebarItems) == Set(allCases) && sidebarItems.count == allCases.count)
        #endif
    }

    var title: String {
        switch self {
        case .dashboard: return String(localized: "Dashboard")
        case .modes: return String(localized: "Modes")
        case .models: return String(localized: "AI Models")
        case .transcribeAudio: return String(localized: "Transcribe")
        case .history: return String(localized: "History")
        case .audio: return String(localized: "Audio")
        case .dictionary: return String(localized: "Dictionary")
        case .voiceAssistant: return String(localized: "Voice Assistant")
        case .notch: return String(localized: "Notch")
        case .settings: return String(localized: "Settings")
        case .license: return String(localized: "VoxOS Pro")
        }
    }

    /// Words people search for that are not in the page's name.
    var searchKeywords: [String] {
        switch self {
        case .dashboard: return ["home", "overview", "stats"]
        case .modes: return ["prompt", "agent", "rewrite"]
        case .models: return ["model", "provider", "llm", "speech", "whisper", "parakeet"]
        case .transcribeAudio: return ["file", "audio", "video", "import"]
        case .history: return ["transcript", "past", "recent"]
        case .audio: return ["microphone", "mic", "input", "sound"]
        case .dictionary: return ["word", "vocabulary", "replacement", "spelling"]
        case .voiceAssistant: return ["shortcut", "agent", "dictation", "mcp", "paste", "transcription"]
        case .notch: return ["notch home", "claude code", "music", "volume", "brightness", "shelf"]
        case .settings: return ["preferences", "general", "appearance", "backup"]
        case .license: return ["pro", "license"]
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "house.fill"
        case .transcribeAudio: return "waveform"
        case .history: return "clock.fill"
        case .models: return "cpu.fill"
        case .modes: return "square.on.square"
        case .audio: return "mic.fill"
        case .dictionary: return "book.fill"
        case .voiceAssistant: return "waveform.circle.fill"
        case .notch: return "rectangle.topthird.inset.filled"
        case .settings: return "gearshape.fill"
        case .license: return "sparkles"
        }
    }

    var navigationShortcut: KeyboardShortcut? {
        if self == .settings {
            return KeyboardShortcut(",", modifiers: .command)
        }
        let pages = NavigationSection.main.items + NavigationSection.aiTools.items
        guard let index = pages.firstIndex(of: self), index < 9 else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
    }

    var shortcutLabel: String? {
        navigationShortcut.map { "⌘\($0.key.character)" }
    }
}

private struct SidebarItemButton: View {
    let viewType: ViewType
    let isSelected: Bool
    let isCollapsed: Bool
    let count: Int?
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovering = false

    private var helpText: String {
        [viewType.title, viewType.shortcutLabel].compactMap { $0 }.joined(separator: "  ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: viewType.icon)
                    .font(.app(size: 13, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? AppTheme.Accent.primary : AppTheme.Text.secondary)
                    .frame(width: 18)

                if !isCollapsed {
                    Text(viewType.title)
                        .font(.app(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(AppTheme.Text.primary)
                        .lineLimit(1)
                        .fixedSize()

                    Spacer(minLength: 4)

                    // The count rests in the slot; the shortcut takes its place on hover or
                    // selection, when it is the more useful thing to know.
                    ZStack(alignment: .trailing) {
                        if let count, count > 0 {
                            Text(verbatim: "\(count)")
                                .font(.appMono(size: 10.5, weight: .medium))
                                .foregroundStyle(AppTheme.Text.muted)
                                .opacity(isSelected || isHovering ? 0 : 1)
                        }
                        if let shortcutLabel = viewType.shortcutLabel {
                            Text(verbatim: shortcutLabel)
                                .font(.appMono(size: 10.5, weight: .medium))
                                .foregroundStyle(AppTheme.Text.muted)
                                .opacity(isSelected || isHovering ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, isCollapsed ? 0 : 10)
            .frame(maxWidth: isCollapsed ? 44 : .infinity, alignment: isCollapsed ? .center : .leading)
            .frame(height: 30)
            .background {
                if isHovering, !isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppTheme.Surface.subtle)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .modifier(SelectionTint(isSelected: isSelected, namespace: namespace))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .keyboardShortcut(viewType.navigationShortcut)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(helpText)
        .accessibilityLabel(viewType.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Selection sits inside the glass sidebar, so it is a plain tinted shape (glass does not nest);
/// `matchedGeometryEffect` keeps the slide between rows.
private struct SelectionTint: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        content.background {
            if isSelected {
                // A quiet tint rather than a saturated, glowing capsule: the page is the subject,
                // the sidebar only says where you are.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.Accent.fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(AppTheme.Selection.border, lineWidth: 1)
                    )
                    .matchedGeometryEffect(id: "sidebar-selection", in: namespace)
            }
        }
    }
}

/// Who is using VoxOS and whether it is ready to listen, with the speech model it will use.
private struct SidebarProfileFooter: View {
    let isCollapsed: Bool
    @AppStorage(DefaultsKeys.dashboardDisplayName) private var storedDisplayName = ""
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager

    private var displayName: String {
        let stored = storedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? SystemAccountName.firstName : stored
    }

    private var initial: String {
        displayName.first.map { String($0).uppercased() } ?? "V"
    }

    private var status: String {
        guard let model = transcriptionModelManager.currentTranscriptionModel else {
            return String(localized: "Ready")
        }
        return String(localized: "Ready · \(model.displayName)")
    }

    var body: some View {
        VStack(spacing: 10) {
            Rectangle()
                .fill(AppTheme.Border.subtle)
                .frame(height: 1)
                .padding(.horizontal, isCollapsed ? 14 : 12)

            HStack(spacing: 10) {
                avatar
                if !isCollapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: displayName)
                            .font(.app(size: 12.5, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.primary)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(AppTheme.Status.success)
                                .frame(width: 5, height: 5)
                            Text(verbatim: status)
                                .font(.appMono(size: 10, weight: .regular))
                                .foregroundStyle(AppTheme.Text.secondary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .padding(.horizontal, isCollapsed ? 0 : 16)
        }
        .help("\(displayName) · \(status)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName), \(status)")
    }

    private var avatar: some View {
        Text(verbatim: initial)
            .font(.app(size: 12, weight: .semibold))
            .foregroundStyle(AppTheme.Accent.primary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(AppTheme.Accent.fill))
            .overlay(Circle().strokeBorder(AppTheme.Accent.border, lineWidth: 1))
    }
}

/// The macOS account's first name, the same fallback the Dashboard greeting uses when no
/// display name has been set.
private enum SystemAccountName {
    static let firstName: String = {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullName.isEmpty {
            if let given = PersonNameComponentsFormatter().personNameComponents(from: fullName)?.givenName,
                !given.isEmpty
            {
                return given
            }
            if let first = fullName.split(whereSeparator: \.isWhitespace).first {
                return String(first)
            }
        }
        let shortName = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return shortName.split(separator: ".").first.map(String.init) ?? "VoxOS"
    }()
}
