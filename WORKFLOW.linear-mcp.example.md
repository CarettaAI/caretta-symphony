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
  mcp_server: codex_apps
workspace:
  root: ./.symphony-workspaces
agent:
  max_concurrent_agents: 5
  max_turns: 20
  max_retry_backoff_ms: 300000
codex:
  command: /Applications/Codex.app/Contents/Resources/codex app-server
  effort: medium
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
    command: /Applications/Codex.app/Contents/Resources/codex app-server
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
    classifier: llm
    classification_fallback: inject
    classifier_effort: low
    classification_timeout_ms: 120000
    skill_paths:
      - /opt/symphony/skills/platform-architecture
    label_triggers: ["codex"]
    keyword_triggers: ["implement", "fix", "bug", "feature", "integration", "UI", "API", "provider", "repo", "code", "web search", "transcription", "chat", "documents", "knowledge base"]
    max_chars: 50000
dashboard:
  summaries:
    enabled: true
    update_interval_ms: 30000
    timeout_ms: 120000
    max_events: 60
    max_chars: 14000
    effort: low
repositories:
  enabled: true
  planner: llm
  fallback: rules
  block_on_needs_human: true
  quarantine_on_mismatch: true
  clone_timeout_ms: 300000
  base_branch: dev
  branch_prefix: Symphony
  known:
    - slug: ExampleOrg/desktop-runtime
      local_path: /opt/symphony/example-repos/client/desktop-runtime
      remote_url: https://github.com/ExampleOrg/desktop-runtime.git
      aliases: ["desktop-runtime", "electron shell", "overlay", "live workflow", "local transcription", "runtime orchestrator"]
      description: Desktop shell and live in-call runtime; local capture, transcript batching, in-app suggestions, and host-side provider calls. Do not choose this for saved-call history pages, post-call detail tabs, or follow-up email drafts unless the issue explicitly says desktop overlay or live runtime.
    - slug: ExampleOrg/web-console
      local_path: /opt/symphony/example-repos/product/web-console
      remote_url: https://github.com/ExampleOrg/web-console.git
      aliases: ["web-console", "web app", "Next.js", "onboarding", "settings", "history", "history tab", "post-call", "saved call", "call details", "follow-up email", "email draft", "calendar", "CRM", "in-app assistant"]
      description: Customer-facing web console, authenticated routes, calendar/CRM settings, saved-call history views, post-call detail tabs, follow-up email drafts/templates, folders, and browser-side gateway proxy.
    - slug: ExampleOrg/shared-contracts
      local_path: /opt/symphony/example-repos/libs/shared-contracts
      aliases: ["shared-contracts", "shared schema", "shared types", "API contracts"]
      description: Shared contracts, schemas, helpers, and utilities consumed by desktop, web, and worker services.
    - slug: ExampleOrg/assistant-engine
      local_path: /opt/symphony/example-repos/services/assistant-engine
      remote_url: https://github.com/ExampleOrg/assistant-engine.git
      aliases: ["assistant-engine", "chat runtime", "async agent", "automation", "daily brief", "trusted route"]
      description: Chat API behavior, async agent workers, automations, prompt composition, and assistant runtime modules.
    - slug: ExampleOrg/knowledge-service
      local_path: /opt/symphony/example-repos/services/knowledge-service
      remote_url: https://github.com/ExampleOrg/knowledge-service.git
      aliases: ["knowledge-service", "knowledge ingestion", "meeting imports", "CRM import", "org knowledge", "vector sync"]
      description: Knowledge ingestion service, transcript FAQ extraction, integration ingestion, and organization knowledge upserts.
    - slug: ExampleOrg/knowledge-docs
      local_path: /opt/symphony/example-repos/content/knowledge-docs
      remote_url: https://github.com/ExampleOrg/knowledge-docs.git
      aliases: ["knowledge-docs", "KB documents", "document packs", "sales playbooks", "RAG eval"]
      description: Document and knowledge-base tooling; scripts and helpers for building, splitting, evaluating, and uploading product knowledge packs.
    - slug: ExampleOrg/model-gateway
      local_path: /opt/symphony/example-repos/platform/model-gateway
      remote_url: https://github.com/ExampleOrg/model-gateway.git
      aliases: ["model-gateway", "LLM gateway", "prompt schema", "provider routing", "terraform"]
      description: Hosted model gateway configuration, prompt/schema files, provider routing, auth, API gateway, and infrastructure code.
    - slug: ExampleOrg/briefing-api
      local_path: /opt/symphony/example-repos/services/briefing-api
      remote_url: https://github.com/ExampleOrg/briefing-api.git
      aliases: ["briefing-api", "pre-call briefing", "CRM briefing", "web enrichment", "company enrichment"]
      description: AI-powered call briefings, CRM enrichment, vector retrieval, and external enrichment providers.
    - slug: ExampleOrg/messaging-app
      local_path: /opt/symphony/example-repos/integrations/messaging-app
      remote_url: https://github.com/ExampleOrg/messaging-app.git
      aliases: ["messaging-app", "Slack app", "OAuth install", "DMs", "events"]
      description: Messaging integration on serverless functions, install/OAuth, DMs, mentions, events, and scheduling plumbing.
    - slug: ExampleOrg/ops-dashboard
      local_path: /opt/symphony/example-repos/ops/dashboard
      remote_url: https://github.com/ExampleOrg/ops-dashboard.git
      aliases: ["ops-dashboard", "KPI dashboard", "cohort filters", "reporting"]
      description: Internal KPI dashboard and server-side reporting queries.
    - slug: ExampleOrg/metrics-console
      local_path: /opt/symphony/example-repos/ops/metrics-console
      remote_url: https://github.com/ExampleOrg/metrics-console.git
      aliases: ["metrics-console", "Svelte metrics", "metrics app"]
      description: Lightweight metrics console for operational telemetry and QA sampling.
    - slug: ExampleOrg/transcript-lab
      local_path: /opt/symphony/example-repos/tools/transcript-lab
      remote_url: https://github.com/ExampleOrg/transcript-lab.git
      aliases: ["transcript-lab", "transcript viewer", "insight viewer"]
      description: Tooling for inspecting insight and transcript behavior, not production runtime changes.
    - slug: ExampleOrg/speech-ingress
      local_path: /opt/symphony/example-repos/services/speech-ingress
      remote_url: https://github.com/ExampleOrg/speech-ingress.git
      aliases: ["speech-ingress", "ASR ingress", "remote ASR"]
      description: Speech ingress and hosted recognition service behavior.
    - slug: ExampleOrg/transcription-proxy
      local_path: /opt/symphony/example-repos/services/transcription-proxy
      remote_url: https://github.com/ExampleOrg/transcription-proxy.git
      aliases: ["transcription-proxy", "remote transcription", "hosted transcription"]
      description: Remote transcription deployment and service runtime.
