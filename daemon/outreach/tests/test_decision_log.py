# daemon/outreach/tests/test_decision_log.py
"""Tests for the per-tick decision log."""
from datetime import datetime, timezone

from outreach.decision_log import DecisionLog


def test_log_entry(dynamodb_table: str) -> None:
    log = DecisionLog(table_name=dynamodb_table)
    log.write(
        tick_id="tick-2026-04-26-12-00-00",
        action="email-send",
        rationale="researcher email backlog has 3 items, top priority is Juliana Rangel",
        outcome="sent ok",
    )
    entries = list(log.recent(n=10))
    assert len(entries) == 1
    assert entries[0]["action"] == "email-send"


def test_recent_returns_in_reverse_chronological_order(dynamodb_table: str) -> None:
    log = DecisionLog(table_name=dynamodb_table)
    log.write(tick_id="tick-1", action="x", rationale="r1", outcome="o1")
    log.write(tick_id="tick-2", action="y", rationale="r2", outcome="o2")
    log.write(tick_id="tick-3", action="z", rationale="r3", outcome="o3")
    entries = list(log.recent(n=10))
    assert [e["tick_id"] for e in entries] == ["tick-3", "tick-2", "tick-1"]


def test_loop_detection_same_action_repeated(dynamodb_table: str) -> None:
    log = DecisionLog(table_name=dynamodb_table)
    for i in range(6):
        log.write(tick_id=f"tick-{i}", action="email-send",
                  rationale="same target", outcome="failed",
                  target="researcher@example.com")
    assert log.detect_loop(window=5) is True


def test_no_loop_when_actions_vary(dynamodb_table: str) -> None:
    log = DecisionLog(table_name=dynamodb_table)
    log.write(tick_id="tick-1", action="email-send", rationale="r", outcome="ok")
    log.write(tick_id="tick-2", action="kpi-snapshot", rationale="r", outcome="ok")
    log.write(tick_id="tick-3", action="email-send", rationale="r", outcome="ok")
    log.write(tick_id="tick-4", action="reply-handle", rationale="r", outcome="ok")
    log.write(tick_id="tick-5", action="email-send", rationale="r", outcome="ok")
    assert log.detect_loop(window=5) is False
