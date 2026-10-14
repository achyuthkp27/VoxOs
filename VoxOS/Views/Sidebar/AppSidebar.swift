import SwiftUI

/// Tahoe sidebar: no rail colour of its own — the blurred window ground shows through — and
/// the selected item is a floating glass capsule that morphs between rows.
struct AppSidebar: View {
    @Binding var selectedView: ViewType
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 0) {
            brand
                .padding(.top, 30)
                .padding(.bottom, 18)

            LiquidGlassContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 14) {
                    sidebarSection("Use", ViewType.useItems)
                    sidebarSection("Set up", ViewType.setupItems)
                    Spacer(minLength: 16)
                    sidebarSection(nil, ViewType.secondaryItems)
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .liquidGlass(cornerRadius: 24)
        .padding(.leading, 10)
        .padding(.vertical, 10)
        .onAppear {
            ViewType.assertSidebarItemsCoverAllCases()
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            Text("VoxOS")
                .font(.app(size: 17, weight: .semibold))
                .tracking(-0.2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(AppTheme.Text.primary)
        .padding(.horizontal, 18)
    }

    /// Grouped by what you do there: pages you use day to day, and pages you set VoxOS up in.
    private func sidebarSection(_ title: LocalizedStringKey?, _ items: [ViewType]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(.app(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.muted)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            ForEach(items) { viewType in
                SidebarItemButton(
                    viewType: viewType,
                    isSelected: selectedView == viewType,
                    namespace: selection
                ) {
                    withAnimation(.snappy(duration: 0.28)) { selectedView = viewType }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

extension ViewType {
    fileprivate var title: LocalizedStringKey {
        switch self {
        case .transcribeAudio:
            return "Transcribe"
        default:
            return LocalizedStringKey(rawValue)
        }
    }

    fileprivate static let useItems: [ViewType] = [.dashboard, .history, .transcribeAudio]
    fileprivate static let setupItems: [ViewType] = [.modes, .dictionary, .models, .audio]
    fileprivate static var primaryItems: [ViewType] { useItems + setupItems }
    fileprivate static let secondaryItems: [ViewType] = [.settings]
    /// Reachable by navigation but deliberately absent from the sidebar (personal build: no licensing).
    fileprivate static let hiddenItems: [ViewType] = [.license]

    fileprivate static func assertSidebarItemsCoverAllCases() {
        #if DEBUG
            let sidebarItems = primaryItems + secondaryItems + hiddenItems
            assert(Set(sidebarItems) == Set(allCases) && sidebarItems.count == allCases.count)
        #endif
    }

    fileprivate var icon: String {
        switch self {
        case .dashboard: return "house.fill"
        case .transcribeAudio: return "waveform"
        case .history: return "clock.fill"
        case .models: return "cpu.fill"
        case .modes: return "square.on.square"
        case .audio: return "mic.fill"
        case .dictionary: return "book.fill"
        case .settings: return "gearshape.fill"
        case .license: return "sparkles"
        }
    }
}

private struct SidebarItemButton: View {
    let viewType: ViewType
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: viewType.icon)
                    .font(.app(size: 13, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? AppTheme.Accent.primary : AppTheme.Text.secondary)
                    .frame(width: 18)

                Text(viewType.title)
                    .font(.app(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHovering, !isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppTheme.Surface.subtle)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .modifier(SelectionGlass(isSelected: isSelected, namespace: namespace))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .help(viewType.title)
        .accessibilityLabel(viewType.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

}

/// Selection sits inside the glass sidebar, so it is a plain tinted shape (glass does not nest);
/// `matchedGeometryEffect` keeps the slide between rows.
private struct SelectionGlass: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        content.background {
            if isSelected {
                // A quiet tint rather than a saturated, glowing capsule: the page is the subject,
                // the sidebar only says where you are.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.Accent.fill)
                    .matchedGeometryEffect(id: "sidebar-selection", in: namespace)
            }
        }
    }
}
