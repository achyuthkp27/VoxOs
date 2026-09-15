# ADR 0001 — Prompt-based JSON tool calls

Status: accepted (2026-08-29)

VoxOS supports many providers, several without native tool calling (Ollama, local CLIs). The
Agent prompt carries `VOXOS AGENT PROTOCOL` plus a tool catalogue; the model answers with one
JSON tool call; `AgentToolExecutor` runs it, appends `TOOL_RESULT`, and loops.

Consequences: identical behaviour on every provider. The catalogue is injected at request time
(seeded prompts go stale) and must stay small, because every step re-sends it and hosted free
tiers throttle on tokens per minute.
