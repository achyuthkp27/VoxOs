import AppKit
import SwiftUI

/// The window switcher's grid: a tile per window — its thumbnail, or its app's icon until one
/// comes — with the app's icon and the window's title under it; the picked one outlined. A search
/// line shows above while searching. Minimized and hidden windows are dimmed and marked, and a
/// grid taller than the screen scrolls to keep the picked window in view.
struct WindowSwitcherView: View {
    @ObservedObject var switcher: WindowSwitcher

    static let tileWidth: CGFloat = 220
    static let spacing: CGFloat = 10
    static let accent = Color(nsColor: .systemBlue)

    var body: some View {
        let windows = switcher.shown
        let columns = Array(
            repeating: GridItem(.fixed(Self.tileWidth), spacing: Self.spacing), count: switcher.columns)
        VStack(alignment: .leading, spacing: 12) {
            if switcher.searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.5))
                    Text(verbatim: switcher.query.isEmpty ? String(localized: "Search windows") : switcher.query)
                        .font(.app(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(switcher.query.isEmpty ? 0.4 : 0.95))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.08)))
            }
            if windows.isEmpty {
                Text("No window matches")
                    .font(.app(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: Self.tileWidth * 2, height: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVGrid(columns: columns, spacing: Self.spacing) {
                            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                                WindowSwitcherTile(
                                    window: window, thumbnail: switcher.thumbnails[window.id],
                                    isSelected: index == switcher.selected
                                )
                                .id(window.id)
                                .onHover { if $0 { switcher.pick(window.id) } }
                                .onTapGesture { switcher.choose(window.id) }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: switcher.maxGridHeight)
                    .onChange(of: switcher.selected) { _, index in
                        guard windows.indices.contains(index) else { return }
                        proxy.scrollTo(windows[index].id)
                    }
                }
            }
            footer

        }
        .padding(16)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(white: 0.08).opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1))
                )
        )
        .environment(\.colorScheme, .dark)
    }

    private var footer: some View {
        let quitting = switcher.quitArmed.flatMap { pid in switcher.windows.first { $0.pid == pid }?.appName }
        let text: Text =
            if let quitting {
                Text("Press Q again to quit \(quitting)")
            } else if switcher.searching {
                Text("Type to search · ⌫ to go back · Return to switch")
            } else {
                Text(
                    "Tab to move · release to switch · W close · M minimize · H hide · Q twice quit · L/R half · F fill · / search"
                )
            }
        return
            text
            .font(.app(size: 11))
            .foregroundStyle(.white.opacity(quitting == nil ? 0.4 : 0.85))
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// A window in the grid.
private struct WindowSwitcherTile: View {
    let window: WindowSwitcher.Window
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        let icon = NSRunningApplication(processIdentifier: window.pid)?.icon
        VStack(spacing: 8) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }
            }
            .frame(width: WindowSwitcher.thumbnailSize.width, height: WindowSwitcher.thumbnailSize.height)
            // Out of sight: dimmed, so the windows on this Space stand out.
            .opacity(window.place == .onScreen ? 1 : 0.55)
            HStack(spacing: 6) {
                if let symbol = placeSymbol {
                    Image(systemName: symbol)
                        .font(.app(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                if let icon, thumbnail != nil {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(verbatim: window.label)
                    .font(.app(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.75))
                    .lineLimit(1)
            }
            .frame(maxWidth: WindowSwitcher.thumbnailSize.width)
            .help(Text(verbatim: "\(window.appName) — \(window.label)"))
        }
        .padding(10)
        .frame(width: WindowSwitcherView.tileWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? WindowSwitcherView.accent.opacity(0.22) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? WindowSwitcherView.accent : .clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var placeSymbol: String? {
        switch window.place {
        case .onScreen: return nil
        case .minimized: return "arrow.down.right.and.arrow.up.left"
        case .hidden: return "eye.slash"
        }
    }
}
