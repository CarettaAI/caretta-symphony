defmodule Symphony.WorkflowConfigTemplateTest do
  use ExUnit.Case, async: true

  alias Symphony.CodingContext
  alias Symphony.Config
  alias Symphony.Config.ConfigManager
  alias Symphony.Error
  alias Symphony.Models.Issue
  alias Symphony.Templating
  alias Symphony.Workflow

  @tag :tmp_dir
  test "workflow front matter config and prompt", %{tmp_dir: tmp_dir} do
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
      api_key: $LINEAR_API_KEY
      project_slug: demo
      required_labels: ["Codex"]
    workspace:
      root: ./work
    agent:
      max_concurrent_agents_by_state:
        Todo: 1
        Bad: 0
    codex:
      command: codex app-server --listen stdio://
    ---
    Work on {{ issue.identifier }} attempt={{ attempt }}.
    """)

    workflow = Workflow.load_workflow(workflow_path)
    config = Config.resolve_config(workflow, %{"LINEAR_API_KEY" => "lin-key"})

    assert workflow.config["tracker"]["kind"] == "linear"
    assert workflow.prompt_template == "Work on {{ issue.identifier }} attempt={{ attempt }}."
    assert config.tracker.api_key == "lin-key"
    assert Config.TrackerConfig.required_label_set(config.tracker) == MapSet.new(["codex"])
    assert config.tracker.handoff_state == "In Review"
    assert config.tracker.done_state == "Done"
    assert config.tracker.merge_base_branch == "dev"
    assert config.tracker.review_states == ["In Review", "Merging"]
    assert config.workspace.root == Path.expand(Path.join(tmp_dir, "work"))
    assert config.agent.max_concurrent_agents_by_state == %{"todo" => 1}
    assert config.codex.command == "codex app-server --listen stdio://"

    rendered =
      Templating.render_prompt(
        workflow.prompt_template,
        %Issue{id: "1", identifier: "ABC-1", title: "Title", state: "Todo"},
        2
      )

    assert rendered == "Work on ABC-1 attempt=2."
  end

  @tag :tmp_dir
  test "missing and non-map workflow errors", %{tmp_dir: tmp_dir} do
    assert_raise Error, ~r/missing_workflow_file/, fn ->
      Workflow.load_workflow(Path.join(tmp_dir, "WORKFLOW.md"))
    end

    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")
    File.write!(workflow_path, "---\n- nope\n---\nbody\n")

    assert_raise Error, ~r/workflow_front_matter_not_a_map/, fn ->
      Workflow.load_workflow(workflow_path)
    end
  end

  test "strict template unknown variable fails" do
    assert_raise Error, ~r/template_render_error/, fn ->
      Templating.render_prompt("{{ issue.identifier }} {{ missing.value }}", %Issue{
        id: "1",
        identifier: "ABC-1",
        title: "Title",
        state: "Todo"
      })
    end
  end

  @tag :tmp_dir
  test "config manager invalid reload blocks dispatch", %{tmp_dir: tmp_dir} do
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
      api_key: $LINEAR_API_KEY
      project_slug: demo
    ---
    body
    """)

    manager = ConfigManager.new(workflow_path, environ: %{"LINEAR_API_KEY" => "key"})
    {manager, _, _} = ConfigManager.load_startup(manager)

    Process.sleep(1100)
    File.write!(workflow_path, "---\ntracker: []\n---\nbody\n")

    {manager, changed?} = ConfigManager.reload_if_changed(manager)
    refute changed?

    assert_raise Error, ~r/workflow_reload_invalid/, fn ->
      ConfigManager.validate_for_dispatch!(manager)
    end
  end

  @tag :tmp_dir
  test "default workflow path uses cwd", %{tmp_dir: tmp_dir} do
    assert Workflow.resolve_workflow_path(nil, tmp_dir) ==
             Path.join(tmp_dir, "WORKFLOW.md") |> Path.expand()
  end

  @tag :tmp_dir
  test "coding context config and prompt augmentation", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join(tmp_dir, "platform-architecture")
    references_dir = Path.join(skill_dir, "references")
    File.mkdir_p!(references_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: platform-architecture\n---\nRead the repo map.\n"
    )

    File.write!(
      Path.join(references_dir, "repo-map.md"),
      "Use desktop-runtime for live workflow provider work.\n"
    )

    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
      api_key: $LINEAR_API_KEY
      project_slug: demo
    context:
      coding:
        enabled: true
        skill_paths:
          - #{skill_dir}
        label_triggers: ["codex"]
        keyword_triggers: ["provider"]
        max_chars: 5000
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
          local_path: #{tmp_dir}
          remote_url: https://github.com/ExampleOrg/desktop-runtime.git
          aliases: ["desktop-runtime", "desktop"]
          description: Desktop app runtime
    ---
    Work on {{ issue.identifier }}.
    """)

    config =
      Config.resolve_config(Workflow.load_workflow(workflow_path), %{
        "LINEAR_API_KEY" => "lin-key"
      })

    assert :ok = Config.validate_dispatch_config!(config)

    issue = %Issue{
      id: "1",
      identifier: "ENG-1",
      title: "Use Linkup provider",
      state: "Todo",
      labels: ["codex"]
    }

    augmented =
      CodingContext.augment_prompt_with_coding_context(
        "Original prompt",
        issue,
        config.context.coding
      )

    assert config.context.coding.enabled
    assert config.context.coding.classifier == "rules"
    assert config.context.coding.skill_paths == [skill_dir]
    assert config.dashboard.summaries_enabled
    assert config.dashboard.summary_update_interval_ms == 30000
    assert config.repositories.enabled
    assert config.repositories.planner == "llm"
    assert hd(config.repositories.repositories).slug == "ExampleOrg/desktop-runtime"
    assert augmented =~ "<symphony_coding_context>"
    assert augmented =~ "Use desktop-runtime for live workflow provider work."
    assert String.ends_with?(augmented, "Original prompt")
  end

  @tag :tmp_dir
  test "coding context ignores non-coding issue", %{tmp_dir: tmp_dir} do
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")
    skill = Path.join(tmp_dir, "skill.md")
    File.write!(skill, "context")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
      api_key: $LINEAR_API_KEY
      project_slug: demo
    context:
      coding:
        enabled: true
        skill_paths:
          - #{skill}
        label_triggers: ["codex"]
    ---
    body
    """)

    config =
      Config.resolve_config(Workflow.load_workflow(workflow_path), %{
        "LINEAR_API_KEY" => "lin-key"
      })

    issue = %Issue{id: "1", identifier: "ENG-1", title: "Triage only", state: "Todo", labels: []}

    assert CodingContext.augment_prompt_with_coding_context(
             "Original prompt",
             issue,
             config.context.coding
           ) == "Original prompt"
  end

  @tag :tmp_dir
  test "llm coding context classifier controls prompt augmentation", %{tmp_dir: tmp_dir} do
    fake_server = Path.join(tmp_dir, "fake_classifier_server.py")

    File.write!(fake_server, ~S"""
    import json
    import sys

    thread_id = "thr_classifier"
    turn_id = "turn_classifier"

    for line in sys.stdin:
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
        elif method == "initialized":
            pass
        elif method == "thread/start":
            print(json.dumps({"id": msg["id"], "result": {"thread": {"id": thread_id}}}), flush=True)
        elif method == "turn/start":
            print(json.dumps({"id": msg["id"], "result": {"turn": {"id": turn_id, "status": "inProgress"}}}), flush=True)
            print(json.dumps({"method": "item/agentMessage/delta", "params": {"threadId": thread_id, "turnId": turn_id, "delta": "{\"coding_context_needed\": true, \"confidence\": 0.91, \"reason\": \"Requires repo changes.\"}"}}), flush=True)
            print(json.dumps({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "items": [], "error": None}}}), flush=True)
    """)

    skill_dir = Path.join(tmp_dir, "platform-architecture")
    File.mkdir!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "Architecture context")

    config = %Config.CodingContextConfig{
      enabled: true,
      classifier: "llm",
      classification_fallback: "skip",
      skill_paths: [skill_dir]
    }

    codex = %Config.CodexConfig{command: "python3 #{fake_server}"}
    parent = self()

    issue = %Issue{
      id: "1",
      identifier: "ENG-1",
      title: "Ambiguous but code",
      state: "Todo",
      labels: []
    }

    augmented =
      CodingContext.augment_prompt_with_coding_context("Original prompt", issue, config,
        codex_config: codex,
        workspace_path: tmp_dir,
        on_event: fn event -> send(parent, {:event, event}) end
      )

    assert augmented =~ "<symphony_coding_context>"
    assert augmented =~ "Classification source: llm"
    assert augmented =~ "Architecture context"

    assert_receive {:event,
                    %{"coding_context_injected" => true, "classification_source" => "llm"}}
  end

  @tag :tmp_dir
  test "missing enabled coding context skill fails validation", %{tmp_dir: tmp_dir} do
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
      api_key: $LINEAR_API_KEY
      project_slug: demo
    context:
      coding:
        enabled: true
        skill_paths:
          - ./missing-skill
    ---
    body
    """)

    config =
      Config.resolve_config(Workflow.load_workflow(workflow_path), %{
        "LINEAR_API_KEY" => "lin-key"
      })

    assert_raise Error, ~r/missing_coding_context_skill/, fn ->
      Config.validate_dispatch_config!(config)
    end
  end

  test "continuation prompt includes fresh Linear snapshot" do
    issue = %Issue{
      id: "1",
      identifier: "ENG-251",
      title: "Web search provider",
      state: "In Progress",
      url: "https://linear.app/example/issue/ENG-251",
      labels: ["codex"],
      description: "Use Linkup for web search provider work."
    }

    prompt = Templating.continuation_prompt(issue, 2, 20)

    assert prompt =~ "Current Linear issue snapshot"
    assert prompt =~ "ENG-251 - Web search provider"
    assert prompt =~ "Labels: codex"
    assert prompt =~ "Use Linkup for web search provider work."
    assert prompt =~ "current Linear text"
  end
end
