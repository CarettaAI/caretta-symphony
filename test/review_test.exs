defmodule Symphony.ReviewTest do
  use ExUnit.Case, async: true

  alias Symphony.Models.{Issue, IssueAttachment}
  alias Symphony.Review

  alias Symphony.Review.{
    PullRequestInfo,
    PullRequestRef,
    ReviewPullRequestResolver,
    ReviewMergeResult
  }

  defp pr(owner, repo, number, opts \\ []) do
    state = Keyword.get(opts, :state, "MERGED")

    %PullRequestInfo{
      ref: %PullRequestRef{owner: owner, repo: repo, number: number},
      url: "https://github.com/#{owner}/#{repo}/pull/#{number}",
      state: state,
      base_ref_name: Keyword.get(opts, :base, "dev"),
      merged_at: if(state == "MERGED", do: "2026-04-29T12:00:00Z"),
      body: Keyword.get(opts, :body, "")
    }
  end

  @tag :tmp_dir
  test "review resolver requires linked workpad and dependency PRs", %{tmp_dir: tmp_dir} do
    first = pr("ExampleOrg", "app", 1, body: "Depends on ExampleOrg/api#3")
    second = pr("ExampleOrg", "app", 2)
    dependency = pr("ExampleOrg", "api", 3)

    inspector = %{
      view_pr_url: fn url -> %{first.url => first, second.url => second}[url] end,
      view_pr_ref: fn ref ->
        %{Review.PullRequestRef.canonical(dependency.ref) => dependency}[
          Review.PullRequestRef.canonical(ref)
        ]
      end,
      list_prs_for_branch: fn _repo, _branch, _base -> [] end
    }

    resolver = ReviewPullRequestResolver.new(inspector)

    issue = %Issue{
      id: "ENG-1",
      identifier: "ENG-1",
      title: "Ready",
      state: "In Review",
      attachments: [%IssueAttachment{url: first.url}]
    }

    comments = [%{"body" => "## Codex Workpad\nPR: #{second.url}"}]

    result =
      ReviewPullRequestResolver.evaluate(resolver, issue,
        comments: comments,
        workspace_path: tmp_dir,
        base_branch: "dev"
      )

    assert result.ready

    assert Enum.map(result.required_prs, &Review.PullRequestRef.canonical(&1.ref)) == [
             "ExampleOrg/api#3",
             "ExampleOrg/app#1",
             "ExampleOrg/app#2"
           ]
  end

  @tag :tmp_dir
  test "review resolver blocks on open wrong base and unresolved dependency", %{tmp_dir: tmp_dir} do
    open_pr = pr("ExampleOrg", "app", 1, state: "OPEN", body: "Needs ExampleOrg/missing#7")
    wrong_base = pr("ExampleOrg", "api", 2, base: "main")

    inspector = %{
      view_pr_url: fn url -> %{open_pr.url => open_pr, wrong_base.url => wrong_base}[url] end,
      view_pr_ref: fn _ref -> nil end,
      list_prs_for_branch: fn _repo, _branch, _base -> [] end
    }

    resolver = ReviewPullRequestResolver.new(inspector)

    issue = %Issue{
      id: "ENG-1",
      identifier: "ENG-1",
      title: "Ready",
      state: "In Review",
      attachments: [%IssueAttachment{url: open_pr.url}, %IssueAttachment{url: wrong_base.url}]
    }

    result =
      ReviewPullRequestResolver.evaluate(resolver, issue,
        comments: [],
        workspace_path: tmp_dir,
        base_branch: "dev"
      )

    reason = ReviewMergeResult.reason(result)

    refute result.ready
    assert reason =~ "ExampleOrg/app#1 is OPEN"
    assert reason =~ "ExampleOrg/api#2 targets main instead of dev"
    assert reason =~ "ExampleOrg/missing#7"
  end

  @tag :tmp_dir
  test "review resolver uses workspace branch fallback", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "ENG-1")
    File.mkdir!(workspace)

    File.write!(
      Path.join(workspace, ".symphony-workspace.json"),
      Jason.encode!(%{
        "repositories" => [
          %{
            "slug" => "ExampleOrg/app",
            "edit_allowed" => true,
            "git" => %{"expected_branch" => "Symphony/ENG-1-app"}
          }
        ]
      })
    )

    fallback = pr("ExampleOrg", "app", 4)

    inspector = %{
      view_pr_url: fn _url -> nil end,
      view_pr_ref: fn _ref -> nil end,
      list_prs_for_branch: fn "ExampleOrg/app", "Symphony/ENG-1-app", "dev" -> [fallback] end
    }

    resolver = ReviewPullRequestResolver.new(inspector)
    issue = %Issue{id: "ENG-1", identifier: "ENG-1", title: "Ready", state: "In Review"}

    result =
      ReviewPullRequestResolver.evaluate(resolver, issue,
        comments: [],
        workspace_path: workspace,
        base_branch: "dev"
      )

    assert result.ready

    assert Enum.map(result.required_prs, &Review.PullRequestRef.canonical(&1.ref)) == [
             "ExampleOrg/app#4"
           ]
  end

  @tag :tmp_dir
  test "review resolver requires some PR evidence", %{tmp_dir: tmp_dir} do
    inspector = %{
      view_pr_url: fn _ -> nil end,
      view_pr_ref: fn _ -> nil end,
      list_prs_for_branch: fn _, _, _ -> [] end
    }

    resolver = ReviewPullRequestResolver.new(inspector)
    issue = %Issue{id: "ENG-1", identifier: "ENG-1", title: "Ready", state: "In Review"}

    result =
      ReviewPullRequestResolver.evaluate(resolver, issue,
        comments: [],
        workspace_path: tmp_dir,
        base_branch: "dev"
      )

    refute result.ready
    assert ReviewMergeResult.reason(result) == "no required PRs were found"
  end
end