---
You are working on a Linear issue in an unattended Symphony run.

Issue: {{ issue.identifier }} - {{ issue.title }}
URL: {{ issue.url }}
Priority: {{ issue.priority }}
State: {{ issue.state }}
Labels: {% for label in issue.labels %}{{ label }}{% unless forloop.last %}, {% endunless %}{% endfor %}

{% if attempt %}
Continuation context:

- This is retry/continuation attempt #{{ attempt }} because the issue was still in an active state.
- Resume from the current workspace and Linear workpad state. Do not restart from scratch.
- Do not end the turn while the issue is still `Todo`, `In Progress`, `Rework`, or `Merging` unless a true external blocker remains.
{% endif %}

Description:
{{ issue.description }}

## Delivery Contract

Symphony only releases the issue when it leaves the configured active states. Your work is not delivered until you update Linear and move the issue to the correct handoff state.

- Use the Linear MCP connector/tools available in Codex to read and update the issue.
- If a Linear MCP write asks for approval, approve it for the session and continue.
- Keep exactly one persistent Linear comment headed `## Codex Workpad`; create it if missing and update that same comment in place.
- Use the workpad for plan, acceptance criteria, validation results, PR/commit status, blockers, and final handoff notes.
- Do not post separate completion summary comments.
- Final assistant message should report completed actions and blockers only. Do not ask the human to do routine follow-up work.

## Credentialed And Data Operations

