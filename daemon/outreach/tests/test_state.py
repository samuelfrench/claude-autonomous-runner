# daemon/outreach/tests/test_state.py
"""Tests for the DynamoDB single-table wrapper."""
import pytest
from outreach.state import State


def test_put_and_get_item(dynamodb_table: str) -> None:
    s = State(table_name=dynamodb_table)
    s.put("post#reddit", "2026-04-26T12:00:00Z#abc123",
          {"sub": "geopolitics", "title": "test", "status": "submitted"})
    item = s.get("post#reddit", "2026-04-26T12:00:00Z#abc123")
    assert item is not None
    assert item["sub"] == "geopolitics"
    assert item["status"] == "submitted"


def test_get_missing_returns_none(dynamodb_table: str) -> None:
    s = State(table_name=dynamodb_table)
    assert s.get("post#reddit", "nonexistent") is None


def test_query_by_pk(dynamodb_table: str) -> None:
    s = State(table_name=dynamodb_table)
    s.put("post#reddit", "2026-04-26T12:00:00Z#a", {"title": "first"})
    s.put("post#reddit", "2026-04-26T13:00:00Z#b", {"title": "second"})
    s.put("post#x", "2026-04-26T12:00:00Z#c", {"title": "different pk"})
    items = list(s.query_pk("post#reddit"))
    assert len(items) == 2
    titles = {i["title"] for i in items}
    assert titles == {"first", "second"}


def test_query_pk_with_sk_prefix(dynamodb_table: str) -> None:
    s = State(table_name=dynamodb_table)
    s.put("post#reddit", "2026-04-25T12:00:00Z#a", {"title": "old"})
    s.put("post#reddit", "2026-04-26T12:00:00Z#b", {"title": "new"})
    items = list(s.query_pk("post#reddit", sk_begins_with="2026-04-26"))
    assert len(items) == 1
    assert items[0]["title"] == "new"


def test_increment_counter(dynamodb_table: str) -> None:
    s = State(table_name=dynamodb_table)
    s.put("rate-limit#email", "2026-04-26", {"count": 0})
    new_val = s.increment("rate-limit#email", "2026-04-26", "count", 1)
    assert new_val == 1
    new_val = s.increment("rate-limit#email", "2026-04-26", "count", 5)
    assert new_val == 6


def test_increment_creates_item_if_missing(dynamodb_table: str) -> None:
    s = State(table_name=dynamodb_table)
    new_val = s.increment("rate-limit#email", "2026-04-26", "count", 1)
    assert new_val == 1


def test_delete(dynamodb_table: str) -> None:
    s = State(table_name=dynamodb_table)
    s.put("post#reddit", "id-1", {"title": "x"})
    s.delete("post#reddit", "id-1")
    assert s.get("post#reddit", "id-1") is None


def test_update_attributes(dynamodb_table: str) -> None:
    s = State(table_name=dynamodb_table)
    s.put("account#reddit:bot1", "metadata", {"status": "warming", "karma": 0})
    s.update("account#reddit:bot1", "metadata", {"status": "active", "karma": 50})
    item = s.get("account#reddit:bot1", "metadata")
    assert item["status"] == "active"
    assert item["karma"] == 50


def test_query_status_index(dynamodb_table: str) -> None:
    s = State(table_name=dynamodb_table)
    s.put("account#reddit:bot1", "metadata", {"status": "flagged", "karma": 0})
    s.put("account#reddit:bot2", "metadata", {"status": "active", "karma": 50})
    s.put("account#reddit:bot3", "metadata", {"status": "flagged", "karma": 5})
    flagged = list(s.query_status("flagged"))
    assert len(flagged) == 2
    pks = {i["pk"] for i in flagged}
    assert pks == {"account#reddit:bot1", "account#reddit:bot3"}
