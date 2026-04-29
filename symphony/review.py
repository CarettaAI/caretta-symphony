from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
from typing import Any, Protocol

from .models import Issue
from .utils import truncate

GITHUB_PR_URL_RE = re.compile(r"https://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)", re.IGNORECASE)
OWNER_REPO_PR_RE = re.compile(r"(?<![\w./-])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\d+)")
WORKSPACE_METADATA = ".symphony-workspace.json"
MAX_DEPENDENCY_PRS = 50


@dataclass(frozen=True, slots=True)
class PullRequestRef:
    owner: str
    repo: str
    number: int

    @property
    def repo_full_name(self) -> str:
        return f"{self.owner}/{self.repo}"

    @property
    def canonical(self) -> str:
        return f"{self.repo_full_name}#{self.number}"


@dataclass(frozen=True, slots=True)
class PullRequestInfo:
    ref: PullRequestRef
    url: str
    state: str
    base_ref_name: str | None = None
    merged_at: str | None = None
    head_ref_name: str | None = None
    body: str = ""


@dataclass(slots=True)
class ReviewMergeResult:
    ready: bool
    required_prs: list[PullRequestInfo] = field(default_factory=list)
    unresolved_refs: list[str] = field(default_factory=list)
    blockers: list[str] = field(default_factory=list)

    @property
    def reason(self) -> str:
        if self.ready:
            return f"all {len(self.required_prs)} required PR(s) are merged"
        if self.blockers:
            return "; ".join(self.blockers)
        if self.unresolved_refs:
            return f"unresolved PR reference(s): {', '.join(self.unresolved_refs)}"
        return "no required PRs were found"


class PullRequestInspector(Protocol):
    async def view_pr_url(self, url: str) -> PullRequestInfo | None:
        ...

    async def view_pr_ref(self, ref: PullRequestRef) -> PullRequestInfo | None:
        ...

    async def list_prs_for_branch(self, repo_full_name: str, branch: str, base_branch: str) -> list[PullRequestInfo]:
        ...


