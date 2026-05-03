#!/bin/bash
# daemon/outreach-runner.sh
# Single-tick wrapper. Designed to be invoked by systemd timer (or cron) every N min.
# Exit codes:
#   0 = success
#   1 = transient failure (will retry)
#   2 = halt-trigger (admin must reset counter file)
#
# Required env (refuse to start if missing):
#   FROM_EMAIL    — verified SES sender for outbound mail (e.g. hello@your-domain.com)
#   ALERT_EMAIL   — recipient for halt/error alerts
#   MANDATE_FILE  — path to the system prompt that drives the bot's per-tick reasoning
#                   (see daemon/outreach-mandate.example.md for a template)

set -uo pipefail
# Note: deliberately NOT using -e so we can capture failures explicitly

# Put the outreach venv's bin first on PATH so `claude -p` (and any subprocess
# it spawns) can invoke the `outreach` CLI without needing to activate the venv.
OUTREACH_VENV="${OUTREACH_VENV:-$HOME/outreach-venv}"
if [ -d "$OUTREACH_VENV/bin" ]; then
  export PATH="$OUTREACH_VENV/bin:$PATH"
fi

REGION="${AWS_REGION:-us-east-1}"
: "${FROM_EMAIL:?Set FROM_EMAIL (verified SES sender)}"
: "${ALERT_EMAIL:?Set ALERT_EMAIL (alert recipient)}"
WORKDIR="${OUTREACH_WORKDIR:-$HOME/outreach-runner-workdir}"
MANDATE_FILE="${MANDATE_FILE:-$WORKDIR/outreach-mandate.md}"
FAILURE_COUNTER="${FAILURE_COUNTER:-/tmp/outreach-runner-failures}"
AUTH_FAILURE_COUNTER="${AUTH_FAILURE_COUNTER:-/tmp/outreach-runner-auth-failures}"
TICK_TIMEOUT_SEC=${TICK_TIMEOUT_SEC:-1200}  # 20 min

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

send_alert() {
  local subject=$1
  local body=$2
  aws ses send-email \
    --from "$FROM_EMAIL" \
    --destination "{\"ToAddresses\":[\"$ALERT_EMAIL\"]}" \
    --message "$(jq -n --arg s "$subject" --arg b "$body" \
        '{Subject:{Data:$s}, Body:{Text:{Data:$b}}}')" \
    --region "$REGION" 2>/dev/null || log "WARN: alert send failed"
}

# 1. Check for global halt
if [ -f "$FAILURE_COUNTER" ]; then
  COUNT=$(cat "$FAILURE_COUNTER")
  if [ "$COUNT" -ge 5 ]; then
    log "HALT: $COUNT consecutive failures. Reset $FAILURE_COUNTER to resume."
    exit 2
  fi
fi
if [ -f "$AUTH_FAILURE_COUNTER" ]; then
  COUNT=$(cat "$AUTH_FAILURE_COUNTER")
  if [ "$COUNT" -ge 3 ]; then
    log "HALT: $COUNT consecutive auth failures. Reset $AUTH_FAILURE_COUNTER to resume."
    exit 2
  fi
fi

# 2. Read model policy from SSM. Each policy controls the OUTER `claude -p`
# invocation for the tick; the mandate governs INNER per-action escalation
# (e.g. "shell out to opus-max for replies, stay on sonnet for routine work").
MODEL_POLICY=$(aws ssm get-parameter --name "/clawd-bot/outreach/model-policy" \
  --query 'Parameter.Value' --output text --region "$REGION" 2>/dev/null || echo "opus-always")

case "$MODEL_POLICY" in
  paused)
    log "Policy=paused. Skipping tick."
    exit 0
    ;;
  opus-always)
    # Outer reasoning + every action runs on opus-4.7 max. Highest quality,
    # highest cost. Default for production until cost becomes a concern.
    MODEL="claude-opus-4-7"; EFFORT="max"
    ;;
  opus-for-high-stakes)
    # Outer reasoning runs on sonnet-medium (cheap). Bot escalates per-action
    # to opus via mandate hard rule (replies, strategy reviews, tool builds
    # shell out). Routine actions stay on sonnet.
    MODEL="claude-sonnet-4-6"; EFFORT="medium"
    ;;
  sonnet-only)
    # Outer reasoning + every action on sonnet-medium. Cheapest mode; the
    # bot does NOT escalate even for high-stakes actions. Use only as a
    # short-term cost-control measure.
    MODEL="claude-sonnet-4-6"; EFFORT="medium"
    ;;
  *)
    # Unknown / typo'd policy. Fail safe by running sonnet-medium and
    # logging a loud warning so misconfig is visible.
    log "WARN: unrecognized model-policy '$MODEL_POLICY' — defaulting to sonnet-medium. Valid: paused / opus-always / opus-for-high-stakes / sonnet-only"
    MODEL="claude-sonnet-4-6"; EFFORT="medium"
    ;;
