from __future__ import annotations


class SymphonyError(Exception):
    """Base exception carrying a stable machine-readable code."""

    def __init__(self, code: str, message: str, *, cause: BaseException | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.__cause__ = cause

    def __str__(self) -> str:
        return f"{self.code}: {self.message}"


class WorkflowError(SymphonyError):
    pass


class ConfigError(SymphonyError):
    pass


class TrackerError(SymphonyError):
    pass


class WorkspaceError(SymphonyError):
    pass


class HookError(WorkspaceError):
    pass


class TemplateError(SymphonyError):
    pass


class AgentError(SymphonyError):
    pass
