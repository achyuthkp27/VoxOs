import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

struct NotchShelfPage: View {
    @ObservedObject var shelf: NotchShelf
    let dropping: Bool
    let pinned: Bool
    let onPin: () -> Void
    /// Tiles that fit beside the clear button; the rest are counted.
    static let visible = 4
    /// The file whose details are open; nothing is read about a file until it is clicked.
    @State private var selected: NotchShelf.Item.ID?

    var body: some View {
        Group {
            if shelf.items.isEmpty || dropping {
                // Two places to drop: the shelf keeps the files, AirDrop sends them on at once.
                HStack(spacing: 8) {
                    dropArea
                    NotchAirDropZone(shelf: shelf, dropping: dropping)
                        .frame(width: 128)
                    NotchRoundButton(
                        symbol: pinned ? "pin.fill" : "pin",
                        label: pinned ? "Unpin: close when the pointer leaves" : "Pin: keep the card open",
                        on: pinned,
                        tint: AppTheme.Accent.primary,
                        action: onPin
                    )
                }
                .padding(.top, 4)
            } else if let item = shelf.items.first(where: { $0.id == selected }) {
                NotchShelfDetail(item: item, shelf: shelf, pinned: pinned, onPin: onPin) { selected = nil }
                    .frame(maxHeight: .infinity)
            } else {
                // No sideways scrolling: a sideways swipe turns the page.
                HStack(alignment: .center, spacing: 6) {
                    ForEach(shelf.items.prefix(Self.visible)) { item in
                        NotchShelfTile(item: item) { selected = item.id }
                    }
                    if shelf.items.count > Self.visible {
                        Text(verbatim: "+\(shelf.items.count - Self.visible)")
                            .font(.app(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 34)
                    }
                    Spacer(minLength: 0)
                    NotchRoundButton(
                        symbol: pinned ? "pin.fill" : "pin",
                        label: pinned ? "Unpin: close when the pointer leaves" : "Pin: keep the card open",
                        on: pinned,
                        tint: AppTheme.Accent.primary,
                        action: onPin
                    )
                    NotchServiceButton(
                        service: NSSharingService(named: .sendViaAirDrop), label: "AirDrop everything on the shelf"
                    ) {
                        shelf.airDrop(shelf.items.map(\.url))
                    }
                    NotchRoundButton(symbol: "trash", label: "Clear the shelf") { shelf.clear() }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        .onAppear { shelf.prune() }
    }

    /// The shelf's half looks idle while files are held over the AirDrop zone.
    private var keeping: Bool { dropping && !shelf.airDropTargeted }

    private var dropArea: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                .white.opacity(keeping ? 0.6 : 0.2), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(keeping ? 0.08 : 0.02))
            )
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: keeping ? "tray.and.arrow.down.fill" : "tray")
                        .font(.system(size: 20, weight: .medium))
                    Text(keeping ? "Drop to keep it here" : "Drop files here to keep them")
                        .font(.app(size: 12))
                }
                .foregroundStyle(.white.opacity(keeping ? 0.9 : 0.45))
            }
    }
}

/// Files dropped here go straight to AirDrop. The zone tells the shelf where it is, so the card
/// can send a drop here rather than onto the shelf.
private struct NotchAirDropZone: View {
    @ObservedObject var shelf: NotchShelf
    let dropping: Bool

    private static let service = NSSharingService(named: .sendViaAirDrop)

    var body: some View {
        let hot = shelf.airDropTargeted
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                hot ? Color(nsColor: .systemBlue) : .white.opacity(0.2),
                style: StrokeStyle(lineWidth: 1.2, dash: hot ? [] : [5, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hot ? Color(nsColor: .systemBlue).opacity(0.18) : .white.opacity(0.02))
            )
            .overlay {
                VStack(spacing: 6) {
                    if let image = Self.service?.image {
                        Image(nsImage: image).resizable().frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 20, weight: .medium))
                    }
                    Text(hot ? "Drop to AirDrop" : "AirDrop")
                        .font(.app(size: 12, weight: hot ? .semibold : .regular))
                }
                .foregroundStyle(.white.opacity(hot ? 0.95 : 0.45))
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(NotchHome.cardSpace))
            } action: { frame in
                shelf.airDropZone = frame
            }
            .onDisappear { shelf.airDropZone = nil }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Drop files here to AirDrop them"))
    }
}

