# daemon/outreach/tests/test_email_send.py
"""Tests for SES outbound (rate-limit, DNC, dryrun, verification gate)."""
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import pytest

from outreach import address_verify
from outreach.config import RECENT_COLD_SEND_WINDOW_DAYS
from outreach.email_send import (
    BadAddressError,
    DoNotContactError,
    EmailSender,
    OverCapError,
    RecentSendError,
)
from outreach.state import State


# ─── Test scaffolding: bypass the multi-layer verifier in unit tests ──────
# Most cold-send tests below don't care about verification; they use the
# `skip_verify` escape hatch to focus on rate-limit / DNC / SES behavior.
# A separate suite below specifically exercises the verifier integration.


def test_send_basic(dynamodb_table: str, ses_client: object) -> None:
    sender = EmailSender(table_name=dynamodb_table)
    msg_id = sender.send(
        to="researcher@example.com",
        subject="Re: pollen analysis follow-up",
        body="Hi, ...",
        thread_id=None,
        skip_verify=True,
    )
    assert msg_id is not None
    state = State(table_name=dynamodb_table)
    sent = list(state.query_pk("post#email"))
    assert len(sent) == 1
    assert sent[0]["to"] == "researcher@example.com"
    assert sent[0]["status"] == "sent"


def test_rate_limit_blocks_at_cap(dynamodb_table: str, ses_client: object) -> None:
    sender = EmailSender(table_name=dynamodb_table)
    for i in range(15):
        sender.send(
            to=f"r{i}@example.com",
            subject="s", body="b", thread_id=None, kind="cold",
            skip_verify=True,
        )
    with pytest.raises(OverCapError):
        sender.send(
            to="r16@example.com", subject="s", body="b",
            thread_id=None, kind="cold",
            skip_verify=True,
        )


def test_reply_kind_uses_separate_quota(dynamodb_table: str, ses_client: object) -> None:
    sender = EmailSender(table_name=dynamodb_table)
    for i in range(15):
        sender.send(
            to=f"r{i}@example.com", subject="s", body="b",
            thread_id=None, kind="cold",
            skip_verify=True,
        )
    msg_id = sender.send(
        to="rep@example.com", subject="Re: x", body="b",
        thread_id="thread-abc", kind="reply",
    )
    assert msg_id is not None


def test_dryrun_mode_does_not_call_ses(dynamodb_table: str, ses_client: object) -> None:
    """Dryrun bypasses both SES + verification (no rate-limit consumed either)."""
    sender = EmailSender(table_name=dynamodb_table, dryrun=True)
    msg_id = sender.send(
        to="x@example.com", subject="s", body="b",
        thread_id=None, kind="cold",
    )
    assert msg_id.startswith("dryrun-")
    from outreach.rate_limit import RateLimiter
    rl = RateLimiter(table_name=dynamodb_table)
    assert rl.used_today("email", "cold") == 0


def _add_dnc(table_name: str, addr: str) -> None:
    State(table_name=table_name).put(
        f"do-not-contact#{addr.lower()}", "metadata",
        {"email": addr.lower(), "added_at": "2026-04-30T00:00:00Z",
         "reason": "stop-reply", "source_inbound_sk": "test"},
    )


def test_cold_send_blocked_for_do_not_contact(dynamodb_table: str, ses_client: object) -> None:
    _add_dnc(dynamodb_table, "optedout@example.com")
    sender = EmailSender(table_name=dynamodb_table)
    with pytest.raises(DoNotContactError):
        sender.send(
            to="optedout@example.com", subject="s", body="b",
            thread_id=None, kind="cold",
            skip_verify=True,
        )
    # do-not-contact rejection must NOT consume rate-limit quota — that would
    # let an attacker DoS our daily cap by replying STOP from many addresses.
    from outreach.rate_limit import RateLimiter
    assert RateLimiter(table_name=dynamodb_table).used_today("email", "cold") == 0


