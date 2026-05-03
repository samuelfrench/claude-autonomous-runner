# daemon/outreach/outreach/state.py
"""DynamoDB single-table wrapper for the outreach daemon.

Encapsulates the (pk, sk) composite-key access pattern. All writes preserve
the `pk` and `sk` attributes plus a `status` attribute (for GSI use). Numeric
counters use atomic ADD.
"""
from __future__ import annotations

from typing import Any, Iterator

import boto3

from outreach.config import AWS_REGION, DDB_TABLE


class State:
    """Thin DynamoDB single-table wrapper."""

    def __init__(self, table_name: str = DDB_TABLE, region: str = AWS_REGION):
        self._ddb = boto3.resource("dynamodb", region_name=region)
        self._table = self._ddb.Table(table_name)
        self._table_name = table_name

    def put(self, pk: str, sk: str, attrs: dict[str, Any]) -> None:
        """Put an item. Always sets pk + sk; status is hoisted if present."""
        item: dict[str, Any] = {"pk": pk, "sk": sk, **attrs}
        self._table.put_item(Item=item)

    def get(self, pk: str, sk: str) -> dict[str, Any] | None:
        resp = self._table.get_item(Key={"pk": pk, "sk": sk})
        return resp.get("Item")

    def delete(self, pk: str, sk: str) -> None:
        self._table.delete_item(Key={"pk": pk, "sk": sk})

    def update(self, pk: str, sk: str, attrs: dict[str, Any]) -> None:
        """SET multiple attributes. Reserved-keyword-safe."""
        if not attrs:
            return
        names = {f"#k{i}": k for i, k in enumerate(attrs.keys())}
        values = {f":v{i}": v for i, v in enumerate(attrs.values())}
        expr = "SET " + ", ".join(f"{n} = {v}" for n, v in zip(names.keys(), values.keys()))
        self._table.update_item(
            Key={"pk": pk, "sk": sk},
            UpdateExpression=expr,
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
        )

    def increment(self, pk: str, sk: str, attr: str, by: int = 1) -> int:
        """Atomic ADD. Creates the item if missing. Returns new value."""
        resp = self._table.update_item(
            Key={"pk": pk, "sk": sk},
            UpdateExpression="ADD #a :n",
            ExpressionAttributeNames={"#a": attr},
            ExpressionAttributeValues={":n": by},
            ReturnValues="UPDATED_NEW",
        )
        return int(resp["Attributes"][attr])

    def query_pk(self, pk: str, sk_begins_with: str | None = None) -> Iterator[dict[str, Any]]:
        """Yield all items with given pk, optionally filtered by sk prefix."""
        kwargs: dict[str, Any] = {
            "KeyConditionExpression": "pk = :pk",
            "ExpressionAttributeValues": {":pk": pk},
        }
        if sk_begins_with is not None:
            kwargs["KeyConditionExpression"] += " AND begins_with(sk, :skp)"
            kwargs["ExpressionAttributeValues"][":skp"] = sk_begins_with
        last: dict[str, Any] | None = None
        while True:
            if last is not None:
                kwargs["ExclusiveStartKey"] = last
            resp = self._table.query(**kwargs)
            for item in resp.get("Items", []):
                yield item
            last = resp.get("LastEvaluatedKey")
            if last is None:
                break

    def query_status(self, status: str) -> Iterator[dict[str, Any]]:
        """Yield all items with the given status (via status-index GSI)."""
        kwargs: dict[str, Any] = {
            "IndexName": "status-index",
            "KeyConditionExpression": "#s = :s",
            "ExpressionAttributeNames": {"#s": "status"},
            "ExpressionAttributeValues": {":s": status},
        }
        last: dict[str, Any] | None = None
        while True:
            if last is not None:
                kwargs["ExclusiveStartKey"] = last
            resp = self._table.query(**kwargs)
            for item in resp.get("Items", []):
                yield item
            last = resp.get("LastEvaluatedKey")
            if last is None:
                break
