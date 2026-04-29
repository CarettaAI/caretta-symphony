from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from symphony.models import Issue, IssueAttachment
from symphony.review import PullRequestInfo, PullRequestRef, ReviewPullRequestResolver


def pr(owner: str, repo: str, number: int, *, state: str = "MERGED", base: str = "dev", body: str = "") -> PullRequestInfo:
    return PullRequestInfo(
        ref=PullRequestRef(owner=owner, repo=repo, number=number),
        url=f"https://github.com/{owner}/{repo}/pull/{number}",
        state=state,
        base_ref_name=base,
        merged_at="2026-04-29T12:00:00Z" if state == "MERGED" else None,
        body=body,
    )


class FakeInspector:
    def __init__(self) -> None:
        self.urls: dict[str, PullRequestInfo | None] = {}
        self.refs: dict[str, PullRequestInfo | None] = {}
        self.branches: dict[tuple[str, str, str], list[PullRequestInfo]] = {}

    async def view_pr_url(self, url: str) -> PullRequestInfo | None:
        return self.urls.get(url)

    async def view_pr_ref(self, ref: PullRequestRef) -> PullRequestInfo | None:
        return self.refs.get(ref.canonical)

    async def list_prs_for_branch(self, repo_full_name: str, branch: str, base_branch: str) -> list[PullRequestInfo]:
        return self.branches.get((repo_full_name, branch, base_branch), [])


@pytest.mark.asyncio
async def test_review_resolver_requires_linked_workpad_and_dependency_prs(tmp_path: Path) -> None:
    inspector = FakeInspector()
    first = pr("ExampleOrg", "app", 1, body="Depends on ExampleOrg/api#3")
    second = pr("ExampleOrg", "app", 2)
    dependency = pr("ExampleOrg", "api", 3)
    inspector.urls[first.url] = first
    inspector.urls[second.url] = second
    inspector.refs[dependency.ref.canonical] = dependency
    resolver = ReviewPullRequestResolver(inspector)
    issue = Issue(
        id="ENG-1",
        identifier="ENG-1",
        title="Ready",
        state="In Review",
        attachments=[IssueAttachment(url=first.url)],
    )
    comments: list[dict[str, Any]] = [{"body": f"## Codex Workpad\nPR: {second.url}"}]

    result = await resolver.evaluate(issue, comments=comments, workspace_path=tmp_path, base_branch="dev")

    assert result.ready is True
    assert [item.ref.canonical for item in result.required_prs] == [
        "ExampleOrg/api#3",
        "ExampleOrg/app#1",
        "ExampleOrg/app#2",
    ]


@pytest.mark.asyncio
async def test_review_resolver_blocks_on_open_wrong_base_and_unresolved_dependency(tmp_path: Path) -> None:
    inspector = FakeInspector()
    open_pr = pr("ExampleOrg", "app", 1, state="OPEN", body="Needs ExampleOrg/missing#7")
    wrong_base = pr("ExampleOrg", "api", 2, base="main")
    inspector.urls[open_pr.url] = open_pr
    inspector.urls[wrong_base.url] = wrong_base
    resolver = ReviewPullRequestResolver(inspector)
    issue = Issue(
        id="ENG-1",
        identifier="ENG-1",
        title="Ready",
        state="In Review",
        attachments=[IssueAttachment(url=open_pr.url), IssueAttachment(url=wrong_base.url)],
    )

    result = await resolver.evaluate(issue, comments=[], workspace_path=tmp_path, base_branch="dev")

    assert result.ready is False
    assert "ExampleOrg/app#1 is OPEN" in result.reason
    assert "ExampleOrg/api#2 targets main instead of dev" in result.reason
    assert "ExampleOrg/missing#7" in result.reason


@pytest.mark.asyncio
async def test_review_resolver_uses_workspace_branch_fallback(tmp_path: Path) -> None:
    workspace = tmp_path / "ENG-1"
    workspace.mkdir()
    (workspace / ".symphony-workspace.json").write_text(
        json.dumps(
            {
                "repositories": [
                    {
                        "slug": "ExampleOrg/app",
                        "edit_allowed": True,
                        "git": {"expected_branch": "Symphony/ENG-1-app"},
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    inspector = FakeInspector()
    fallback = pr("ExampleOrg", "app", 4)
    inspector.branches[("ExampleOrg/app", "Symphony/ENG-1-app", "dev")] = [fallback]
    resolver = ReviewPullRequestResolver(inspector)
    issue = Issue(id="ENG-1", identifier="ENG-1", title="Ready", state="In Review")

    result = await resolver.evaluate(issue, comments=[], workspace_path=workspace, base_branch="dev")

    assert result.ready is True
    assert [item.ref.canonical for item in result.required_prs] == ["ExampleOrg/app#4"]


@pytest.mark.asyncio
async def test_review_resolver_requires_some_pr_evidence(tmp_path: Path) -> None:
    resolver = ReviewPullRequestResolver(FakeInspector())
    issue = Issue(id="ENG-1", identifier="ENG-1", title="Ready", state="In Review")

    result = await resolver.evaluate(issue, comments=[], workspace_path=tmp_path, base_branch="dev")

    assert result.ready is False
    assert result.reason == "no required PRs were found"
