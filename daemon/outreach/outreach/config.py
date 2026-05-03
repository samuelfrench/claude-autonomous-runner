# daemon/outreach/outreach/config.py
"""Centralized configuration constants for the outreach daemon.

All values must be uppercase module-level constants. Avoid environment-variable
reads here — those belong in the entry-point scripts so tests stay deterministic.
"""

# AWS
AWS_REGION = "us-east-1"

# DynamoDB
DDB_TABLE = "clawd-bot-outreach"
DDB_TABLE_DRYRUN = "clawd-bot-outreach-dryrun"

# S3
S3_INBOUND_BUCKET = "clawd-bot-outreach-mail"

# SSM Parameter Store
SSM_PREFIX = "/clawd-bot/outreach/"
SSM_MODEL_POLICY = "/clawd-bot/outreach/model-policy"

# Email
DOMAIN = "example.com"
EMAIL_FROM = f"hello@{DOMAIN}"
EMAIL_REPLY_TO = f"replies@{DOMAIN}"
EMAIL_SIGNUPS = f"signups@{DOMAIN}"

# Alerts (SES → admin)
ALERT_EMAIL = "admin@example.com"

# Rate-limit caps (Moderate cadence per spec)
RATE_LIMITS: dict[str, dict[str, int]] = {
    "reddit": {"submit": 2, "reply": 15},
    "x":      {"post": 8, "reply": 30},
    "email":  {"cold": 15, "reply": 9999},
}

# Cold-pitch deduplication window. A cold send to a recipient pitched
# within this many days raises RecentSendError before any SES call.
# Without this safety net, an LLM planner with no memory across ticks
# will pitch the same recipient twice within minutes. 30 days matches
# typical cold-outreach norms — long enough that a re-pitch isn't
# perceived as spam, short enough that genuine "we never replied, try
# a different angle" follow-ups can still happen via the reply lane
# (which bypasses this check, like DNC).
RECENT_COLD_SEND_WINDOW_DAYS = 30

# Account warm-up targets (days)
WARMUP_DAYS: dict[str, int] = {
    "reddit": 30,
    "x": 14,
    "email": 0,
}

# Failure thresholds
TICK_FAILURE_HALT = 5
AUTH_FAILURE_HALT = 3
LOOP_DETECT_TICKS = 5

# Tool-build promotion
TOOL_PROMOTE_AFTER_RUNS = 5
