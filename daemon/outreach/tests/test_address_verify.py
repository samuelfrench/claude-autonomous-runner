# daemon/outreach/tests/test_address_verify.py
"""Tests for the multi-layer pre-send address verifier."""
from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from outreach import address_verify
from outreach.address_verify import VerificationResult, verify_address
from outreach.state import State


# ─── Layer 1: syntax ─────────────────────────────────────────────────────


@pytest.mark.parametrize("addr", [
    "",
    "no-at-sign",
    "@no-local",
    "no-domain@",
    "x@y",  # tld too short
    "x@y.",
    "x y@example.com",  # whitespace
    "x@.com",
])
def test_syntax_rejects_obviously_bad(addr):
    res = verify_address(addr, skip_outlet_page=True)
    assert res.ok is False
    assert res.layer == "syntax"


# ─── Layer 2: do-not-contact ────────────────────────────────────────────


def test_dnc_blocks(dynamodb_table: str):
    state = State(table_name=dynamodb_table)
    state.put("do-not-contact#blocked@example.com", "metadata",
              {"email": "blocked@example.com"})
    res = verify_address(
        "blocked@example.com", state=state,
        sesv2_client=_mock_sesv2_no_suppression(),
        skip_outlet_page=True,
    )
    assert res.ok is False
    assert res.layer == "dnc"


# ─── Layer 3: SES suppression list ──────────────────────────────────────


def _mock_sesv2_no_suppression():
    mock = MagicMock()
    mock.exceptions.NotFoundException = type("NotFoundException", (Exception,), {})
    mock.get_suppressed_destination.side_effect = (
        mock.exceptions.NotFoundException("not in list")
    )
    return mock


def _mock_sesv2_suppressed(addr: str, reason: str = "BOUNCE"):
    mock = MagicMock()
    mock.exceptions.NotFoundException = type("NotFoundException", (Exception,), {})
    mock.get_suppressed_destination.return_value = {
        "SuppressedDestination": {
            "EmailAddress": addr,
            "Reason": reason,
            "LastUpdateTime": "2026-05-01T18:21:16Z",
        }
    }
    return mock


def test_ses_suppressed_blocks(dynamodb_table: str):
    res = verify_address(
        "bouncey@example.com",
        state=State(table_name=dynamodb_table),
        sesv2_client=_mock_sesv2_suppressed("bouncey@example.com"),
        skip_outlet_page=True,
    )
    assert res.ok is False
    assert res.layer == "ses-suppression"
    assert res.reason == "BOUNCE"


# ─── Layer 4: MX records ────────────────────────────────────────────────


def test_mx_missing_blocks(dynamodb_table: str):
    """The 2026-05-01 nonexistent-domain.example case: domain has no nameservers."""
    with patch.object(
        address_verify.dns.resolver, "resolve",
        side_effect=address_verify.dns.resolver.NXDOMAIN,
    ):
        res = verify_address(
            "x@nonexistent-foo-bar-baz.invalid",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
            skip_outlet_page=True,
        )
    assert res.ok is False
    assert res.layer == "mx"
    assert res.reason == "nxdomain"


def test_mx_present_passes(dynamodb_table: str):
    fake_answer = [MagicMock(exchange="aspmx.l.google.com.")]
    with patch.object(
        address_verify.dns.resolver, "resolve",
        return_value=fake_answer,
    ):
        res = verify_address(
            "anyone@example.com",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
            skip_outlet_page=True,
        )
    assert res.ok is True
    assert res.extra["mx_records"] == ["aspmx.l.google.com"]


def test_mx_transient_dns_error_fails_open(dynamodb_table: str):
    """Don't halt the whole bot on a transient DNS hiccup."""
    with patch.object(
        address_verify.dns.resolver, "resolve",
        side_effect=address_verify.dns.exception.Timeout,
    ):
        res = verify_address(
            "anyone@example.com",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
            skip_outlet_page=True,
        )
    # fail-open at the MX layer; still passes overall when no other gate trips
    assert res.ok is True


# ─── Layer 5: outlet-page substring check ───────────────────────────────


def _mx_ok():
    return patch.object(
        address_verify.dns.resolver, "resolve",
        return_value=[MagicMock(exchange="mail.example.com.")],
    )


def test_outlet_page_address_present_passes(dynamodb_table: str):
    fake_resp = MagicMock(status_code=200, text="Pitch us at editorial@x.com.")
    with _mx_ok(), patch.object(
        address_verify.requests, "get", return_value=fake_resp,
    ):
        res = verify_address(
            "editorial@x.com",
            source_url="https://x.com/contact",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
        )
    assert res.ok is True


def test_outlet_page_address_absent_blocks(dynamodb_table: str):
    """The 2026-05-01 hallucination case: bot picked editorial@example.com but
    example.com/p/how-to-pitch-outlet actually says pitches@example.com."""
    fake_resp = MagicMock(
        status_code=200,
        text="Send freelance pitches to <b>pitches@example.com</b>",
    )
    with _mx_ok(), patch.object(
        address_verify.requests, "get", return_value=fake_resp,
    ):
        res = verify_address(
            "editorial@example.com",  # hallucinated
            source_url="https://example.com/p/how-to-pitch-outlet",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
        )
    assert res.ok is False
    assert res.layer == "outlet-page"
    assert res.reason == "address-not-on-page"


