# Symphony Implementation Notes

This implementation follows the core conformance checklist in the draft spec.

Implemented:

- explicit or default `WORKFLOW.md` discovery
- optional YAML front matter plus Markdown prompt body parsing
- typed config defaults, validation, `$VAR` indirection, and path normalization
- dynamic workflow reload with last-known-good config retention and dispatch blocking on invalid reloads
- Linear reader operations for candidates, terminal-state cleanup, and running-state reconciliation
- OAuth-backed Linear MCP reader extension via Codex app-server (`tracker.kind: linear_mcp`)
- review-state reconciliation that moves Linear issues to `Done` only after required GitHub PRs are merged into the configured base branch
- required label gating via `tracker.required_labels`
- deterministic sanitized workspaces below `workspace.root`
- workspace hooks with timeout handling and spec-defined fatal/best-effort behavior
- strict Liquid prompt rendering with `issue` and `attempt`
- Codex app-server subprocess integration using JSON-RPC JSONL over stdio
- continuation turns on the same thread during a worker lifetime
- retry queue with continuation retries and exponential failure backoff
- reconciliation that cancels terminal/non-active/stalled runs
- startup terminal workspace cleanup
- structured key=value logging
- optional HTTP status and refresh API

Implementation-defined choices:

- existing non-directory workspace paths fail safely
- secrets are validated by presence only and are not logged
- no durable database is used; retry/running state is in-memory
- `tracker.kind: linear_mcp` uses Codex app-server's `mcpServer/tool/call` gateway and the configured `tracker.mcp_server`/`tracker.mcp_command`
- `linear_mcp` uses the issue identifier as the internal issue ID because the Linear connector list output does not expose the Linear GraphQL UUID
- `linear_graphql` dynamic tool calls are handled if the agent app-server asks for them, but dynamic tool advertisement is not enabled because the generated schema for the installed Codex app-server version does not expose `dynamicTools` on `thread/start`
- app-server tool approval prompts are auto-answered with `Approve this Session` when available; other tool input prompts receive a standard non-interactive fallback answer
