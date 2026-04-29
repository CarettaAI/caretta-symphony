# Symphony Runner

This is a Python reference implementation of the draft Symphony service specification:
https://github.com/openai/symphony/blob/main/SPEC.md

It implements the core daemon layers: `WORKFLOW.md` parsing and reload, typed config resolution, Linear issue reads, per-issue workspaces and hooks, Codex app-server JSONL orchestration, retry/reconciliation logic, structured logs, and an optional local status API.

## Install

```bash
python3 -m pip install -e ".[dev]"
```

## Workflow File

Create `WORKFLOW.md` in the repository you want Symphony to run from:

```markdown
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: my-project
  active_states: ["Todo", "In Progress", "Rework", "Merging"]
  review_states: ["In Review", "Merging"]
  handoff_state: In Review
  done_state: Done
  merge_base_branch: dev
  required_labels: ["codex"]
workspace:
  root: ./.symphony-workspaces
agent:
  max_concurrent_agents: 3
codex:
  command: codex app-server
  effort: medium
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
server:
  port: 8765
context:
  coding:
    enabled: true
    classifier: llm
    classification_fallback: inject
    skill_paths:
      - /opt/symphony/skills/platform-architecture
    label_triggers: ["codex"]
dashboard:
  summaries:
    enabled: true
    update_interval_ms: 30000
repositories:
  enabled: true
  planner: llm
  fallback: rules
  block_on_needs_human: true
  known:
    - slug: ExampleOrg/desktop-runtime
      local_path: /opt/symphony/example-repos/client/desktop-runtime
      remote_url: https://github.com/ExampleOrg/desktop-runtime.git
      aliases: ["desktop", "electron", "overlay", "live workflow", "suggestions"]
      description: Desktop live-session runtime and proactive suggestion surface.
    - slug: ExampleOrg/model-gateway
      local_path: /opt/symphony/example-repos/platform/model-gateway
      remote_url: https://github.com/ExampleOrg/model-gateway.git
      aliases: ["LLM gateway", "gateway", "prompt schema", "provider routing"]
      description: Hosted model gateway config, schemas, prompts, provider routing, and infra.
---
Implement the Linear issue below.

Issue: {{ issue.identifier }} - {{ issue.title }}

{{ issue.description }}
```

Then run:

```bash
symphony WORKFLOW.md
```

If no positional path is supplied, `symphony` uses `./WORKFLOW.md`. Do not pass `--once` for normal operation; without it, Symphony keeps polling until the process is stopped.

### Using the Linear MCP Connector

If the Linear connector is enabled in Codex, Symphony can read issues through Codex app-server's MCP gateway instead of a raw Linear API key:

```yaml
tracker:
  kind: linear_mcp
  project_slug: Q3 Platform Reliability
  team: Platform Automation
  active_states: ["Todo", "In Progress", "Rework", "Merging"]
  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  review_states: ["In Review", "Merging"]
  handoff_state: In Review
  done_state: Done
  merge_base_branch: dev
  required_labels: ["codex"]
  mcp_command: /Applications/Codex.app/Contents/Resources/codex app-server
  mcp_server: codex_apps
```

`linear_mcp` is an implementation extension. It uses the connected Linear OAuth session exposed by `codex app-server`, and it uses the Linear issue identifier, for example `ENG-136`, as Symphony's stable issue ID because the connector tool does not expose Linear's GraphQL UUID in list responses.

`tracker.required_labels` is a hard dispatch and reconciliation gate. With `["codex"]`, Symphony ignores active issues that do not have the `codex` label and stops an in-flight worker if that label is removed.

`context.coding` injects a configured Codex skill into the first prompt for issues classified as coding work. Set `classifier: llm` to run a short Codex classifier turn over the current Linear issue before deciding whether to inject the skill. `classification_fallback: inject` is the safer default because a false negative is worse than giving a non-coding task extra architecture context. `classifier: rules` keeps the older label/keyword behavior, and `classifier: always` injects context for every dispatched issue.

On continuation turns, Symphony sends a fresh Linear issue snapshot, including the current description, labels, state, URL, and `updated_at`. If an issue changes while an agent is already running, the continuation prompt tells the agent that the current Linear text overrides earlier assumptions.

The dashboard at `/` shows service status, running agents, continuation queues, failure retries, blocked issues, token totals, recent activity, and an LLM-generated work summary for each active agent. A clean worker exit appears as `Continuing`, because Symphony re-checks the issue after a short delay and only releases the claim when the issue is no longer eligible. Keep the configured handoff state out of `tracker.active_states`; moving an issue there is how the agent delivers work and releases the Symphony claim. By default agents hand off completed PR work to `In Review`; Symphony moves review-state issues to `Done` only after all required GitHub PRs are merged into `tracker.merge_base_branch`. Dashboard summaries are throttled by `dashboard.summaries.update_interval_ms` and include whether the issue appears to need human attention.

`repositories` makes repo selection explicit before Codex starts. With `planner: llm`, Symphony asks a short planning turn to choose a primary repo, optional secondary repos, and read-only context repos from `repositories.known`. The selected repos are checked out under the issue workspace:

```text
.symphony-workspaces/ENG-251/
  repo-plan.json
  repos/
    desktop-runtime/
    model-gateway/
```

If an existing issue workspace is a legacy single-repo checkout or contains a planned repo with the wrong remote, Symphony quarantines it under `_quarantine/` before creating the planned multi-repo layout. If the planner cannot identify a clear primary repo and `block_on_needs_human` is true, the issue is blocked before Codex edits files and the dashboard shows the repo-plan reason.

For macOS background operation, adapt [launchd/com.symphony.linear-mcp.example.plist](launchd/com.symphony.linear-mcp.example.plist). It is an example file only; installing it into `~/Library/LaunchAgents` will make launchd keep Symphony running.

## Status API

The optional HTTP status surface starts when `--port` is passed or `server.port` is set in the workflow front matter.

```bash
symphony WORKFLOW.md --port 8765
```

Endpoints:

- `GET /`
- `GET /api/v1/state`
- `GET /api/v1/<issue_identifier>`
- `POST /api/v1/refresh`

## Security Posture

This implementation is designed for trusted automation environments. Its default Codex posture is:

- `approval_policy: never`
- `thread_sandbox: workspace-write`
- `turn_sandbox_policy: {"type": "workspaceWrite", "networkAccess": true, "writableRoots": [workspace_path]}`
- app-server command/file approval prompts are answered with `acceptForSession`
- app-server tool approval prompts are answered with `Approve this Session` when that option is available
- generic app-server tool input prompts receive a non-interactive fallback answer so unattended MCP calls do not stall

The workspace root and per-issue workspace path are still validated before launch, and the Codex process is only started with the per-issue workspace as `cwd`. Tighten the Codex approval/sandbox settings in `WORKFLOW.md` before using this with untrusted tracker data, repositories, hooks, or credentials.
