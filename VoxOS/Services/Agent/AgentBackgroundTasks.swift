import AppKit
import Foundation
import LLMkit

/// Marks tool calls made by a background task. Background runs share tools with the notch
/// but never its confirmation, pause, progress or card state.
enum AgentRunScope {
    @TaskLocal static var isBackground = false

    /// Tools a background task may not run: they need the user in the loop, or would leave a
    /// pending confirmation for the next foreground request to approve unseen.
    static func backgroundBlockReason(tool: String, args: [String: Any]) -> String? {
        let sends: Bool = {
            if let flag = args["send"] as? Bool { return flag }
            if let flag = args["send"] as? Int { return flag != 0 }
            return ["true", "yes", "1"].contains(((args["send"] as? String) ?? "").lowercased())
        }()
        switch tool {
        case "confirm_action", "cancel_action":
            return "background tasks cannot confirm anything"
        case "wait_for_user":
            return
                "background tasks cannot ask questions; finish with what you have and put the question in the final reply"
        case "background_task":
            return "background tasks cannot start other background tasks"
        case "messages_send", "set_control_mode":
            return "this needs the user's confirmation; say in the final reply what to ask for"
        // Written as one condition: a `where` on a multi-pattern case guards only its last pattern.
        case "mail_compose", "gmail_compose", "slack_send":
            return sends
                ? "sending needs the user's confirmation; leave a draft instead and say so in the final reply"
                : askBeforeActingReason(tool)
        default:
            return askBeforeActingReason(tool)
        }
    }
}

extension AgentRunScope {
    fileprivate static func askBeforeActingReason(_ tool: String) -> String? {
        guard AgentControlMode.current == .askBeforeAction, AgentControlMode.isMutating(tool) else { return nil }
        return "ask-before-acting is on, so background tasks can only look, not act"
    }
}

/// The provider, model and prompt of the latest foreground Agent run, reused by background tasks.
enum AgentRunContext {
    struct Snapshot {
        let systemPrompt: String?
        let provider: AIProvider
        let modelName: String?
        weak var aiService: AIService?
    }

    private static let lock = NSLock()
    private static var last: Snapshot?

    static func record(systemPrompt: String?, provider: AIProvider, modelName: String?, aiService: AIService) {
        lock.withLock {
            last = Snapshot(systemPrompt: systemPrompt, provider: provider, modelName: modelName, aiService: aiService)
        }
    }

    static var latest: Snapshot? { lock.withLock { last } }
}

struct AgentBackgroundTask: Identifiable, Equatable {
    enum Status: Equatable {
        case running
        case done
        case failed
        case cancelled
    }

    let id: UUID
    let title: String
    let instruction: String
    let startedAt: Date
    var finishedAt: Date?
    var status: Status
    var result: String
}

/// Long Agent jobs that keep running after the notch closes: "research flights to Osaka",
/// "tidy my desktop into folders". Results arrive as a toast and on the Dashboard.
@MainActor
final class AgentTaskCenter: ObservableObject {
    static let shared = AgentTaskCenter()
    static let maxRunning = 2
    static let maxKept = 20

    @Published private(set) var tasks: [AgentBackgroundTask] = []
    private var handles: [UUID: Task<Void, Never>] = [:]

    var runningCount: Int { tasks.filter { $0.status == .running }.count }

    func start(instruction: String, title: String?) -> Result<AgentBackgroundTask, TaskError> {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.missingTask) }
        guard runningCount < Self.maxRunning else { return .failure(.tooMany) }
        guard let context = AgentRunContext.latest, let aiService = context.aiService else {
            return .failure(.noAgentContext)
        }

        let taskTitle =
            (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? String(trimmed.prefix(60))
        let task = AgentBackgroundTask(
            id: UUID(), title: taskTitle, instruction: trimmed, startedAt: Date(), finishedAt: nil, status: .running,
            result: "")
        tasks.insert(task, at: 0)
        trim()

        let id = task.id
        handles[id] = Task.detached(priority: .utility) {
            let outcome: (AgentBackgroundTask.Status, String) = await AgentRunScope.$isBackground.withValue(true) {
                let messages = [
                    ChatMessage.user(
                        "BACKGROUND TASK — the user is not watching and cannot answer. Do the whole job with tools, never ask questions or wait for confirmation, then reply with a short report of the result.\n\nTask: \(trimmed)"
                    )
                ]
                do {
                    let first = try await aiService.completeChat(
                        provider: context.provider, modelName: context.modelName, messages: messages,
                        systemPrompt: context.systemPrompt, timeout: 60)
                    let final = await AgentToolExecutor.runLoop(
                        firstReply: first, priorMessages: messages, systemPrompt: context.systemPrompt,
                        provider: context.provider, modelName: context.modelName, aiService: aiService)
                    return Task.isCancelled ? (.cancelled, "Cancelled.") : (.done, final)
                } catch {
                    return Task.isCancelled ? (.cancelled, "Cancelled.") : (.failed, error.localizedDescription)
                }
            }
            await AgentTaskCenter.shared.finish(id: id, status: outcome.0, result: outcome.1)
        }
        return .success(task)
    }

    func cancel(matching query: String) -> AgentBackgroundTask? {
        let q = query.lowercased()
        guard
            let task = tasks.first(where: {
                $0.status == .running
                    && ($0.id.uuidString.lowercased().hasPrefix(q) || $0.title.lowercased().contains(q))
            })
        else { return nil }
        handles[task.id]?.cancel()
        finish(id: task.id, status: .cancelled, result: "Cancelled.")
        return task
    }

    func cancel(id: UUID) {
        handles[id]?.cancel()
        finish(id: id, status: .cancelled, result: "Cancelled.")
    }

    func clearFinished() {
        tasks.removeAll { $0.status != .running }
    }

    private func finish(id: UUID, status: AgentBackgroundTask.Status, result: String) {
        handles[id] = nil
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status == .running else { return }
        tasks[index].status = status
        tasks[index].finishedAt = Date()
        tasks[index].result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status != .cancelled else { return }

        let title = tasks[index].title
        NotificationManager.shared.showNotification(
            title: status == .done ? "Done: \(title)" : "Couldn't finish: \(title)",
            type: status == .done ? .info : .warning,
            duration: 8,
            actionButton: (
                label: String(localized: "Show"),
                action: {
                    _ = WindowManager.shared.showMainWindow()
                    NotificationCenter.default.post(
                        name: .navigateToDestination, object: nil, userInfo: ["destination": "Dashboard"])
                }
            )
        )
    }

    private func trim() {
        let finished = tasks.enumerated().filter { $0.element.status != .running }
        guard tasks.count > Self.maxKept, let oldest = finished.last else { return }
        tasks.remove(at: oldest.offset)
    }

    func toolList() -> [String: Any] {
        [
            "tasks": tasks.map { task -> [String: Any] in
                var entry: [String: Any] = [
                    "id": String(task.id.uuidString.prefix(8)), "title": task.title, "status": "\(task.status)",
                ]
                if !task.result.isEmpty { entry["result"] = String(task.result.prefix(600)) }
                return entry
            }
        ]
    }

    enum TaskError: Error, Equatable {
        case missingTask
        case tooMany
        case noAgentContext

        var message: String {
            switch self {
            case .missingTask: return "task is required"
            case .tooMany: return "two background tasks are already running; wait for one or cancel it"
            case .noAgentContext: return "no Agent model is ready yet"
            }
        }
    }
}
