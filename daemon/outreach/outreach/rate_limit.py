# daemon/outreach/outreach/rate_limit.py
"""Per-channel sliding-window (UTC-day) rate limiter.

Consumes counters from DynamoDB items keyed `rate-limit#<channel>` /
`<YYYY-MM-DD>`. Caps come from config.RATE_LIMITS.
"""
from __future__ import annotations

from datetime import datetime, timezone

from outreach.config import RATE_LIMITS
from outreach.state import State


def utcnow() -> datetime:
    """Indirection so tests can monkeypatch."""
    return datetime.now(timezone.utc)


class RateLimiter:
    def __init__(self, table_name: str | None = None):
        self._state = State(table_name=table_name) if table_name else State()

    def _cap(self, channel: str, action: str) -> int:
        if channel not in RATE_LIMITS:
            raise KeyError(f"unknown channel: {channel}")
        if action not in RATE_LIMITS[channel]:
            raise KeyError(f"unknown action {action} for channel {channel}")
        return RATE_LIMITS[channel][action]

    def _today_sk(self) -> str:
        return utcnow().strftime("%Y-%m-%d")

    def used_today(self, channel: str, action: str) -> int:
        item = self._state.get(f"rate-limit#{channel}", self._today_sk())
        if item is None:
            return 0
        return int(item.get(action, 0))

    def allowed(self, channel: str, action: str) -> bool:
        cap = self._cap(channel, action)
        return self.used_today(channel, action) < cap

    def consume(self, channel: str, action: str) -> bool:
        """Atomically consume 1 unit. Returns True if successful, False if at-cap."""
        cap = self._cap(channel, action)
        if self.used_today(channel, action) >= cap:
            return False
        new_val = self._state.increment(f"rate-limit#{channel}", self._today_sk(), action, 1)
        if new_val > cap:
            self._state.increment(f"rate-limit#{channel}", self._today_sk(), action, -1)
            return False
        return True
