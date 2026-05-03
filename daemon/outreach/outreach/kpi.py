# daemon/outreach/outreach/kpi.py
"""Daily KPI snapshot.

Writes a single kpi#<YYYY-MM-DD> item per UTC day. Idempotent (second call
within the same day overwrites).
"""
from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

from outreach.state import State


class KpiSnapshot:
    def __init__(self, table_name: str | None = None):
        self._state = State(table_name=table_name) if table_name else State()

    def write_today(self) -> dict[str, Any]:
        today = datetime.now(timezone.utc).date().isoformat()
        cold_count = 0
        reply_count = 0
        for item in self._state.query_pk("post#email", sk_begins_with=today):
            if item.get("status") in ("sent", "dryrun"):
                kind = item.get("kind", "cold")
                if kind == "cold":
                    cold_count += 1
                elif kind == "reply":
                    reply_count += 1
        inbound_count = 0
        for item in self._state.query_pk("inbound#email", sk_begins_with=today):
            inbound_count += 1
        reply_rate = Decimal(inbound_count) / Decimal(cold_count) if cold_count > 0 else Decimal("0")
        snapshot = {
            "date": today,
            "emails_sent_cold": cold_count,
            "emails_sent_reply": reply_count,
            "emails_inbound": inbound_count,
            "reply_rate_today": reply_rate,
            "ts": datetime.now(timezone.utc).isoformat(),
        }
        self._state.put("kpi", today, snapshot)
        return snapshot