esac
log "Policy=$MODEL_POLICY  Model=$MODEL  Effort=$EFFORT"

# 2b. Bounce-rate guard. SES auto-suspends accounts at >5% bounce rate.
# Halt at 3% to leave a safety margin while diagnosing. The halt
# self-clears once the cooldown elapses AND no fresh suppressions
# remain in the rolling window. Admin can `rm` the sentinel early to
# resume sooner.
BOUNCE_HALT_FILE="${BOUNCE_HALT_FILE:-/tmp/outreach-bounce-halt}"
BOUNCE_RATE_THRESHOLD_PCT="${BOUNCE_RATE_THRESHOLD_PCT:-3}"
BOUNCE_MIN_SENDS="${BOUNCE_MIN_SENDS:-10}"  # don't enforce below sample size
HALT_COOLDOWN_SEC="${HALT_COOLDOWN_SEC:-86400}"  # 24h — aligned with rolling window

if [ -f "$BOUNCE_HALT_FILE" ]; then
  HALT_AGE_SEC=$(($(date +%s) - $(stat -c %Y "$BOUNCE_HALT_FILE")))
  if [ "$HALT_AGE_SEC" -lt "$HALT_COOLDOWN_SEC" ]; then
    log "HALT: bounce-halt set $((HALT_AGE_SEC/3600))h ago, cooldown $((HALT_COOLDOWN_SEC/3600))h. Remove $BOUNCE_HALT_FILE to resume early."
    exit 2
  fi
  COOLDOWN_AGO_ISO=$(date -u -d "${HALT_COOLDOWN_SEC} seconds ago" +%Y-%m-%dT%H:%M:%S)
  FRESH_SUPPRESSED=$(aws sesv2 list-suppressed-destinations \
    --start-date "$COOLDOWN_AGO_ISO" --region "$REGION" \
    --query 'SuppressedDestinationSummaries | length(@)' \
    --output text 2>/dev/null || echo 0)
  if [ "$FRESH_SUPPRESSED" = "0" ]; then
    log "Bounce-halt cooldown elapsed ($((HALT_AGE_SEC/3600))h) and 0 fresh SES suppressions. Auto-clearing."
    rm -f "$BOUNCE_HALT_FILE"
    send_alert "outreach-runner resumed: bounce-halt auto-cleared" \
      "$((HALT_AGE_SEC/3600))h cooldown elapsed; 0 SES suppressions in window since ${COOLDOWN_AGO_ISO}. Outreach resumes."
  else
    log "HALT: cooldown elapsed but ${FRESH_SUPPRESSED} fresh suppressions still in window. Re-arming halt."
    touch "$BOUNCE_HALT_FILE"
    exit 2
  fi
fi

ONE_DAY_AGO_ISO=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%S)
SENT_24H=$(aws dynamodb query --table-name clawd-bot-outreach --region "$REGION" \
  --key-condition-expression "pk = :pk AND sk >= :sk" \
  --filter-expression "#k = :ki AND #s = :se" \
  --expression-attribute-names '{"#k":"kind","#s":"status"}' \
  --expression-attribute-values "{\":pk\":{\"S\":\"post#email\"},\":sk\":{\"S\":\"$ONE_DAY_AGO_ISO\"},\":ki\":{\"S\":\"cold\"},\":se\":{\"S\":\"sent\"}}" \
  --select COUNT --query 'Count' --output text 2>/dev/null || echo 0)

# SES-side ground truth: bounces + complaints land in the suppression list.
SUPPRESSED_24H=$(aws sesv2 list-suppressed-destinations \
  --start-date "$ONE_DAY_AGO_ISO" --region "$REGION" \
  --query 'SuppressedDestinationSummaries | length(@)' \
  --output text 2>/dev/null || echo 0)

