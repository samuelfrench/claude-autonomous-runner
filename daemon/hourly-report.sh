#!/bin/bash
set -euo pipefail

REGION="us-east-1"
EMAIL="${NOTIFICATION_EMAIL:-your-email@example.com}"
QUEUE_NAME="clawd-bot-tasks"
DLQ_NAME="clawd-bot-tasks-dlq"
CODEX_QUEUE_NAME="clawd-bot-tasks-codex"
LOG_FILE="/tmp/clawd-hourly-report.log"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE"; }

# Queue stats
QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$REGION" --query 'QueueUrl' --output text)
DLQ_URL=$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$REGION" --query 'QueueUrl' --output text)

ATTRS=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --region "$REGION" --output json)
PENDING=$(echo "$ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages')
IN_FLIGHT=$(echo "$ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible')

DLQ_ATTRS=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
    --attribute-names ApproximateNumberOfMessages --region "$REGION" --output json)
DLQ_COUNT=$(echo "$DLQ_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages')

# Codex queue stats
CODEX_QUEUE_URL=$(aws sqs get-queue-url --queue-name "$CODEX_QUEUE_NAME" --region "$REGION" --query 'QueueUrl' --output text 2>/dev/null || echo "")
CODEX_PENDING="n/a"
CODEX_IN_FLIGHT="n/a"
if [ -n "$CODEX_QUEUE_URL" ]; then
    CODEX_ATTRS=$(aws sqs get-queue-attributes --queue-url "$CODEX_QUEUE_URL" \
        --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
        --region "$REGION" --output json 2>/dev/null || echo '{"Attributes":{}}')
    CODEX_PENDING=$(echo "$CODEX_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages // "n/a"')
    CODEX_IN_FLIGHT=$(echo "$CODEX_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // "n/a"')
fi

# Daemon status
DAEMON_STATUS=$(systemctl is-active clawd-runner 2>/dev/null || echo "unknown")
UPTIME=$(systemctl show clawd-runner --property=ActiveEnterTimestamp --value 2>/dev/null || echo "unknown")
CODEX_DAEMON_STATUS=$(systemctl is-active codex-runner 2>/dev/null || echo "not installed")

# Auth status
AUTH_STATUS=$(claude auth status 2>&1 | jq -r '.loggedIn // "unknown"' 2>/dev/null || echo "check failed")

# Last hour of task activity from journal
RECENT_TASKS=$(journalctl -u clawd-runner --since "1 hour ago" --no-pager 2>/dev/null \
    | grep -E "(=== Task:|Claude status:|Pushed commits|No new commits|push FAILED)" \
    || echo "No tasks in the last hour")

# Disk usage
DISK=$(df -h / | tail -1 | awk '{print $3 " used / " $2 " total (" $5 " full)"}')

BODY="Clawd-Bot Hourly Report
$(date -u +%Y-%m-%dT%H:%M:%SZ)
========================================

Claude:    $DAEMON_STATUS (since $UPTIME)
Codex:     $CODEX_DAEMON_STATUS
Auth:      logged_in=$AUTH_STATUS
Claude Q:  $PENDING pending, $IN_FLIGHT in-flight
Codex Q:   $CODEX_PENDING pending, $CODEX_IN_FLIGHT in-flight
DLQ:       $DLQ_COUNT failed
Disk:      $DISK

Recent Activity (last hour):
----------------------------------------
$RECENT_TASKS"

BODY_JSON=$(printf '%s' "$BODY" | jq -Rs .)

aws ses send-email \
    --from "$EMAIL" \
    --destination "{\"ToAddresses\":[\"$EMAIL\"]}" \
    --message "{\"Subject\":{\"Data\":\"[clawd-bot] Hourly Status Report\"},\"Body\":{\"Text\":{\"Data\":${BODY_JSON}}}}" \
    --region "$REGION"

log "Hourly report sent"