def test_outlet_page_404_blocks(dynamodb_table: str):
    fake_resp = MagicMock(status_code=404, text="Not Found")
    with _mx_ok(), patch.object(
        address_verify.requests, "get", return_value=fake_resp,
    ):
        res = verify_address(
            "x@x.com", source_url="https://x.com/contact",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
        )
    assert res.ok is False
    assert res.layer == "outlet-page"
    assert res.reason == "http-404"


def test_require_source_url_blocks_when_missing(dynamodb_table: str):
    with _mx_ok():
        res = verify_address(
            "x@example.com",
            source_url=None,
            require_source_url=True,
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
        )
    assert res.ok is False
    assert res.layer == "outlet-page"
    assert res.reason == "source-url-required-but-missing"


# ─── Layer 6: Hunter.io ─────────────────────────────────────────────────


def test_hunter_skipped_when_no_api_key(dynamodb_table: str, monkeypatch):
    monkeypatch.delenv("HUNTER_API_KEY", raising=False)
    with _mx_ok():
        res = verify_address(
            "x@example.com",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
            skip_outlet_page=True,
        )
    assert res.ok is True
    assert res.layer == "ok"


def test_hunter_invalid_blocks(dynamodb_table: str, monkeypatch):
    monkeypatch.setenv("HUNTER_API_KEY", "test-key")
    fake_resp = MagicMock(
        status_code=200,
        json=lambda: {"data": {"status": "invalid", "score": 0}},
    )
    with _mx_ok(), patch.object(
        address_verify.requests, "get", return_value=fake_resp,
    ):
        res = verify_address(
            "fake@example.com",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
            skip_outlet_page=True,
        )
    assert res.ok is False
    assert res.layer == "hunter"


def test_hunter_accept_all_high_score_passes(dynamodb_table: str, monkeypatch):
    monkeypatch.setenv("HUNTER_API_KEY", "test-key")
    fake_resp = MagicMock(
        status_code=200,
        json=lambda: {"data": {"status": "accept_all", "score": 85}},
    )
    with _mx_ok(), patch.object(
        address_verify.requests, "get", return_value=fake_resp,
    ):
        res = verify_address(
            "x@catchall.example.com",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
            skip_outlet_page=True,
        )
    assert res.ok is True
    assert "accept-all" in res.reason


def test_hunter_accept_all_low_score_blocks(dynamodb_table: str, monkeypatch):
    monkeypatch.setenv("HUNTER_API_KEY", "test-key")
    fake_resp = MagicMock(
        status_code=200,
        json=lambda: {"data": {"status": "accept_all", "score": 35}},
    )
    with _mx_ok(), patch.object(
        address_verify.requests, "get", return_value=fake_resp,
    ):
        res = verify_address(
            "x@catchall.example.com",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
            skip_outlet_page=True,
        )
    assert res.ok is False
    assert "low-score" in res.reason


def test_hunter_network_error_fails_open(dynamodb_table: str, monkeypatch):
    """Don't halt on Hunter API blip; layers 1-5 are still defending."""
    monkeypatch.setenv("HUNTER_API_KEY", "test-key")
    with _mx_ok(), patch.object(
        address_verify.requests, "get",
        side_effect=address_verify.requests.RequestException("timeout"),
    ):
        res = verify_address(
            "x@example.com",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
            skip_outlet_page=True,
        )
    assert res.ok is True


# ─── End-to-end: the 2026-05-01 incident ────────────────────────────────


def test_e2e_catches_pitches_at_outlet_via_suppression_list(dynamodb_table: str):
    """After the first bounce, SES adds the address to the suppression list.
    A subsequent verify call must catch it BEFORE we burn another send."""
    res = verify_address(
        "pitches@example.com",
        state=State(table_name=dynamodb_table),
        sesv2_client=_mock_sesv2_suppressed("pitches@example.com", "BOUNCE"),
        skip_outlet_page=True,
    )
    assert res.ok is False
    assert res.layer == "ses-suppression"


def test_e2e_catches_hallucinated_outlet_via_outlet_page(dynamodb_table: str):
    """If the bot tries to send to editorial@example.com but the outlet's
    pitch page says pitches@example.com, layer 5 catches it BEFORE first send.
    This is the path that prevents future hallucination bounces."""
    fake_resp = MagicMock(
        status_code=200,
        text="To pitch the outlet, email pitches@example.com with subject FREELANCE PITCH",
    )
    with _mx_ok(), patch.object(
        address_verify.requests, "get", return_value=fake_resp,
    ):
        res = verify_address(
            "editorial@example.com",
            source_url="https://example.com/p/how-to-pitch-outlet",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
        )
    assert res.ok is False
    assert res.layer == "outlet-page"
    assert res.reason == "address-not-on-page"


def test_e2e_catches_nonexistent_domain_via_mx(dynamodb_table: str):
    """The 2026-05-01 nonexistent-domain.example case: SERVFAIL on dig NS."""
    with patch.object(
        address_verify.dns.resolver, "resolve",
        side_effect=address_verify.dns.resolver.NXDOMAIN,
    ):
        res = verify_address(
            "submissions@nonexistent-domain.example",
            state=State(table_name=dynamodb_table),
            sesv2_client=_mock_sesv2_no_suppression(),
            skip_outlet_page=True,
        )
    assert res.ok is False
    assert res.layer == "mx"
