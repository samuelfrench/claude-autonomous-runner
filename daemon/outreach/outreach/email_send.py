# daemon/outreach/outreach/email_send.py
"""SES outbound — cold + reply lanes, rate-limited, DynamoDB-logged.

Cold sends are gated by a multi-layer pre-send verifier (see
`address_verify`). Verification failures auto-write a do-not-contact row
so future ticks short-circuit before any SES round trip.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

from outreach.address_verify import VerificationResult, verify_address
from outreach.config import (
    AWS_REGION,
    EMAIL_FROM,
    EMAIL_REPLY_TO,
    RECENT_COLD_SEND_WINDOW_DAYS,
)
from outreach.rate_limit import RateLimiter
from outreach.state import State


class OverCapError(Exception):
    """Raised when an email send would exceed the daily rate cap."""


class DoNotContactError(Exception):
    """Raised when a cold send is attempted to an address on the do-not-contact list.

    The list is populated by the SES inbound parser Lambda when a recipient
    replies with STOP / unsubscribe / etc. — the AWS SES production-access
    commitment requires that we honour these. The list also auto-grows from
    bounce DSNs (hard 5.x.x → immediate; soft 4.x.x → 3-in-7d threshold).
    """


class RecentSendError(Exception):
    """Raised when a cold send would duplicate a recent prior cold send.

    Same recipient, kind=cold, sent within RECENT_COLD_SEND_WINDOW_DAYS.
    Carries the prior send's timestamp + msg_id so callers can log
    context. Without this safety net an LLM planner with no cross-tick
    memory will pitch the same recipient twice within minutes.

    Unlike BadAddressError, this does NOT auto-DNC. The address is
    fine; we just shouldn't re-pitch.
    """

    def __init__(self, addr: str, last_ts: str, last_msg_id: str = ""):
        super().__init__(
            f"recent cold send to {addr} at {last_ts} "
            f"(within {RECENT_COLD_SEND_WINDOW_DAYS}d window)"
        )
        self.addr = addr
        self.last_ts = last_ts
        self.last_msg_id = last_msg_id


class BadAddressError(Exception):
    """Raised when pre-send address verification fails (any layer).

    Carries the structured `VerificationResult` so callers / decision-log
    can record exactly which layer rejected the address.
    """

    def __init__(self, message: str, result: VerificationResult):
        super().__init__(message)
        self.result = result


class EmailSender:
    def __init__(self, table_name: str | None = None, dryrun: bool = False,
                 sesv2_client=None):
        """Args:
            table_name: optional override for the DDB table (test plumbing)
            dryrun: when True, no SES calls and no rate-limit consumption
            sesv2_client: optional override for the boto3 sesv2 client
                (test plumbing — moto doesn't yet implement
                `get_suppressed_destination`, so tests inject a MagicMock)
        """
        self._state = State(table_name=table_name) if table_name else State()
        self._rl = RateLimiter(table_name=table_name) if table_name else RateLimiter()
        self._dryrun = dryrun
        self._ses = boto3.client("ses", region_name=AWS_REGION) if not dryrun else None
        if sesv2_client is not None:
            self._sesv2 = sesv2_client
        elif not dryrun:
            self._sesv2 = boto3.client("sesv2", region_name=AWS_REGION)
        else:
            self._sesv2 = None

    def _is_do_not_contact(self, addr: str) -> bool:
        """True iff there is a do-not-contact#<lower(addr)> row in DDB."""
        return self._state.get(f"do-not-contact#{addr.lower().strip()}", "metadata") is not None

    def _recent_cold_send(self, addr: str) -> dict[str, Any] | None:
        """Return the most recent prior cold send to `addr` within the
        RECENT_COLD_SEND_WINDOW_DAYS window, or None.

        Scans `post#email` and filters in Python — at 15 cold/day cap
        and a 30-day window, worst case is ~450 rows. Larger tables
        will eventually want a server-side filter, but this is fine
        until volume scales an order of magnitude.
        """
        cutoff = (
            datetime.now(timezone.utc)
            - timedelta(days=RECENT_COLD_SEND_WINDOW_DAYS)
        ).isoformat()
        addr_lower = addr.lower().strip()
        most_recent: dict[str, Any] | None = None
        for item in self._state.query_pk("post#email"):
            if item.get("kind") != "cold":
                continue
            if item.get("status") != "sent":
                # A previously-failed send shouldn't block a retry
                continue
            if (item.get("to") or "").lower().strip() != addr_lower:
                continue
            ts = item.get("ts", "")
            if ts < cutoff:
                continue
            if most_recent is None or ts > most_recent.get("ts", ""):
                most_recent = item
        return most_recent

    def _record_dnc_from_verification(self, addr: str, res: VerificationResult) -> None:
        """Write a do-not-contact row when verification fails. Future ticks
        short-circuit at the DNC check without re-running the verifier."""
        norm = addr.lower().strip()
        self._state.put(f"do-not-contact#{norm}", "metadata", {
            "email": norm,
            "added_at": datetime.now(timezone.utc).isoformat(),
            "reason": f"verify-{res.layer}-{res.reason}",
            "verification_layer": res.layer,
            "verification_reason": res.reason,
            "verification_extra": res.extra,
        })

    def send(self, *, to: str, subject: str, body: str,
             thread_id: str | None, kind: str = "cold",
             source_url: str | None = None,
             require_source_url: bool = True,
             skip_verify: bool = False) -> str:
        """Send a cold pitch or reply.

        Args:
            to: recipient address
            subject: subject line (cold sends should keep ≤60 chars)
            body: text body (must end with mandatory STOP opt-out line for cold)
            thread_id: conversation thread id for replies; None for new pitches
            kind: "cold" | "reply"
            source_url: outlet's published contact-page URL — required for
                cold sends so the verifier can confirm the address actually
                appears on the outlet's own site (the canonical defense
                against the 2026-05-01 LLM-hallucination failure mode)
            require_source_url: if True (default), cold sends without a
                source_url are rejected at verify time
            skip_verify: dryrun / test escape hatch
        """
        if kind not in ("cold", "reply"):
            raise ValueError(f"invalid email kind: {kind}")

        # Cold sends only — replies are conversation continuation; if they
        # truly opted out they wouldn't have replied in the first place.
        if kind == "cold" and self._is_do_not_contact(to):
            raise DoNotContactError(f"address on do-not-contact list: {to}")

        # Cold-pitch deduplication. An LLM planner with no cross-tick memory
        # will pitch the same recipient twice within minutes if not blocked.
        # This is the deterministic safety net. Replies bypass — a thread
        # continuation is by definition not a duplicate cold pitch.
        if kind == "cold" and not self._dryrun:
            prior = self._recent_cold_send(to)
            if prior:
                raise RecentSendError(
                    addr=to,
                    last_ts=prior.get("ts", ""),
                    last_msg_id=prior.get("ses_message_id", ""),
                )

        # Pre-send address verification (cold sends only).
        # We cannot trust LLM-generated
        # targeting lists without verification: 7/10 addresses were
        # hallucinated. The verifier runs syntax → DNC → SES suppression →
        # MX → outlet-page substring → optional Hunter.io.
        if kind == "cold" and not skip_verify and not self._dryrun:
            res = verify_address(
                to,
                source_url=source_url,
                state=self._state,
                sesv2_client=self._sesv2,
                require_source_url=require_source_url,
            )
            if not res.ok:
                self._record_dnc_from_verification(to, res)
                raise BadAddressError(
                    f"address verification failed at layer={res.layer} "
                    f"reason={res.reason}",
                    res,
                )

        if not self._dryrun:
            if not self._rl.consume("email", kind):
                raise OverCapError(f"email/{kind} daily cap reached")

        ts = datetime.now(timezone.utc).isoformat()
        if self._dryrun:
            msg_id = f"dryrun-{uuid.uuid4().hex}"
        else:
            try:
                resp = self._ses.send_email(
                    Source=EMAIL_FROM,
                    Destination={"ToAddresses": [to]},
                    Message={
                        "Subject": {"Data": subject},
                        "Body": {"Text": {"Data": body}},
                    },
                    ReplyToAddresses=[EMAIL_REPLY_TO],
                )
                msg_id = resp["MessageId"]
            except ClientError as e:
                self._rl._state.increment(
                    f"rate-limit#email", self._rl._today_sk(), kind, -1)
                self._state.put("post#email", f"{ts}#failed-{uuid.uuid4().hex[:8]}", {
                    "to": to,
                    "subject": subject,
                    "kind": kind,
                    "thread_id": thread_id,
                    "status": "failed",
                    "error": str(e),
                    "ts": ts,
                })
                raise

        self._state.put("post#email", f"{ts}#{msg_id}", {
            "to": to,
            "subject": subject,
            "kind": kind,
            "thread_id": thread_id,
            "status": "sent" if not self._dryrun else "dryrun",
            "ses_message_id": msg_id,
            "ts": ts,
        })
        return msg_id
