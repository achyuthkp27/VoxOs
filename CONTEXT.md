# VoxOS — domain context

VoxOS is a personal macOS voice app: local dictation plus a voice Agent that acts on the Mac.
It is a fork of VoiceInk (GPL v3) with the cursor-voice tool layer (MIT) ported in
(`THIRD_PARTY_LICENSES.md`). SwiftUI, macOS 26, built with `make local`.

## Vocabulary

- **Mode** — a `ModeConfig`: transcription model, AI provider/model, prompt, context switches,
  output mode (paste / respond / custom command). Stored in UserDefaults `modeConfigurationsV2`.
- **Agent mode** — the built-in mode with id `10000000-…-0006` (`StarterModeCatalog.agentId`).
  `AgentModeGuard` recreates and repairs it on launch, after onboarding and on ⌃⌃; it cannot
  be deleted.
- **Recording shortcut** — fn by default (hybrid: hold = push-to-talk, tap = hands-free).
  **⌃⌃** (double-tap Control, `.agentDoubleTap`) opens the Agent. Agent recordings auto-send
  after ~1.4 s of silence (`AgentAutoSend`).
- **Recorder** — notch (default) or bottom. Both are a black pill with a five-bar wave:
  white = dictation (plain or AI-enhanced), violet = Agent. No text on the pill. The Agent's
  violet orb shows in the reply composer only in Agent mode.
- **Recording context snapshot** — selected text, clipboard, screen OCR, the element under the
  pointer and the **writing destination** (app + browser site), captured at recording start.
- **Writing destination** — category of where text lands (email, chat, AI chat, notes, document,
  code, terminal). Adds prompt guidance and a deterministic paste rule (`WritingDestination`).
- **Agent tool loop** — `AgentToolExecutor.runLoop`: prompt-based JSON tool calls, max 14 steps.
  Tool list lives in `AgentToolCatalog.promptSection` (kept under 5k characters).
- **Quick intent** — requests answered without a model (`AgentQuickIntents`): open an app,
  "app not found" with suggestions, current time.
- **Control mode** — takeover / ask-before-action / observe-only. Loosening needs confirmation.
- **Pending action** — anything that really sends returns `confirm_required`; `confirm_action`
  on a *later* request executes it.
- **Background task** — a detached Agent run (`AgentTaskCenter`) scoped by `AgentRunScope`:
  no confirmations, questions, sends or notch state.
- **Nudge** — a reminder that fires when an app comes to the front and/or at a time
  (`AgentNudges`, `nudges.json`).
- **MCP server** — configured in `~/Library/Application Support/com.achyuthkp.VoxOS/mcp.json`
  (standard `mcpServers` format). stdio (`MCPConnection`) or Streamable HTTP
  (`MCPHTTPConnection`); tools appear as `mcp_<server>_<tool>`.
- **Claude Code bridge** — `ClaudeCodeBridge`, a listener on 127.0.0.1:47317 that Claude Code's
  hooks post to through curl (ADR 0006). Settings → Claude Code installs the hooks in
  `~/.claude/settings.json` (`ClaudeCodeHooks`) and removes them when switched off.
- **Claude Code notch** — `ClaudeCodeNotchManager`'s own panel: a card for a PermissionRequest
  (Allow, Deny, Always allow, Auto mode) or an AskUserQuestion (options, or "Other…" typed in),
  and, only if turned on, a band while a session works. Hidden while the recorder is up.
- **Notch Home** — `NotchHomeManager`'s panel on the notch between dictations (ADR 0007). Collapsed
  it is a **band** (one notice, timer or track) or a bare notch-sized target; hovering the notch
  opens the **card** with its **pages**: Music, Calendar, Reminders, Pomodoro, Shelf.
- **Live music bars** — bars driven by the real output through `SystemAudioLevels` (a Core Audio
  tap), in the band and on the Music page, only when the setting is on and `PowerState`
  allows: never in Low Power Mode, on battery only if allowed.
  Otherwise ambient.
- **Shelf** — files dropped on the notch, kept by path in `shelf.json`; details only when clicked.

## Invariants

- Audio transcription stays local; only text and context go to the chosen LLM.
- Nothing is sent to another person without a confirmation from a later request.
- Background runs never leave state for the foreground to act on.
- Timeouts around async work use `mcpRace`, never a TaskGroup (which waits for the loser).
- Registered defaults live in `AppDefaults.swift`; a code-level default is ignored if that file
  registers a different value.

## Build & test

`make local` (full build + install), `make test`. Live MCP check:
`TEST_RUNNER_VOXOS_LIVE_MCP=1 make test`. Chain build → test → commit → push with `&&`.
