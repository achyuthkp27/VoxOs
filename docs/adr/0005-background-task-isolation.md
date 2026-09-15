# ADR 0005 — Background tasks are isolated from the notch

Status: accepted (2026-09-15)

Background Agent runs share tools but not per-request state. A task-local
`AgentRunScope.isBackground` blocks confirm/cancel, `wait_for_user`, nested background tasks,
real sends, control-mode changes, and mutating tools under ask-before-acting. Background runs
never call `AgentPendingAction.beginRun()` — doing so would let a foreground model confirm its
own pending action — and never write progress, cards or paused-task state.
