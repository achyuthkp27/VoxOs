# ADR 0006 — Claude Code reaches the notch through local hooks

Status: accepted (2026-10-28)

Claude Code's hooks post every event to `http://127.0.0.1:47317/voxos/claude-code/hook` with
`/usr/bin/curl -sf … || true` command hooks; there is no helper binary. `type: "http"` hooks were
the first choice, but with VoxOS not running the CLI prints "hook error: connect ECONNREFUSED"
under every prompt and tool call; a curl that fails quietly prints nothing and the session never
waits on VoxOS. curl prints the bridge's JSON answer, which the CLI reads as the hook's output. Requests need the `X-VoxOS-Hook` header (a browser cannot add it
cross-origin without a preflight the bridge never answers) and a loopback `Host` (defeats DNS
rebinding).

Measured on Claude Code 2.1.312 before building, with both hook types, and the reason for the
design:
- The terminal permission dialog is drawn while the PermissionRequest hook is still waiting, so
  the notch and the terminal can both answer; whichever answers first wins.
- A hook reply of `decision.behavior = "allow"` runs the tool.
- "Yes" in the terminal leaves the hook's connection open, then sends PostToolUse with the
  `tool_use_id` of the PreToolUse sent just before the request (PermissionRequest itself carries
  no `tool_use_id`). "No" and Esc close the connection and send nothing else.

So a request leaves the notch on the matching PostToolUse, on a closed connection, on the end of
the session's turn, or after 590 s (the hook waits 600 s). Turning the integration on edits
`~/.claude/settings.json`; VoxOS hooks are identified only by their URL path, the user's own hooks
are never changed, and turning it off removes them.

Added the same day, also measured:
- A long Bash command allowed in the terminal sends PostToolUse only when it finishes, but the
  CLI starts it at once as its own child (`/bin/zsh -c source …/shell-snapshots/… <cmd>`). The
  hook passes the CLI's pid (`$PPID`), and VoxOS settles a waiting Bash request as soon as a new
  child like that appears, and drops a session whose CLI process has died (killed outright, it
  sends no SessionEnd and leaves its curl holding the request).
- The card offers the terminal dialog's choices: Allow, Deny, "Always allow" (echoes the request's
  `permission_suggestions` as `updatedPermissions`) and "Auto mode" (`setMode` auto, `session`).
- AskUserQuestion fires PermissionRequest too, while the terminal shows the question. Allowing with
  `updatedInput` = the questions plus an `answers` map answers it; multiple choices are joined
  with ", ". The notch shows the questions one at a time.
- ExitPlanMode fires PermissionRequest too, with the plan as markdown in `tool_input.plan`. The
  CLI's plan dialog maps onto hook answers: a plain allow runs the tool, whose own code returns the
  session to the mode it had before planning; "Yes, auto-accept edits" is `setMode` acceptEdits for
  the session; "No, keep planning" is a deny whose message carries what to change. The notch's plan
  card gives the same three.
- The transcript (`transcript_path`) says what hooks do not: `gitBranch` on every message line,
  `ai-title` and, after /rename, `custom-title` lines that are appended again later (last wins),
  and an Esc as a user message "[Request interrupted by user…]". Cards name the session by its
  folder, branch and title, read from the file's tail. Esc ends a turn with no hook, so while the
  working band is on, a working session's transcript is followed through a kernel file watch.
- A session's terminal app is the nearest regular app above its CLI (CLI, zsh, login, cmux). While
  it is in front, the terminal is already asking, so a request waits as a small band with a count
  until clicked; a CLI under tmux or ssh has no such app and keeps the card.
