# daemon/outreach/outreach/account.py
"""Bot account state machine.

States: warming → active → degraded → flagged → retired.
Transitions are enforced; invalid transitions raise InvalidTransition.
Promotion warming→active gated by config.WARMUP_DAYS + a karma threshold.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from enum import Enum
from typing import Any

from outreach.config import WARMUP_DAYS
from outreach.state import State


class AccountStatus(str, Enum):
    WARMING = "warming"
    ACTIVE = "active"
    DEGRADED = "degraded"
    FLAGGED = "flagged"
    RETIRED = "retired"


class InvalidTransition(Exception):
    """Raised when an unsupported state transition is attempted."""


KARMA_THRESHOLD: dict[str, int] = {
    "reddit": 50,
    "x": 10,
    "email": 0,
}


@dataclass
class Account:
    channel: str
    account_id: str
    _raw: dict[str, Any]
    _state: State

    @property
    def status(self) -> AccountStatus:
        return AccountStatus(self._raw["status"])

    @property
    def created_at(self) -> datetime:
        return datetime.fromisoformat(self._raw["created_at"])

    @classmethod
    def create(cls, *, channel: str, account_id: str, ssm_creds_ref: str,
               table_name: str | None = None) -> "Account":
        state = State(table_name=table_name) if table_name else State()
        now = datetime.now(timezone.utc).isoformat()
        raw = {
            "channel": channel,
            "account_id": account_id,
            "status": AccountStatus.WARMING.value,
            "created_at": now,
            "ssm_creds_ref": ssm_creds_ref,
            "warmup_target_days": WARMUP_DAYS.get(channel, 30),
            "post_count": 0,
            "reply_count": 0,
        }
        state.put(f"account#{channel}:{account_id}", "metadata", raw)
        return cls(channel=channel, account_id=account_id, _raw=raw, _state=state)

    @classmethod
    def load(cls, *, channel: str, account_id: str,
             table_name: str | None = None) -> "Account | None":
        state = State(table_name=table_name) if table_name else State()
        raw = state.get(f"account#{channel}:{account_id}", "metadata")
        if raw is None:
            return None
        return cls(channel=channel, account_id=account_id, _raw=raw, _state=state)

    def _save(self) -> None:
        self._state.put(f"account#{self.channel}:{self.account_id}", "metadata", self._raw)

    def _set_status(self, new_status: AccountStatus, allowed_from: set[AccountStatus]) -> None:
        if self.status not in allowed_from:
            raise InvalidTransition(f"cannot transition {self.status.value} -> {new_status.value}")
        self._raw["status"] = new_status.value
        self._save()

    def promote_if_warmup_complete(self, karma: int) -> bool:
        """Promote warming -> active if age + karma thresholds met. Returns True if promoted."""
        if self.status != AccountStatus.WARMING:
            return False
        age = datetime.now(timezone.utc) - self.created_at
        target_days = int(self._raw.get("warmup_target_days", WARMUP_DAYS.get(self.channel, 30)))
        if age < timedelta(days=target_days):
            return False
        if karma < KARMA_THRESHOLD.get(self.channel, 0):
            return False
        self._raw["status"] = AccountStatus.ACTIVE.value
        self._save()
        return True

    def mark_active(self) -> None:
        """Direct promotion to active — only valid from DEGRADED (recovery)."""
        self._set_status(AccountStatus.ACTIVE, {AccountStatus.DEGRADED})

    def mark_degraded(self, reason: str) -> None:
        self._raw["degraded_reason"] = reason
        self._set_status(AccountStatus.DEGRADED, {AccountStatus.ACTIVE})

    def mark_flagged(self, reason: str) -> None:
        self._raw["flagged_reason"] = reason
        if self.status == AccountStatus.RETIRED:
            raise InvalidTransition("cannot flag a retired account")
        self._raw["status"] = AccountStatus.FLAGGED.value
        self._save()

    def mark_retired(self) -> None:
        self._set_status(
            AccountStatus.RETIRED,
            {AccountStatus.FLAGGED, AccountStatus.DEGRADED, AccountStatus.ACTIVE},
        )

    def can_post(self) -> bool:
        return self.status == AccountStatus.ACTIVE

    def can_warmup(self) -> bool:
        return self.status == AccountStatus.WARMING
