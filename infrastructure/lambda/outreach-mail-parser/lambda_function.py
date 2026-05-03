# infrastructure/lambda/outreach-mail-parser/lambda_function.py
"""SES inbound parser Lambda.

Triggered when SES delivers a raw MIME message to S3. Two paths:

1. **Bounce DSN path** — if the message is a delivery-status notification
   (From: MAILER-DAEMON@*), parse the multipart/report body for
   Final-Recipient + Status (RFC 3463). Hard bounces (5.x.x) immediately
   write do-not-contact#<addr>. Soft bounces (4.x.x) accumulate in
   bounce#<addr> rolling-7-day records; promote to do-not-contact when
   3+ soft bounces land in the window. The bounce DSN itself is recorded as
   inbound#email with status=auto-processed so it does not appear as a
   pending reply for the bot to drain.

2. **Regular inbound path** — non-DSN mail is parsed for headers + body,
   classified by sender priority (researcher/press/domain-org/general),
   and written as inbound#email/unprocessed for the bot to triage.
   STOP/unsubscribe replies in the body auto-write do-not-contact#<email>.
"""
import email
import json
import logging
import os
import re
from datetime import datetime, timedelta, timezone
from email.policy import default
from email.utils import parseaddr

import boto3

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

DDB_TABLE = os.environ.get("DDB_TABLE", "clawd-bot-outreach")
S3_BUCKET = os.environ.get("S3_BUCKET", "clawd-bot-outreach-mail")
REGION = os.environ.get("AWS_REGION", "us-east-1")

s3 = boto3.client("s3", region_name=REGION)
ddb = boto3.resource("dynamodb", region_name=REGION)
table = ddb.Table(DDB_TABLE)


# Unambiguous opt-out phrases — searched anywhere in subject or first 500 body
# chars. These are essentially never used in casual reply prose.
UNAMBIGUOUS_OPT_OUT_RE = re.compile(
    r"\b(?:UNSUBSCRIBE|DO[\s-]NOT[\s-]CONTACT|REMOVE\s+ME(?:\s+FROM)?)\b",
    re.IGNORECASE,
)
# "STOP" alone is ambiguous ("had to stop by the apiary..."), so require it to
# be its own line (optionally with "please " prefix and trailing punctuation),
# in the first 5 lines of the body or in the subject.
BARE_STOP_RE = re.compile(
    r"^\s*(?:please\s+)?STOP[.!]?\s*$",
    re.IGNORECASE,
)


# ─────────────────────────────────────────────────────────────────────────
# Bounce / DSN parsing
# ─────────────────────────────────────────────────────────────────────────

# DSN messages come from MAILER-DAEMON (most servers) or postmaster (some).
DSN_FROM_RE = re.compile(r"\b(?:MAILER-DAEMON|postmaster)@", re.IGNORECASE)

# RFC 3464 / 6522 DSN field parsers. The body is a multipart/report whose
# message/delivery-status part contains one or more per-recipient stanzas
# with these headers. We also fall back to scanning the plain body because
# some senders emit a flat-text DSN.
FINAL_RECIPIENT_RE = re.compile(
    r"^Final-Recipient:\s*(?:rfc822;)?\s*([^\r\n]+)$",
    re.IGNORECASE | re.MULTILINE,
)
STATUS_RE = re.compile(r"^Status:\s*([0-9.]+)\s*$", re.IGNORECASE | re.MULTILINE)
DIAGNOSTIC_CODE_RE = re.compile(
    r"^Diagnostic-Code:\s*([^\r\n]+(?:\r?\n[ \t]+[^\r\n]+)*)",
    re.IGNORECASE | re.MULTILINE,
)

SOFT_BOUNCE_WINDOW_DAYS = 7
SOFT_BOUNCE_THRESHOLD = 3  # 3 soft bounces in 7 days → do-not-contact


def is_dsn(from_addr: str) -> bool:
    """True if the From header looks like a delivery-status notification."""
    return bool(DSN_FROM_RE.search(from_addr or ""))


