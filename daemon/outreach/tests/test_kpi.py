# daemon/outreach/tests/test_kpi.py
"""Tests for the daily KPI snapshot writer."""
from datetime import datetime, timezone, timedelta

from outreach.kpi import KpiSnapshot
from outreach.state import State


def test_snapshot_writes_daily_record(dynamodb_table: str) -> None:
    state = State(table_name=dynamodb_table)
    today = datetime.now(timezone.utc).date().isoformat()
    state.put("post#email", f"{today}T08:00:00Z#m1",
              {"kind": "cold", "status": "sent", "ts": f"{today}T08:00:00Z"})
    state.put("post#email", f"{today}T10:00:00Z#m2",
              {"kind": "cold", "status": "sent", "ts": f"{today}T10:00:00Z"})
    state.put("post#email", f"{today}T12:00:00Z#m3",
              {"kind": "reply", "status": "sent", "ts": f"{today}T12:00:00Z"})
    state.put("inbound#email", f"{today}T13:00:00Z#m4",
              {"from": "researcher@x.com", "status": "processed",
               "ts": f"{today}T13:00:00Z"})

    kpi = KpiSnapshot(table_name=dynamodb_table)
    snapshot = kpi.write_today()

    assert snapshot["emails_sent_cold"] == 2
    assert snapshot["emails_sent_reply"] == 1
    assert snapshot["emails_inbound"] == 1
    assert snapshot["reply_rate_today"] == 0.5


def test_snapshot_is_idempotent(dynamodb_table: str) -> None:
    state = State(table_name=dynamodb_table)
    today = datetime.now(timezone.utc).date().isoformat()
    state.put("post#email", f"{today}T08:00:00Z#m1",
              {"kind": "cold", "status": "sent", "ts": f"{today}T08:00:00Z"})

    kpi = KpiSnapshot(table_name=dynamodb_table)
    snap1 = kpi.write_today()
    snap2 = kpi.write_today()
    assert snap1["emails_sent_cold"] == snap2["emails_sent_cold"]
    items = list(state.query_pk("kpi"))
    assert len(items) == 1
