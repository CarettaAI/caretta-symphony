---
tracker:
  kind: linear_mcp
  team: Caretta
  active_states: ["Todo", "In Progress", "Rework", "Merging"]
  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  review_states: ["In Review", "Merging"]
  handoff_state: In Review
  rework_state: Rework
  done_state: Done
  merge_base_branch: main
  blocked_escalation_enabled: true
  blocked_escalation_mentions: ["@Omar"]
  required_labels: ["codex"]
  mcp_command: /Applications/Codex.app/Contents/Resources/codex app-server
  mcp_server: codex_apps
workspace:
  root: /Users/caretta/Documents/repos/caretta-symphony/.symphony-workspaces
hooks:
  after_run: /Users/caretta/Documents/repos/caretta-symphony/scripts/symphony-workspace-hook.sh after_run
  before_remove: /Users/caretta/Documents/repos/caretta-symphony/scripts/symphony-workspace-hook.sh before_remove
  timeout_ms: 10000
polling:
  interval_ms: 30000
agent:
  max_concurrent_agents: 5
  max_concurrent_agents_by_state:
    Todo: 3
    In Progress: 2
    Rework: 2
    Merging: 1
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
  host: 127.0.0.1
  port: 8765
self_healing:
  enabled: true
  base_branch: main
  branch_prefix: codex/self-heal
  workspace_root: /Users/caretta/Documents/repos/caretta-symphony/.symphony-self-heal
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
    workflow_path: /Users/caretta/Documents/repos/caretta-symphony/WORKFLOW.caretta-local.md
