from __future__ import annotations

import json
from pathlib import Path
import subprocess

import pytest

from symphony.config import HooksConfig, RepositoryConfig, RepositoryPlanningConfig, WorkspaceConfig
from symphony.errors import HookError, WorkspaceError
from symphony.models import RepoPlan, RepoPlanItem
from symphony.workspace import WorkspaceManager


@pytest.mark.asyncio
async def test_workspace_sanitizes_and_after_create_runs_once(tmp_path: Path) -> None:
    manager = WorkspaceManager(
        WorkspaceConfig(root=tmp_path / "root"),
        HooksConfig(after_create="echo created >> marker.txt", before_run="echo before >> marker.txt"),
    )

    first = await manager.create_for_issue("ABC/1")
    second = await manager.create_for_issue("ABC/1")
    await manager.before_run(first.path)

    assert first.workspace_key == "ABC_1"
    assert second.created_now is False
    assert first.path == second.path
    assert (first.path / "marker.txt").read_text(encoding="utf-8").splitlines() == ["created", "before"]


@pytest.mark.asyncio
async def test_before_run_failure_is_fatal(tmp_path: Path) -> None:
    manager = WorkspaceManager(WorkspaceConfig(root=tmp_path), HooksConfig(before_run="exit 7"))
    workspace = await manager.create_for_issue("ABC-1")

    with pytest.raises(HookError) as exc:
        await manager.before_run(workspace.path)
    assert exc.value.code == "hook_failed"


@pytest.mark.asyncio
async def test_existing_non_directory_workspace_fails(tmp_path: Path) -> None:
    root = tmp_path / "root"
    root.mkdir()
    (root / "ABC-1").write_text("not a dir", encoding="utf-8")
    manager = WorkspaceManager(WorkspaceConfig(root=root), HooksConfig())

    with pytest.raises(WorkspaceError) as exc:
        await manager.create_for_issue("ABC-1")
    assert exc.value.code == "workspace_path_not_directory"


