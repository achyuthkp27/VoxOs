# ADR 0002 — Real sends need a confirmation from a later request

Status: accepted (2026-09-11)

`messages_send`, and mail/Gmail/Slack with `send: true`, store an `AgentPendingAction` and
return `confirm_required`. Only `confirm_action` in a later run executes it; loosening the
control mode uses the same gate. Injected text and the model itself cannot self-confirm.
