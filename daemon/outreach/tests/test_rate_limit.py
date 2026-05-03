# daemon/outreach/tests/test_rate_limit.py
"""Tests for the per-channel rate limiter."""
from datetime import datetime, timezone
from unittest.mock import patch

import pytest
from outreach.rate_limit import RateLimiter


@pytest.fixture
def fixed_now() -> datetime:
    return datetime(2026, 4, 26, 12, 0, 0, tzinfo=timezone.utc)


def test_under_cap_allowed(dynamodb_table: str, fixed_now: datetime) -> None:
    rl = RateLimiter(table_name=dynamodb_table)
    with patch("outreach.rate_limit.utcnow", return_value=fixed_now):
        assert rl.allowed("email", "cold") is True
        assert rl.allowed("reddit", "submit") is True


def test_at_cap_blocked(dynamodb_table: str, fixed_now: datetime) -> None:
    rl = RateLimiter(table_name=dynamodb_table)
    with patch("outreach.rate_limit.utcnow", return_value=fixed_now):
        for _ in range(15):
            rl.consume("email", "cold")
        assert rl.allowed("email", "cold") is False


def test_consume_increments(dynamodb_table: str, fixed_now: datetime) -> None:
    rl = RateLimiter(table_name=dynamodb_table)
    with patch("outreach.rate_limit.utcnow", return_value=fixed_now):
        rl.consume("email", "cold")
        rl.consume("email", "cold")
        assert rl.used_today("email", "cold") == 2


def test_resets_at_utc_midnight(dynamodb_table: str) -> None:
    rl = RateLimiter(table_name=dynamodb_table)
    day1 = datetime(2026, 4, 26, 23, 59, 59, tzinfo=timezone.utc)
    day2 = datetime(2026, 4, 27, 0, 0, 0, tzinfo=timezone.utc)
    with patch("outreach.rate_limit.utcnow", return_value=day1):
        for _ in range(15):
            rl.consume("email", "cold")
        assert rl.allowed("email", "cold") is False
    with patch("outreach.rate_limit.utcnow", return_value=day2):
        assert rl.allowed("email", "cold") is True
        assert rl.used_today("email", "cold") == 0


def test_unknown_channel_or_action_raises(dynamodb_table: str) -> None:
    rl = RateLimiter(table_name=dynamodb_table)
    with pytest.raises(KeyError):
        rl.allowed("bogus-channel", "submit")
    with pytest.raises(KeyError):
        rl.allowed("reddit", "bogus-action")


def test_consume_returns_blocked_on_overage(dynamodb_table: str, fixed_now: datetime) -> None:
    rl = RateLimiter(table_name=dynamodb_table)
    with patch("outreach.rate_limit.utcnow", return_value=fixed_now):
        for _ in range(2):  # reddit submit cap is 2
            rl.consume("reddit", "submit")
        assert rl.consume("reddit", "submit") is False  # over cap, not consumed
