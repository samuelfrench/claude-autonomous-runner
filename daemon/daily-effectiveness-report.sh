#!/bin/bash
set -euo pipefail

REGION="us-east-1"
EMAIL="${NOTIFICATION_EMAIL:-your-email@example.com}"
DYNAMO_TABLE="clawd-bot-tasks"
CREDS_FILE="$HOME/.claude/.credentials.json"
CONFIG_FILE="$HOME/clawd-bot/config/projects.json"
ENV_FILE="$HOME/.clawd-env"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

send_email() {
    local subject=$1
    local body=$2
    local body_json subject_json
    body_json=$(printf '%s' "$body" | jq -Rs .)
    subject_json=$(printf '%s' "$subject" | jq -Rs .)
    aws ses send-email \
        --from "$EMAIL" \
        --destination "{\"ToAddresses\":[\"$EMAIL\"]}" \
        --message "{\"Subject\":{\"Data\":${subject_json}},\"Body\":{\"Text\":{\"Data\":${body_json}}}}" \
        --region "$REGION" 2>/dev/null || log "WARNING: email send failed"
}

# ─── 1. Task stats (last 24h) ───

YESTERDAY=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)

# Query completed tasks
COMPLETED=$(aws dynamodb scan --table-name "$DYNAMO_TABLE" \
    --filter-expression "#s = :s AND completed_at > :t" \
    --expression-attribute-names '{"#s":"status"}' \
    --expression-attribute-values "{\":s\":{\"S\":\"completed\"},\":t\":{\"S\":\"$YESTERDAY\"}}" \
    --select COUNT --region "$REGION" --output json 2>/dev/null | jq -r '.Count // 0') || COMPLETED=0
COMPLETED=${COMPLETED:-0}

FAILED=$(aws dynamodb scan --table-name "$DYNAMO_TABLE" \
    --filter-expression "#s = :s AND completed_at > :t" \
    --expression-attribute-names '{"#s":"status"}' \
    --expression-attribute-values "{\":s\":{\"S\":\"failed\"},\":t\":{\"S\":\"$YESTERDAY\"}}" \
    --select COUNT --region "$REGION" --output json 2>/dev/null | jq -r '.Count // 0') || FAILED=0
FAILED=${FAILED:-0}

TOTAL=$((COMPLETED + FAILED))
if [ "$TOTAL" -gt 0 ]; then
    SUCCESS_RATE=$((COMPLETED * 100 / TOTAL))
else
    SUCCESS_RATE="n/a"
fi

# Count commits pushed (last 24h)
PUSHED=$(aws dynamodb scan --table-name "$DYNAMO_TABLE" \
    --filter-expression "git_status = :g AND completed_at > :t" \
    --expression-attribute-values "{\":g\":{\"S\":\"pushed\"},\":t\":{\"S\":\"$YESTERDAY\"}}" \
    --select COUNT --region "$REGION" --output json 2>/dev/null | jq -r '.Count // 0') || PUSHED=0
PUSHED=${PUSHED:-0}

# ─── 2. Auth health ───

AUTH_SECTION="Unknown"
if [ -f "$CREDS_FILE" ]; then
    EXPIRES_MS=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CREDS_FILE" 2>/dev/null)
    NOW_S=$(date +%s)
    EXPIRES_S=$((EXPIRES_MS / 1000))
    REMAINING_H=$(( (EXPIRES_S - NOW_S) / 3600 ))
    HAS_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS_FILE" 2>/dev/null)
    SUB_TYPE=$(jq -r '.claudeAiOauth.subscriptionType // "unknown"' "$CREDS_FILE" 2>/dev/null)

    if [ -z "$HAS_TOKEN" ]; then
        AUTH_SECTION="BROKEN — no access token in credentials file"
    elif [ "$REMAINING_H" -le 0 ]; then
        AUTH_SECTION="EXPIRED — token expired ${REMAINING_H#-}h ago (plan: $SUB_TYPE)"
    elif [ "$REMAINING_H" -le 2 ]; then
        AUTH_SECTION="EXPIRING SOON — ${REMAINING_H}h remaining (plan: $SUB_TYPE)"
    else
        AUTH_SECTION="OK — ${REMAINING_H}h remaining (plan: $SUB_TYPE)"
    fi
else
    AUTH_SECTION="MISSING — no credentials file found"
fi

# ─── 3. Failure analysis (last 24h) ───

FAILURE_DETAILS=""
SUGGESTIONS=""

