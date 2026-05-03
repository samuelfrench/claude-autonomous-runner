# daemon/outreach/outreach/tools_registry.py
"""Registry for self-built tools (the bot's runtime-authored CLIs).

Tools live as files under outreach-runner-workdir/dynamic-tools/. This
registry tracks their lifecycle: experimental → stable (after 5 successes)
or quarantined (after 3 consecutive failures).
"""
from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import Any, Iterator

from outreach.config import TOOL_PROMOTE_AFTER_RUNS
from outreach.state import State


class ToolStatus(str, Enum):
    EXPERIMENTAL = "experimental"
    STABLE = "stable"
    QUARANTINED = "quarantined"


CONSECUTIVE_FAIL_THRESHOLD = 3


class ToolsRegistry:
    def __init__(self, table_name: str | None = None):
        self._state = State(table_name=table_name) if table_name else State()

    def register(self, *, name: str, purpose: str, source_path: str) -> None:
        now = datetime.now(timezone.utc).isoformat()
        self._state.put(f"tool-build#{name}", "metadata", {
            "name": name,
            "purpose": purpose,
            "source_path": source_path,
            "created_at": now,
            "status": ToolStatus.EXPERIMENTAL.value,
            "run_count": 0,
            "success_count": 0,
            "consecutive_failures": 0,
        })

    def get(self, name: str) -> dict[str, Any] | None:
        return self._state.get(f"tool-build#{name}", "metadata")

    def record_run(self, name: str, success: bool) -> None:
        tool = self.get(name)
        if tool is None:
            raise KeyError(f"tool not registered: {name}")
        tool["run_count"] = int(tool.get("run_count", 0)) + 1
        if success:
            tool["success_count"] = int(tool.get("success_count", 0)) + 1
            tool["consecutive_failures"] = 0
            if (tool["status"] == ToolStatus.EXPERIMENTAL.value
                    and tool["success_count"] >= TOOL_PROMOTE_AFTER_RUNS):
                tool["status"] = ToolStatus.STABLE.value
        else:
            tool["consecutive_failures"] = int(tool.get("consecutive_failures", 0)) + 1
            if tool["consecutive_failures"] >= CONSECUTIVE_FAIL_THRESHOLD:
                tool["status"] = ToolStatus.QUARANTINED.value
        tool["last_run_at"] = datetime.now(timezone.utc).isoformat()
        self._state.put(f"tool-build#{name}", "metadata", tool)

    def list_stable(self) -> Iterator[dict[str, Any]]:
        # Note: query_pk requires exact pk match; for `tool-build#*` we scan with prefix.
        ddb = self._state._table  # type: ignore[attr-defined]
        resp = ddb.scan(
            FilterExpression="begins_with(pk, :p)",
            ExpressionAttributeValues={":p": "tool-build#"},
        )
        for item in resp.get("Items", []):
            if item.get("sk") == "metadata" and item.get("status") == ToolStatus.STABLE.value:
                yield item

    def list_all(self) -> Iterator[dict[str, Any]]:
        ddb = self._state._table  # type: ignore[attr-defined]
        resp = ddb.scan(
            FilterExpression="begins_with(pk, :p)",
            ExpressionAttributeValues={":p": "tool-build#"},
        )
        for item in resp.get("Items", []):
            if item.get("sk") == "metadata":
                yield item
