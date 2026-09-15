import SwiftUI

/// Background Agent jobs on the Dashboard: running ones with a spinner and Cancel, finished
/// ones with their report. Hidden when there are none.
struct DashboardBackgroundTasks: View {
    @ObservedObject private var center = AgentTaskCenter.shared
    @State private var expanded: Set<UUID> = []

    var body: some View {
        if !center.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Background Tasks")
                        .font(.app(size: 17, weight: .semibold))
                    Spacer()
                    if center.tasks.contains(where: { $0.status != .running }) {
                        Button("Clear Finished") { center.clearFinished() }
                            .buttonStyle(.borderless)
                            .font(.app(size: 12, weight: .medium))
                    }
                }

                VStack(spacing: 0) {
                    ForEach(center.tasks) { task in
                        row(task)
                        if task.id != center.tasks.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
                .padding(.vertical, 4)
                .glassCard(radius: 18)
            }
        }
    }

    private func row(_ task: AgentBackgroundTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusIcon(task.status)
                    .frame(width: 18)
                Text(task.title)
                    .font(.app(size: 14, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if task.status == .running {
                    TimelineView(.periodic(from: task.startedAt, by: 1)) { context in
                        Text(Self.elapsed(task.startedAt, context.date))
                            .font(.app(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") { center.cancel(id: task.id) }
                        .buttonStyle(.borderless)
                        .font(.app(size: 12, weight: .medium))
                } else if let finished = task.finishedAt {
                    Text(finished, style: .time)
                        .font(.app(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if !task.result.isEmpty {
                Text(task.result)
                    .font(.app(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded.contains(task.id) ? nil : 2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if expanded.contains(task.id) { expanded.remove(task.id) } else { expanded.insert(task.id) }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusIcon(_ status: AgentBackgroundTask.Status) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private static func elapsed(_ start: Date, _ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
