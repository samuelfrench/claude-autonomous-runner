# daemon/outreach/outreach/cli.py
"""Subcommand router for the outreach toolkit.

Each subcommand emits JSON to stdout for easy parsing by the bot.
Use --dryrun to suppress side effects.
"""
from __future__ import annotations

import json
import sys
from typing import Any

import click

from outreach.address_verify import verify_address
from outreach.email_inbox import EmailInbox
from outreach.email_send import (
    BadAddressError,
    DoNotContactError,
    EmailSender,
    OverCapError,
    RecentSendError,
)
from outreach.kpi import KpiSnapshot
from outreach.state import State


@click.group()
@click.option("--dryrun/--no-dryrun", default=False, help="Suppress side effects.")
@click.pass_context
def main(ctx: click.Context, dryrun: bool) -> None:
    """outreach — autonomous outreach toolkit."""
    ctx.ensure_object(dict)
    ctx.obj["dryrun"] = dryrun


@main.group()
def state() -> None:
    """DynamoDB state operations."""


@state.command("get")
@click.argument("pk")
@click.argument("sk")
def state_get(pk: str, sk: str) -> None:
    s = State()
    item = s.get(pk, sk)
    click.echo(json.dumps(item, default=str))


@state.command("put")
@click.argument("pk")
@click.argument("sk")
@click.argument("attrs_json")
def state_put(pk: str, sk: str, attrs_json: str) -> None:
    s = State()
    attrs = json.loads(attrs_json)
    s.put(pk, sk, attrs)
    click.echo(json.dumps({"ok": True}))


@main.group()
def email() -> None:
    """Email channel operations."""


@email.command("send")
@click.option("--to", required=True)
@click.option("--subject", required=True)
@click.option("--body", required=True)
@click.option("--kind", type=click.Choice(["cold", "reply"]), default="cold")
@click.option("--thread-id", default=None)
@click.option("--source-url", default=None,
              help="URL of outlet's published contact/pitch page where "
                   "this address appears. Required for cold sends.")
@click.option("--allow-unverified", is_flag=True, default=False,
              help="Skip the source-URL requirement (escape hatch — only "
                   "use for warm targets like canary addresses).")
@click.pass_context
def email_send(ctx: click.Context, to: str, subject: str, body: str,
               kind: str, thread_id: str | None,
               source_url: str | None, allow_unverified: bool) -> None:
    sender = EmailSender(dryrun=ctx.obj["dryrun"])
    try:
        msg_id = sender.send(
            to=to, subject=subject, body=body,
            thread_id=thread_id, kind=kind,
            source_url=source_url,
            require_source_url=not allow_unverified,
        )
        click.echo(json.dumps({"message_id": msg_id, "ok": True}))
    except OverCapError as e:
        click.echo(json.dumps({"ok": False, "error": str(e), "kind": "rate-limit"}),
                   err=True)
        sys.exit(2)
    except BadAddressError as e:
        click.echo(json.dumps({
            "ok": False,
            "error": str(e),
            "kind": "verify-failed",
            "verification_layer": e.result.layer,
            "verification_reason": e.result.reason,
            "verification_extra": e.result.extra,
        }), err=True)
        sys.exit(3)
    except DoNotContactError as e:
        click.echo(json.dumps({"ok": False, "error": str(e), "kind": "do-not-contact"}),
                   err=True)
        sys.exit(4)
    except RecentSendError as e:
        click.echo(json.dumps({
            "ok": False,
            "error": str(e),
            "kind": "recent-send",
            "addr": e.addr,
            "last_ts": e.last_ts,
            "last_msg_id": e.last_msg_id,
        }), err=True)
        sys.exit(5)


@email.command("verify")
@click.argument("addr")
@click.option("--source-url", default=None)
def email_verify(addr: str, source_url: str | None) -> None:
    """Run the multi-layer pre-send verifier without sending."""
    res = verify_address(addr, source_url=source_url)
    click.echo(json.dumps({
        "addr": addr,
        "ok": res.ok,
        "layer": res.layer,
        "reason": res.reason,
        "extra": res.extra,
    }, default=str))


@email.group("inbox")
def email_inbox_group() -> None:
    """Inbound email triage. Reads inbound#email items written by the
    SES → S3 → Lambda parser pipeline. Lets the bot autonomously surface
    replies that need attention."""


@email_inbox_group.command("list-unprocessed")
@click.option("--limit", type=int, default=20,
              help="Max items to return (default 20).")
def email_inbox_list_unprocessed(limit: int) -> None:
    """List unprocessed inbound items as JSON. Use to triage replies."""
    inbox = EmailInbox()
    items: list[dict[str, Any]] = []
    for item in inbox.unprocessed():
        if len(items) >= limit:
            break
        items.append({
            "sk": item.get("sk", ""),
            "ts": item.get("ts", ""),
            "from": item.get("from", ""),
            "to": item.get("to", ""),
            "subject": item.get("subject", ""),
            "priority_hint": item.get("priority_hint", "general"),
            "in_reply_to": item.get("in_reply_to", ""),
        })
    click.echo(json.dumps({"unprocessed": items, "count": len(items)},
                          default=str))


@email_inbox_group.command("read")
@click.argument("sk")
def email_inbox_read(sk: str) -> None:
    """Read a single inbound item by sk (full body included)."""
    s = State()
    item = s.get("inbound#email", sk)
    if item is None:
        click.echo(json.dumps({"ok": False, "error": "not-found", "sk": sk}),
                   err=True)
        sys.exit(1)
    click.echo(json.dumps(item, default=str))


@email_inbox_group.command("mark-processed")
@click.argument("sk")
@click.option("--reply-msg-id", default=None,
              help="If we replied, the SES message_id of the reply.")
def email_inbox_mark_processed(sk: str, reply_msg_id: str | None) -> None:
    """Mark an inbound item processed (so it stops appearing in
    list-unprocessed). Optionally record the reply msg_id."""
    inbox = EmailInbox()
    inbox.mark_processed(sk, reply_msg_id=reply_msg_id)
    click.echo(json.dumps({"ok": True, "sk": sk,
                           "reply_msg_id": reply_msg_id}))


@email_inbox_group.command("next-priority")
def email_inbox_next_priority() -> None:
    """Return the highest-priority unprocessed item (researcher > press
    > domain-org > general > low). Null if inbox is empty."""
    inbox = EmailInbox()
    item = inbox.next_priority()
    click.echo(json.dumps(item, default=str))


@main.group()
def kpi() -> None:
    """KPI snapshot operations."""


@kpi.command("snapshot")
def kpi_snapshot() -> None:
    snap = KpiSnapshot()
    result = snap.write_today()
    click.echo(json.dumps(result, default=str))


if __name__ == "__main__":
    main()
