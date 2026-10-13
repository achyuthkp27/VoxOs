import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModeSettingsPanelView: View {
    @ObservedObject var modeManager: ModeManager
    let onDismiss: () -> Void

    @AppStorage(DefaultsKeys.modeTipDismissed)
    private var isTipDismissed = false

    private let contentInset: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Modes Settings")
                    .font(.app(.headline))
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.app(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(AppTheme.Surface.card)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .overlay(Divider().opacity(0.5), alignment: .bottom)

            HStack {
                Text("Reorder Modes")
                    .font(.app(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    + Text(" (drag to reorder)")
                    .font(.app(size: 12, weight: .regular))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, contentInset)
            .padding(.top, 18)
            .padding(.bottom, 8)

            ModeReorderList(modeManager: modeManager)
                .padding(.horizontal, contentInset)

            if !isTipDismissed {
                ModeSettingsQuickSwitchTip {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isTipDismissed = true
                    }
                }
                .padding(.horizontal, contentInset)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.16), value: isTipDismissed)
        .onExitCommand(perform: onDismiss)
    }

}

private struct ModeReorderList: View {
    @ObservedObject var modeManager: ModeManager

    /// The drag's source row. Kept apart from the faded `draggedConfigID` because SwiftUI gives no
    /// drag-ended callback: a drop outside the list never reaches `performDrop`, so the fade is
    /// cleared on `dropExited` while the source survives for a re-entry.
    @State private var dragSourceID: UUID?
    @State private var draggedConfigID: UUID?
    @State private var targetedConfigID: UUID?
    /// Order being previewed mid-drag, as mode ids. Only the drop commits it, so one drag saves
    /// once instead of on every row crossed; nil means the list shows what is saved. Ids rather
    /// than copies, so an edit saved elsewhere during the drag is not reverted by the drop.
    @State private var pendingOrder: [UUID]?
    /// Clears the drag state once the mouse is released, because SwiftUI reports no drag end and
    /// a drag cancelled over a row (Escape, or a release outside any target) never drops.
    @State private var dragEndWatcher: Task<Void, Never>?

    private var displayedConfigurations: [ModeConfig] {
        guard let pendingOrder else { return modeManager.configurations }
        return Self.configurations(modeManager.configurations, orderedBy: pendingOrder)
    }

