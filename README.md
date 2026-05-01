# Caretta Symphony

Caretta Symphony runs many Codex agents from Linear, across many repositories, with a live dashboard for the whole queue.

It is an independent Elixir implementation of OpenAI's draft [Symphony service specification](https://github.com/openai/symphony/blob/main/SPEC.md). OpenAI defined the core pattern: poll Linear, create an isolated workspace, run a coding agent, and reconcile the issue state. Caretta Symphony keeps that model and adds the operating layer we needed for a real multi-repo product.

The core value is control: get the work out of the issue tracker, put each agent in the right repos, and see what all of them are doing while they run.

> [!WARNING]
> Caretta Symphony is early automation software for trusted engineering environments. Review your workflow, sandbox, repository, and credential settings before running it on untrusted issues or repositories.

## What Caretta adds

### Live agent dashboard

Symphony can run several agents at once. The dashboard shows them in one place: running agents, queued continuations, retries, blocked work, completed work, token totals, recent activity, and the repository plan for each issue.

When summaries are enabled, Symphony runs a lightweight LLM summary over recent agent events. Each card gets a short live summary, the current step, risk, confidence, and whether a human should step in.

### Multi-repo workspaces

The original Symphony pattern is cleanest when a task fits in one repository. Many teams do not work that way. A single issue may touch a desktop app, a web app, shared contracts, backend services, and model routing.

Caretta Symphony lets you define a repository catalog. Before Codex starts, Symphony chooses:

- a primary repository
- secondary repositories Codex may edit
- read-only repositories for context

Each issue gets its own workspace:

```text
.symphony-workspaces/ENG-251/
  repo-plan.json
  .symphony-workspace.json
  repos/
    desktop-runtime/
    shared-contracts/
    model-gateway/
```

The repo plan is injected into the agent prompt so Codex starts in the right place and knows which repos are editable.

### Git branch safety

Each planned repo is checked out on a Symphony-prepared branch derived from the issue key and repo name. Symphony installs a workspace-local `pre-push` guard that refuses pushes from the wrong branch, pushes to the wrong remote ref, and remote branch deletes.

This is the main safety feature for multi-repo work. Agents can work across repos without accidentally pushing inherited local branches.

### Linear MCP mode

Caretta Symphony can use Codex app-server's Linear MCP gateway instead of a raw Linear API key. That lets a connected Codex Linear session read issues, update workpads, and move issue states.

Raw Linear GraphQL mode is also supported.

### Review gate

Agents hand work to a review state. Symphony can move an issue to `Done` only after the required GitHub pull requests are merged into the configured base branch.

While an issue is in a review state, Symphony also polls Linear comments and linked GitHub PR feedback. New human-authored feedback moves the issue to the configured `rework_state` so Codex can continue from the existing workspace.

### Blocked issue escalation

When an agent or repository plan cannot continue without human input, Symphony creates or updates one Linear comment headed `## Symphony Blocked Escalation`. It mentions the Linear assignee when the tracker payload includes one; otherwise it uses `tracker.blocked_escalation_mentions`. A later human comment on the issue releases the block so the normal dispatcher can retry.

## Relationship to OpenAI Symphony

OpenAI's `openai/symphony` repository contains a language-agnostic spec and an experimental Elixir implementation.

Caretta Symphony is not an official OpenAI project. It does not include OpenAI's reference implementation code. It implements the public Symphony spec in Elixir and extends it for:

- multi-repo product work
- repo planning before dispatch
- branch-safe agent workspaces
- Linear MCP operation
- a local dashboard with LLM-generated live summaries
- GitHub review-state reconciliation

## Install

```bash
mix deps.get
mix escript.build
```

## Run

Create a `WORKFLOW.md`:

