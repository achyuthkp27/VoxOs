import Combine
import Foundation

/// What every running Claude Code session is doing, and the permission requests waiting on an
/// answer from the notch. Fed by ClaudeCodeBridge, read by ClaudeCodeNotchManager.
///
/// A permission request is shown in the terminal *and* in the notch at the same time: the CLI
/// draws its own dialog while the hook is still waiting (measured on 2.1.312), so whichever side
/// answers first wins. A request therefore has to leave the notch when it is answered elsewhere,
/// and the CLI only says so indirectly:
/// - "No" or Esc in the terminal closes the hook's connection (`connectionClosed`).
/// - "Yes" in the terminal leaves the connection open; the tool then runs, and its PostToolUse
///   carries the tool_use_id of the PreToolUse that preceded the request.
/// - A turn that ends, a new prompt, or the session ending settles everything in that session.
@MainActor
final class ClaudeCodeActivity: ObservableObject {
    static let shared = ClaudeCodeActivity()

    enum Phase: Equatable {
        case idle
        case working
        case done
        case failed
    }

    struct Session: Identifiable, Equatable {
        let id: String
        var project: String
        var phase: Phase
        var updated: Date
        /// The CLI process behind the session, when known.
        var cliPID: Int32?
        var transcriptPath: String? = nil
        /// From the transcript: the session's title and branch, and when they were last read.
        var title: String? = nil
        var branch: String? = nil
        var infoRead: Date? = nil
    }

    struct PermissionPrompt: Identifiable, Equatable {
        let id: UUID
        let sessionID: String
        let project: String
        let summary: ClaudeCodeToolSummary
        /// The tool_use_id of the matching PreToolUse, when one was seen.
        let toolUseID: String?
        let received: Date
        /// AskUserQuestion: the questions to answer instead of allowing or denying.
        var questions: [ClaudeCodeQuestion]? = nil
        /// ExitPlanMode: the plan to approve, as markdown; empty when the call did not carry it.
        var plan: String? = nil
        /// Edit, MultiEdit, Write: the lines the change removes and adds.
        var diff: [ClaudeCodeDiff.Line]? = nil
        /// The session's title and branch, which tell two sessions in one folder apart.
        var sessionTitle: String? = nil
        var branch: String? = nil
        /// What "Always allow" would allow, when the CLI offers it.
        var alwaysAllow: String? = nil
        /// The session is in a mode that "Allow in auto mode" would change.
        var canSwitchToAutoMode = false
    }

    /// The terminal dialog's choices, plus the answers to a question.
    enum Decision: Equatable {
        case allow
        /// Allow, and grant the CLI's permission_suggestions so it does not ask again.
        case allowAlways
        /// Allow, and switch the session to auto mode.
        case allowInAutoMode
        case deny
        /// AskUserQuestion: question text to the chosen label(s).
        case answer([String: String])
        /// ExitPlanMode: go ahead. Without `acceptEdits` the session returns to the mode it had
        /// before planning (the CLI's own rule); with it, edits are accepted without asking.
        case approvePlan(acceptEdits: Bool)
        /// ExitPlanMode: not yet; what to change, which may be empty.
        case keepPlanning(String)

        var trailName: String {
            switch self {
            case .allow: return "allow"
            case .allowAlways: return "allow always"
            case .allowInAutoMode: return "allow auto mode"
            case .deny: return "deny"
            case .answer: return "answer"
            case .approvePlan(let acceptEdits): return acceptEdits ? "approve plan, accept edits" : "approve plan"
            case .keepPlanning: return "keep planning"
            }
        }
    }

    /// Modes in which the terminal offers "Yes, and switch to auto mode".
    static let modesThatCanSwitchToAuto: Set<String> = ["default", "acceptEdits"]

    /// What the bridge writes back on the held connection.
    enum Resolution: Equatable {
        case decided(Decision)
        /// Answered in the terminal, superseded, or expired: an empty 200 leaves the CLI's own
        /// flow untouched.
        case noDecision
    }

    /// What the status band shows when no request is waiting.
    struct Status: Equatable {
        var working: Int
        /// A session finished (or failed) within `finishedLinger`.
        var finished: Phase?

