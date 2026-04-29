defmodule Symphony.Review do
  @moduledoc false

  alias Symphony.Models.Issue
  alias Symphony.Utils

  @github_pr_url_re ~r"https://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)"i
  @owner_repo_pr_re ~r"(?<![\w.\/-])([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#(\d+)"
  @workspace_metadata ".symphony-workspace.json"
  defmodule PullRequestRef do
    defstruct owner: nil, repo: nil, number: nil

    def repo_full_name(%__MODULE__{} = ref), do: "#{ref.owner}/#{ref.repo}"
    def canonical(%__MODULE__{} = ref), do: "#{repo_full_name(ref)}##{ref.number}"
  end

  defmodule PullRequestInfo do
    defstruct ref: nil,
              url: nil,
              state: nil,
              base_ref_name: nil,
              merged_at: nil,
              head_ref_name: nil,
              body: ""
  end

  defmodule ReviewMergeResult do
    defstruct ready: false, required_prs: [], unresolved_refs: [], blockers: []

    def reason(%__MODULE__{ready: true, required_prs: prs}),
      do: "all #{length(prs)} required PR(s) are merged"

    def reason(%__MODULE__{blockers: blockers}) when blockers != [], do: Enum.join(blockers, "; ")

    def reason(%__MODULE__{unresolved_refs: refs}) when refs != [],
      do: "unresolved PR reference(s): #{Enum.join(refs, ", ")}"

    def reason(_), do: "no required PRs were found"
  end

  defmodule GhPullRequestInspector do
    alias Symphony.Review
    alias Symphony.Review.PullRequestRef

    def view_pr_url(url) do
      run_gh_json([
        "pr",
        "view",
        url,
        "--json",
        "number,url,state,mergedAt,baseRefName,headRefName,body"
      ])
      |> Review.pr_info_from_payload()
    end

    def view_pr_ref(%PullRequestRef{} = ref) do
      run_gh_json([
        "pr",
        "view",
        to_string(ref.number),
        "--repo",
        PullRequestRef.repo_full_name(ref),
        "--json",
        "number,url,state,mergedAt,baseRefName,headRefName,body"
      ])
      |> Review.pr_info_from_payload(fallback_ref: ref)
    end

    def list_prs_for_branch(repo_full_name, branch, base_branch) do
      payload =
        run_gh_json([
          "pr",
          "list",
          "--repo",
          repo_full_name,
          "--head",
          branch,
          "--base",
          base_branch,
          "--state",
          "all",
          "--limit",
          "20",
          "--json",
          "number,url,state,mergedAt,baseRefName,headRefName,body"
        ])

      if is_list(payload),
        do: payload |> Enum.map(&Review.pr_info_from_payload/1) |> Enum.reject(&is_nil/1),
        else: []
    end

    defp run_gh_json(args) do
      case System.cmd("gh", args, stderr_to_stdout: true) do
        {body, 0} -> Jason.decode!(body)
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  defmodule ReviewPullRequestResolver do
    @max_dependency_prs 50

    defstruct inspector: GhPullRequestInspector

    alias Symphony.Review
    alias Symphony.Review.{ReviewMergeResult, PullRequestRef}

    def new(inspector \\ GhPullRequestInspector), do: %__MODULE__{inspector: inspector}

    def evaluate(%__MODULE__{} = resolver, %Issue{} = issue, opts) do
      comments = Keyword.get(opts, :comments, [])
      workspace_path = Keyword.fetch!(opts, :workspace_path)
      base_branch = Keyword.fetch!(opts, :base_branch)

      {required, unresolved, queue} =
        (Review.issue_attachment_pr_urls(issue) ++ Review.comment_pr_urls(comments))
        |> Review.dedupe_strings()
        |> Enum.reduce({%{}, MapSet.new(), []}, fn url, {required, unresolved, queue} ->
          case call_inspector(resolver.inspector, :view_pr_url, [url]) do
            nil ->
              {required, MapSet.put(unresolved, url), queue}

            pr ->
              if Map.has_key?(required, PullRequestRef.canonical(pr.ref)) do
                {required, unresolved, queue}
              else
                {Map.put(required, PullRequestRef.canonical(pr.ref), pr), unresolved,
                 queue ++ [pr]}
              end
          end
        end)

      metadata = Review.load_workspace_metadata(workspace_path)

      {required, queue} =
        metadata
        |> Review.workspace_branch_candidates(issue)
        |> Enum.reduce({required, queue}, fn {repo_full_name, branch}, {required, queue} ->
          resolver.inspector
          |> call_inspector(:list_prs_for_branch, [repo_full_name, branch, base_branch])
          |> Enum.reduce({required, queue}, fn pr, {required, queue} ->
            key = PullRequestRef.canonical(pr.ref)

            if Map.has_key?(required, key),
              do: {required, queue},
              else: {Map.put(required, key, pr), queue ++ [pr]}
          end)
        end)

      {required, unresolved} = resolve_dependencies(resolver, queue, required, unresolved)
      blockers = Review.merge_blockers(Map.values(required), unresolved, base_branch)

      %ReviewMergeResult{
        ready: map_size(required) > 0 and blockers == [],
        required_prs: Enum.sort_by(Map.values(required), &PullRequestRef.canonical(&1.ref)),
        unresolved_refs: unresolved |> MapSet.to_list() |> Enum.sort(),
        blockers: blockers
      }
    end

    defp resolve_dependencies(resolver, queue, required, unresolved) do
      do_resolve_dependencies(resolver, queue, required, unresolved, 0)
    end

    defp do_resolve_dependencies(_resolver, [], required, unresolved, _count),
      do: {required, unresolved}

    defp do_resolve_dependencies(resolver, [pr | rest], required, unresolved, count) do
      if map_size(required) + MapSet.size(unresolved) >= @max_dependency_prs or
           count >= @max_dependency_prs do
        {required, unresolved}
      else
        {required, unresolved, queue_additions} =
          pr.body
          |> Review.dependency_refs()
          |> Enum.reduce({required, unresolved, []}, fn ref, {required, unresolved, additions} ->
            key = PullRequestRef.canonical(ref)

            cond do
              Map.has_key?(required, key) ->
                {required, unresolved, additions}

              dependency = call_inspector(resolver.inspector, :view_pr_ref, [ref]) ->
                {Map.put(required, key, dependency), unresolved, additions ++ [dependency]}

              true ->
                {required, MapSet.put(unresolved, key), additions}
            end
          end)

        do_resolve_dependencies(
          resolver,
          rest ++ queue_additions,
          required,
          unresolved,
          count + 1
        )
      end
    end

    defp call_inspector(inspector, function, args) when is_atom(inspector),
      do: apply(inspector, function, args)

    defp call_inspector(inspector, function, args) when is_map(inspector) do
      apply(Map.fetch!(inspector, function), args)
    end

    defp call_inspector(inspector, function, args), do: apply(inspector, function, args)
  end

  def issue_attachment_pr_urls(%Issue{} = issue) do
    Enum.flat_map(issue.attachments, fn attachment ->
      [attachment.url, attachment.title, attachment.subtitle]
      |> Enum.flat_map(&pr_urls(to_string(&1 || "")))
    end)
  end

  def comment_pr_urls(comments) do
    Enum.flat_map(comments, fn comment ->
      body =
        comment["body"] || comment[:body] || comment["text"] || comment[:text] ||
          comment["content"] || comment[:content] || ""

      if is_binary(body) and String.contains?(body, "## Codex Workpad") do
        pr_urls(body)
      else
        []
      end
    end)
  end

  def pr_urls(text) do
    @github_pr_url_re
    |> Regex.scan(text)
    |> Enum.map(fn [_match, owner, repo, number] ->
      "https://github.com/#{owner}/#{repo}/pull/#{number}"
    end)
  end

  def dependency_refs(text) do
    url_refs =
      @github_pr_url_re
      |> Regex.scan(text || "")
      |> Enum.map(fn [_match, owner, repo, number] ->
        %PullRequestRef{owner: owner, repo: repo, number: String.to_integer(number)}
      end)

    shorthand_refs =
      @owner_repo_pr_re
      |> Regex.scan(text || "")
      |> Enum.map(fn [_match, owner_repo, number] ->
        [owner, repo] = String.split(owner_repo, "/", parts: 2)
        %PullRequestRef{owner: owner, repo: repo, number: String.to_integer(number)}
      end)

    (url_refs ++ shorthand_refs)
    |> Map.new(&{PullRequestRef.canonical(&1), &1})
    |> Map.values()
    |> Enum.sort_by(&PullRequestRef.canonical/1)
  end

  def merge_blockers(prs, unresolved, base_branch) do
    unresolved_list = unresolved |> MapSet.to_list() |> Enum.sort()

    blockers =
      if unresolved_list == [],
        do: [],
        else: ["unresolved PR reference(s): #{Enum.join(unresolved_list, ", ")}"]

    prs = Enum.to_list(prs)

    blockers =
      if prs == [] and unresolved_list == [],
        do: blockers ++ ["no required PRs were found"],
        else: blockers

    Enum.reduce(prs, blockers, fn pr, acc ->
      cond do
        pr.base_ref_name != base_branch ->
          acc ++
            [
              "#{PullRequestRef.canonical(pr.ref)} targets #{pr.base_ref_name || "unknown"} instead of #{base_branch}"
            ]

        String.upcase(to_string(pr.state || "")) != "MERGED" ->
          acc ++ ["#{PullRequestRef.canonical(pr.ref)} is #{pr.state || "unknown"}"]

        true ->
          acc
      end
    end)
  end

  def load_workspace_metadata(workspace_path) do
    path = Path.join(workspace_path, @workspace_metadata)

    with {:ok, body} <- File.read(path),
         {:ok, payload} when is_map(payload) <- Jason.decode(body) do
      payload
    else
      _ -> %{}
    end
  end

  def workspace_branch_candidates(metadata, issue) do
    (metadata["repositories"] || [])
    |> Enum.flat_map(fn
      repo when is_map(repo) ->
        if Map.get(repo, "edit_allowed", true) do
          repo_full_name = repo_full_name(repo)
          git = if is_map(repo["git"]), do: repo["git"], else: %{}
          branch = git["expected_branch"] || git["current_branch"] || issue.branch_name
          if repo_full_name && branch, do: [{repo_full_name, to_string(branch)}], else: []
        else
          []
        end

      _ ->
        []
    end)
    |> dedupe_pairs()
  end

  def repo_full_name(repo) do
    cond do
      is_binary(repo["slug"]) and String.contains?(repo["slug"], "/") ->
        repo["slug"]

      is_binary(repo["remote_url"]) ->
        repo_full_name_from_remote(repo["remote_url"])

      is_map(repo["git"]) and is_binary(repo["git"]["remote_url"]) ->
        repo_full_name_from_remote(repo["git"]["remote_url"])

      true ->
        nil
    end
  end

  def repo_full_name_from_remote(remote) do
    text =
      remote
      |> to_string()
      |> String.trim()
      |> then(fn text ->
        if String.starts_with?(text, "git@github.com:"),
          do: "https://github.com/" <> String.replace_prefix(text, "git@github.com:", ""),
          else: text
      end)

    case Regex.run(~r"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", text) do
      [_match, owner, repo] -> "#{owner}/#{repo}"
      _ -> nil
    end
  end

  def pr_info_from_payload(payload, opts \\ [])

  def pr_info_from_payload(payload, opts) when is_map(payload) do
    fallback_ref = Keyword.get(opts, :fallback_ref)
    url = to_string(payload["url"] || "")
    ref = ref_from_url(url) || fallback_ref

    ref =
      if is_nil(ref) and is_integer(payload["number"]) and is_binary(payload["owner"]) and
           is_binary(payload["repo"]) do
        %PullRequestRef{owner: payload["owner"], repo: payload["repo"], number: payload["number"]}
      else
        ref
      end

    if ref do
      %PullRequestInfo{
        ref: ref,
        url:
          if(url == "",
            do: "https://github.com/#{ref.owner}/#{ref.repo}/pull/#{ref.number}",
            else: url
          ),
        state: to_string(payload["state"] || ""),
        base_ref_name: maybe_string(payload["baseRefName"]),
        merged_at: maybe_string(payload["mergedAt"]),
        head_ref_name: maybe_string(payload["headRefName"]),
        body: Utils.truncate(to_string(payload["body"] || ""), 50_000)
      }
    end
  end

  def pr_info_from_payload(_, _), do: nil

  def ref_from_url(url) do
    case Regex.run(@github_pr_url_re, url) do
      [_match, owner, repo, number] ->
        %PullRequestRef{owner: owner, repo: repo, number: String.to_integer(number)}

      _ ->
        nil
    end
  end

  def dedupe_strings(values) do
    values
    |> Enum.reduce({MapSet.new(), []}, fn value, {seen, acc} ->
      if MapSet.member?(seen, value),
        do: {seen, acc},
        else: {MapSet.put(seen, value), acc ++ [value]}
    end)
    |> elem(1)
  end

  defp dedupe_pairs(values) do
    values
    |> Enum.reduce({MapSet.new(), []}, fn value, {seen, acc} ->
      if MapSet.member?(seen, value),
        do: {seen, acc},
        else: {MapSet.put(seen, value), acc ++ [value]}
    end)
    |> elem(1)
  end

  defp maybe_string(nil), do: nil
  defp maybe_string(value), do: to_string(value)
end
