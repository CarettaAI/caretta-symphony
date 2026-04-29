from __future__ import annotations

import argparse
import asyncio
import logging

from .config import ConfigManager
from .errors import SymphonyError
from .http_server import StatusHTTPServer
from .logging import configure_logging, log_event
from .orchestrator import Orchestrator

LOGGER = logging.getLogger(__name__)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="symphony", description="Run the Symphony automation service.")
    parser.add_argument("workflow_path", nargs="?", help="Path to WORKFLOW.md. Defaults to ./WORKFLOW.md.")
    parser.add_argument("--port", type=int, help="Enable the local status HTTP server on this port. Overrides server.port.")
    parser.add_argument("--log-level", default="INFO", help="Python logging level. Default: INFO.")
    parser.add_argument("--once", action="store_true", help="Run one poll/reconcile tick and exit. Intended for smoke tests.")
    return parser


async def async_main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    configure_logging(args.log_level)
    manager = ConfigManager(args.workflow_path)
    try:
        manager.load_startup()
    except SymphonyError as exc:
        log_event(LOGGER, logging.ERROR, "startup_failed", reason=exc)
        return 1

    orchestrator = Orchestrator(manager)
    http_server: StatusHTTPServer | None = None
    _, config = manager.current()
    port = args.port if args.port is not None else config.server.port
    if port is not None:
        http_server = StatusHTTPServer(orchestrator, host=config.server.host, port=port)
        await http_server.start()
    try:
        if args.once:
            await orchestrator.startup_terminal_workspace_cleanup()
            await orchestrator.tick()
            return 0
        await orchestrator.start()
        return 0
    except KeyboardInterrupt:
        return 0
    except SymphonyError as exc:
        log_event(LOGGER, logging.ERROR, "host_failed", reason=exc)
        return 1
    finally:
        await orchestrator.stop()
        if http_server:
            await http_server.stop()


def main(argv: list[str] | None = None) -> int:
    return asyncio.run(async_main(argv))
