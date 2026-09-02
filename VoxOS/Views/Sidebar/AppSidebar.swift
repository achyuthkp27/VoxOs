import SwiftUI

/// Tahoe sidebar: no rail colour of its own — the blurred window ground shows through — and
/// the selected item is a floating glass capsule that morphs between rows.
struct AppSidebar: View {
    @Binding var selectedView: ViewType
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 0) {
            brand
                .padding(.top, 40)
                .padding(.bottom, 14)

            LiquidGlassContainer(spacing: 8) {
                VStack(spacing: 0) {
                    sidebarSection(ViewType.primaryItems)
                    Spacer(minLength: 16)
                    sidebarSection(ViewType.secondaryItems)
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .liquidGlass(cornerRadius: 24)
        .padding(.leading, 10)
        .padding(.vertical, 10)
        .onAppear {
            ViewType.assertSidebarItemsCoverAllCases()
        }
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSImage(named: "menuBarIcon") ?? NSImage())
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 17, height: 17)
            Text("VoxOS")
                .font(.app(size: 15, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(AppTheme.Text.primary)
        .padding(.horizontal, 22)
    }

    private func sidebarSection(_ items: [ViewType]) -> some View {
        VStack(spacing: 3) {
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

private extension ViewType {
    var title: LocalizedStringKey {
        switch self {
        case .transcribeAudio:
            return "Transcribe"
        default:
            return LocalizedStringKey(rawValue)
        }
    }

    static let primaryItems: [ViewType] = [.dashboard, .modes, .transcribeAudio, .history, .dictionary, .models, .audio]
    static let secondaryItems: [ViewType] = [.settings, .license]

    static func assertSidebarItemsCoverAllCases() {
        #if DEBUG
            let sidebarItems = primaryItems + secondaryItems
            assert(Set(sidebarItems) == Set(allCases) && sidebarItems.count == allCases.count)
        #endif
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
            HStack(spacing: 10) {
                Image(systemName: viewType.icon)
                    .font(.app(size: 14, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 20)

                Text(viewType.title)
                    .font(.app(size: 13.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : AppTheme.Text.primary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHovering, !isSelected { Capsule().fill(AppTheme.Surface.subtle) }
            }
            .contentShape(Capsule())
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

/// Selection sits inside the glass sidebar, so it is a plain tinted capsule (glass does not
/// nest); `matchedGeometryEffect` keeps the slide between rows.
private struct SelectionGlass: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        content.background {
            if isSelected {
                Capsule()
                    .fill(AppTheme.Accent.primary.opacity(0.85))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: AppTheme.Accent.primary.opacity(0.35), radius: 8, y: 2)
                    .matchedGeometryEffect(id: "sidebar-selection", in: namespace)
            }
        }
    }
}
