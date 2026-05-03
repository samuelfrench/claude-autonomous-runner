# daemon/outreach/tests/test_cli.py
"""Tests for the CLI subcommand router."""
import json

from click.testing import CliRunner
from outreach.cli import main
from outreach.state import State


def test_cli_help() -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["--help"])
    assert result.exit_code == 0
    assert "outreach" in result.output


def test_state_get_missing(dynamodb_table: str) -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["state", "get", "post#x", "missing-id"])
    assert result.exit_code == 0
    assert result.output.strip() == "null"


def test_state_put_then_get(dynamodb_table: str) -> None:
    runner = CliRunner()
    payload = json.dumps({"foo": "bar"})
    r1 = runner.invoke(main, ["state", "put", "post#x", "id1", payload])
    assert r1.exit_code == 0
    r2 = runner.invoke(main, ["state", "get", "post#x", "id1"])
    assert r2.exit_code == 0
    parsed = json.loads(r2.output)
    assert parsed["foo"] == "bar"


def test_email_send_dryrun(dynamodb_table: str, ses_client: object) -> None:
    runner = CliRunner()
    result = runner.invoke(main, [
        "--dryrun",
        "email", "send",
        "--to", "x@example.com",
        "--subject", "s",
        "--body", "b",
        "--kind", "cold",
    ])
    assert result.exit_code == 0
    assert "dryrun-" in result.output


def test_kpi_snapshot(dynamodb_table: str) -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["kpi", "snapshot"])
    assert result.exit_code == 0
    parsed = json.loads(result.output)
    assert "date" in parsed
    assert "emails_sent_cold" in parsed


# ─── Inbox subcommands ───────────────────────────────────────────────────


def test_email_inbox_list_unprocessed_empty(dynamodb_table: str) -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["email", "inbox", "list-unprocessed"])
    assert result.exit_code == 0
    parsed = json.loads(result.output)
    assert parsed["count"] == 0
    assert parsed["unprocessed"] == []


def test_email_inbox_list_unprocessed_returns_pending(dynamodb_table: str) -> None:
    state = State(table_name=dynamodb_table)
    state.put("inbound#email", "2026-05-02T10:00:00Z#m1", {
        "from": "editor@nytimes.com",
        "to": "hello@example.com",
        "subject": "Re: pitch",
        "ts": "2026-05-02T10:00:00Z",
        "status": "unprocessed",
        "priority_hint": "press",
        "in_reply_to": "",
    })
    state.put("inbound#email", "2026-05-02T11:00:00Z#m2", {
        "from": "old@example.com",
        "subject": "stale",
        "status": "processed",
    })
    runner = CliRunner()
    result = runner.invoke(main, ["email", "inbox", "list-unprocessed"])
    assert result.exit_code == 0
    parsed = json.loads(result.output)
    assert parsed["count"] == 1
    assert parsed["unprocessed"][0]["from"] == "editor@nytimes.com"
    assert parsed["unprocessed"][0]["priority_hint"] == "press"


def test_email_inbox_read_returns_full_item(dynamodb_table: str) -> None:
    state = State(table_name=dynamodb_table)
    state.put("inbound#email", "2026-05-02T10:00:00Z#m1", {
        "from": "x@x.com",
        "subject": "test",
        "body": "the full body of the email",
        "status": "unprocessed",
    })
    runner = CliRunner()
    result = runner.invoke(main, [
        "email", "inbox", "read", "2026-05-02T10:00:00Z#m1",
    ])
    assert result.exit_code == 0
    parsed = json.loads(result.output)
    assert parsed["body"] == "the full body of the email"


def test_email_inbox_read_missing_exits_nonzero(dynamodb_table: str) -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["email", "inbox", "read", "not-a-real-sk"])
    assert result.exit_code == 1
    parsed = json.loads(result.output)
    assert parsed["ok"] is False
    assert parsed["error"] == "not-found"


def test_email_inbox_mark_processed(dynamodb_table: str) -> None:
    state = State(table_name=dynamodb_table)
    state.put("inbound#email", "2026-05-02T10:00:00Z#m1",
              {"from": "x@x.com", "status": "unprocessed"})
    runner = CliRunner()
    result = runner.invoke(main, [
        "email", "inbox", "mark-processed", "2026-05-02T10:00:00Z#m1",
        "--reply-msg-id", "ses-reply-msg-abc",
    ])
    assert result.exit_code == 0
    item = state.get("inbound#email", "2026-05-02T10:00:00Z#m1")
    assert item["status"] == "processed"
    assert item["reply_msg_id"] == "ses-reply-msg-abc"


def test_email_inbox_next_priority(dynamodb_table: str) -> None:
    state = State(table_name=dynamodb_table)
    state.put("inbound#email", "ts1#m1", {
        "from": "random@gmail.com", "status": "unprocessed",
        "priority_hint": "low",
    })
    state.put("inbound#email", "ts2#m2", {
        "from": "researcher@example.edu", "status": "unprocessed",
        "priority_hint": "researcher",
    })
    runner = CliRunner()
    result = runner.invoke(main, ["email", "inbox", "next-priority"])
    assert result.exit_code == 0
    parsed = json.loads(result.output)
    assert parsed["from"] == "researcher@example.edu"


def test_email_inbox_next_priority_empty(dynamodb_table: str) -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["email", "inbox", "next-priority"])
    assert result.exit_code == 0
    assert result.output.strip() == "null"
