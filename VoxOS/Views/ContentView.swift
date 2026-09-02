import OSLog
import SwiftUI

enum ViewType: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case modes = "Modes"
    case models = "AI Models"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case audio = "Audio"
    case dictionary = "Dictionary"
    case settings = "Settings"
    case license = "VoxOS Pro"

    var id: String { rawValue }
}

final class MainWindowNavigation: ObservableObject {
    static let shared = MainWindowNavigation()

    @Published var selectedView: ViewType = .dashboard

    private init() {}

    func navigate(to destination: String) {
        guard let viewType = ViewType(rawValue: destination) else {
            return
        }

        navigate(to: viewType)
    }

    func navigate(to destination: ViewType) {
        selectedView = destination
    }
}

struct ContentView: View {
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "ContentView")
    private static let detailBackgroundTintOpacity = 0.50
    @EnvironmentObject private var navigation: MainWindowNavigation

    var body: some View {
        HStack(spacing: 6) {
            AppSidebar(selectedView: $navigation.selectedView)

            detailContent
        }
        .frame(width: AppWindowLayout.width)
        .frame(minHeight: AppWindowLayout.minimumHeight)
        // Liquid Glass reads the wallpaper and the system appearance; nothing is forced.
        .glassWindowBackground()
        // Forms and lists drop their opaque ground so the glass shows through everywhere.
        .scrollContentBackground(.hidden)
        .onAppear {
            logger.notice("ContentView appeared")
        }
        .onDisappear {
            logger.notice("ContentView disappeared")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDestination)) { notification in
            if let destination = notification.userInfo?["destination"] as? String {
                logger.notice("navigateToDestination received: \(destination, privacy: .public)")
                navigation.navigate(to: destination)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        detailView(for: navigation.selectedView)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(detailBackground)
    }

    private var detailBackground: some View {
        Color.clear
    }

    @ViewBuilder
    private func detailView(for viewType: ViewType) -> some View {
        switch viewType {
        case .dashboard:
            DashboardView()
        case .models:
            ModelManagementView()
        case .transcribeAudio:
            AudioTranscribeView()
        case .history:
            InlineHistoryView()
        case .audio:
            AudioSetupView()
        case .dictionary:
            DictionarySettingsView()
        case .modes:
            ModeView()
        case .settings:
            SettingsView()
        case .license:
            LicenseManagementView()
        }
    }
}


/// Pins the hosting NSWindow to an appearance so the title bar and SwiftUI content agree.
private struct WindowAppearanceSetter: NSViewRepresentable {
    let appearance: NSAppearance.Name

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.appearance = NSAppearance(named: appearance) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.appearance = NSAppearance(named: appearance)
    }
}
