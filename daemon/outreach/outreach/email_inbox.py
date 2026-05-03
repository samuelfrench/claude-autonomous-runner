# daemon/outreach/outreach/email_inbox.py
"""Email inbox polling — reads inbound#email items from DynamoDB.

Inbound flow: SES inbound rule writes raw MIME to S3, Lambda parses and
puts inbound#email items here. This module reads them for the bot to
triage.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Iterator

from outreach.state import State


PRIORITY_ORDER = {
    "researcher": 0,
    "press": 1,
    "domain-org": 2,
    "general": 3,
    "low": 4,
}


class EmailInbox:
    def __init__(self, table_name: str | None = None):
        self._state = State(table_name=table_name) if table_name else State()

    def unprocessed(self) -> Iterator[dict[str, Any]]:
        for item in self._state.query_pk("inbound#email"):
            if item.get("status") == "unprocessed":
                yield item

    def mark_processed(self, sk: str, reply_msg_id: str | None = None) -> None:
        attrs: dict[str, Any] = {"status": "processed",
                                 "processed_at": datetime.now(timezone.utc).isoformat()}
        if reply_msg_id:
            attrs["reply_msg_id"] = reply_msg_id
        self._state.update("inbound#email", sk, attrs)

    def next_priority(self) -> dict[str, Any] | None:
        items = list(self.unprocessed())
        if not items:
            return None
        items.sort(key=lambda x: PRIORITY_ORDER.get(x.get("priority_hint", "general"), 99))
        return items[0]
