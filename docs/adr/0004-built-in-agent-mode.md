# ADR 0004 — The Agent mode is built in

Status: accepted (2026-09-15)

After an app-data reset left users without the Agent, it stopped being an optional starter
mode. `AgentModeGuard` recreates it, re-enables it, re-seeds its prompt and moves it to a
connected chat-capable provider (never VoxOS Refine) on launch, after onboarding and on ⌃⌃.
The Delete button is hidden and `removeConfiguration` refuses it.
