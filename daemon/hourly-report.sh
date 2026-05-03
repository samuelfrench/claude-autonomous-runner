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
AUTH_STATUS=$(/home/ec2-user/.local/bin/claude auth status 2>&1 | jq -r '.loggedIn // "unknown"' 2>/dev/null || echo "check failed")

# Last hour of task activity from journal
RECENT_TASKS=$(journalctl -u clawd-runner --since "1 hour ago" --no-pager 2>/dev/null \
    | grep -E "(=== Task:|Claude status:|Pushed commits|No new commits|push FAILED)" \
    || echo "No tasks in the last hour")

# Disk usage
DISK=$(df -h / | tail -1 | awk '{print $3 " used / " $2 " total (" $5 " full)"}')

# Outreach-runner stats
OUTREACH_FAILURE_COUNT=$(cat /tmp/outreach-runner-failures 2>/dev/null || echo 0)
OUTREACH_AUTH_FAILURE_COUNT=$(cat /tmp/outreach-runner-auth-failures 2>/dev/null || echo 0)
OUTREACH_DAEMON_STATUS=$(systemctl is-active outreach-runner.timer 2>/dev/null || echo "not installed")
OUTREACH_POLICY=$(aws ssm get-parameter --name /clawd-bot/outreach/model-policy --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "n/a")
OUTREACH_LAST_TICK=$(journalctl -u outreach-runner.service --no-pager -n 200 2>/dev/null | grep "Starting tick" | tail -1 | sed 's/.*Starting tick //' || echo "no recent tick")
OUTREACH_TODAY=$(date -u +%Y-%m-%d)
OUTREACH_EMAIL_COLD=$(aws dynamodb get-item --table-name clawd-bot-outreach --region "$REGION" \
    --key "{\"pk\":{\"S\":\"rate-limit#email\"},\"sk\":{\"S\":\"$OUTREACH_TODAY\"}}" \
    --query 'Item.cold.N' --output text 2>/dev/null || echo "0")
OUTREACH_EMAIL_REPLY=$(aws dynamodb get-item --table-name clawd-bot-outreach --region "$REGION" \
    --key "{\"pk\":{\"S\":\"rate-limit#email\"},\"sk\":{\"S\":\"$OUTREACH_TODAY\"}}" \
    --query 'Item.reply.N' --output text 2>/dev/null || echo "0")
[ "$OUTREACH_EMAIL_COLD" = "None" ] && OUTREACH_EMAIL_COLD=0
[ "$OUTREACH_EMAIL_REPLY" = "None" ] && OUTREACH_EMAIL_REPLY=0
OUTREACH_INBOUND_UNPROCESSED=$(aws dynamodb scan --table-name clawd-bot-outreach --region "$REGION" \
    --filter-expression "pk = :pk AND #s = :s" \
    --expression-attribute-names '{"#s":"status"}' \
    --expression-attribute-values "{\":pk\":{\"S\":\"inbound#email\"},\":s\":{\"S\":\"unprocessed\"}}" \
    --query 'Count' --output text 2>/dev/null || echo "0")

# Outreach activity in last hour — sk is "<iso-ts>#<msg-id>" so a sk >= cutoff
# query is enough; no scan needed.
ONE_HOUR_AGO_ISO=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)

OUTBOUND_LAST_HR=$(aws dynamodb query --table-name clawd-bot-outreach --region "$REGION" \
    --key-condition-expression "pk = :pk AND sk >= :sk" \
    --expression-attribute-values "{\":pk\":{\"S\":\"post#email\"},\":sk\":{\"S\":\"$ONE_HOUR_AGO_ISO\"}}" \
    --output json 2>/dev/null || echo '{"Items":[]}')

INBOUND_LAST_HR=$(aws dynamodb query --table-name clawd-bot-outreach --region "$REGION" \
    --key-condition-expression "pk = :pk AND sk >= :sk" \
    --expression-attribute-values "{\":pk\":{\"S\":\"inbound#email\"},\":sk\":{\"S\":\"$ONE_HOUR_AGO_ISO\"}}" \
    --output json 2>/dev/null || echo '{"Items":[]}')

