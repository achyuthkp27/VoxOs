# ADR 0003 — MCP instead of per-service OAuth

Status: accepted (2026-09-15)

Notion, Drive, Gmail and similar services are reached through MCP servers rather than bespoke
OAuth clients. VoxOS implements the MCP client (stdio and Streamable HTTP with header auth).
Tools a server marks `readOnlyHint` bypass the control-mode gate; all others are mutating.
Browser sign-in (OAuth) for remote servers is not implemented.