/// A file on the shelf: its icon and name. Click for its details and AirDrop; drag it out to
/// use it, and it stays on the shelf.
private struct NotchShelfTile: View {
    let item: NotchShelf.Item
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NotchShelf.icon(for: item))
                .resizable()
                .frame(width: 40, height: 40)
            Text(verbatim: item.name)
                .font(.app(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 66, height: 70)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovered ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onSelect)
        .onDrag { NotchShelf.itemProvider(for: item) }
        .help(item.name)
        .accessibilityAddTraits(.isButton)
    }
}

/// One file, opened from its tile: what it is, and what to do with it — AirDrop it, open it,
/// show it in Finder, or take it off the shelf.
private struct NotchShelfDetail: View {
    let item: NotchShelf.Item
    let shelf: NotchShelf
    let pinned: Bool
    let onPin: () -> Void
    let onClose: () -> Void
    @State private var details: NotchShelf.Details?

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NotchShelf.icon(for: item))
                .resizable()
                .frame(width: 52, height: 52)
                .onDrag { NotchShelf.itemProvider(for: item) }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.name)
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let details {
                    Text(verbatim: details.summary)
                        .font(.app(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Text(verbatim: String(localized: "Added \(item.added.formatted(date: .omitted, time: .shortened))"))
                    .font(.app(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                NotchRoundButton(
                    symbol: pinned ? "pin.fill" : "pin",
                    label: pinned ? "Unpin: close when the pointer leaves" : "Pin: keep the card open",
                    on: pinned,
                    tint: AppTheme.Accent.primary,
                    action: onPin
                )
                NotchServiceButton(service: NSSharingService(named: .sendViaAirDrop), label: "AirDrop") {
                    shelf.airDrop([item.url])
                }
                NotchRoundButton(symbol: "arrow.up.forward.app", label: "Open") { NSWorkspace.shared.open(item.url) }
                NotchRoundButton(symbol: "doc.on.doc", label: "Copy the file") { shelf.copy(item) }
                NotchRoundButton(symbol: "doc.zipper", label: "Compress to a zip") { shelf.compress(item) }
                NotchRoundButton(symbol: "folder", label: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                NotchRoundButton(symbol: "trash", label: "Remove from the shelf") {
                    shelf.remove(item.id)
                    onClose()
                }
                NotchRoundButton(symbol: "xmark", label: "Back to the shelf", action: onClose)
            }
        }
        .task(id: item.id) { details = NotchShelf.details(of: item) }
    }
}

/// A round button showing a system sharing service's own icon, so AirDrop looks like AirDrop.
private struct NotchServiceButton: View {
    let service: NSSharingService?
    let label: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let image = service?.image {
                    Image(nsImage: image).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                }
            }
            .frame(width: 32, height: 32)
            .background(Circle().fill(.white.opacity(hovered ? 0.16 : 0.09)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(service == nil)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Controls

struct NotchChip: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var fill: Color {
        prominent ? AppTheme.Accent.primary.opacity(hovered ? 1 : 0.85) : .white.opacity(hovered ? 0.16 : 0.09)
    }
}

struct NotchRoundButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var on: Bool = false
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? (tint ?? AppTheme.Accent.primary) : .white.opacity(hovered ? 1 : 0.75))
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(
                        on
                            ? (tint ?? AppTheme.Accent.primary).opacity(hovered ? 0.3 : 0.18)
                            : .white.opacity(hovered ? 0.16 : 0.09)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Sound