- You run under the same macOS user context as Symphony. Before declaring missing non-GitHub auth, inspect configured local auth and secret sources without printing secret values:
  - `which supabase && supabase projects list`
  - `which aws && aws sts get-caller-identity`
  - local repo `.env*` files, Vercel env, AWS Secrets Manager/SSM names, Supabase project links, and connected MCP tools when relevant.
- Never paste secret values into Linear, PRs, terminal summaries, or final messages. Load credentials into the command environment or an untracked temporary file only when required for the operation.
- For Supabase/Postgres data migrations, a PR or migration script alone is not completion. Record dry-run output and either apply output or a concrete verified reason the data operation must not be run.
- If the issue explicitly asks to move, copy, backfill, delete, or repair production rows or cloud resources, do not move it to `In Review` just because code was written. Move it to `In Review` only after the operation has been executed and verified, or after the requester explicitly converts the issue to a code-only preparatory task.

## State Routing

- `Backlog`: out of scope. Do not modify the issue. Stop.
- `Todo`: immediately move the issue to `In Progress`, create/update the workpad, then execute the task.
- `In Progress`: continue from the existing workpad and workspace.
- `Rework`: read all issue and PR feedback, update the workpad with the rework plan, address feedback, revalidate, push, and return to `In Review`.
- `Merging`: follow the repository's merge/land instructions. After the PR is merged, update the workpad; Symphony's merge gate moves the issue to `Done`.
- `Done`: terminal. Do nothing.

## Execution Flow

1. Fetch the current Linear issue by `{{ issue.identifier }}` and confirm its state, labels, description, comments, and links.
2. Follow the injected Symphony repo plan. Start in the primary repo, use secondary repos only when the plan allows it, and do not edit read-only context repos.
3. Reconcile the `## Codex Workpad` before editing code:
   - check off completed work,
   - add or refine the implementation plan,
   - mirror any issue-provided validation/test-plan items as required checklist items,
   - record a compact environment stamp with host, absolute workspace path, and short commit SHA when available.
4. Reproduce or inspect the current behavior enough to make the fix target explicit, then implement the requested change. For credentialed data or cloud operations, prove the access path first using configured CLIs, local env files, or secret stores, then run the required dry-run/apply or read-only verification without exposing secrets.
5. Run validation appropriate to the changed surface. Treat issue-provided validation instructions as mandatory.
6. Commit and push only the Symphony-prepared branch recorded in `.symphony-workspace.json` when changes are ready. Never push an inherited source checkout branch; if the current branch differs from the expected branch, stop and report the mismatch. Open or update the PR and attach/link the PR to the Linear issue. Prefer Linear attachments/links; use the workpad only if attachments are unavailable.
7. Before handoff, sweep existing PR feedback and checks:
   - address or explicitly respond to actionable comments,
   - confirm checks/validation are green or document a real external blocker,
   - refresh the workpad so plan, acceptance criteria, validation, commit, and PR status match reality.
8. Move the issue to `In Review` only after the handoff bar below is satisfied. If blocked by missing non-GitHub auth, permissions, or required tooling after checking the configured local CLIs/env/secret stores, document the blocker in the workpad, leave the issue active, and report the blocker in the final message. `Done` is reserved for Symphony's merge gate after every required PR has merged into `dev`.

## Handoff Bar Before `In Review`

- Workpad exists and is current.
- Implementation is complete for the issue scope.
- Required validation/test-plan items are complete and recorded.
- For credentialed data or cloud operations, the requested operation is executed and verified, with dry-run/apply output or read-only verification recorded. A code-only helper script is not enough unless the requester explicitly asked only for a helper script.
- Symphony-prepared branch is pushed and PR is linked on the issue.
- PR feedback has been swept; no known actionable comments remain unaddressed.
- PR checks are passing, or any failure is documented as an external blocker that cannot be resolved in-session.

## Workpad Template

Keep this structure and edit it in place:

````md
## Codex Workpad

```text
<hostname>:<abs-workspace-path>@<short-sha>
```

### Plan

- [ ] 1. Parent task
  - [ ] 1.1 Child task

### Acceptance Criteria

- [ ] Criterion

### Validation

- [ ] `<command>` - result

### Notes

- <timestamped concise note>

### Confusions

- <only include when something was unclear>
````
