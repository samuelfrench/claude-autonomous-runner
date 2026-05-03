# daemon/outreach/tests/test_email_inbox.py
"""Tests for email inbox polling."""
from datetime import datetime, timezone

from outreach.email_inbox import EmailInbox
from outreach.state import State


def test_unprocessed_returns_only_unprocessed(dynamodb_table: str) -> None:
    state = State(table_name=dynamodb_table)
    state.put("inbound#email", "2026-04-26T10:00:00Z#m1",
              {"from": "a@x.com", "subject": "s1", "status": "unprocessed"})
    state.put("inbound#email", "2026-04-26T11:00:00Z#m2",
              {"from": "b@x.com", "subject": "s2", "status": "processed"})
    state.put("inbound#email", "2026-04-26T12:00:00Z#m3",
              {"from": "c@x.com", "subject": "s3", "status": "unprocessed"})

    inbox = EmailInbox(table_name=dynamodb_table)
    items = list(inbox.unprocessed())
    assert len(items) == 2
    froms = {i["from"] for i in items}
    assert froms == {"a@x.com", "c@x.com"}


def test_mark_processed(dynamodb_table: str) -> None:
    state = State(table_name=dynamodb_table)
    state.put("inbound#email", "2026-04-26T10:00:00Z#m1",
              {"from": "a@x.com", "status": "unprocessed"})
    inbox = EmailInbox(table_name=dynamodb_table)
    inbox.mark_processed("2026-04-26T10:00:00Z#m1", reply_msg_id="reply-123")
    item = state.get("inbound#email", "2026-04-26T10:00:00Z#m1")
    assert item["status"] == "processed"
    assert item["reply_msg_id"] == "reply-123"


def test_prioritize_researcher_emails_above_press_above_other(dynamodb_table: str) -> None:
    state = State(table_name=dynamodb_table)
    state.put("inbound#email", "ts1#m1",
              {"from": "random@gmail.com", "status": "unprocessed", "priority_hint": "low"})
    state.put("inbound#email", "ts2#m2",
              {"from": "researcher@example.edu", "status": "unprocessed",
               "priority_hint": "researcher"})
    state.put("inbound#email", "ts3#m3",
              {"from": "editor@nytimes.com", "status": "unprocessed",
               "priority_hint": "press"})

    inbox = EmailInbox(table_name=dynamodb_table)
    items = inbox.next_priority()
    assert items is not None
    assert items["from"] == "researcher@example.edu"