        static let none = Status(working: 0, finished: nil)
        var isEmpty: Bool { working == 0 && finished == nil }
    }

    /// How long "done" stays in the notch after a turn ends.
    static let finishedLinger: TimeInterval = 4
    /// A working session that has sent nothing for this long is assumed gone (the CLI was killed,
    /// so no Stop or SessionEnd will ever come).
    static let staleAfter: TimeInterval = 30 * 60
    /// The installed hook waits 600 s; the notch lets go a little earlier so its answer is never
    /// written to a connection the CLI has already given up on.
    static let promptLifetime: TimeInterval = 590
    /// How far back a PreToolUse can be and still be the one a PermissionRequest is about.
    static let correlationWindow: TimeInterval = 10
    /// A session's title and branch are read again for a request after this long.
    static let infoLifetime: TimeInterval = 30

    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var prompts: [PermissionPrompt] = []

    private var responders: [UUID: (Resolution) -> Void] = [:]
    private var recentToolUses: [String: [(id: String, key: String, at: Date)]] = [:]
    /// Bash requests from a CLI whose pid is known, with the CLI's children when the request
    /// arrived: a new child running the command means it was allowed in the terminal.
    private var bashWatches: [UUID: (cliPID: Int32, command: String, known: Set<Int32>)] = [:]
    /// The CLI's child processes; replaced in tests.
    var childProcesses: (Int32) -> [ClaudeCodeChildProcess] = ClaudeCodeProcesses.children
    /// Reads a transcript's title and branch off the main thread; replaced in tests.
    var readInfo: @Sendable (String) async -> ClaudeCodeTranscript.Info = { path in
        await Task.detached(priority: .utility) { ClaudeCodeTranscript.info(at: path) }.value
    }
    /// Esc ends a turn with no hook, and only the "working" band shows that a turn runs, so a
    /// working session's transcript is followed only while that band is on.
    var followsTranscripts: () -> Bool = { ClaudeCodeIntegration.statusEnabled }
    private var watches: [String: ClaudeCodeTranscriptWatch] = [:]

    init() {}

    // MARK: Events

    /// Every event except PermissionRequest, which needs an answer (see `request`).
    func receive(_ event: ClaudeCodeHookEvent, now: Date = Date()) {
        switch event.kind {
        case .sessionStart:
            update(event, phase: .idle, now: now)
            settleSession(event.sessionID)
        case .userPromptSubmit:
            update(event, phase: .working, now: now)
            settleSession(event.sessionID)
        case .preToolUse:
            update(event, phase: .working, now: now)
            if let id = event.toolUseID, let key = toolKey(event) {
                var uses = recentToolUses[event.sessionID, default: []].filter {
                    now.timeIntervalSince($0.at) < Self.correlationWindow
                }
                uses.append((id, key, now))
                recentToolUses[event.sessionID] = uses
            }
        case .postToolUse, .postToolUseFailure:
            update(event, phase: .working, now: now)
            if let id = event.toolUseID {
                settle { $0.toolUseID == id }
            }
        case .stop:
            update(event, phase: .done, now: now)
            settleSession(event.sessionID)
        case .stopFailure:
            update(event, phase: .failed, now: now)
            settleSession(event.sessionID)
        case .sessionEnd:
            sessions[event.sessionID] = nil
            recentToolUses[event.sessionID] = nil
            stopFollowing(event.sessionID)
            settleSession(event.sessionID)
        case .notification where event.notificationType == "idle_prompt":
            // Waiting for the user's next prompt: the turn is over. Esc ends a turn without a
            // Stop event, so this is what clears a session interrupted that way.
            if var session = sessions[event.sessionID], session.phase == .working {
                session.phase = .idle
                session.updated = now
                sessions[event.sessionID] = session
                stopFollowing(event.sessionID)
            }
        case .notification, .permissionRequest:
            // Any other notification is the CLI announcing the dialog the notch is already showing.
            break
        }
    }