class GhPullRequestInspector:
    async def view_pr_url(self, url: str) -> PullRequestInfo | None:
        body = await self._run_gh_json(
            "pr",
            "view",
            url,
            "--json",
            "number,url,state,mergedAt,baseRefName,headRefName,body",
        )
        return _pr_info_from_payload(body)

    async def view_pr_ref(self, ref: PullRequestRef) -> PullRequestInfo | None:
        body = await self._run_gh_json(
            "pr",
            "view",
            str(ref.number),
            "--repo",
            ref.repo_full_name,
            "--json",
            "number,url,state,mergedAt,baseRefName,headRefName,body",
        )
        return _pr_info_from_payload(body, fallback_ref=ref)

    async def list_prs_for_branch(self, repo_full_name: str, branch: str, base_branch: str) -> list[PullRequestInfo]:
        body = await self._run_gh_json(
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
            "number,url,state,mergedAt,baseRefName,headRefName,body",
        )
        if not isinstance(body, list):
            return []
        prs = [_pr_info_from_payload(item) for item in body]
        return [pr for pr in prs if pr is not None]

    async def _run_gh_json(self, *args: str) -> Any | None:
        try:
            proc = await asyncio.create_subprocess_exec(
                "gh",
                *args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except OSError:
            return None
        stdout, stderr = await proc.communicate()
        if proc.returncode != 0:
            return None
        try:
            return json.loads(stdout.decode("utf-8"))
        except json.JSONDecodeError:
            return None


class ReviewPullRequestResolver:
    def __init__(self, inspector: PullRequestInspector | None = None):
        self.inspector = inspector or GhPullRequestInspector()

    async def evaluate(
        self,
        issue: Issue,
        *,
        comments: list[dict[str, Any]],
        workspace_path: Path,
        base_branch: str,
    ) -> ReviewMergeResult:
        required: dict[str, PullRequestInfo] = {}
        unresolved: set[str] = set()
        queue: list[PullRequestInfo] = []

        initial_urls = _dedupe_strings(
            [
                *_issue_attachment_pr_urls(issue),
                *_comment_pr_urls(comments),
            ]
        )
        for url in initial_urls:
            pr = await self.inspector.view_pr_url(url)
            if pr is None:
                unresolved.add(url)
                continue
            if _add_required(required, pr):
                queue.append(pr)

        metadata = _load_workspace_metadata(workspace_path)
        for repo_full_name, branch in _workspace_branch_candidates(metadata, issue):
            for pr in await self.inspector.list_prs_for_branch(repo_full_name, branch, base_branch):
                if _add_required(required, pr):
                    queue.append(pr)

        while queue and len(required) + len(unresolved) < MAX_DEPENDENCY_PRS:
            pr = queue.pop(0)
            for ref in _dependency_refs(pr.body):
                if ref.canonical in required:
                    continue
                dependency = await self.inspector.view_pr_ref(ref)
                if dependency is None:
                    unresolved.add(ref.canonical)
                    continue
                if _add_required(required, dependency):
                    queue.append(dependency)

        blockers = _merge_blockers(required.values(), unresolved, base_branch)
        return ReviewMergeResult(
            ready=bool(required) and not blockers,
            required_prs=sorted(required.values(), key=lambda pr: pr.ref.canonical),
            unresolved_refs=sorted(unresolved),
            blockers=blockers,
        )


def _issue_attachment_pr_urls(issue: Issue) -> list[str]:
    urls: list[str] = []
    for attachment in issue.attachments:
        for value in (attachment.url, attachment.title, attachment.subtitle):
            urls.extend(_pr_urls(str(value or "")))
    return urls


def _comment_pr_urls(comments: list[dict[str, Any]]) -> list[str]:
    urls: list[str] = []
    for comment in comments:
        body = comment.get("body") or comment.get("text") or comment.get("content") or ""
        if isinstance(body, str) and "## Codex Workpad" in body:
            urls.extend(_pr_urls(body))
    return urls


def _pr_urls(text: str) -> list[str]:
    return [
        f"https://github.com/{match.group(1)}/{match.group(2)}/pull/{match.group(3)}"
        for match in GITHUB_PR_URL_RE.finditer(text)
    ]


def _dependency_refs(text: str) -> list[PullRequestRef]:
    refs: dict[str, PullRequestRef] = {}
    for match in GITHUB_PR_URL_RE.finditer(text):
        ref = PullRequestRef(owner=match.group(1), repo=match.group(2), number=int(match.group(3)))
        refs[ref.canonical] = ref
    for match in OWNER_REPO_PR_RE.finditer(text):
        owner, repo = match.group(1).split("/", 1)
        ref = PullRequestRef(owner=owner, repo=repo, number=int(match.group(2)))
        refs[ref.canonical] = ref
    return sorted(refs.values(), key=lambda item: item.canonical)


def _add_required(required: dict[str, PullRequestInfo], pr: PullRequestInfo) -> bool:
    if pr.ref.canonical in required:
        return False
    required[pr.ref.canonical] = pr
    return True


def _merge_blockers(prs: Any, unresolved: set[str], base_branch: str) -> list[str]:
    blockers: list[str] = []
    if unresolved:
        blockers.append(f"unresolved PR reference(s): {', '.join(sorted(unresolved))}")
    prs = list(prs)
    if not prs and not unresolved:
        blockers.append("no required PRs were found")
    for pr in prs:
        if pr.base_ref_name != base_branch:
            blockers.append(f"{pr.ref.canonical} targets {pr.base_ref_name or 'unknown'} instead of {base_branch}")
            continue
        if pr.state.upper() != "MERGED":
            blockers.append(f"{pr.ref.canonical} is {pr.state or 'unknown'}")
    return blockers


def _load_workspace_metadata(workspace_path: Path) -> dict[str, Any]:
    path = workspace_path / WORKSPACE_METADATA
    try:
        body = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return body if isinstance(body, dict) else {}


def _workspace_branch_candidates(metadata: dict[str, Any], issue: Issue) -> list[tuple[str, str]]:
    candidates: list[tuple[str, str]] = []
    repos = metadata.get("repositories")
    if isinstance(repos, list):
        for repo in repos:
            if not isinstance(repo, dict) or not repo.get("edit_allowed", True):
                continue
            repo_full_name = _repo_full_name(repo)
            git = repo.get("git") if isinstance(repo.get("git"), dict) else {}
            branch = git.get("expected_branch") or git.get("current_branch") or issue.branch_name
            if repo_full_name and branch:
                candidates.append((repo_full_name, str(branch)))
    return _dedupe_pairs(candidates)


def _repo_full_name(repo: dict[str, Any]) -> str | None:
    slug = repo.get("slug")
    if isinstance(slug, str) and "/" in slug:
        return slug
    remote = repo.get("remote_url")
    if not isinstance(remote, str):
        git = repo.get("git") if isinstance(repo.get("git"), dict) else {}
        remote = git.get("remote_url") if isinstance(git.get("remote_url"), str) else ""
    return _repo_full_name_from_remote(remote)


def _repo_full_name_from_remote(remote: str) -> str | None:
    text = remote.strip()
    if text.startswith("git@github.com:"):
        text = "https://github.com/" + text.removeprefix("git@github.com:")
    match = re.search(r"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", text)
    if not match:
        return None
    return f"{match.group(1)}/{match.group(2)}"


def _pr_info_from_payload(payload: Any, *, fallback_ref: PullRequestRef | None = None) -> PullRequestInfo | None:
    if not isinstance(payload, dict):
        return None
    url = str(payload.get("url") or "")
    ref = _ref_from_url(url) or fallback_ref
    number = payload.get("number")
    if ref is None and isinstance(number, int):
        owner = payload.get("owner")
        repo = payload.get("repo")
        if isinstance(owner, str) and isinstance(repo, str):
            ref = PullRequestRef(owner=owner, repo=repo, number=number)
    if ref is None:
        return None
    return PullRequestInfo(
        ref=ref,
        url=url or f"https://github.com/{ref.owner}/{ref.repo}/pull/{ref.number}",
        state=str(payload.get("state") or ""),
        base_ref_name=str(payload["baseRefName"]) if payload.get("baseRefName") is not None else None,
        merged_at=str(payload["mergedAt"]) if payload.get("mergedAt") is not None else None,
        head_ref_name=str(payload["headRefName"]) if payload.get("headRefName") is not None else None,
        body=truncate(str(payload.get("body") or ""), 50000),
    )


def _ref_from_url(url: str) -> PullRequestRef | None:
    match = GITHUB_PR_URL_RE.search(url)
    if not match:
        return None
    return PullRequestRef(owner=match.group(1), repo=match.group(2), number=int(match.group(3)))


def _dedupe_strings(values: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def _dedupe_pairs(values: list[tuple[str, str]]) -> list[tuple[str, str]]:
    result: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result
