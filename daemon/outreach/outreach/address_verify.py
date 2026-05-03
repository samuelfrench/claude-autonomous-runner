# daemon/outreach/outreach/address_verify.py
"""Multi-layer pre-send address verification.

The bot's targeting list comes from LLM-generated markdown that has been
shown to hallucinate plausible-looking but non-existent addresses (the
2026-05-01 incident: 7/10 fabricated). This module guards every cold send
behind a layered check:

  1. Syntax (regex)                       — local, free
  2. DDB do-not-contact# row              — local, free
  3. SES account-level suppression list   — boto3 head request, free
  4. DNS MX-record existence              — dnspython, free
  5. Outlet-page substring match           — requests, free, strongest
                                            defense against LLM hallucinations
                                            (when source_url is provided)
  6. Hunter.io verifier (optional)        — paid SaaS, only runs if
                                            HUNTER_API_KEY is set

Returns a structured `VerificationResult` so callers can log the failing
layer and reason. Layers 1-5 are typically sufficient: layer 4 catches
unresolvable domains, and layer 5 catches addresses that don't appear on
the outlet's published contact page. Layer 6 is belt-and-suspenders.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Optional

import boto3
import dns.resolver
import dns.exception
import requests
from botocore.exceptions import ClientError

from outreach.config import AWS_REGION
from outreach.state import State


# Lexical sanity. Not RFC 5322 — we accept what real-world MTAs accept.
_SYNTAX_RE = re.compile(r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$")

_HUNTER_VERIFY_URL = "https://api.hunter.io/v2/email-verifier"
_HUNTER_TIMEOUT_SEC = 10
# Hunter score threshold for `accept_all` (catch-all) responses. Catch-all
# domains are common in editorial/journalism; rejecting all of them costs
# legitimate targets. Threshold from independent-benchmark recommendations.
_HUNTER_CATCH_ALL_SCORE_THRESHOLD = 70

_DEFAULT_PAGE_TIMEOUT_SEC = 8
_DEFAULT_PAGE_USER_AGENT = (
    "outreach-outreach-verifier/1.0 (+https://example.com)"
)


@dataclass
class VerificationResult:
    ok: bool
    layer: str  # which layer made the decision
    reason: str  # human-readable detail
    extra: dict  # metadata (Hunter score, MX records, etc.)


def _syntax_ok(addr: str) -> bool:
    return bool(_SYNTAX_RE.match(addr or ""))


def _check_dnc(addr: str, state: State) -> bool:
    """True iff there is a do-not-contact#<lower(addr)> row."""
    return state.get(f"do-not-contact#{addr.lower().strip()}", "metadata") is not None


def _check_ses_suppressed(addr: str, sesv2_client) -> tuple[bool, str]:
    """Query SES account-level suppression list. Returns (is_suppressed, reason).

    SES auto-adds bounced/complained addresses; subsequent sends silently
    drop. Querying this list pre-send lets us short-circuit and write a
    do-not-contact row so the bot's targeting view stays in sync.
    """
    try:
        resp = sesv2_client.get_suppressed_destination(EmailAddress=addr.lower())
        attrs = resp.get("SuppressedDestination", {})
        return True, (attrs.get("Reason") or "suppressed")
    except sesv2_client.exceptions.NotFoundException:
        return False, ""
    except ClientError as e:
        # Unrecognised error — fail-open with a warning, not a block.
        # We don't want a transient SES API blip to halt the whole bot.
        return False, f"ses-api-error:{e.response.get('Error', {}).get('Code', '?')}"


def _check_mx(addr: str) -> tuple[bool, str, list[str]]:
    """DNS MX lookup. Returns (ok, reason, mx_records).

    Catches the 'domain does not resolve at all' case (NXDOMAIN /
    SERVFAIL / no MX). Does NOT catch 'mailbox doesn't exist on a real
    domain' — that's Hunter.io's job (or the bounce handler's after the
    fact).
    """
    domain = addr.split("@", 1)[-1]
    if not domain:
        return False, "no-domain-part", []
    try:
        answers = dns.resolver.resolve(domain, "MX", lifetime=5.0)
        mx = [str(r.exchange).rstrip(".") for r in answers]
        if not mx:
            return False, "no-mx-records", []
        return True, "", mx
    except dns.resolver.NXDOMAIN:
        return False, "nxdomain", []
    except dns.resolver.NoAnswer:
        # Domain exists but has no MX. Some shops use only A records for
        # mail; conservative read is to fail. Real role addresses on
        # editorial domains always have MX.
        return False, "no-mx-records", []
    except dns.resolver.NoNameservers:
        return False, "no-nameservers", []
    except dns.exception.DNSException as e:
        # Transient DNS errors. Fail open — the SES suppression list +
        # bounce handler will catch sustained badness.
        return True, f"dns-error:{type(e).__name__}", []


