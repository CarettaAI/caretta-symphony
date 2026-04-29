# Caretta Symphony

Caretta Symphony is a Python implementation of OpenAI's draft [Symphony service specification](https://github.com/openai/symphony/blob/main/SPEC.md).

Symphony turns project work into isolated, autonomous implementation runs. It watches Linear for eligible issues, creates a per-issue workspace, launches Codex in app-server mode, and keeps the agent working until the issue reaches the workflow-defined handoff state.

> [!WARNING]
> Caretta Symphony is early automation software for trusted engineering environments. Review the workflow, sandbox, repository, and credential settings before running it on untrusted issues or repositories.

## Relationship to OpenAI Symphony

OpenAI's `openai/symphony` repository provides two things:

1. A language-agnostic `SPEC.md` that defines the service layers and behavior.
2. An experimental Elixir/OTP implementation intended as a reference and evaluation prototype.

Caretta Symphony follows the same core model:

- Poll Linear for candidate work.
- Create or reuse an isolated workspace per issue.
- Render a repository-owned `WORKFLOW.md` prompt.
- Launch Codex in app-server mode inside the workspace.
- Stream Codex events back into an orchestrator.
- Reconcile issue state, retry transient failures, and stop runs that are no longer eligible.
- Expose structured logs and an optional local status surface.

This project is not an official OpenAI project. It is an independent Python implementation built from the public Symphony specification.

## What's different

Caretta Symphony keeps the core Symphony shape, then adds production-oriented policy around the places where real agent operations tend to need more structure.

- **Python runtime**: standard-library asyncio service with a small dependency set.
- **Linear MCP mode**: can read and update Linear through Codex app-server's MCP gateway, so a connected Codex Linear session can be used instead of a raw Linear API key.
- **Repository planning**: asks a lightweight planner to choose the primary repo, editable secondary repos, and read-only context repos from a configured repo catalog.
- **Multi-repo workspaces**: checks out selected repositories under `repos/`, records `repo-plan.json`, and quarantines incompatible legacy workspaces.
- **Branch safety**: installs a pre-push guard so agents can only push the Symphony-prepared branch for each repo.
- **Coding context injection**: can inject configured Codex skills into coding issues, with rules-based, always-on, or LLM-based classification.
- **Continuation turns**: sends a fresh Linear issue snapshot on continuation instead of replaying the original task.
- **Review gate**: agents hand off completed PR work to a review state; Symphony can move the issue to `Done` only after required GitHub PRs are merged into the configured base branch.
- **Dashboard summaries**: optional local status API and HTML dashboard with runtime counts, recent activity, token totals, and LLM-generated run summaries.
- **Delivery fallback**: if an in-agent Linear write is rejected after work is complete, the orchestrator can perform a tracker-owned workpad/state handoff.

## How it works

1. Load `WORKFLOW.md`.
2. Resolve typed runtime config from YAML front matter.
3. Poll Linear for issues in active states.
4. Apply dispatch gates such as labels, blockers, concurrency, and current issue state.
5. Create a deterministic workspace for each issue.
6. Optionally plan and materialize the repository set for that issue.
7. Launch `codex app-server` in the workspace.
8. Send the rendered workflow prompt to Codex.
9. Track events, token usage, retries, summaries, and stalls.
10. Release the claim when the issue leaves active states or reaches a terminal state.

## Install

```bash
python3 -m pip install -e ".[dev]"
```

## Run

Create a `WORKFLOW.md` in the repository you want Symphony to run from:

```markdown
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: my-project
  active_states: ["Todo", "In Progress", "Rework", "Merging"]
  review_states: ["In Review", "Merging"]
  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  handoff_state: In Review
  done_state: Done
  merge_base_branch: dev
  required_labels: ["codex"]
workspace:
  root: ./.symphony-workspaces
agent:
  max_concurrent_agents: 3
  max_turns: 20
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

Then start the service:

```bash
symphony WORKFLOW.md
```

If no path is supplied, `symphony` uses `./WORKFLOW.md`.

## Linear MCP mode

If the Linear connector is enabled in Codex, Symphony can use Codex app-server's MCP gateway instead of a raw Linear API key:

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

`linear_mcp` uses the Linear issue identifier, for example `ENG-136`, as the stable issue ID because the connector list response does not expose Linear's GraphQL UUID.

## Repository planning

With `repositories.enabled: true`, Symphony chooses a repo plan before Codex starts. The selected repositories are checked out under the issue workspace:

```text
.symphony-workspaces/ENG-251/
  repo-plan.json
  .symphony-workspace.json
  repos/
    desktop-runtime/
    model-gateway/
```

If an existing workspace is a legacy single-repo checkout or contains a planned repo with the wrong remote, Symphony quarantines it under `_quarantine/` before creating the planned layout.

## Status API

Set `server.port` in `WORKFLOW.md` or pass `--port`:

```bash
symphony WORKFLOW.md --port 8765
```

Endpoints:

- `GET /`
- `GET /api/v1/state`
- `GET /api/v1/<issue_identifier>`
- `POST /api/v1/refresh`

The status surface is unauthenticated and is intended for local trusted operation. Keep `server.host` bound to `127.0.0.1` unless you put it behind your own access controls.

## macOS background operation

For launchd-based background operation, adapt [`launchd/com.symphony.linear-mcp.example.plist`](launchd/com.symphony.linear-mcp.example.plist). The file is illustrative; replace every path and command with your local installation layout.

## Project layout

- `symphony/`: service implementation
- `tests/`: pytest coverage for workflow parsing, tracker clients, workspace materialization, orchestration, Codex app-server behavior, and review gating
- `docs/IMPLEMENTATION.md`: implementation notes and conformance summary
- `WORKFLOW.linear-mcp.example.md`: larger real-world-style workflow example with anonymized repos
- `launchd/`: example macOS launch agent

## Testing

```bash
python3 -m pytest
```

## Security posture

This implementation is designed for trusted automation environments. Its default posture in the example workflow is high-trust:

- `approval_policy: never`
- `thread_sandbox: workspace-write`
- `turn_sandbox_policy: {"type": "workspaceWrite", "networkAccess": true}`
- app-server approval prompts are answered for the session when the configured policy allows it
- workspace and repository paths are normalized before use
- branch guards prevent pushing unexpected refs from agent workspaces

Tighten Codex approval and sandbox settings before using Symphony with untrusted tracker data, repositories, hooks, or credentials.

## License

Caretta Symphony is licensed under the [Apache License 2.0](LICENSE).

The OpenAI Symphony project is also licensed under Apache-2.0. This project implements OpenAI's public Symphony specification and does not include OpenAI's reference implementation code.
