defmodule Symphony.ReviewTest do
  use ExUnit.Case, async: true

  alias Symphony.Models.{Issue, IssueAttachment}
  alias Symphony.Review

  alias Symphony.Review.{
    PullRequestInfo,
    PullRequestRef,
    ReviewFeedbackItem,
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

  test "feedback snapshot filters bots workpads and blank reviews" do
    comments = [
      %{
        "id" => "linear-1",
        "body" => "Please handle the empty state.",
        "createdAt" => "2026-04-29T10:00:00Z",
        "user" => %{"login" => "omar", "type" => "User"}
      },
      %{
        "id" => "linear-2",
        "body" => "## Codex Workpad\nupdated",
        "createdAt" => "2026-04-29T10:01:00Z",
        "user" => %{"login" => "codex-agent", "type" => "Bot"}
      }
    ]

    pr_feedback = [
      %ReviewFeedbackItem{
        source: "github_pr_comment",
        id: "pr-comment-1",
        body: "Automated check passed.",
        author: "ci-bot",
        author_type: "Bot",
        updated_at: ~U[2026-04-29 10:02:00Z]
      },
      %ReviewFeedbackItem{
        source: "github_pr_review",
        id: "review-1",
        body: "",
        author: "human",
        author_type: "User",
        updated_at: ~U[2026-04-29 10:03:00Z]
      }
    ]

    snapshot = Review.feedback_snapshot(comments, pr_feedback)

    assert Enum.map(snapshot.items, & &1.id) == ["linear_comment:linear-1"]
    assert snapshot.latest_feedback_at == ~U[2026-04-29 10:00:00Z]
  end

  test "feedback fingerprint changes when human feedback changes" do
    first =
      Review.feedback_snapshot(
        [%{"id" => "1", "body" => "First", "createdAt" => "2026-04-29T10:00:00Z"}],
        []
      )

    second =
      Review.feedback_snapshot(
        [%{"id" => "1", "body" => "Second", "updatedAt" => "2026-04-29T10:05:00Z"}],
        []
      )

    assert first.fingerprint != second.fingerprint
    assert second.latest_feedback_at == ~U[2026-04-29 10:05:00Z]
  end

  test "PR feedback payloads normalize review comment metadata" do
    ref = %PullRequestRef{owner: "ExampleOrg", repo: "app", number: 12}

    item =
      Review.pr_feedback_item_from_payload(ref, "github_pr_review_comment", %{
        "id" => 99,
        "body" => "This branch needs the same validation as the API PR.",
        "html_url" => "https://github.com/ExampleOrg/app/pull/12#discussion_r99",
        "created_at" => "2026-04-29T11:00:00Z",
        "user" => %{"login" => "reviewer", "type" => "User"}
      })

    assert item.id == "ExampleOrg/app#12:github_pr_review_comment:99"
    assert item.author == "reviewer"
    assert item.updated_at == ~U[2026-04-29 11:00:00Z]
    assert Review.human_feedback_item?(item)
  end

  test "blank approving reviews are ignored but blank request-changes reviews count" do
    ref = %PullRequestRef{owner: "ExampleOrg", repo: "app", number: 12}

    approval =
      Review.pr_feedback_item_from_payload(ref, "github_pr_review", %{
        "id" => 1,
        "body" => "",
        "state" => "APPROVED",
        "user" => %{"login" => "reviewer", "type" => "User"}
      })

    changes =
      Review.pr_feedback_item_from_payload(ref, "github_pr_review", %{
        "id" => 2,
        "body" => "",
        "state" => "CHANGES_REQUESTED",
        "user" => %{"login" => "reviewer", "type" => "User"}
      })

    refute Review.human_feedback_item?(approval)
    assert Review.human_feedback_item?(changes)
    assert changes.body == "Review state: CHANGES_REQUESTED"
  end
end