    /// The live configurations in `order`. Modes added during the drag keep their saved place at
    /// the end, and ids of modes removed during the drag are dropped.
    private static func configurations(_ live: [ModeConfig], orderedBy order: [UUID]) -> [ModeConfig] {
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = order.compactMap { byID[$0] }
        let orderedIDs = Set(order)
        return ordered + live.filter { !orderedIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(displayedConfigurations) { config in
                    ModeReorderRow(
                        config: config,
                        isDragged: draggedConfigID == config.id,
                        isTargeted: targetedConfigID == config.id
                    )
                    .onDrag {
                        dragSourceID = config.id
                        draggedConfigID = config.id
                        watchForDragEnd()
                        return NSItemProvider(object: config.id.uuidString as NSString)
                    } preview: {
                        ModeReorderDragPreview(config: config)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: ModeReorderDropDelegate(
                            item: config,
                            dragSourceID: $dragSourceID,
                            draggedConfigID: $draggedConfigID,
                            targetedConfigID: $targetedConfigID,
                            pendingOrder: $pendingOrder,
                            savedOrder: modeManager.configurations.map(\.id),
                            commit: commitPendingOrder
                        )
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
        .onDrop(
            of: [UTType.text],
            delegate: ModeReorderResetDropDelegate(
                draggedConfigID: $draggedConfigID,
                targetedConfigID: $targetedConfigID,
                pendingOrder: $pendingOrder,
                commit: commitPendingOrder
            )
        )
        .onDisappear(perform: resetDragState)
    }

    private func commitPendingOrder() {
        if let pendingOrder {
            // Map onto the live list at drop time, so the saved order carries current contents.
            let live = modeManager.configurations
            let reordered = Self.configurations(live, orderedBy: pendingOrder)
            if reordered.map(\.id) != live.map(\.id) {
                modeManager.replaceConfigurations(reordered)
            }
        }
        resetDragState()
    }

    private func resetDragState() {
        dragEndWatcher?.cancel()
        dragEndWatcher = nil
        pendingOrder = nil
        dragSourceID = nil
        draggedConfigID = nil
        targetedConfigID = nil
    }

    private func watchForDragEnd() {
        dragEndWatcher?.cancel()
        dragEndWatcher = Task { @MainActor in
            // A drop is delivered on mouse-up, so waiting for two released samples in a row
            // leaves `performDrop` time to commit first; this only cleans up a drag that ended
            // without one.
            var releasedSamples = 0
            while releasedSamples < 2 {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
                releasedSamples = NSEvent.pressedMouseButtons & 1 == 0 ? releasedSamples + 1 : 0
            }
            withAnimation(.smooth(duration: 0.18)) {
                pendingOrder = nil
            }
            dragSourceID = nil
            draggedConfigID = nil
            targetedConfigID = nil
            dragEndWatcher = nil
        }
    }
}

private struct ModeReorderRow: View {
    let config: ModeConfig
    let isDragged: Bool
    let isTargeted: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ModeIconView(icon: config.icon, size: config.icon.kind == .emoji ? 18 : 14)
            }
            .frame(width: 34, height: 34)
            .background(
                AppCardBackground(isSelected: false, cornerRadius: 17)
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(config.name)
                    .font(.app(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    ModeReorderMeta(icon: "app.fill", value: countText(config.allAppConfigs.count, plural: "Apps"))
                    ModeReorderMeta(icon: "globe", value: countText(config.allURLConfigs.count, plural: "Websites"))
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                if config.isDefault {
                    DefaultModeIndicator()
                }

                if !config.isEnabled {
                    ModeReorderBadge(title: "Disabled", systemImage: "slash.circle.fill")
                }
            }

        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(rowBorder, lineWidth: isTargeted ? 1.5 : 1)
        }
        .shadow(
            color: Color.black.opacity(isDragged ? 0.10 : 0.03), radius: isDragged ? 10 : 2, x: 0, y: isDragged ? 5 : 1
        )
        .scaleEffect(isDragged ? 0.985 : 1)
        .opacity(isDragged ? 0.55 : 1)
        .animation(.smooth(duration: 0.16), value: isDragged)
        .animation(.smooth(duration: 0.16), value: isTargeted)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(config.name)
    }

    private var rowBackground: Color {
        if isTargeted {
            return AppTheme.Selection.fill
        }

        if isHovering {
            return AppTheme.Surface.controlActive
        }

        return AppTheme.Surface.card
    }

    private var rowBorder: Color {
        if isTargeted {
            return AppTheme.Selection.border
        }

        return AppTheme.Border.control.opacity(0.55)
    }

    private func countText(_ count: Int, plural: String) -> String {
        if count == 0 {
            return plural == "Apps" ? String(localized: "No Apps") : String(localized: "No Websites")
        }

        if plural == "Apps" {
            return String(localized: "\(count) Apps")
        } else {
            return String(localized: "\(count) Websites")
        }
    }
}

private struct ModeReorderMeta: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.app(size: 9, weight: .medium))

            Text(value)
                .font(.app(size: 11, weight: .regular))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }
}

private struct ModeReorderBadge: View {
    let title: LocalizedStringKey
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.app(size: 10, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
            }

            Text(title)
                .font(.app(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(AppTheme.Surface.card)
        }
        .overlay {
            Capsule()
                .stroke(AppTheme.Border.control, lineWidth: 0.5)
        }
    }
}

private struct ModeReorderDragPreview: View {
    let config: ModeConfig

    var body: some View {
        HStack(spacing: 10) {
            ModeIconView(icon: config.icon, size: config.icon.kind == .emoji ? 18 : 14)

            Text(config.name)
                .font(.app(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.Border.control, lineWidth: 0.5)
        }
    }
}

private struct ModeReorderDropDelegate: DropDelegate {
    let item: ModeConfig
    @Binding var dragSourceID: UUID?
    @Binding var draggedConfigID: UUID?
    @Binding var targetedConfigID: UUID?
    @Binding var pendingOrder: [UUID]?
    let savedOrder: [UUID]
    let commit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragSourceID, dragSourceID != item.id else {
            return
        }

        var order = pendingOrder ?? savedOrder
        guard let fromIndex = order.firstIndex(of: dragSourceID),
            let toIndex = order.firstIndex(of: item.id)
        else {
            return
        }

        // Re-entering after the pointer left the list restores the fade cleared on exit.
        draggedConfigID = dragSourceID
        targetedConfigID = item.id

        withAnimation(.smooth(duration: 0.18)) {
            order.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
            pendingOrder = order
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if targetedConfigID == item.id {
            targetedConfigID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        commit()
        return true
    }
}

private struct ModeReorderResetDropDelegate: DropDelegate {
    @Binding var draggedConfigID: UUID?
    @Binding var targetedConfigID: UUID?
    @Binding var pendingOrder: [UUID]?
    let commit: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Leaving the list may be the end of the drag (a drop outside never calls performDrop), so
        // snap back to the saved order and un-fade the row; a re-entry rebuilds the preview.
        withAnimation(.smooth(duration: 0.18)) {
            pendingOrder = nil
        }
        draggedConfigID = nil
        targetedConfigID = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        commit()
        return true
    }
}