```markdown
---
tracker:
  kind: linear_mcp
  team: Platform Automation
  active_states: ["Todo", "In Progress", "Rework", "Merging"]
  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  review_states: ["In Review", "Merging"]
  handoff_state: In Review
  rework_state: Rework
  done_state: Done
  merge_base_branch: dev
  blocked_escalation_enabled: true
  blocked_escalation_mentions: ["@operator"]
  required_labels: ["codex"]
  mcp_command: /Applications/Codex.app/Contents/Resources/codex app-server
workspace:
  root: ./.symphony-workspaces
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: /Applications/Codex.app/Contents/Resources/codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
server:
  port: 8765
self_healing:
  enabled: false
  base_branch: main
  branch_prefix: codex/self-heal
  workspace_root: ./.symphony-self-heal
  stale_poll_ms: 120000
  cooldown_ms: 900000
  max_attempts: 3
  validation_commands:
    - mix format --check-formatted
    - mix test
    - mix escript.build
  codex:
    model: gpt-5.5
    effort: xhigh
    approval_policy: never
    thread_sandbox: workspace-write
    turn_sandbox_policy:
      type: workspaceWrite
      networkAccess: true
  restart:
    tmux_session: symphony-elixir
    port: 8765
    workflow_path: ./WORKFLOW.md
context:
  coding:
    enabled: true
    classifier: rules
    classification_fallback: inject
    skill_paths:
      - ./docs/IMPLEMENTATION.md # Replace with your architecture or repo-map notes.
    label_triggers: ["codex"]
    keyword_triggers: ["implement", "fix", "bug", "feature", "integration", "repo"]
dashboard:
  summaries:
    enabled: true
    update_interval_ms: 30000
repositories:
  enabled: true
  planner: llm
  fallback: rules
  base_branch: dev
  branch_prefix: Symphony
  known:
    - slug: ExampleOrg/desktop-runtime
      local_path: /opt/symphony/example-repos/client/desktop-runtime
      remote_url: https://github.com/ExampleOrg/desktop-runtime.git
      aliases: ["desktop", "runtime", "overlay", "local capture"]
      description: Desktop shell and live-session runtime.
    - slug: ExampleOrg/shared-contracts
      local_path: /opt/symphony/example-repos/libs/shared-contracts
      aliases: ["schemas", "types", "API contracts"]
      description: Shared contracts and helpers used across services.
    - slug: ExampleOrg/model-gateway
      local_path: /opt/symphony/example-repos/platform/model-gateway
      remote_url: https://github.com/ExampleOrg/model-gateway.git
      aliases: ["LLM gateway", "provider routing", "prompts"]
      description: Model gateway config, prompts, schemas, and provider routing.
---
Implement the Linear issue below.

Issue: {{ issue.identifier }} - {{ issue.title }}

{{ issue.description }}
```

Start Symphony:

```bash
./symphony WORKFLOW.md --port 8765
```

Open `http://127.0.0.1:8765` for the dashboard.

For a larger anonymized workflow, see [`WORKFLOW.linear-mcp.example.md`](WORKFLOW.linear-mcp.example.md). For macOS background operation, adapt [`launchd/com.symphony.linear-mcp.example.plist`](launchd/com.symphony.linear-mcp.example.plist).

## Self-healing watchdog

Symphony can run a separate local watchdog when `self_healing.enabled: true` is configured. The watchdog polls `GET /api/v1/state`; when Symphony is unreachable, degraded, or stale, it runs a high-reasoning Codex repair agent in `.symphony-self-heal/worktrees/<run-id>`, validates the repair, deploys the validated escript artifact locally, restarts the managed tmux session, pushes a `codex/self-heal/...` branch, opens a ready PR into `main`, and requests GitHub auto-merge without bypassing branch protection.

Local deployment intentionally comes from the validated artifact, not from `main`. The PR is the audit and sync path back to GitHub.

Useful commands:

```bash
./symphony WORKFLOW.md --watchdog
./symphony WORKFLOW.md --self-heal-once --reason "manual diagnosis"
./symphony WORKFLOW.md --restart-managed
```

On macOS, `scripts/symphony-managed.sh` and `launchd/com.caretta.symphony.watchdog.plist` provide a launcher path that goes through `/bin/zsh -lc`, which avoids direct launchd escript startup failures.

The managed launcher resolves the executable in this order: `SYMPHONY_EXECUTABLE`, the validated self-heal deployment at `.symphony-self-heal/deploy/current/symphony`, then the local `./symphony` build artifact. It fails before invoking escript if none of those paths is executable, so generated build artifacts are never assumed to exist after checkout or cleanup.

## Status API

When `server.port` is set, Symphony exposes:

- `GET /`
- `GET /api/v1/state`
- `GET /api/v1/<issue_identifier>`
- `POST /api/v1/refresh`

The status surface is unauthenticated. Keep `server.host` bound to `127.0.0.1` unless you put it behind your own access controls.

## Testing

```bash
mix test
```

## Project layout

- `lib/symphony/` - service implementation
- `test/` - ExUnit coverage
- `mix.exs` - Elixir project metadata and escript configuration
- `docs/IMPLEMENTATION.md` - implementation notes and conformance summary
- `WORKFLOW.linear-mcp.example.md` - anonymized multi-repo Linear MCP workflow
- `launchd/` - example macOS launch agent

## Security posture

The example workflow is high-trust. It uses `approval_policy: never`, `workspace-write` sandboxing, and network access for agent turns.

Tighten Codex approval and sandbox settings before using Symphony with untrusted tracker data, repositories, hooks, or credentials. The branch guard helps prevent wrong-branch pushes, but it is not a sandbox.

## License

Caretta Symphony is licensed under the [Apache License 2.0](LICENSE).
