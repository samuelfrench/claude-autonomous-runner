# infrastructure/lambda/outreach-kpi-sanity/lambda_function.py
"""KPI sanity Lambda — runs hourly via EventBridge.

Reads recent KPI snapshots, alerts on:
- Reply rate drops >50% week-over-week
- Engagement rate < expected_min for 6h
- Account karma slope negative for 24h

Phase 0+1 implements the email-based KPI sanity. Reddit/X KPI sanity
is added in their respective phase plans.
"""
import json
import logging
import os
from datetime import datetime, timezone, timedelta
from decimal import Decimal

import boto3

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

DDB_TABLE = os.environ.get("DDB_TABLE", "clawd-bot-outreach")
ALERT_EMAIL = os.environ.get("ALERT_EMAIL", "admin@example.com")
FROM_EMAIL = os.environ.get("FROM_EMAIL", "hello@example.com")
REGION = os.environ.get("AWS_REGION", "us-east-1")

ddb = boto3.resource("dynamodb", region_name=REGION)
ses = boto3.client("ses", region_name=REGION)
table = ddb.Table(DDB_TABLE)


def get_kpi_for_date(date_str: str) -> dict | None:
    resp = table.get_item(Key={"pk": "kpi", "sk": date_str})
    return resp.get("Item")


def alert(subject: str, body: str) -> None:
    LOG.warning(f"ALERTING: {subject}")
    try:
        ses.send_email(
            Source=FROM_EMAIL,
            Destination={"ToAddresses": [ALERT_EMAIL]},
            Message={
                "Subject": {"Data": f"[clawd-bot-outreach] {subject}"},
                "Body": {"Text": {"Data": body}},
            },
        )
    except Exception as e:
        LOG.error(f"Alert send failed: {e}")


def lambda_handler(event, context):
    today = datetime.now(timezone.utc).date()
    today_str = today.isoformat()
    week_ago_str = (today - timedelta(days=7)).isoformat()

    today_kpi = get_kpi_for_date(today_str)
    week_ago_kpi = get_kpi_for_date(week_ago_str)

    LOG.info(f"today: {today_kpi}")
    LOG.info(f"week_ago: {week_ago_kpi}")

    if today_kpi is None:
        LOG.info("No KPI for today yet (bot may not have run snapshot)")
        return {"ok": True, "alerted": False}

    alerts_fired = []

    # Reply-rate week-over-week
    today_rate = float(today_kpi.get("reply_rate_today", 0) or 0)
    if week_ago_kpi:
        week_ago_rate = float(week_ago_kpi.get("reply_rate_today", 0) or 0)
        if week_ago_rate > 0.05 and today_rate < (week_ago_rate * 0.5):
            alert(
                "Reply rate dropped >50% WoW",
                f"Today: {today_rate:.2%}\nWeek ago: {week_ago_rate:.2%}\n\n"
                f"Investigate cold-pitch quality or list saturation."
            )
            alerts_fired.append("reply-rate-drop")

    return {"ok": True, "alerted": bool(alerts_fired), "alerts": alerts_fired}