def test_dnc_check_is_case_insensitive(dynamodb_table: str, ses_client: object) -> None:
    _add_dnc(dynamodb_table, "person@example.com")
    sender = EmailSender(table_name=dynamodb_table)
    with pytest.raises(DoNotContactError):
        sender.send(
            to="Person@Example.COM", subject="s", body="b",
            thread_id=None, kind="cold",
            skip_verify=True,
        )


def test_reply_kind_ignores_do_not_contact(dynamodb_table: str, ses_client: object) -> None:
    """Replies to inbound conversation are not blocked — opt-out is a cold-send concept."""
    _add_dnc(dynamodb_table, "convo@example.com")
    sender = EmailSender(table_name=dynamodb_table)
    msg_id = sender.send(
        to="convo@example.com", subject="Re: x", body="thanks",
        thread_id="thread-1", kind="reply",
    )
    assert msg_id is not None


# ─── Verification-gate integration tests ────────────────────────────────


def _patch_mx_ok():
    """Make all DNS MX lookups succeed in unit tests."""
    return patch.object(
        address_verify.dns.resolver, "resolve",
        return_value=[MagicMock(exchange="aspmx.l.google.com.")],
    )


def _mock_sesv2_no_suppression():
    """sesv2 client mock that always returns 'not in suppression list'."""
    mock = MagicMock()
    mock.exceptions.NotFoundException = type("NotFoundException", (Exception,), {})
    mock.get_suppressed_destination.side_effect = (
        mock.exceptions.NotFoundException("not in list")
    )
    return mock


def test_cold_send_rejects_when_no_source_url(
        dynamodb_table: str, ses_client: object) -> None:
    """Cold sends without a source_url are blocked at the verifier — the
    architectural change that prevents future LLM hallucinations."""
    sender = EmailSender(
        table_name=dynamodb_table, sesv2_client=_mock_sesv2_no_suppression(),
    )
    with _patch_mx_ok():
        with pytest.raises(BadAddressError) as exc_info:
            sender.send(
                to="someone@example.com", subject="s", body="b",
                thread_id=None, kind="cold",
                source_url=None,
            )
    assert exc_info.value.result.layer == "outlet-page"


def test_cold_send_records_dnc_on_verification_failure(
        dynamodb_table: str, ses_client: object) -> None:
    """When verification fails, write a do-not-contact row so future ticks
    short-circuit at the DNC check without re-running the verifier."""
    sender = EmailSender(
        table_name=dynamodb_table, sesv2_client=_mock_sesv2_no_suppression(),
    )
    with _patch_mx_ok():
        try:
            sender.send(
                to="someone@example.com", subject="s", body="b",
                thread_id=None, kind="cold",
                source_url=None,  # triggers source-url-required failure
            )
        except BadAddressError:
            pass
    state = State(table_name=dynamodb_table)
    dnc = state.get(f"do-not-contact#someone@example.com", "metadata")
    assert dnc is not None
    assert "verify-outlet-page" in dnc["reason"]


def test_cold_send_does_not_consume_rate_limit_on_verify_failure(
        dynamodb_table: str, ses_client: object) -> None:
    """A bad-address rejection must NOT burn quota — same anti-DoS reasoning
    as the DNC path."""
    sender = EmailSender(
        table_name=dynamodb_table, sesv2_client=_mock_sesv2_no_suppression(),
    )
    with _patch_mx_ok():
        with pytest.raises(BadAddressError):
            sender.send(
                to="someone@example.com", subject="s", body="b",
                thread_id=None, kind="cold",
                source_url=None,
            )
    from outreach.rate_limit import RateLimiter
    assert RateLimiter(table_name=dynamodb_table).used_today("email", "cold") == 0


def test_cold_send_passes_when_source_url_validates(
        dynamodb_table: str, ses_client: object) -> None:
    """Happy path: address appears on the outlet's contact page → send proceeds."""
    fake_resp = MagicMock(
        status_code=200,
        text="Pitch the outlet: pitches@example.com",
    )
    sender = EmailSender(
        table_name=dynamodb_table, sesv2_client=_mock_sesv2_no_suppression(),
    )
    with _patch_mx_ok(), patch.object(
        address_verify.requests, "get", return_value=fake_resp,
    ):
        msg_id = sender.send(
            to="pitches@example.com", subject="s", body="b",
            thread_id=None, kind="cold",
            source_url="https://example.com/p/how-to-pitch-outlet",
        )
    assert msg_id is not None