context:
  coding:
    enabled: true
    classifier: llm
    classification_fallback: inject
    classifier_effort: low
    classification_timeout_ms: 120000
    skill_paths:
      - /Users/caretta/Documents/repos/caretta-repo-map
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
  base_branch: main
  branch_prefix: Symphony
  known:
    - slug: CarettaAI/Project-N
      local_path: /Users/caretta/Documents/repos/Project-N
      remote_url: https://github.com/CarettaAI/Project-N.git
      aliases: ["desktop", "electron", "overlay", "local transcription", "whisper", "meeting capture", "Project N"]
      description: Desktop overlay for calls, local transcription, native capture, and in-call AI coaching.
    - slug: CarettaAI/caretta-webapp
      local_path: /Users/caretta/Documents/repos/caretta-webapp
      remote_url: https://github.com/CarettaAI/caretta-webapp.git
      aliases: ["webapp", "web app", "Next.js", "CRM", "calendar", "settings", "history", "knowledge base", "onboarding"]
      description: Customer-facing Next.js app and integration API routes for Caretta product workflows.
    - slug: CarettaAI/projectN-lambdas
      local_path: /Users/caretta/Documents/repos/projectN-lambdas
      remote_url: https://github.com/CarettaAI/projectN-lambdas.git
      aliases: ["lambdas", "backend", "serverless", "Supabase", "Drizzle", "database", "contacts", "calls"]
      description: Serverless backend, shared package, database schema, migrations, and API handlers.
    - slug: CarettaAI/chat-engine
      local_path: /Users/caretta/Documents/repos/chat-engine
      remote_url: https://github.com/CarettaAI/chat-engine.git
      aliases: ["chat", "assistant", "automations", "daily brief", "agent worker", "runtime"]
      description: Chat API, async agent worker, automations, and inference orchestration.
    - slug: CarettaAI/asr-service
      local_path: /Users/caretta/Documents/repos/asr-service
      remote_url: https://github.com/CarettaAI/asr-service.git
      aliases: ["ASR", "remote transcription", "ingress", "gRPC", "GPU transcription", "speech service"]
      description: Production remote ASR ingress, service, protobuf contracts, tests, and AWS ECS/GPU infra.
    - slug: CarettaAI/caretta-transcription
      local_path: /Users/caretta/Documents/repos/caretta-transcription
      remote_url: https://github.com/CarettaAI/caretta-transcription.git
      aliases: ["Parakeet", "FastAPI transcription", "legacy transcription", "OpenAI audio API"]
      description: Standalone Parakeet FastAPI speech-to-text service with REST and WebSocket endpoints.
    - slug: CarettaAI/llm-gateway-tensorzero
      local_path: /Users/caretta/Documents/repos/llm-gateway-tensorzero
      remote_url: https://github.com/CarettaAI/llm-gateway-tensorzero.git
      aliases: ["TensorZero", "LLM gateway", "model gateway", "provider routing", "Supabase JWT"]
      description: TensorZero gateway configuration and AWS ECS/API Gateway infrastructure.
    - slug: CarettaAI/airweave-caretta
      local_path: /Users/caretta/Documents/repos/airweave-caretta
      remote_url: https://github.com/CarettaAI/airweave-caretta.git
      aliases: ["Airweave", "connectors", "retrieval", "search", "MCP search", "sync pipeline"]
      description: Forked Airweave context retrieval, connector ingestion, search, frontend, and MCP server.
    - slug: CarettaAI/kb-service
      local_path: /Users/caretta/Documents/repos/kb-service
      remote_url: https://github.com/CarettaAI/kb-service.git
      aliases: ["knowledge service", "KB service", "org knowledge", "FAQ extraction", "EventBridge"]
      description: Knowledge-base Lambda concept for transcript FAQ extraction into Supabase org_knowledge.
    - slug: CarettaAI/lambda-gen-embeds
      local_path: /Users/caretta/Documents/repos/lambda-gen-embeds
      remote_url: https://github.com/CarettaAI/lambda-gen-embeds.git
      aliases: ["embeddings", "embed lambda", "embed-text", "process_embeddings"]
      description: Lambda for generating text embeddings for Postgres/application jobs.
    - slug: CarettaAI/doc-to-context
      local_path: /Users/caretta/Documents/repos/doc-to-context
      remote_url: https://github.com/CarettaAI/doc-to-context.git
      aliases: ["documents", "doc extraction", "context conversion", "Rust lambda"]
      description: Rust Lambda for turning documents into context.
    - slug: CarettaAI/caretta-slack
      local_path: /Users/caretta/Documents/repos/caretta-slack
      remote_url: https://github.com/CarettaAI/caretta-slack.git
      aliases: ["Slack", "Slack app", "Slack OAuth", "daily greetings", "messages", "DMs"]
      description: Slack Bolt app runtime and AWS infrastructure for Caretta messaging workflows.
    - slug: CarettaAI/caretta-infra
      local_path: /Users/caretta/Documents/repos/caretta-infra
      remote_url: https://github.com/CarettaAI/caretta-infra.git
      aliases: ["infra", "VPC", "Terraform modules", "shared infrastructure", "networking"]
      description: Shared Terraform modules and environment infrastructure.
    - slug: CarettaAI/caretta-analytics
      local_path: /Users/caretta/Documents/repos/caretta-analytics
      remote_url: https://github.com/CarettaAI/caretta-analytics.git
      aliases: ["analytics", "ClickHouse", "analysis lambda", "Postgres analytics"]
      description: Analytics Lambda and infrastructure for product/operational analysis jobs.
    - slug: CarettaAI/caretta-dashboard
      local_path: /Users/caretta/Documents/repos/caretta-dashboard
      remote_url: https://github.com/CarettaAI/caretta-dashboard.git
      aliases: ["dashboard", "admin dashboard", "KPI", "cohort filters", "Supabase dashboard"]
      description: Next.js Supabase-backed admin KPI dashboard.
    - slug: CarettaAI/caretta-metrics
      local_path: /Users/caretta/Documents/repos/caretta-metrics
      remote_url: https://github.com/CarettaAI/caretta-metrics.git
      aliases: ["metrics", "Svelte metrics", "telemetry console", "ops metrics"]
      description: SvelteKit metrics console for operational telemetry.
    - slug: CarettaAI/caretta-symphony
      local_path: /Users/caretta/Documents/repos/caretta-symphony
      remote_url: https://github.com/CarettaAI/caretta-symphony.git
      aliases: ["Symphony", "Linear runner", "Codex agents", "repo planner", "coding context"]
      description: Elixir Symphony runner for unattended Linear/Codex multi-repo work.
    - slug: CarettaAI/yc-launch-lp
      local_path: /Users/caretta/Documents/repos/yc-launch-lp
      remote_url: https://github.com/CarettaAI/yc-launch-lp.git
      aliases: ["YC landing", "launch page", "marketing", "demo page", "investors", "careers"]
      description: Current launch/YC marketing site.
    - slug: CarettaAI/caretta-landing-q4
      local_path: /Users/caretta/Documents/repos/caretta-landing-q4
      remote_url: https://github.com/CarettaAI/caretta-landing-q4.git
      aliases: ["old landing", "Q4 landing", "marketing site", "Resend", "Cal.com"]
      description: Older Q4 Caretta landing page.
    - slug: CarettaAI/rachel-blog
      local_path: /Users/caretta/Documents/repos/rachel-blog
      remote_url: https://github.com/CarettaAI/rachel-blog.git
      aliases: ["Rachel blog", "essays", "content site", "blog"]
      description: Rachel blog and essay content site.
    - slug: CarettaAI/project-mene
      local_path: /Users/caretta/Documents/repos/project-mene
      remote_url: https://github.com/CarettaAI/project-mene.git
      aliases: ["Mene", "fal.ai demo", "deal pipeline", "proposal demo", "sales demo"]
      description: Demo deal pipeline/proposal app.
    - slug: CarettaAI/Nous
      local_path: /Users/caretta/Documents/repos/Nous
      remote_url: https://github.com/CarettaAI/Nous.git
      aliases: ["Nous", "experiments", "FAL", "Gemini", "Supabase scripts", "prototype"]
      description: Older experimental scripts, documents, and prototype workspace.
---
You are working on a Linear issue in an unattended Symphony run.

Issue: {{ issue.identifier }} - {{ issue.title }}
URL: {{ issue.url }}
Priority: {{ issue.priority }}
State: {{ issue.state }}
Attempt: {{ attempt }}

Use the injected Caretta repo map and repository plan before editing files.

Description:
{{ issue.description }}

## Delivery Contract

Symphony releases the issue only when it leaves the configured active states.
Keep exactly one persistent Linear comment headed `## Codex Workpad`, update that comment in place, and move the issue to the configured handoff state when the work is ready for review.