if [ "$SENT_24H" -ge "$BOUNCE_MIN_SENDS" ]; then
  BOUNCE_PCT=$(( SUPPRESSED_24H * 100 / SENT_24H ))
  log "Bounce-rate check: ${SUPPRESSED_24H} suppressed / ${SENT_24H} cold sends = ${BOUNCE_PCT}% (threshold ${BOUNCE_RATE_THRESHOLD_PCT}%)"
  if [ "$BOUNCE_PCT" -ge "$BOUNCE_RATE_THRESHOLD_PCT" ]; then
    log "HALT: bounce-rate ${BOUNCE_PCT}% >= ${BOUNCE_RATE_THRESHOLD_PCT}% threshold"
    send_alert "outreach-runner halted: bounce-rate ${BOUNCE_PCT}%" \
      "Last-24h: ${SUPPRESSED_24H} suppressed / ${SENT_24H} cold sends = ${BOUNCE_PCT}%. SES suspends at 5%; halting at 3% margin to protect sender reputation. Diagnose with: aws sesv2 list-suppressed-destinations --start-date ${ONE_DAY_AGO_ISO} --region ${REGION}. Auto-clears in $((HALT_COOLDOWN_SEC/3600))h if window recovers; remove ${BOUNCE_HALT_FILE} to resume earlier."
    touch "$BOUNCE_HALT_FILE"
    exit 2
  fi
else
  log "Bounce-rate check: only ${SENT_24H} cold sends in last 24h (need ${BOUNCE_MIN_SENDS} for enforcement) — skipping"
fi

# 3. (Optional) refresh a context repo here if your bot needs read-only
# access to recently shipped content for outreach angle-tying:
#
#   if [ -n "${OUTREACH_CONTEXT_REPO:-}" ]; then
#     CONTEXT_DIR="$WORKDIR/$(basename "$OUTREACH_CONTEXT_REPO" .git)"
#     if [ ! -d "$CONTEXT_DIR" ]; then
#       git clone --depth 50 "$OUTREACH_CONTEXT_REPO" "$CONTEXT_DIR" || true
#     else
#       (cd "$CONTEXT_DIR" && git fetch --depth 50 origin main >/dev/null 2>&1 \
#         && git reset --hard origin/main >/dev/null 2>&1) || true
#     fi
#   fi

# 4. Generate tick id
TICK_ID="tick-$(date -u +%Y%m%d-%H%M%S)"
log "Starting tick $TICK_ID"

# 5. Invoke claude -p. Mirror clawd-runner's pattern: prompt right after -p so
# it isn't consumed as a value to a variadic flag like --tools.
PROMPT="Read your state from DynamoDB (use \`outreach state\` and \`outreach email inbox\` CLIs). Pick the single highest-leverage outreach action right now per the mandate's action priority. Execute it. Persist the outcome to DynamoDB and log your reasoning to decision-log. Tick id: $TICK_ID."

cd "$WORKDIR"
timeout "$TICK_TIMEOUT_SEC" claude -p "$PROMPT" \
  --dangerously-skip-permissions \
  --model "$MODEL" \
  --effort "$EFFORT" \
  --append-system-prompt "$(cat "$MANDATE_FILE")"
EXIT=$?

# 6. Handle exit
case $EXIT in
  0)
    log "Tick $TICK_ID succeeded"
    rm -f "$FAILURE_COUNTER" "$AUTH_FAILURE_COUNTER"
    exit 0
    ;;
  124)  # timeout
    log "Tick $TICK_ID timed out"
    PREV=$(cat "$FAILURE_COUNTER" 2>/dev/null || echo 0)
    echo $((PREV + 1)) > "$FAILURE_COUNTER"
    exit 1
    ;;
  *)
    log "Tick $TICK_ID failed exit=$EXIT"
    PREV=$(cat "$FAILURE_COUNTER" 2>/dev/null || echo 0)
    echo $((PREV + 1)) > "$FAILURE_COUNTER"
    NEW=$((PREV + 1))
    if [ "$NEW" -ge 5 ]; then
      send_alert "outreach-runner halted: 5 consecutive failures" \
        "Tick $TICK_ID was the 5th consecutive failure. Diagnose, then \`rm $FAILURE_COUNTER\` to resume."
    fi
    exit 1
    ;;
esac