if [ "$FAILED" -gt 0 ]; then
    # Get recent failed task outputs
    FAILED_TASKS=$(aws dynamodb scan --table-name "$DYNAMO_TABLE" \
        --filter-expression "#s = :s AND completed_at > :t" \
        --expression-attribute-names '{"#s":"status","#o":"output"}' \
        --expression-attribute-values "{\":s\":{\"S\":\"failed\"},\":t\":{\"S\":\"$YESTERDAY\"}}" \
        --projection-expression "task_id, #o, exit_code, project, completed_at" \
        --region "$REGION" --output json 2>/dev/null) || FAILED_TASKS='{"Items":[]}'

    FAILURE_DETAILS=$(echo "$FAILED_TASKS" | jq -r '
        .Items[] |
        "  - \(.task_id.S) (\(.project.S // "?")) exit=\(.exit_code.N // "?")\n    \(.output.S // "no output" | .[0:200] | gsub("\n"; " "))"
    ' 2>/dev/null | head -c 3000)

    # Pattern matching on failure outputs
    ALL_OUTPUT=$(echo "$FAILED_TASKS" | jq -r '.Items[].output.S // ""' 2>/dev/null)

    if echo "$ALL_OUTPUT" | grep -qi "auth\|credential\|token\|login\|unauthorized\|401"; then
        SUGGESTIONS="${SUGGESTIONS}
  * AUTH: Token may be expiring faster than the 4h sync interval.
    ACTION: Re-authenticate Claude on your local machine (claude login).
    The cron sync will push it to EC2 within 4 hours, or run:
    ~/clawd-bot/infrastructure/sync-auth.sh"
    fi

    if echo "$ALL_OUTPUT" | grep -qi "fal\|FAL_KEY\|image.*generat\|fal\.ai"; then
        SUGGESTIONS="${SUGGESTIONS}
  * FAL.AI: Image generation may be failing.
    ACTION: Verify FAL_KEY is valid: ssh ec2 'source ~/.clawd-env && echo \$FAL_KEY'
    If expired, get a new key from https://fal.ai/dashboard/keys and update ~/.clawd-env"
    fi

    if echo "$ALL_OUTPUT" | grep -qi "rate.limit\|429\|too many\|overloaded"; then
        SUGGESTIONS="${SUGGESTIONS}
  * RATE LIMIT: Claude API rate limits hit.
    ACTION: Increase cooldown_minutes in config/projects.json, or reduce effort level."
    fi

    if echo "$ALL_OUTPUT" | grep -qi "disk\|space\|ENOSPC\|no space"; then
        SUGGESTIONS="${SUGGESTIONS}
  * DISK: Running low on disk space.
    ACTION: SSH to EC2 and clean up: docker system prune, rm old logs."
    fi

    if echo "$ALL_OUTPUT" | grep -qi "permission\|EPERM\|EACCES\|forbidden\|403"; then
        SUGGESTIONS="${SUGGESTIONS}
  * PERMISSIONS: Permission errors detected.
    ACTION: Check file/repo permissions on EC2. May need git credential or SSH key refresh."
    fi
fi

# ─── 4. Environment check ───

ENV_ISSUES=""

# Check FAL_KEY
if [ -f "$ENV_FILE" ]; then
    if ! grep -q 'FAL_KEY=' "$ENV_FILE" 2>/dev/null; then
        ENV_ISSUES="${ENV_ISSUES}
  * FAL_KEY not set in ~/.clawd-env — image generation will fail.
    Get one at https://fal.ai/dashboard/keys"
    fi
else
    ENV_ISSUES="${ENV_ISSUES}
  * ~/.clawd-env file missing — no environment secrets configured.
    Create it with: echo 'FAL_KEY=your_key' > ~/.clawd-env && chmod 600 ~/.clawd-env"
fi

# Check for common useful API keys that could enhance the bot
MISSING_KEYS=""

# Check if any project goal mentions things that need API keys
ALL_GOALS=$(jq -r '.[].autonomous.goal // empty' "$CONFIG_FILE" 2>/dev/null)

if echo "$ALL_GOALS" | grep -qi "image\|visual\|photo\|illustration"; then
    if [ -f "$ENV_FILE" ] && ! grep -q 'FAL_KEY=' "$ENV_FILE" 2>/dev/null; then
        MISSING_KEYS="${MISSING_KEYS}
  * FAL_KEY — needed for AI image generation (fal.ai). Get one at https://fal.ai/dashboard/keys"
    fi
fi

# ─── 5. Autonomous loop health ───

AUTO_SECTION=""
for project in $(jq -r 'to_entries[] | select(.value.autonomous.enabled == true) | .key' "$CONFIG_FILE" 2>/dev/null); do
    FAIL_FILE="/tmp/clawd-auto-failures-${project}"
    FAIL_COUNT=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
    COOLDOWN=$(jq -r ".[\"$project\"].autonomous.cooldown_minutes // 10" "$CONFIG_FILE")
    EFFORT=$(jq -r ".[\"$project\"].autonomous.effort // \"medium\"" "$CONFIG_FILE")

    if [ "$FAIL_COUNT" -ge 5 ]; then
        AUTO_SECTION="${AUTO_SECTION}
  ${project}: HALTED ($FAIL_COUNT consecutive failures)
    ACTION: Fix the issue, then: rm $FAIL_FILE"
    elif [ "$FAIL_COUNT" -gt 0 ]; then
        AUTO_SECTION="${AUTO_SECTION}
  ${project}: DEGRADED ($FAIL_COUNT failures, backing off)
    cooldown=${COOLDOWN}m, effort=${EFFORT}"
    else
        AUTO_SECTION="${AUTO_SECTION}
  ${project}: HEALTHY (cooldown=${COOLDOWN}m, effort=${EFFORT})"
    fi
done

# ─── 6. Zombie task check ───

ZOMBIE_COUNT=$(aws dynamodb scan --table-name "$DYNAMO_TABLE" \
    --filter-expression "#s IN (:r, :p)" \
    --expression-attribute-names '{"#s":"status"}' \
    --expression-attribute-values '{":r":{"S":"running"},":p":{"S":"pending"}}' \
    --select COUNT --region "$REGION" --output json 2>/dev/null | jq -r '.Count // 0') || ZOMBIE_COUNT=0
ZOMBIE_COUNT=${ZOMBIE_COUNT:-0}

ZOMBIE_SECTION=""
if [ "$ZOMBIE_COUNT" -gt 0 ]; then
    ZOMBIE_SECTION="
WARNING: $ZOMBIE_COUNT zombie tasks stuck in pending/running state.
  ACTION: Clean up via: aws dynamodb scan + update-item to mark as failed."
fi

# ─── 7. Disk usage ───

DISK=$(df -h / | tail -1 | awk '{print $3 " / " $2 " (" $5 ")"}')

# ─── 8. What would help ───

HELP_SECTION=""

# Always include auth sync health
SYNC_LOG="/tmp/clawd-sync-auth.log"
LAST_SYNC=$(tail -1 "$SYNC_LOG" 2>/dev/null || echo "no sync log found")
HELP_SECTION="${HELP_SECTION}
  Auth sync: $LAST_SYNC"

# Suggest things based on current state
if [ "$FAILED" -gt "$COMPLETED" ] && [ "$TOTAL" -gt 0 ]; then
    HELP_SECTION="${HELP_SECTION}
  * More tasks are failing than succeeding. Consider:
    - Checking recent failure emails for patterns
    - Adjusting the autonomous goal to be more specific
    - Reducing effort level if hitting rate limits"
fi

if [ "$TOTAL" -eq 0 ]; then
    HELP_SECTION="${HELP_SECTION}
  * No tasks ran in the last 24h. The bot may be stuck.
    - Check: sudo systemctl status clawd-runner
    - Check SQS queue for pending messages
    - Check auth token validity"
fi

# ─── Build email ───

SUBJECT="[clawd-bot] Daily Effectiveness Report — $(date -u +%Y-%m-%d)"

BODY="Clawd-Bot Daily Effectiveness Report
$(date -u +%Y-%m-%dT%H:%M:%SZ)
========================================

LAST 24 HOURS
  Tasks completed: $COMPLETED
  Tasks failed:    $FAILED
  Success rate:    ${SUCCESS_RATE}%
  Commits pushed:  $PUSHED
  Disk:            $DISK

AUTH STATUS
  $AUTH_SECTION

AUTONOMOUS LOOPS
$AUTO_SECTION
$ZOMBIE_SECTION"

if [ -n "$FAILURE_DETAILS" ]; then
    BODY="${BODY}

RECENT FAILURES
$FAILURE_DETAILS"
fi

if [ -n "$SUGGESTIONS" ] || [ -n "$ENV_ISSUES" ] || [ -n "$MISSING_KEYS" ]; then
    BODY="${BODY}

========================================
WHAT YOU CAN DO TO HELP
========================================"
fi

if [ -n "$SUGGESTIONS" ]; then
    BODY="${BODY}

Based on recent failures:
$SUGGESTIONS"
fi

if [ -n "$ENV_ISSUES" ]; then
    BODY="${BODY}

Environment issues:
$ENV_ISSUES"
fi

if [ -n "$MISSING_KEYS" ]; then
    BODY="${BODY}

API keys that would unlock features:
$MISSING_KEYS"
fi

BODY="${BODY}

$HELP_SECTION

────────────────────────────────────────
To adjust autonomous behavior:
  Edit config/projects.json on the EC2 instance.

To force re-auth:
  Run 'claude login' locally. Creds sync to EC2 every 4h.
  Or force sync: ~/clawd-bot/infrastructure/sync-auth.sh

To submit a manual task:
  ./client/clawd <project> \"task description\"
────────────────────────────────────────"

send_email "$SUBJECT" "$BODY"
log "Daily effectiveness report sent"