@pytest.mark.asyncio
async def test_repo_plan_materializes_multi_repo_workspace_and_quarantines_legacy_checkout(tmp_path: Path) -> None:
    project_source, project_remote = _git_repo_with_remote(tmp_path, "desktop-runtime")
    wrong_source, _ = _git_repo_with_remote(tmp_path, "model-gateway")
    _checkout_branch_with_commit(project_source, "feature/aec-bugfix", "feature.txt")
    root = tmp_path / "root"
    root.mkdir()
    legacy_workspace = root / "ENG-251"
    subprocess.run(["git", "clone", str(wrong_source), str(legacy_workspace)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    manager = WorkspaceManager(WorkspaceConfig(root=root), HooksConfig())
    workspace = await manager.create_for_issue("ENG-251")
    plan = RepoPlan(
        issue_identifier="ENG-251",
        coding_task=True,
        planner="rules",
        source="test",
        primary_repo=RepoPlanItem(slug="ExampleOrg/desktop-runtime", role="primary", path_name="desktop-runtime"),
    )
    repo_config = RepositoryPlanningConfig(
        enabled=True,
        repositories=[
            RepositoryConfig(
                slug="ExampleOrg/desktop-runtime",
                local_path=project_source,
                remote_url=str(project_remote),
            )
        ],
    )

    prepared = await manager.materialize_repo_plan(workspace, plan, repo_config)

    assert prepared.primary_repo_path == root / "ENG-251" / "repos" / "desktop-runtime"
    assert (prepared.primary_repo_path / ".git").exists()
    assert (root / "ENG-251" / "repo-plan.json").exists()
    assert list((root / "_quarantine").glob("ENG-251-*"))
    remote = subprocess.run(
        ["git", "-C", str(prepared.primary_repo_path), "config", "--get", "remote.origin.url"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()
    branch = subprocess.run(
        ["git", "-C", str(prepared.primary_repo_path), "branch", "--show-current"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()
    metadata = json.loads((root / "ENG-251" / ".symphony-workspace.json").read_text(encoding="utf-8"))

    assert remote == str(project_remote)
    assert branch == "Symphony/ENG-251-desktop-runtime"
    assert not (prepared.primary_repo_path / "feature.txt").exists()
    assert metadata["repositories"][0]["git"]["expected_branch"] == "Symphony/ENG-251-desktop-runtime"
    assert metadata["repositories"][0]["git"]["base_ref"] == "origin/dev"
    assert (prepared.primary_repo_path / ".git" / "hooks" / "pre-push").exists()


@pytest.mark.asyncio
async def test_pre_push_guard_allows_expected_branch_and_rejects_wrong_pushes(tmp_path: Path) -> None:
    project_source, project_remote = _git_repo_with_remote(tmp_path, "desktop-runtime")
    manager = WorkspaceManager(WorkspaceConfig(root=tmp_path / "root"), HooksConfig())
    workspace = await manager.create_for_issue("ENG-260")
    plan = RepoPlan(
        issue_identifier="ENG-260",
        coding_task=True,
        planner="rules",
        source="test",
        primary_repo=RepoPlanItem(slug="ExampleOrg/desktop-runtime", role="primary", path_name="desktop-runtime"),
    )
    repo_config = RepositoryPlanningConfig(
        enabled=True,
        repositories=[
            RepositoryConfig(
                slug="ExampleOrg/desktop-runtime",
                local_path=project_source,
                remote_url=str(project_remote),
            )
        ],
    )

    prepared = await manager.materialize_repo_plan(workspace, plan, repo_config)
    repo_path = prepared.primary_repo_path
    assert repo_path is not None
    expected_branch = "Symphony/ENG-260-desktop-runtime"

    allowed = subprocess.run(
        ["git", "-C", str(repo_path), "push", "origin", f"HEAD:{expected_branch}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    wrong_destination = subprocess.run(
        ["git", "-C", str(repo_path), "push", "origin", "HEAD:feature/aec-bugfix"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    subprocess.run(["git", "-C", str(repo_path), "checkout", "-b", "feature/aec-bugfix"], check=True)
    wrong_current_branch = subprocess.run(
        ["git", "-C", str(repo_path), "push", "origin", f"HEAD:{expected_branch}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    assert allowed.returncode == 0, allowed.stderr
    assert wrong_destination.returncode != 0
    assert "Symphony branch guard" in wrong_destination.stderr
    assert wrong_current_branch.returncode != 0
    assert "Symphony branch guard" in wrong_current_branch.stderr


def _git_repo_with_remote(tmp_path: Path, name: str) -> tuple[Path, Path]:
    remote = tmp_path / "remotes" / f"{name}.git"
    remote.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
    source = tmp_path / "source" / name
    source.mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=source, check=True)
    _configure_git_user(source)
    (source / "README.md").write_text(f"# {name}\n", encoding="utf-8")
    subprocess.run(["git", "add", "README.md"], cwd=source, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "initial"], cwd=source, check=True)
    subprocess.run(["git", "branch", "-M", "dev"], cwd=source, check=True)
    subprocess.run(["git", "remote", "add", "origin", str(remote)], cwd=source, check=True)
    subprocess.run(["git", "push", "-q", "-u", "origin", "dev"], cwd=source, check=True)
    return source, remote


def _checkout_branch_with_commit(repo_path: Path, branch: str, filename: str) -> None:
    subprocess.run(["git", "checkout", "-q", "-b", branch], cwd=repo_path, check=True)
    (repo_path / filename).write_text("source branch residue\n", encoding="utf-8")
    subprocess.run(["git", "add", filename], cwd=repo_path, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "source branch residue"], cwd=repo_path, check=True)


def _configure_git_user(repo_path: Path) -> None:
    subprocess.run(["git", "config", "user.name", "Symphony Test"], cwd=repo_path, check=True)
    subprocess.run(["git", "config", "user.email", "symphony@example.com"], cwd=repo_path, check=True)