def _extract_dsn_record(text: str) -> dict:
    """Extract one bounce record (recipient + status + diagnostic) from a
    DSN per-recipient stanza or flat-text body."""
    rec: dict = {}
    m = FINAL_RECIPIENT_RE.search(text)
    if m:
        rec["recipient"] = parseaddr(m.group(1).strip())[1].lower().strip()
    m = STATUS_RE.search(text)
    if m:
        status = m.group(1).strip()
        rec["status"] = status
        rec["bounce_type"] = (
            "hard" if status.startswith("5.") else
            "soft" if status.startswith("4.") else
            "unknown"
        )
    m = DIAGNOSTIC_CODE_RE.search(text)
    if m:
        rec["diagnostic_code"] = " ".join(m.group(1).split())[:500]
    return rec


def parse_dsn(raw_message: bytes) -> list[dict]:
    """Parse a DSN MIME message and return one record per failed recipient.

    Walks the multipart/report body for `message/delivery-status` parts
    (the canonical DSN format), then falls back to scanning the plain text
    body if no structured DSN part was found (some legacy mailers).
    """
    msg = email.message_from_bytes(raw_message, policy=default)
    bounces: list[dict] = []

    for part in msg.walk():
        if part.get_content_type() != "message/delivery-status":
            continue
        try:
            payload = part.get_payload()
        except Exception:
            payload = None
        # message/delivery-status is itself a sequence of message-like
        # objects, one per recipient. Walk them.
        if isinstance(payload, list):
            for sub in payload:
                rec = _extract_dsn_record(str(sub))
                if rec.get("recipient"):
                    bounces.append(rec)
        else:
            rec = _extract_dsn_record(str(payload))
            if rec.get("recipient"):
                bounces.append(rec)

    if not bounces:
        # Fallback: flat-text DSN. Pull text/plain body and try once.
        body = ""
        for part in msg.walk():
            if part.get_content_type() == "text/plain":
                try:
                    body = part.get_content()
                except Exception:
                    body = ""
                break
        rec = _extract_dsn_record(body)
        if rec.get("recipient"):
            bounces.append(rec)

    return bounces


def mark_bounced(table_handle, addr: str, bounce_type: str, status: str,
                 diagnostic_code: str, inbound_sk: str) -> None:
    """Record a bounce. Hard bounces immediately become do-not-contact.
    Soft bounces accumulate; promote to do-not-contact at threshold.

    The bounce#<addr> record is the rolling event log. The do-not-contact
    row is the source of truth checked by email_send.py."""
    addr = (addr or "").lower().strip()
    if not addr:
        return

    ts = datetime.now(timezone.utc).isoformat()
    table_handle.put_item(Item={
        "pk": f"bounce#{addr}",
        "sk": ts,
        "addr": addr,
        "bounce_type": bounce_type,
        "status_code": status,
        "diagnostic_code": diagnostic_code or "",
        "source_inbound_sk": inbound_sk,
    })

    if bounce_type == "hard":
        mark_do_not_contact(
            table_handle, addr, f"hard-bounce-{status}", inbound_sk,
        )
        LOG.info(f"Hard bounce: {addr} status={status} → do-not-contact")
        return

    if bounce_type == "soft":
        cutoff = (
            datetime.now(timezone.utc)
            - timedelta(days=SOFT_BOUNCE_WINDOW_DAYS)
        ).isoformat()
        try:
            resp = table_handle.query(
                KeyConditionExpression="pk = :pk AND sk >= :sk",
                ExpressionAttributeValues={
                    ":pk": f"bounce#{addr}",
                    ":sk": cutoff,
                },
            )
            soft_count = sum(
                1 for it in resp.get("Items", [])
                if it.get("bounce_type") == "soft"
            )
        except Exception as e:
            LOG.warning(f"soft-bounce count query failed for {addr}: {e}")
            soft_count = 1  # be conservative
        if soft_count >= SOFT_BOUNCE_THRESHOLD:
            mark_do_not_contact(
                table_handle, addr,
                f"soft-bounce-threshold-{soft_count}-in-{SOFT_BOUNCE_WINDOW_DAYS}d",
                inbound_sk,
            )
            LOG.info(
                f"Soft-bounce threshold reached: {addr} "
                f"({soft_count} in {SOFT_BOUNCE_WINDOW_DAYS}d) → do-not-contact"
            )
        else:
            LOG.info(
                f"Soft bounce: {addr} status={status} "
                f"(count={soft_count} in {SOFT_BOUNCE_WINDOW_DAYS}d window)"
            )