    /// Queues a request and keeps `respond` until it is decided, answered elsewhere or expires.
    /// `respond` is called at most once.
    @discardableResult
    func request(
        _ event: ClaudeCodeHookEvent, now: Date = Date(), respond: @escaping (Resolution) -> Void
    ) -> UUID {
        update(event, phase: .working, now: now)
        let prompt = PermissionPrompt(
            id: UUID(),
            sessionID: event.sessionID,
            project: event.project,
            summary: event.summary ?? ClaudeCodeToolSummary(title: event.toolName ?? "Claude Code", detail: ""),
            toolUseID: claimToolUse(for: event, now: now),
            received: now,
            questions: event.questions,
            plan: event.plan,
            diff: event.questions == nil && event.plan == nil
                ? ClaudeCodeDiff.lines(toolName: event.toolName ?? "", input: event.toolInput) : nil,
            sessionTitle: sessions[event.sessionID]?.title,
            branch: sessions[event.sessionID]?.branch,
            alwaysAllow: event.questions == nil && event.plan == nil
                ? ClaudeCodePermissionSuggestion.describe(event.permissionSuggestions) : nil,
            canSwitchToAutoMode: event.questions == nil && event.plan == nil
                && Self.modesThatCanSwitchToAuto.contains(event.permissionMode ?? "")
        )
        responders[prompt.id] = respond
        prompts.append(prompt)
        refreshInfo(of: event.sessionID, now: now)
        if event.toolName == "Bash", let pid = sessions[event.sessionID]?.cliPID {
            bashWatches[prompt.id] = (pid, prompt.summary.detail, Set(childProcesses(pid).map(\.pid)))
        }
        ActivityTrail.mark("claude permission request \(prompt.summary.title)")
        return prompt.id
    }

    /// The user's answer from the notch.
    func decide(_ id: UUID, _ decision: Decision) {
        ActivityTrail.mark("claude permission \(decision.trailName)")
        finish(id, with: .decided(decision))
    }

    /// The CLI dropped the hook's connection: answered "No" or Esc in the terminal, or it quit.
    func connectionClosed(_ id: UUID) {
        guard prompts.contains(where: { $0.id == id }) else { return }
        responders[id] = nil
        bashWatches[id] = nil
        prompts.removeAll { $0.id == id }
    }

    /// Settles Bash requests whose command has started running: "Yes" in the terminal, which the
    /// CLI otherwise reports only once the command has finished.
    func noticeStartedCommands() {
        for (id, watch) in bashWatches {
            let started = childProcesses(watch.cliPID).contains {
                !watch.known.contains($0.pid) && ClaudeCodeProcesses.isBashToolShell($0, command: watch.command)
            }
            if started { finish(id, with: .noDecision) }
        }
    }

    /// Lets go of requests nobody answered and forgets sessions that went quiet, or whose CLI is
    /// gone. A CLI killed outright sends no SessionEnd, and the curl holding its request outlives
    /// it; settling the request answers that curl so it exits too.
    func expire(now: Date = Date(), isAlive: (Int32) -> Bool = ClaudeCodeActivity.processIsAlive) {
        settle { now.timeIntervalSince($0.received) >= Self.promptLifetime }
        for (id, session) in sessions {
            let ended = session.cliPID.map { !isAlive($0) } ?? false
            guard ended || now.timeIntervalSince(session.updated) >= Self.staleAfter else { continue }
            sessions[id] = nil
            recentToolUses[id] = nil
            stopFollowing(id)
            settleSession(id)
        }
    }

    nonisolated static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Answers every waiting request with no decision, as when the integration is switched off.
    func settleAll() {
        settle { _ in true }
    }

    /// Esc in the terminal: the turn is over, and whatever it was waiting on with it.
    func interrupted(_ sessionID: String, now: Date = Date()) {
        stopFollowing(sessionID)
        guard var session = sessions[sessionID], session.phase == .working else { return }
        ActivityTrail.mark("claude session interrupted")
        session.phase = .idle
        session.updated = now
        sessions[sessionID] = session
        settleSession(sessionID)
    }

    // MARK: Session info

    /// Reads the session's title and branch for a request, at most every `infoLifetime`; the
    /// card shows what is already known meanwhile and fills in when the read lands.
    private func refreshInfo(of sessionID: String, now: Date) {
        guard let session = sessions[sessionID], let path = session.transcriptPath,
            session.infoRead.map({ now.timeIntervalSince($0) >= Self.infoLifetime }) ?? true
        else { return }
        sessions[sessionID]?.infoRead = now
        let read = readInfo
        Task { @MainActor [weak self] in
            let info = await read(path)
            self?.apply(info, to: sessionID)
        }
    }

