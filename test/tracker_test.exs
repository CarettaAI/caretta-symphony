defmodule Symphony.TrackerTest do
  use ExUnit.Case, async: true

  alias Symphony.Config.TrackerConfig
  alias Symphony.Tracker.{CodexMcpGateway, LinearClient, LinearMcpClient}

  test "Linear candidate pagination and normalization" do
    parent = self()

    transport = fn query, variables ->
      send(parent, {:call, query, variables})
      assert query =~ "slugId"

      if variables["after"] == nil do
        %{
          "data" => %{
            "issues" => %{
              "nodes" => [
                %{
                  "id" => "id-1",
                  "identifier" => "ABC-1",
                  "title" => "First",
                  "description" => "Body",
                  "priority" => 1,
                  "branchName" => "abc-1",
                  "url" => "https://linear.app/x/ABC-1",
                  "createdAt" => "2026-01-01T00:00:00Z",
                  "updatedAt" => "2026-01-02T00:00:00Z",
                  "state" => %{"name" => "Todo"},
                  "labels" => %{"nodes" => [%{"name" => "Backend"}]},
                  "inverseRelations" => %{
                    "nodes" => [
                      %{
                        "type" => "blocks",
                        "issue" => %{
                          "id" => "blocker",
                          "identifier" => "ABC-0",
                          "state" => %{"name" => "Done"}
                        }
                      }
                    ]
                  }
                }
              ],
              "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-1"}
            }
          }
        }
      else
        %{
          "data" => %{
            "issues" => %{
              "nodes" => [],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      end
    end

    client = %LinearClient{
      config: %TrackerConfig{
        kind: "linear",
        endpoint: "https://example.test/graphql",
        api_key: "key",
        project_slug: "proj"
      },
      transport: transport
    }

    issues = LinearClient.fetch_candidate_issues(client)

    assert_received {:call, _query, %{"stateNames" => ["Todo", "In Progress"], "after" => nil}}
    assert_received {:call, _query, %{"after" => "cursor-1"}}
    assert hd(issues).labels == ["backend"]
    assert hd(issues).blocked_by |> hd() |> Map.fetch!(:identifier) == "ABC-0"
    assert hd(issues).created_at
  end

  test "empty fetch by states skips API call" do
    transport = fn _query, _variables -> flunk("transport should not be called") end

    client = %LinearClient{
      config: %TrackerConfig{
        kind: "linear",
        endpoint: "https://example.test/graphql",
        api_key: "key",
        project_slug: "proj"
      },
      transport: transport
    }

    assert LinearClient.fetch_issues_by_states(client, []) == []
  end

  test "state refresh query uses GraphQL id typing" do
    parent = self()

    transport = fn query, _variables ->
      send(parent, {:query, query})

      %{
        "data" => %{
          "issues" => %{
            "nodes" => [
              %{
                "id" => "id-1",
                "identifier" => "ABC-1",
                "title" => "First",
                "state" => %{"name" => "In Progress"},
                "labels" => %{"nodes" => []},
                "inverseRelations" => %{"nodes" => []}
              }
            ]
          }
        }
      }
    end

    client = %LinearClient{
      config: %TrackerConfig{
        kind: "linear",
        endpoint: "https://example.test/graphql",
        api_key: "key",
        project_slug: "proj"
      },
      transport: transport
    }

    issues = LinearClient.fetch_issue_states_by_ids(client, ["id-1"])

    assert_received {:query, query}
    assert query =~ "[ID!]"
    assert hd(issues).state == "In Progress"
  end

  test "Linear MCP client lists and hydrates todo blockers" do
    parent = self()

    gateway = fn tool, arguments ->
      send(parent, {:gateway, tool, arguments})

      if String.ends_with?(tool, "list_issues") do
        %{
          "issues" => [
            %{
              "id" => "ENG-1",
              "title" => "Ready",
              "status" => "Todo",
              "priority" => %{"value" => 2, "name" => "High"},
              "assignee" => %{"id" => "user-1", "displayName" => "Omar", "username" => "omar"},
              "labels" => ["Bug"],
              "gitBranchName" => "agent/eng-1-ready",
              "attachments" => [
                %{
                  "id" => "att-1",
                  "title" => "PR 1",
                  "url" => "https://github.com/ExampleOrg/app/pull/1"
                },
                %{
                  "id" => "att-2",
                  "title" => "PR 2",
                  "url" => "https://github.com/ExampleOrg/app/pull/2"
                }
              ]
            }
          ],
          "hasNextPage" => false
        }
      else
        %{
          "id" => "ENG-1",
          "title" => "Ready",
          "status" => "Todo",
          "priority" => %{"value" => 2, "name" => "High"},
          "assignee" => %{"id" => "user-1", "displayName" => "Omar", "username" => "omar"},
          "labels" => ["Bug"],
          "attachments" => [
            %{
              "id" => "att-1",
              "title" => "PR 1",
              "url" => "https://github.com/ExampleOrg/app/pull/1"
            },
            %{
              "id" => "att-2",
              "title" => "PR 2",
              "url" => "https://github.com/ExampleOrg/app/pull/2"
            }
          ],
          "relations" => %{"blockedBy" => [%{"id" => "ENG-0", "status" => "Done"}]}
        }
      end
    end

    client = %LinearMcpClient{
      config: %TrackerConfig{
        kind: "linear_mcp",
        project_slug: "Pilot",
        team: "Platform Automation",
        active_states: ["Todo"],
        required_labels: ["codex"]
      },
      gateway: gateway
    }

    issues = LinearMcpClient.fetch_candidate_issues(client)
    issue = hd(issues)

    assert issue.id == "ENG-1"
    assert issue.identifier == "ENG-1"
    assert issue.labels == ["bug"]
    assert issue.assignee.display_name == "Omar"
    assert issue.assignee.mention == "@omar"

    assert Enum.map(issue.attachments, & &1.url) == [
             "https://github.com/ExampleOrg/app/pull/1",
             "https://github.com/ExampleOrg/app/pull/2"
           ]

    assert hd(issue.blocked_by).identifier == "ENG-0"

    assert_received {:gateway, "_list_issues",
                     %{"project" => "Pilot", "team" => "Platform Automation", "label" => "codex"}}
  end

  test "Linear MCP client falls back across unavailable tool aliases" do
    parent = self()

    gateway = fn tool, arguments ->
      send(parent, {:gateway, tool, arguments})

      case tool do
        "old_list_issues" ->
          raise Symphony.Error,
            code: :linear_mcp_tool_error,
            message:
              Jason.encode!(%{
                "content" => [%{"type" => "text", "text" => "Unknown tool: old_list_issues"}],
                "isError" => true
              })

        "current_list_issues" ->
          assert arguments["state"] == "Todo"
          %{"issues" => [], "hasNextPage" => false}
      end
    end

    client = %LinearMcpClient{
      config: %TrackerConfig{
        kind: "linear_mcp",
        project_slug: "Pilot",
        active_states: ["Todo"],
        mcp_tools: %{"list_issues" => ["old_list_issues", "current_list_issues"]}
      },
      gateway: gateway
    }

    assert LinearMcpClient.fetch_candidate_issues(client) == []
    assert_receive {:gateway, "old_list_issues", _}
    assert_receive {:gateway, "current_list_issues", _}
  end

  test "Linear MCP client does not try aliases for non-discovery tool errors" do
    parent = self()

    gateway = fn tool, _arguments ->
      send(parent, {:gateway, tool})

      raise Symphony.Error,
        code: :linear_mcp_tool_error,
        message:
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "user rejected MCP tool call"}],
            "isError" => true
          })
    end

    client = %LinearMcpClient{
      config: %TrackerConfig{
        kind: "linear_mcp",
        project_slug: "Pilot",
        active_states: ["Todo"],
        mcp_tools: %{"list_issues" => ["first_list_issues", "second_list_issues"]}
      },
      gateway: gateway
    }

    assert_raise Symphony.Error, ~r/user rejected MCP tool call/, fn ->
      LinearMcpClient.fetch_candidate_issues(client)
    end

    assert_receive {:gateway, "first_list_issues"}
    refute_receive {:gateway, "second_list_issues"}
  end

  test "Linear MCP client writes comments and state" do
    parent = self()

    gateway = fn tool, arguments ->
      send(parent, {:gateway, tool, arguments})

      cond do
        String.ends_with?(tool, "list_comments") ->
          %{"comments" => [%{"id" => "comment-1", "body" => "## Codex Workpad\nold"}]}

        String.ends_with?(tool, "save_comment") ->
          %{"id" => arguments["id"] || "comment-2"}

        String.ends_with?(tool, "save_issue") ->
          %{"id" => arguments["id"], "state" => arguments["state"]}
      end
    end

    client = %LinearMcpClient{
      config: %TrackerConfig{kind: "linear_mcp", project_slug: "Pilot"},
      gateway: gateway
    }

    comments = LinearMcpClient.list_issue_comments(client, "ENG-1")

    LinearMcpClient.save_issue_comment(client, "ENG-1", "## Codex Workpad\nnew",
      comment_id: hd(comments)["id"]
    )

    LinearMcpClient.save_issue_state(client, "ENG-1", "completed")

    assert_received {:gateway, "_list_comments",
                     %{"issueId" => "ENG-1", "limit" => 250, "orderBy" => "createdAt"}}

    assert_received {:gateway, "_save_comment",
                     %{"body" => "## Codex Workpad\nnew", "id" => "comment-1"}}

    assert_received {:gateway, "_save_issue", %{"id" => "ENG-1", "state" => "completed"}}
  end

  @tag :tmp_dir
  test "Codex MCP gateway decodes tool response and approvals", %{tmp_dir: tmp_dir} do
    fake_server = Path.join(tmp_dir, "fake_app_server.py")

    File.write!(fake_server, ~S"""
    import json
    import sys

    call_request_id = None

    for line in sys.stdin:
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
        elif method == "initialized":
            pass
        elif method == "thread/start":
            print(json.dumps({"id": msg["id"], "result": {"thread": {"id": "thr_1"}}}), flush=True)
        elif method == "mcpServer/tool/call":
            call_request_id = msg["id"]
            print(json.dumps({"id": 110, "method": "item/tool/requestUserInput", "params": {"questions": [{"id": "mcp_tool_call_approval_call-1", "options": [{"label": "Approve Once"}, {"label": "Approve this Session"}, {"label": "Deny"}]}]}}), flush=True)
        elif msg.get("id") == 110:
            assert msg["result"]["answers"]["mcp_tool_call_approval_call-1"]["answers"] == ["Approve this Session"]
            print(json.dumps({"id": call_request_id, "result": {"content": [{"type": "text", "text": "{\"ok\": true}"}], "isError": False}}), flush=True)
    """)

    gateway = %CodexMcpGateway{command: "python3 #{fake_server}", cwd: tmp_dir}

    assert CodexMcpGateway.call_tool(gateway, "_save_issue", %{
             "id" => "ENG-1",
             "state" => "completed"
           }) == %{"ok" => true}
  end
end
