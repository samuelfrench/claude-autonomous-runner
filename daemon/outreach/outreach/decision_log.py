# daemon/outreach/outreach/decision_log.py
"""Per-tick reasoning log + loop detection."""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Iterator

from outreach.state import State


class DecisionLog:
    def __init__(self, table_name: str | None = None):
        self._state = State(table_name=table_name) if table_name else State()

    def write(self, *, tick_id: str, action: str, rationale: str,
              outcome: str, target: str | None = None) -> None:
        ts = datetime.now(timezone.utc).isoformat()
        sk = f"{ts}#{tick_id}"
        attrs: dict[str, Any] = {
            "tick_id": tick_id,
            "action": action,
            "rationale": rationale,
            "outcome": outcome,
            "ts": ts,
        }
        if target is not None:
            attrs["target"] = target
        self._state.put("decision-log", sk, attrs)

    def recent(self, n: int = 10) -> Iterator[dict[str, Any]]:
        items = list(self._state.query_pk("decision-log"))
        items.sort(key=lambda x: x["sk"], reverse=True)
        yield from items[:n]

    def detect_loop(self, window: int = 5) -> bool:
        """Return True if last `window` entries share action+target+outcome."""
        recent = list(self.recent(n=window))
        if len(recent) < window:
            return False
        signature = (
            recent[0].get("action"),
            recent[0].get("target"),
            recent[0].get("outcome"),
        )
        return all(
            (e.get("action"), e.get("target"), e.get("outcome")) == signature
            for e in recent
        )