def test_cold_send_blocks_hallucinated_address_via_outlet_page(
        dynamodb_table: str, ses_client: object) -> None:
    """The 2026-05-01 incident: bot pitched editorial@example.com but
    example.com/p/how-to-pitch-outlet actually says pitches@example.com.
    Verifier blocks this BEFORE SES is called."""
    fake_resp = MagicMock(
        status_code=200,
        text="Pitch the outlet: pitches@example.com",
    )
    sender = EmailSender(
        table_name=dynamodb_table, sesv2_client=_mock_sesv2_no_suppression(),
    )
    with _patch_mx_ok(), patch.object(
        address_verify.requests, "get", return_value=fake_resp,
    ):
        with pytest.raises(BadAddressError) as exc:
            sender.send(
                to="editorial@example.com",  # hallucinated
                subject="s", body="b",
                thread_id=None, kind="cold",
                source_url="https://example.com/p/how-to-pitch-outlet",
            )
    assert exc.value.result.layer == "outlet-page"
    assert exc.value.result.reason == "address-not-on-page"


def test_reply_kind_skips_verification(
        dynamodb_table: str, ses_client: object) -> None:
    """Replies are addressed to people who replied to us — already verified
    by virtue of the conversation existing. Skip the verifier."""
    sender = EmailSender(table_name=dynamodb_table)
    msg_id = sender.send(
        to="they-replied@example.com", subject="Re: x", body="thanks",
        thread_id="thread-1", kind="reply",
    )
    assert msg_id is not None


# ─── Recent-send deduplication (30-day window) ──────────────────────────


def _seed_prior_cold_send(table_name: str, addr: str, ts: str,
                          msg_id: str = "test-msg-id",
                          status: str = "sent") -> None:
    """Backfill a post#email row simulating a prior cold send."""
    State(table_name=table_name).put(
        "post#email", f"{ts}#{msg_id}",
        {
            "to": addr,
            "subject": "prior pitch",
            "kind": "cold",
            "thread_id": None,
            "status": status,
            "ses_message_id": msg_id,
            "ts": ts,
        },
    )


def test_cold_send_blocks_recent_duplicate(
        dynamodb_table: str, ses_client: object) -> None:
    """The 2026-05-02 incident: OUTLET-A pitched twice in 17min, OUTLET-B twice in
    20min. Within-window prior cold send must block at the deterministic
    layer regardless of LLM planner state."""
    addr = "outlet-a@outlet-a.example"
    ts_recent = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    _seed_prior_cold_send(dynamodb_table, addr, ts_recent, "msg-recent")
    sender = EmailSender(table_name=dynamodb_table)
    with pytest.raises(RecentSendError) as exc_info:
        sender.send(
            to=addr, subject="dup", body="b",
            thread_id=None, kind="cold",
            skip_verify=True,
        )
    assert exc_info.value.addr == addr
    assert exc_info.value.last_ts == ts_recent
    assert exc_info.value.last_msg_id == "msg-recent"


def test_cold_send_allows_after_window(
        dynamodb_table: str, ses_client: object) -> None:
    """A cold send to the same recipient outside the window is allowed —
    follow-up after a few months is legitimate outreach, not spam."""
    addr = "editor@old-pitch.example.com"
    ts_old = (
        datetime.now(timezone.utc)
        - timedelta(days=RECENT_COLD_SEND_WINDOW_DAYS + 5)
    ).isoformat()
    _seed_prior_cold_send(dynamodb_table, addr, ts_old, "msg-old")
    sender = EmailSender(table_name=dynamodb_table)
    msg_id = sender.send(
        to=addr, subject="follow-up", body="b",
        thread_id=None, kind="cold",
        skip_verify=True,
    )
    assert msg_id is not None


