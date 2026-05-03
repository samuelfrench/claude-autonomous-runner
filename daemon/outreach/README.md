# outreach

Python toolkit for the outreach automation daemon.

A self-contained skeleton for running reputation-safe cold-pitch + reply
loops at low volume (~15 cold sends/day). Designed for autonomous LLM
operation — every send goes through a multi-layer verifier so the bot
can't accidentally pitch hallucinated addresses, and a SES inbound
Lambda parses bounce DSNs + STOP replies into a single
`do-not-contact` source of truth.

## What it gives you

- **`state.py`** — single-table DynamoDB wrapper (pk/sk + status GSI).
- **`rate_limit.py`** — per-channel sliding-window (UTC day) limiter.
- **`account.py`** — account state machine (warming → active →
  degraded → flagged → retired) with karma + age gating.
- **`email_send.py`** — SES outbound with cold + reply lanes; gated by
  pre-send verifier, do-not-contact list, and a 30-day cold-pitch
  dedup window.
- **`email_inbox.py`** — inbound triage from `inbound#email` rows
  written by the SES → S3 → Lambda parser.
- **`address_verify.py`** — multi-layer pre-send check: syntax → DDB
  do-not-contact → SES suppression → MX → outlet-page substring →
  optional Hunter.io.
- **`decision_log.py`** — per-tick reasoning log + loop detection.
- **`tools_registry.py`** — lifecycle for self-built tools
  (experimental → stable → quarantined).
- **`kpi.py`** — daily KPI snapshot.
- **`cli.py`** — `outreach` CLI: `state`, `email send / verify / inbox`,
  `kpi`.

## What it does NOT give you

- A targeting list — you bring your own (see `outreach-mandate.example.md`).
- Campaign content — the mandate file drives that, the toolkit just
  ships sends.
- Inbox triage policy beyond the priority hint heuristic — your
  mandate decides what to do with each class.

## Local development

    cd daemon/outreach
    python -m venv .venv
    source .venv/bin/activate
    pip install -e ".[dev]"
    pytest

The tests use moto to fake DynamoDB / SES / S3 / SSM, so no AWS account
is required to run them.

## CLI usage (after install)

    outreach state get <pk> <sk>
    outreach email verify <addr> --source-url <url>
    outreach email send --to <addr> --subject <s> --body <b> --source-url <url>
    outreach email inbox next-priority
    outreach kpi snapshot
    outreach --help

## Wiring

The toolkit assumes:

- DynamoDB table from `infrastructure/outreach-dynamodb-schema.json`.
- IAM role with `infrastructure/outreach-iam-policy.json` (replace
  `<AWS_ACCOUNT_ID>` and `example.com` with your own).
- Lambda from `infrastructure/lambda/outreach-mail-parser/` triggered
  on S3 PUT under the `raw/` prefix.
- SES domain identity verified for the domain you set in
  `outreach.config.DOMAIN`.