    func apply(_ info: ClaudeCodeTranscript.Info, to sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        let branch = info.branch == "HEAD" ? nil : info.branch
        if session.title != info.title || session.branch != branch {
            session.title = info.title
            session.branch = branch
            sessions[sessionID] = session
        }
        for index in prompts.indices where prompts[index].sessionID == sessionID {
            if prompts[index].sessionTitle != info.title { prompts[index].sessionTitle = info.title }
            if prompts[index].branch != branch { prompts[index].branch = branch }
        }
    }

    /// While a session works and the band is on, its transcript is followed for an Esc.
    private func follow(_ session: Session) {
        guard session.phase == .working else { return stopFollowing(session.id) }
        guard watches[session.id] == nil, followsTranscripts(), let path = session.transcriptPath else { return }
        let id = session.id
        watches[id] = ClaudeCodeTranscriptWatch(path: path) { [weak self] in
            Task { @MainActor in self?.interrupted(id) }
        }
    }

    private func stopFollowing(_ sessionID: String) {
        watches.removeValue(forKey: sessionID)?.cancel()
    }

    // MARK: Status

    func status(now: Date = Date()) -> Status {
        var status = Status.none
        var latestFinish: Session?
        for session in sessions.values {
            switch session.phase {
            case .working where now.timeIntervalSince(session.updated) < Self.staleAfter:
                status.working += 1
            case .done, .failed:
                if now.timeIntervalSince(session.updated) < Self.finishedLinger,
                    latestFinish.map({ session.updated > $0.updated }) ?? true
                {
                    latestFinish = session
                }
            default:
                break
            }
        }
        // While anything is still working the band shows that; "done" only once all are quiet.
        if status.working == 0 { status.finished = latestFinish?.phase }
        return status
    }

    /// When the status band next changes on its own (a "done" running out), so the notch can
    /// refresh then instead of polling.
    func nextStatusChange(after now: Date = Date()) -> Date? {
        sessions.values
            .filter { $0.phase == .done || $0.phase == .failed }
            .map { $0.updated.addingTimeInterval(Self.finishedLinger) }
            .filter { $0 > now }
            .min()
    }

    // MARK: Private

    private func update(_ event: ClaudeCodeHookEvent, phase: Phase, now: Date) {
        var session =
            sessions[event.sessionID]
            ?? Session(id: event.sessionID, project: event.project, phase: phase, updated: now)
        session.project = event.project
        session.phase = phase
        session.updated = now
        if let pid = event.cliPID { session.cliPID = pid }
        if let path = event.transcriptPath { session.transcriptPath = path }
        sessions[event.sessionID] = session
        follow(session)
    }

    private func toolKey(_ event: ClaudeCodeHookEvent) -> String? {
        guard let name = event.toolName else { return nil }
        return name + "\n" + (event.toolInputKey ?? "")
    }

    /// The most recent unclaimed PreToolUse in the session with the same tool and input.
    private func claimToolUse(for event: ClaudeCodeHookEvent, now: Date) -> String? {
        guard let key = toolKey(event), var uses = recentToolUses[event.sessionID],
            let index = uses.lastIndex(where: { $0.key == key && now.timeIntervalSince($0.at) < Self.correlationWindow }
            )
        else { return nil }
        let id = uses[index].id
        uses.remove(at: index)
        recentToolUses[event.sessionID] = uses
        return id
    }

    private func settleSession(_ sessionID: String) {
        settle { $0.sessionID == sessionID }
    }

    private func settle(where shouldSettle: (PermissionPrompt) -> Bool) {
        for prompt in prompts where shouldSettle(prompt) {
            finish(prompt.id, with: .noDecision)
        }
    }

    private func finish(_ id: UUID, with resolution: Resolution) {
        bashWatches[id] = nil
        guard let respond = responders.removeValue(forKey: id) else { return }
        prompts.removeAll { $0.id == id }
        respond(resolution)
    }
}