def test_recent_send_check_is_case_insensitive(
        dynamodb_table: str, ses_client: object) -> None:
    """Same-mailbox case-fold must block — `OUTLET-A@outlet-a.example` and
    `outlet-a@outlet-a.example` are the same recipient."""
    ts_recent = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    _seed_prior_cold_send(dynamodb_table, "outlet-a@outlet-a.example", ts_recent)
    sender = EmailSender(table_name=dynamodb_table)
    with pytest.raises(RecentSendError):
        sender.send(
            to="OUTLET-A@OUTLET-A.EXAMPLE", subject="dup", body="b",
            thread_id=None, kind="cold",
            skip_verify=True,
        )


def test_reply_kind_ignores_recent_send_check(
        dynamodb_table: str, ses_client: object) -> None:
    """A reply to a thread we already started is by definition not a
    duplicate cold pitch. Reply lane bypasses the dedup check."""
    addr = "convo@example.com"
    ts_recent = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    _seed_prior_cold_send(dynamodb_table, addr, ts_recent)
    sender = EmailSender(table_name=dynamodb_table)
    msg_id = sender.send(
        to=addr, subject="Re: prior", body="thanks for replying",
        thread_id="thread-1", kind="reply",
    )
    assert msg_id is not None


def test_recent_send_does_not_consume_rate_limit(
        dynamodb_table: str, ses_client: object) -> None:
    """A recent-send rejection must NOT burn quota — same anti-DoS
    reasoning as the DNC + verify-failure paths."""
    addr = "spam@example.com"
    ts_recent = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    _seed_prior_cold_send(dynamodb_table, addr, ts_recent)
    sender = EmailSender(table_name=dynamodb_table)
    with pytest.raises(RecentSendError):
        sender.send(
            to=addr, subject="dup", body="b",
            thread_id=None, kind="cold",
            skip_verify=True,
        )
    from outreach.rate_limit import RateLimiter
    assert RateLimiter(table_name=dynamodb_table).used_today("email", "cold") == 0


def test_recent_send_does_not_auto_dnc(
        dynamodb_table: str, ses_client: object) -> None:
    """A recent-send rejection must NOT add the address to do-not-contact —
    the address is fine, just recently pitched. Compare to verify-failure
    which DOES auto-DNC the bad address."""
    addr = "outlet-a@outlet-a.example"
    ts_recent = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    _seed_prior_cold_send(dynamodb_table, addr, ts_recent)
    sender = EmailSender(table_name=dynamodb_table)
    with pytest.raises(RecentSendError):
        sender.send(
            to=addr, subject="dup", body="b",
            thread_id=None, kind="cold",
            skip_verify=True,
        )
    state = State(table_name=dynamodb_table)
    dnc = state.get(f"do-not-contact#{addr}", "metadata")
    assert dnc is None


def test_failed_prior_send_does_not_block_retry(
        dynamodb_table: str, ses_client: object) -> None:
    """A prior cold send with status='failed' (SES API blip, etc.)
    must not block a retry — failure means the email never landed."""
    addr = "retry@example.com"
    ts_recent = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    _seed_prior_cold_send(dynamodb_table, addr, ts_recent,
                          msg_id="failed-abc", status="failed")
    sender = EmailSender(table_name=dynamodb_table)
    msg_id = sender.send(
        to=addr, subject="retry", body="b",
        thread_id=None, kind="cold",
        skip_verify=True,
    )
    assert msg_id is not None


def test_dryrun_skips_recent_send_check(
        dynamodb_table: str, ses_client: object) -> None:
    """Dryrun bypasses verification AND recent-send checks — it's a
    'simulate the send' mode, not a 'gate-test' mode."""
    addr = "dup@example.com"
    ts_recent = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    _seed_prior_cold_send(dynamodb_table, addr, ts_recent)
    sender = EmailSender(table_name=dynamodb_table, dryrun=True)
    msg_id = sender.send(
        to=addr, subject="dup", body="b",
        thread_id=None, kind="cold",
    )
    assert msg_id.startswith("dryrun-")
