from __future__ import annotations

import logging
import sys
from typing import Any

from .utils import key_value_message


def configure_logging(level: str = "INFO") -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s level=%(levelname)s logger=%(name)s %(message)s",
        stream=sys.stderr,
    )


def log_event(logger: logging.Logger, level: int, event: str, **fields: Any) -> None:
    logger.log(level, key_value_message(event, **fields))