# ─────────────────────────────────────────────────────────────────────────
# Opt-out (STOP / unsubscribe) detection
# ─────────────────────────────────────────────────────────────────────────


def is_opt_out(subject: str, body: str) -> bool:
    """True if subject or body looks like an explicit opt-out.

    We separate two classes of signal because they have very different false-
    positive risk:

    1. **Unambiguous phrases** (`unsubscribe`, `do not contact`, `remove me`)
       are extremely uncommon in legitimate reply prose, so we search anywhere
       in the subject or the first 500 body chars.

    2. **Bare "STOP"** is common as a verb in normal English ("I had to stop
       by the apiary yesterday"). To avoid mis-classifying enthusiastic
       replies as opt-outs, we only treat STOP as opt-out when it appears as
       the entire content of its own line (optionally with "please" prefix
       and trailing `.`/`!`), within the first 5 body lines or in the
       subject. The 500-char body window is unchanged and still applies as
       an upper bound.
    """
    subj = subject or ""
    body = body or ""
    if UNAMBIGUOUS_OPT_OUT_RE.search(subj):
        return True
    if UNAMBIGUOUS_OPT_OUT_RE.search(body[:500]):
        return True
    if BARE_STOP_RE.match(subj):
        return True
    for line in body[:500].splitlines()[:5]:
        if BARE_STOP_RE.match(line):
            return True
    return False


def normalize_email(raw: str) -> str:
    """Extract and lowercase the address part of a From: header.

    'Name <addr@host>' -> 'addr@host'; bare 'addr@host' returns as-is. Used
    as the canonical key for do-not-contact and cold-target lookups.
    """
    _, addr = parseaddr(raw or "")
    return addr.lower().strip()


def mark_do_not_contact(table_handle, email_addr: str, reason: str,
                        inbound_sk: str) -> None:
    """Write authoritative do-not-contact#<email> row + set flag on any
    matching cold-target#<email> row so the bot's own state view stays in sync.

    The do-not-contact# row is the source of truth checked by email_send.py
    — the cold-target update is a convenience for the agent's targeting logic.
    """
    ts = datetime.now(timezone.utc).isoformat()
    table_handle.put_item(Item={
        "pk": f"do-not-contact#{email_addr}",
        "sk": "metadata",
        "email": email_addr,
        "added_at": ts,
        "reason": reason,
        "source_inbound_sk": inbound_sk,
    })
    # Best-effort update on any existing cold-target row. Conditional so we
    # don't accidentally create a placeholder row for an address that was
    # never targeted (e.g. someone proactively emailing in to opt out).
    try:
        table_handle.update_item(
            Key={"pk": f"cold-target#{email_addr}", "sk": "metadata"},
            UpdateExpression=(
                "SET do_not_contact = :t, do_not_contact_at = :ts, "
                "do_not_contact_reason = :r, #status = :s"
            ),
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":t": True,
                ":ts": ts,
                ":r": reason,
                ":s": "do-not-contact",
            },
            ConditionExpression="attribute_exists(pk)",
        )
    except table_handle.meta.client.exceptions.ConditionalCheckFailedException:
        pass


def classify_priority(from_addr: str, to_addr: str, subject: str) -> str:
    """Heuristic priority hint."""
    from_lower = from_addr.lower()
    if any(d in from_lower for d in [".edu", ".ac.", "cornell", "harvard", "ucdavis", "berkeley"]):
        return "researcher"
    if any(d in from_lower for d in ["nytimes.com", "wapo.com", "theatlantic", "bbc.co", "guardian.co",
                                       "wired.com", "scientificamerican", "sciam.com"]):
        return "press"
    # Replace these substrings with keywords that match the trade /
    # association / niche orgs you care about hearing from quickly.
    domain_org_keywords = tuple(
        s.strip() for s in os.environ.get("DOMAIN_ORG_KEYWORDS", "").split(",") if s.strip()
    )
    if domain_org_keywords and any(k in from_lower for k in domain_org_keywords):
        return "domain-org"
    return "general"


