# daemon/outreach/tests/test_account.py
"""Tests for the account state machine."""
from datetime import datetime, timezone, timedelta
from unittest.mock import patch

import pytest
from outreach.account import Account, AccountStatus, InvalidTransition


def test_create_account(dynamodb_table: str) -> None:
    acc = Account.create(channel="reddit", account_id="bot1",
                          ssm_creds_ref="/clawd-bot/outreach/reddit/bot1/credentials",
                          table_name=dynamodb_table)
    assert acc.status == AccountStatus.WARMING
    assert acc.channel == "reddit"
    assert acc.account_id == "bot1"


def test_load_account(dynamodb_table: str) -> None:
    Account.create(channel="reddit", account_id="bot1",
                   ssm_creds_ref="/x/y", table_name=dynamodb_table)
    acc = Account.load(channel="reddit", account_id="bot1", table_name=dynamodb_table)
    assert acc is not None
    assert acc.status == AccountStatus.WARMING


def test_load_missing_returns_none(dynamodb_table: str) -> None:
    acc = Account.load(channel="reddit", account_id="missing", table_name=dynamodb_table)
    assert acc is None


def test_promote_warming_to_active(dynamodb_table: str) -> None:
    acc = Account.create(channel="reddit", account_id="bot1",
                          ssm_creds_ref="/x/y", table_name=dynamodb_table)
    older = (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()
    acc._raw["created_at"] = older
    acc._save()
    acc.promote_if_warmup_complete(karma=100)
    assert acc.status == AccountStatus.ACTIVE


def test_no_promote_if_too_young(dynamodb_table: str) -> None:
    acc = Account.create(channel="reddit", account_id="bot1",
                          ssm_creds_ref="/x/y", table_name=dynamodb_table)
    acc.promote_if_warmup_complete(karma=100)
    assert acc.status == AccountStatus.WARMING


def test_no_promote_if_low_karma(dynamodb_table: str) -> None:
    acc = Account.create(channel="reddit", account_id="bot1",
                          ssm_creds_ref="/x/y", table_name=dynamodb_table)
    older = (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()
    acc._raw["created_at"] = older
    acc._save()
    acc.promote_if_warmup_complete(karma=10)  # too low
    assert acc.status == AccountStatus.WARMING


def test_mark_degraded(dynamodb_table: str) -> None:
    acc = Account.create(channel="reddit", account_id="bot1",
                          ssm_creds_ref="/x/y", table_name=dynamodb_table)
    older = (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()
    acc._raw["created_at"] = older
    acc._save()
    acc.promote_if_warmup_complete(karma=100)
    assert acc.status == AccountStatus.ACTIVE
    acc.mark_degraded(reason="karma drop 12% in 24h")
    assert acc.status == AccountStatus.DEGRADED


def test_mark_flagged(dynamodb_table: str) -> None:
    acc = Account.create(channel="reddit", account_id="bot1",
                          ssm_creds_ref="/x/y", table_name=dynamodb_table)
    acc.mark_flagged(reason="shadowbanned")
    assert acc.status == AccountStatus.FLAGGED


def test_invalid_transition_warming_to_active_directly(dynamodb_table: str) -> None:
    acc = Account.create(channel="reddit", account_id="bot1",
                          ssm_creds_ref="/x/y", table_name=dynamodb_table)
    with pytest.raises(InvalidTransition):
        acc.mark_active()


def test_active_can_be_posted_to(dynamodb_table: str) -> None:
    acc = Account.create(channel="reddit", account_id="bot1",
                          ssm_creds_ref="/x/y", table_name=dynamodb_table)
    older = (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()
    acc._raw["created_at"] = older
    acc._save()
    acc.promote_if_warmup_complete(karma=100)
    assert acc.can_post() is True


def test_warming_account_cannot_be_posted_to(dynamodb_table: str) -> None:
    acc = Account.create(channel="reddit", account_id="bot1",
                          ssm_creds_ref="/x/y", table_name=dynamodb_table)
    assert acc.can_post() is False
    assert acc.can_warmup() is True


def test_flagged_account_cannot_be_used_at_all(dynamodb_table: str) -> None:
    acc = Account.create(channel="reddit", account_id="bot1",
                          ssm_creds_ref="/x/y", table_name=dynamodb_table)
    acc.mark_flagged(reason="test")
    assert acc.can_post() is False
    assert acc.can_warmup() is False