# Cold pitches sent (status=sent, kind=cold) in last hour
COLD_COUNT=$(echo "$OUTBOUND_LAST_HR" | jq '[.Items[] | select(.kind.S == "cold" and .status.S == "sent")] | length')
COLD_LIST=$(echo "$OUTBOUND_LAST_HR" | jq -r '
    [.Items[] | select(.kind.S == "cold" and .status.S == "sent")]
    | if length == 0 then "  (none)"
      else map("  - \(.to.S) — " + (.subject.S)) | join("\n")
      end')

# Replies sent (status=sent, kind=reply) in last hour
REPLY_COUNT=$(echo "$OUTBOUND_LAST_HR" | jq '[.Items[] | select(.kind.S == "reply" and .status.S == "sent")] | length')
REPLY_LIST=$(echo "$OUTBOUND_LAST_HR" | jq -r '
    [.Items[] | select(.kind.S == "reply" and .status.S == "sent")]
    | if length == 0 then "  (none)"
      else map("  - \(.to.S) — " + (.subject.S)) | join("\n")
      end')

# Failed sends in last hour (any kind)
FAIL_COUNT=$(echo "$OUTBOUND_LAST_HR" | jq '[.Items[] | select(.status.S == "failed")] | length')
FAIL_LIST=$(echo "$OUTBOUND_LAST_HR" | jq -r '
    [.Items[] | select(.status.S == "failed")]
    | if length == 0 then ""
      else "\nSend failures (" + (length | tostring) + "):\n" + (map("  - \(.to.S) [\(.kind.S)] — " + ((.error.S // "unknown")[:100])) | join("\n"))
      end')

# Inbound received in last hour (call out bounces + STOP auto-opt-outs separately)
INBOUND_COUNT=$(echo "$INBOUND_LAST_HR" | jq '.Items | length')
BOUNCE_COUNT=$(echo "$INBOUND_LAST_HR" | jq '[.Items[] | select(.from.S | test("MAILER-DAEMON|postmaster@|noreply@"; "i"))] | length')
STOP_COUNT=$(echo "$INBOUND_LAST_HR" | jq '[.Items[] | select(.auto_processed_reason.S == "stop-reply")] | length')
HUMAN_COUNT=$(( INBOUND_COUNT - BOUNCE_COUNT ))
INBOUND_LIST=$(echo "$INBOUND_LAST_HR" | jq -r '
    .Items
    | if length == 0 then "  (none)"
      else map(
        "  - \(.from.S) [\(.priority_hint.S)] — " + (.subject.S)
        + (if .auto_processed_reason then " {auto: \(.auto_processed_reason.S)}" else "" end)
      ) | join("\n")
      end')

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

Outreach Runner:
----------------------------------------
Daemon:           $OUTREACH_DAEMON_STATUS
Model policy:     $OUTREACH_POLICY
Failure counter:  $OUTREACH_FAILURE_COUNT (halts at 5) | auth-fail: $OUTREACH_AUTH_FAILURE_COUNT (halts at 3)
Last tick:        $OUTREACH_LAST_TICK
Email today:      cold=$OUTREACH_EMAIL_COLD/15  reply=$OUTREACH_EMAIL_REPLY
Inbound queue:    $OUTREACH_INBOUND_UNPROCESSED unprocessed

Outreach Activity (last hour):
----------------------------------------
Cold pitches sent ($COLD_COUNT):
$COLD_LIST
Replies sent ($REPLY_COUNT):
$REPLY_LIST
Inbound received ($INBOUND_COUNT total: $HUMAN_COUNT human, $BOUNCE_COUNT bounces, $STOP_COUNT auto-stop):
$INBOUND_LIST$FAIL_LIST

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
