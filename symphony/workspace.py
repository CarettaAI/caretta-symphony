from __future__ import annotations

import asyncio
import json
import logging
import shlex
import shutil
from pathlib import Path
from typing import Any

from .config import HooksConfig, RepositoryConfig, RepositoryPlanningConfig, WorkspaceConfig
from .errors import HookError, WorkspaceError
from .logging import log_event
from .models import RepoPlan, RepoPlanItem, Workspace
from .utils import isoformat_z, now_utc, resolve_under_root, sanitize_workspace_key, truncate

LOGGER = logging.getLogger(__name__)


class WorkspaceManager:
    def __init__(self, workspace_config: WorkspaceConfig, hooks: HooksConfig):
        self.root = workspace_config.root.resolve(strict=False)
        self.hooks = hooks

    def workspace_path_for_identifier(self, identifier: str) -> Path:
        return resolve_under_root(self.root, sanitize_workspace_key(identifier))

    async def create_for_issue(self, identifier: str) -> Workspace:
        workspace_key = sanitize_workspace_key(identifier)
        workspace_path = resolve_under_root(self.root, workspace_key)
        self.root.mkdir(parents=True, exist_ok=True)
        created_now = False
        if workspace_path.exists() and not workspace_path.is_dir():
            raise WorkspaceError("workspace_path_not_directory", f"workspace path exists and is not a directory: {workspace_path}")
        if not workspace_path.exists():
            workspace_path.mkdir(parents=False)
            created_now = True
        workspace = Workspace(path=workspace_path, workspace_key=workspace_key, created_now=created_now)
        if created_now and self.hooks.after_create:
            await self.run_hook("after_create", workspace.path, fatal=True)
        return workspace

    async def materialize_repo_plan(
        self,
        workspace: Workspace,
        repo_plan: RepoPlan,
        config: RepositoryPlanningConfig,
    ) -> Workspace:
        if not repo_plan.coding_task or repo_plan.primary_repo is None:
            workspace.repo_plan = repo_plan
            return workspace

        if self._workspace_requires_quarantine(workspace.path, repo_plan, config):
            if not config.quarantine_on_mismatch:
                raise WorkspaceError(
                    "workspace_repo_mismatch",
                    f"workspace does not match repo plan and quarantine_on_mismatch is false: {workspace.path}",
                )
            self._quarantine_workspace(workspace.path)
            workspace.path.mkdir(parents=False, exist_ok=False)
            workspace.created_now = True

        repos_dir = workspace.path / "repos"
        repos_dir.mkdir(parents=True, exist_ok=True)
        repository_by_slug = config.repository_by_slug
        repo_metadata: list[dict[str, Any]] = []
        for planned_repo in repo_plan.all_repos():
            repo_config = repository_by_slug.get(planned_repo.slug)
            if repo_config is None:
                raise WorkspaceError("unknown_planned_repository", f"repo plan references unknown repo: {planned_repo.slug}")
            repo_path = repos_dir / self._repo_path_name(planned_repo, repo_config)
            base_branch = _base_branch_name(repo_config.base_branch or config.base_branch)
            expected_branch = self._expected_branch_name(repo_plan.issue_identifier, planned_repo, repo_config, config.branch_prefix)
            checkout_metadata = await self._ensure_repo_checkout(
                repo_path,
                repo_config,
                config.clone_timeout_ms,
                base_branch=base_branch,
                expected_branch=expected_branch,
            )
            repo_metadata.append(
                {
                    "slug": planned_repo.slug,
                    "role": planned_repo.role,
                    "edit_allowed": planned_repo.edit_allowed,
                    "path_name": self._repo_path_name(planned_repo, repo_config),
                    "path": f"repos/{self._repo_path_name(planned_repo, repo_config)}",
                    "remote_url": checkout_metadata.get("remote_url"),
                    "git": checkout_metadata,
                }
            )

        self._write_repo_metadata(workspace.path, repo_plan, repo_metadata)
        workspace.repo_plan = repo_plan
        workspace.primary_repo_path = self.repo_path(workspace.path, repo_plan.primary_repo, repository_by_slug)
        return workspace

    def repo_path(self, workspace_path: Path, repo_item: RepoPlanItem, repository_by_slug: dict[str, RepositoryConfig]) -> Path:
        repo_config = repository_by_slug[repo_item.slug]
        return workspace_path / "repos" / self._repo_path_name(repo_item, repo_config)

    async def before_run(self, workspace_path: Path) -> None:
        if self.hooks.before_run:
            await self.run_hook("before_run", workspace_path, fatal=True)

    async def after_run(self, workspace_path: Path) -> None:
        if self.hooks.after_run:
            try:
                await self.run_hook("after_run", workspace_path, fatal=False)
            except HookError:
                pass

    async def remove_for_identifier(self, identifier: str) -> None:
        workspace_path = self.workspace_path_for_identifier(identifier)
        if not workspace_path.exists():
            return
        if self.hooks.before_remove:
            try:
                await self.run_hook("before_remove", workspace_path, fatal=False)
            except HookError:
                pass
        if workspace_path.exists():
            if workspace_path.is_dir():
                shutil.rmtree(workspace_path)
            else:
                workspace_path.unlink()
        log_event(LOGGER, logging.INFO, "workspace_removed", issue_identifier=identifier, workspace_path=workspace_path)

    def _workspace_requires_quarantine(
        self,
        workspace_path: Path,
        repo_plan: RepoPlan,
        config: RepositoryPlanningConfig,
    ) -> bool:
        if not workspace_path.exists():
            return False
        if (workspace_path / ".git").is_dir():
            log_event(LOGGER, logging.WARNING, "legacy_workspace_checkout_detected", workspace_path=workspace_path)
            return True
        repos_dir = workspace_path / "repos"
        ignored = {"repo-plan.json", ".symphony-workspace.json", "repos"}
        existing_entries = [entry.name for entry in workspace_path.iterdir() if entry.name not in ignored]
        if existing_entries and not repos_dir.exists():
            log_event(
                LOGGER,
                logging.WARNING,
                "non_repo_plan_workspace_detected",
                workspace_path=workspace_path,
                entries=existing_entries[:10],
            )
            return True
        repository_by_slug = config.repository_by_slug
        for planned_repo in repo_plan.all_repos():
            repo_config = repository_by_slug.get(planned_repo.slug)
            if repo_config is None:
                continue
            repo_path = workspace_path / "repos" / self._repo_path_name(planned_repo, repo_config)
            if repo_path.exists() and not self._repo_checkout_matches(repo_path, repo_config):
                log_event(
                    LOGGER,
                    logging.WARNING,
                    "repo_checkout_mismatch_detected",
                    workspace_path=workspace_path,
                    repo_path=repo_path,
                    expected_slug=repo_config.slug,
                )
                return True
        return False

    def _quarantine_workspace(self, workspace_path: Path) -> None:
        if not workspace_path.exists():
            return
        quarantine_root = workspace_path.parent / "_quarantine"
        quarantine_root.mkdir(parents=True, exist_ok=True)
        timestamp = isoformat_z(now_utc()).replace(":", "").replace(".", "-") if isoformat_z(now_utc()) else "unknown"
        target = quarantine_root / f"{workspace_path.name}-{timestamp}"
        suffix = 1
        while target.exists():
            suffix += 1
            target = quarantine_root / f"{workspace_path.name}-{timestamp}-{suffix}"
        workspace_path.rename(target)
        log_event(LOGGER, logging.WARNING, "workspace_quarantined", original_path=workspace_path, quarantine_path=target)

    async def _ensure_repo_checkout(
        self,
        repo_path: Path,
        repo_config: RepositoryConfig,
        timeout_ms: int,
        *,
        base_branch: str,
        expected_branch: str,
    ) -> dict[str, Any]:
        if repo_path.exists():
            if not repo_path.is_dir():
                raise WorkspaceError("repo_path_not_directory", f"repo path exists and is not a directory: {repo_path}")
            if not self._repo_checkout_matches(repo_path, repo_config):
                raise WorkspaceError("repo_checkout_mismatch", f"repo path exists but remote does not match {repo_config.slug}: {repo_path}")
            current_branch = await self._git_output(
                repo_path,
                ["branch", "--show-current"],
                timeout_ms,
                "repo_branch_read_failed",
                f"failed reading current branch for {repo_config.slug}",
            )
            await self._install_pre_push_guard(repo_path, expected_branch)
            return {
                "base_branch": base_branch,
                "base_ref": f"origin/{base_branch}",
                "base_sha": None,
                "expected_branch": expected_branch,
                "expected_ref": f"refs/heads/{expected_branch}",
                "current_branch": current_branch,
                "branch_prepared": False,
                "pre_push_guard": True,
                "remote_url": self._git_remote(repo_path),
            }
        source = str(repo_config.local_path or repo_config.remote_url or "")
        if not source:
            raise WorkspaceError("repository_missing_source", f"repository has no clone source: {repo_config.slug}")
        repo_path.parent.mkdir(parents=True, exist_ok=True)
        command = ["git", "clone"]
        if repo_config.local_path is not None:
            command.append("--no-hardlinks")
        command.extend([source, str(repo_path)])
        log_event(LOGGER, logging.INFO, "repo_clone_started", repo_slug=repo_config.slug, source=source, repo_path=repo_path)
        proc = await asyncio.create_subprocess_exec(
            *command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout_ms / 1000)
        except TimeoutError as exc:
            proc.kill()
            await proc.communicate()
            raise WorkspaceError("repo_clone_timeout", f"git clone timed out after {timeout_ms} ms: {repo_config.slug}", cause=exc) from exc
        if proc.returncode != 0:
            output = truncate((stdout or b"").decode(errors="replace") + (stderr or b"").decode(errors="replace"), 2000)
            raise WorkspaceError("repo_clone_failed", f"git clone failed for {repo_config.slug}: {output}")
        if repo_config.remote_url:
            await self._set_repo_remote(repo_path, repo_config.remote_url, timeout_ms)
        base_sha = await self._prepare_expected_branch(repo_path, repo_config.slug, base_branch, expected_branch, timeout_ms)
        await self._install_pre_push_guard(repo_path, expected_branch)
        log_event(LOGGER, logging.INFO, "repo_clone_completed", repo_slug=repo_config.slug, repo_path=repo_path)
        return {
            "base_branch": base_branch,
            "base_ref": f"origin/{base_branch}",
            "base_sha": base_sha,
            "expected_branch": expected_branch,
            "expected_ref": f"refs/heads/{expected_branch}",
            "current_branch": expected_branch,
            "branch_prepared": True,
            "pre_push_guard": True,
            "remote_url": self._git_remote(repo_path),
        }

    async def _set_repo_remote(self, repo_path: Path, remote_url: str, timeout_ms: int) -> None:
        proc = await asyncio.create_subprocess_exec(
            "git",
            "-C",
            str(repo_path),
            "remote",
            "set-url",
            "origin",
            remote_url,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout_ms / 1000)
        except TimeoutError as exc:
            proc.kill()
            await proc.communicate()
            raise WorkspaceError("repo_remote_set_timeout", f"git remote set-url timed out for {repo_path}", cause=exc) from exc
        if proc.returncode != 0:
            output = truncate((stdout or b"").decode(errors="replace") + (stderr or b"").decode(errors="replace"), 2000)
            raise WorkspaceError("repo_remote_set_failed", f"git remote set-url failed for {repo_path}: {output}")

    async def _prepare_expected_branch(
        self,
        repo_path: Path,
        repo_slug: str,
        base_branch: str,
        expected_branch: str,
        timeout_ms: int,
    ) -> str:
        await self._git_output(
            repo_path,
            ["fetch", "origin", f"+{base_branch}:refs/remotes/origin/{base_branch}"],
            timeout_ms,
            "repo_base_fetch_failed",
            f"failed fetching origin/{base_branch} for {repo_slug}",
        )
        base_sha = await self._git_output(
            repo_path,
            ["rev-parse", f"origin/{base_branch}"],
            timeout_ms,
            "repo_base_ref_failed",
            f"failed resolving origin/{base_branch} for {repo_slug}",
        )
        await self._git_output(
            repo_path,
            ["checkout", "-B", expected_branch, f"origin/{base_branch}"],
            timeout_ms,
            "repo_branch_checkout_failed",
            f"failed checking out {expected_branch} from origin/{base_branch} for {repo_slug}",
        )
        await self._git_output(
            repo_path,
            ["config", f"branch.{expected_branch}.remote", "origin"],
            timeout_ms,
            "repo_branch_config_failed",
            f"failed configuring push remote for {expected_branch} in {repo_slug}",
        )
        await self._git_output(
            repo_path,
            ["config", f"branch.{expected_branch}.merge", f"refs/heads/{expected_branch}"],
            timeout_ms,
            "repo_branch_config_failed",
            f"failed configuring upstream branch for {expected_branch} in {repo_slug}",
        )
        log_event(
            LOGGER,
            logging.INFO,
            "repo_branch_prepared",
            repo_slug=repo_slug,
            repo_path=repo_path,
            base_branch=base_branch,
            base_sha=base_sha,
            expected_branch=expected_branch,
        )
        return base_sha

    async def _git_output(
        self,
        repo_path: Path,
        args: list[str],
        timeout_ms: int,
        error_code: str,
        error_message: str,
    ) -> str:
        proc = await asyncio.create_subprocess_exec(
            "git",
            "-C",
            str(repo_path),
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout_ms / 1000)
        except TimeoutError as exc:
            proc.kill()
            await proc.communicate()
            raise WorkspaceError(error_code, f"{error_message}: timed out after {timeout_ms} ms", cause=exc) from exc
        if proc.returncode != 0:
            output = truncate((stdout or b"").decode(errors="replace") + (stderr or b"").decode(errors="replace"), 2000)
            raise WorkspaceError(error_code, f"{error_message}: {output}")
        return (stdout or b"").decode(errors="replace").strip()

    async def _install_pre_push_guard(self, repo_path: Path, expected_branch: str) -> None:
        git_dir = repo_path / ".git"
        if not git_dir.is_dir():
            raise WorkspaceError("repo_git_dir_missing", f"repo .git directory is missing: {repo_path}")
        hooks_dir = git_dir / "hooks"
        hooks_dir.mkdir(parents=True, exist_ok=True)
        expected_ref = f"refs/heads/{expected_branch}"
        script = f"""#!/bin/sh
expected_branch={shlex.quote(expected_branch)}
expected_ref={shlex.quote(expected_ref)}
zero_oid=0000000000000000000000000000000000000000

current_branch=$(git symbolic-ref --quiet --short HEAD) || {{
  echo "Symphony branch guard: refusing to push from detached HEAD. Expected $expected_branch." >&2
  exit 1
}}

if [ "$current_branch" != "$expected_branch" ]; then
  echo "Symphony branch guard: refusing to push from $current_branch. Expected $expected_branch." >&2
  exit 1
fi

while read local_ref local_oid remote_ref remote_oid
do
  [ -z "$local_ref" ] && continue
  if [ "$local_oid" = "$zero_oid" ]; then
    echo "Symphony branch guard: refusing to delete remote refs from an agent workspace." >&2
    exit 1
  fi
  if [ "$local_ref" != "$expected_ref" ] && [ "$local_ref" != "HEAD" ]; then
    echo "Symphony branch guard: refusing to push $local_ref. Expected $expected_ref." >&2
    exit 1
  fi
  if [ "$remote_ref" != "$expected_ref" ]; then
    echo "Symphony branch guard: refusing to push to $remote_ref. Expected $expected_ref." >&2
    exit 1
  fi
done
exit 0
"""
        hook_path = hooks_dir / "pre-push"
        hook_path.write_text(script, encoding="utf-8")
        hook_path.chmod(0o755)

    def _repo_checkout_matches(self, repo_path: Path, repo_config: RepositoryConfig) -> bool:
        if not (repo_path / ".git").exists():
            return False
        try:
            remote = self._git_remote(repo_path)
        except WorkspaceError:
            return False
        if repo_config.remote_url:
            return _normalize_git_remote(remote) == _normalize_git_remote(repo_config.remote_url)
        if repo_config.local_path is not None:
            try:
                return Path(remote).expanduser().resolve(strict=False) == repo_config.local_path.resolve(strict=False)
            except OSError:
                return False
        return _slug_in_remote(repo_config.slug, remote)

    def _git_remote(self, repo_path: Path) -> str:
        try:
            import subprocess

            result = subprocess.run(
                ["git", "-C", str(repo_path), "config", "--get", "remote.origin.url"],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except OSError as exc:
            raise WorkspaceError("git_remote_failed", f"failed reading git remote for {repo_path}", cause=exc) from exc
        if result.returncode != 0:
            raise WorkspaceError("git_remote_failed", f"failed reading git remote for {repo_path}: {result.stderr}")
        return result.stdout.strip()

    def _write_repo_metadata(self, workspace_path: Path, repo_plan: RepoPlan, repositories: list[dict[str, Any]]) -> None:
        plan_payload = repo_plan.to_dict()
        (workspace_path / "repo-plan.json").write_text(json.dumps(plan_payload, indent=2, sort_keys=True), encoding="utf-8")
        metadata = {
            "version": 1,
            "layout": "multi_repo",
            "updated_at": isoformat_z(now_utc()),
            "repo_plan": plan_payload,
            "repositories": repositories,
        }
        (workspace_path / ".symphony-workspace.json").write_text(json.dumps(metadata, indent=2, sort_keys=True), encoding="utf-8")

    def _repo_path_name(self, repo_item: RepoPlanItem, repo_config: RepositoryConfig) -> str:
        return sanitize_workspace_key(repo_item.path_name or repo_config.path_name)

    def _expected_branch_name(
        self,
        issue_identifier: str,
        repo_item: RepoPlanItem,
        repo_config: RepositoryConfig,
        branch_prefix: str,
    ) -> str:
        prefix = _branch_segment(branch_prefix) or "Symphony"
        issue_segment = _branch_segment(issue_identifier)
        repo_segment = _branch_segment(repo_item.path_name or repo_config.path_name)
        return f"{prefix}/{issue_segment}-{repo_segment}"

    async def run_hook(self, hook_name: str, workspace_path: Path, *, fatal: bool) -> None:
        script = getattr(self.hooks, hook_name)
        if not script:
            return
        workspace_abs = workspace_path.resolve(strict=False)
        root_abs = self.root.resolve(strict=False)
        if str(workspace_abs) != str(workspace_path.resolve(strict=False)):
            raise WorkspaceError("invalid_workspace_cwd", f"workspace path is not normalized: {workspace_path}")
        if workspace_abs == root_abs or root_abs not in workspace_abs.parents:
            raise WorkspaceError("invalid_workspace_cwd", f"workspace path is outside workspace root: {workspace_abs}")
        log_event(LOGGER, logging.INFO, "hook_started", hook=hook_name, workspace_path=workspace_abs)
        proc = await asyncio.create_subprocess_exec(
            "bash",
            "-lc",
            script,
            cwd=workspace_abs,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=self.hooks.timeout_ms / 1000)
        except TimeoutError as exc:
            proc.kill()
            await proc.communicate()
            message = f"hook timed out after {self.hooks.timeout_ms} ms"
            log_event(LOGGER, logging.ERROR, "hook_timed_out", hook=hook_name, workspace_path=workspace_abs, fatal=fatal)
            if fatal:
                raise HookError("hook_timeout", message, cause=exc) from exc
            raise HookError("hook_timeout", message, cause=exc) from exc
        if proc.returncode != 0:
            output = truncate((stdout or b"").decode(errors="replace") + (stderr or b"").decode(errors="replace"), 2000)
            message = f"hook failed with exit code {proc.returncode}: {output}"
            log_event(
                LOGGER,
                logging.ERROR,
                "hook_failed",
                hook=hook_name,
                workspace_path=workspace_abs,
                exit_code=proc.returncode,
                fatal=fatal,
                output=output,
            )
            if fatal:
                raise HookError("hook_failed", message)
            raise HookError("hook_failed", message)
        log_event(LOGGER, logging.INFO, "hook_completed", hook=hook_name, workspace_path=workspace_abs)


def _normalize_git_remote(value: str | None) -> str:
    text = (value or "").strip().lower()
    if text.startswith("git@github.com:"):
        text = "https://github.com/" + text.removeprefix("git@github.com:")
    if text.endswith(".git"):
        text = text[:-4]
    return text.rstrip("/")


def _slug_in_remote(slug: str, remote: str) -> bool:
    normalized_slug = slug.strip().lower()
    return normalized_slug in _normalize_git_remote(remote)


def _base_branch_name(value: str | None) -> str:
    text = (value or "dev").strip()
    if text.startswith("refs/heads/"):
        text = text.removeprefix("refs/heads/")
    if text.startswith("origin/"):
        text = text.removeprefix("origin/")
    parts = [_branch_segment(part) for part in text.split("/")]
    return "/".join(part for part in parts if part) or "dev"


def _branch_segment(value: str | None) -> str:
    text = sanitize_workspace_key((value or "").strip())
    return text.strip("._-")