def lambda_handler(event, context):
    """Triggered on s3:ObjectCreated:Put under raw/ prefix."""
    LOG.info(f"Event: {json.dumps(event)}")
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        if not key.startswith("raw/"):
            continue

        obj = s3.get_object(Bucket=bucket, Key=key)
        raw = obj["Body"].read()
        msg = email.message_from_bytes(raw, policy=default)

        from_addr = msg.get("From", "").strip()
        to_addr = msg.get("To", "").strip()
        subject = msg.get("Subject", "").strip()
        message_id = msg.get("Message-ID", "").strip().strip("<>")
        in_reply_to = msg.get("In-Reply-To", "").strip().strip("<>")
        references = msg.get("References", "").strip()

        # ── Bounce DSN path ──
        # Mailer-daemon DSNs get their recipients recorded as bounces and
        # the message itself stored as auto-processed inbound. We do NOT
        # run the normal STOP/priority pipeline on DSN bodies — they are
        # not a human reply.
        if is_dsn(from_addr):
            bounces = parse_dsn(raw)
            ts = datetime.now(timezone.utc).isoformat()
            sk = f"{ts}#dsn-{key.split('/')[-1]}"

            # Audit row for the DSN itself
            table.put_item(Item={
                "pk": "inbound#email",
                "sk": sk,
                "status": "auto-processed",
                "auto_processed_reason": "bounce-dsn",
                "from": from_addr,
                "to": to_addr,
                "subject": subject,
                "message_id": message_id,
                "s3_key": key,
                "ts": ts,
                "bounces": [{
                    "recipient": b.get("recipient", ""),
                    "bounce_type": b.get("bounce_type", "unknown"),
                    "status": b.get("status", ""),
                    "diagnostic_code": b.get("diagnostic_code", ""),
                } for b in bounces],
            })

            for b in bounces:
                if b.get("recipient"):
                    mark_bounced(
                        table,
                        b["recipient"],
                        b.get("bounce_type", "unknown"),
                        b.get("status", "?"),
                        b.get("diagnostic_code", ""),
                        sk,
                    )

            LOG.info(
                f"DSN: {len(bounces)} bounce record(s) parsed, "
                f"sk={sk} from={from_addr}"
            )
            continue  # skip the normal inbound path

        # Body extraction
        body = ""
        if msg.is_multipart():
            for part in msg.walk():
                if part.get_content_type() == "text/plain":
                    body = part.get_content()
                    break
        else:
            body = msg.get_content()

        # Truncate body for DynamoDB (400KB item limit)
        if len(body) > 100_000:
            body = body[:100_000] + "\n\n[...truncated]"

        ts = datetime.now(timezone.utc).isoformat()
        sk = f"{ts}#{message_id or key.split('/')[-1]}"

        priority_hint = classify_priority(from_addr, to_addr, subject)

        opt_out = is_opt_out(subject, body)
        item = {
            "pk": "inbound#email",
            "sk": sk,
            "status": "auto-processed" if opt_out else "unprocessed",
            "from": from_addr,
            "to": to_addr,
            "subject": subject,
            "body": body,
            "message_id": message_id,
            "in_reply_to": in_reply_to,
            "references": references,
            "s3_key": key,
            "priority_hint": priority_hint,
            "ts": ts,
        }
        if opt_out:
            item["auto_processed_reason"] = "stop-reply"
        table.put_item(Item=item)

        if opt_out:
            sender = normalize_email(from_addr)
            if sender:
                mark_do_not_contact(table, sender, "stop-reply", sk)
                LOG.info(
                    f"Opt-out: marked do-not-contact#{sender} from inbound sk={sk}"
                )
            else:
                LOG.warning(f"Opt-out detected but no parseable sender: from={from_addr!r} sk={sk}")

        LOG.info(f"Stored inbound: pk=inbound#email sk={sk} from={from_addr} priority={priority_hint} opt_out={opt_out}")

    return {"ok": True}