def _check_outlet_page(addr: str, source_url: str,
                       timeout: float = _DEFAULT_PAGE_TIMEOUT_SEC,
                       user_agent: str = _DEFAULT_PAGE_USER_AGENT,
                       ) -> tuple[bool, str]:
    """Fetch the outlet's published contact page and confirm the address
    appears in the body. This is the strongest free defense against the
    LLM-hallucination failure mode.

    A bot that pitches `pitches@example.com` and links to
    https://example.com/p/how-to-pitch-outlet must be able to find the
    string `pitches@example.com` on that page. If not, the bot has either
    hallucinated the address or the outlet has changed its policy — both
    are blocking conditions.
    """
    if not source_url:
        return False, "no-source-url"
    try:
        resp = requests.get(
            source_url,
            timeout=timeout,
            headers={"User-Agent": user_agent},
            allow_redirects=True,
        )
    except requests.RequestException as e:
        return False, f"fetch-error:{type(e).__name__}"
    if resp.status_code != 200:
        return False, f"http-{resp.status_code}"
    if addr.lower() not in resp.text.lower():
        return False, "address-not-on-page"
    return True, ""


def _check_hunter(addr: str, api_key: str) -> tuple[bool, str, dict]:
    """Hunter.io email verification. Returns (ok, reason, extras)."""
    try:
        r = requests.get(
            _HUNTER_VERIFY_URL,
            params={"email": addr, "api_key": api_key},
            timeout=_HUNTER_TIMEOUT_SEC,
        )
    except requests.RequestException as e:
        return True, f"hunter-network-error:{type(e).__name__}", {}
    if r.status_code != 200:
        return True, f"hunter-http-{r.status_code}", {}
    data = (r.json() or {}).get("data", {}) or {}
    status = data.get("status", "unknown")
    score = int(data.get("score") or 0)
    extras = {"hunter_status": status, "hunter_score": score}
    if status == "valid":
        return True, "hunter-valid", extras
    if status == "accept_all":
        if score >= _HUNTER_CATCH_ALL_SCORE_THRESHOLD:
            return True, f"hunter-accept-all-score-{score}", extras
        return False, f"hunter-accept-all-low-score-{score}", extras
    if status in ("invalid", "disposable"):
        return False, f"hunter-{status}", extras
    # Unknown / webmail / etc. — fail closed; better safe than another bounce.
    return False, f"hunter-{status}", extras


def verify_address(
    addr: str,
    *,
    source_url: Optional[str] = None,
    state: Optional[State] = None,
    sesv2_client=None,
    require_source_url: bool = False,
    skip_outlet_page: bool = False,
) -> VerificationResult:
    """Run the layered pre-send check. Layers fail-fast.

    Args:
        addr: address to verify
        source_url: outlet's published contact-page URL — enables layer 5
        state: optional reused State (avoids extra DDB client churn)
        sesv2_client: optional reused boto3 client
        require_source_url: when True, missing source_url is a hard fail
            (recommended for cold sends post-2026-05-01 incident)
        skip_outlet_page: tests / dryrun escape hatch
    """
    addr = (addr or "").strip()

    if not _syntax_ok(addr):
        return VerificationResult(False, "syntax", "invalid-syntax", {})

    state = state or State()
    if _check_dnc(addr, state):
        return VerificationResult(False, "dnc", "in-do-not-contact-list", {})

    sesv2_client = sesv2_client or boto3.client("sesv2", region_name=AWS_REGION)
    suppressed, reason = _check_ses_suppressed(addr, sesv2_client)
    if suppressed:
        return VerificationResult(False, "ses-suppression", reason, {})

    mx_ok, mx_reason, mx = _check_mx(addr)
    if not mx_ok:
        return VerificationResult(
            False, "mx", mx_reason, {"mx_records": mx},
        )

    if require_source_url and not source_url:
        return VerificationResult(
            False, "outlet-page", "source-url-required-but-missing", {},
        )

    if source_url and not skip_outlet_page:
        page_ok, page_reason = _check_outlet_page(addr, source_url)
        if not page_ok:
            return VerificationResult(
                False, "outlet-page", page_reason,
                {"source_url": source_url},
            )

    api_key = os.environ.get("HUNTER_API_KEY")
    if api_key:
        hok, hreason, hextras = _check_hunter(addr, api_key)
        if not hok:
            return VerificationResult(False, "hunter", hreason, hextras)
        return VerificationResult(True, "hunter", hreason, hextras)

    return VerificationResult(True, "ok", "passed-layers-1-5", {"mx_records": mx})
