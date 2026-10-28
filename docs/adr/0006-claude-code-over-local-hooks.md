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
