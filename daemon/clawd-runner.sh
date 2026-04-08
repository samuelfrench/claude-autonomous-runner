#!/bin/bash
set -euo pipefail

PROJECTS_DIR="$HOME/projects"
CONFIG_FILE="$HOME/clawd-bot/config/projects.json"
REGION="us-east-1"
EMAIL="${NOTIFICATION_EMAIL:-your-email@example.com}"
DYNAMO_TABLE="clawd-bot-tasks"
PROVIDER="claude"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

dynamo_update() {
    local task_id=$1
    local expression=$2
    local names=$3
    local values=$4
    aws dynamodb update-item \
        --table-name "$DYNAMO_TABLE" \
        --key "{\"task_id\":{\"S\":\"$task_id\"}}" \
        --update-expression "$expression" \
        --expression-attribute-names "$names" \
        --expression-attribute-values "$values" \
        --region "$REGION" 2>/dev/null || log "WARNING: DynamoDB update failed for $task_id"
}

# Discover queue URL
QUEUE_URL=$(aws sqs get-queue-url --queue-name clawd-bot-tasks --region "$REGION" --query 'QueueUrl' --output text)
log "clawd-runner started. Queue: $QUEUE_URL"
mkdir -p "$PROJECTS_DIR"

send_email() {
    local subject=$1
    local body=$2
    local body_json
    body_json=$(printf '%s' "$body" | jq -Rs .)
    local subject_json
    subject_json=$(printf '%s' "$subject" | jq -Rs .)

    aws ses send-email \
        --from "$EMAIL" \
        --destination "{\"ToAddresses\":[\"$EMAIL\"]}" \
        --message "{\"Subject\":{\"Data\":${subject_json}},\"Body\":{\"Text\":{\"Data\":${body_json}}}}" \
        --region "$REGION" 2>/dev/null || log "WARNING: email send failed"
}

trap 'log "Shutting down..."; exit 0' SIGTERM SIGINT

while true; do
    # Long-poll SQS (20s wait)
    RESPONSE=$(aws sqs receive-message \
        --queue-url "$QUEUE_URL" \
        --wait-time-seconds 20 \
        --max-number-of-messages 1 \
        --region "$REGION" 2>/dev/null) || continue

    # Check for message
    BODY=$(echo "$RESPONSE" | jq -r '.Messages[0].Body // empty' 2>/dev/null) || continue
    [ -z "$BODY" ] && continue

    RECEIPT=$(echo "$RESPONSE" | jq -r '.Messages[0].ReceiptHandle')
    PROJECT=$(echo "$BODY" | jq -r '.project')
    PROMPT=$(echo "$BODY" | jq -r '.prompt')
    TASK_ID=$(echo "$BODY" | jq -r '.task_id // "unknown"')

    log "=== Task: $TASK_ID | Project: $PROJECT ==="
    log "Prompt: $PROMPT"

    # Extend visibility timeout to 2 hours
    aws sqs change-message-visibility \
        --queue-url "$QUEUE_URL" \
        --receipt-handle "$RECEIPT" \
        --visibility-timeout 7200 \
        --region "$REGION" 2>/dev/null || true

    # Record task start in DynamoDB
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    dynamo_update "$TASK_ID" \
        "SET #s = :s, started_at = :t, provider = :pv, #p = :proj, #pr = :pr" \
        '{"#s":"status","#p":"project","#pr":"prompt"}' \
        "{\":s\":{\"S\":\"running\"},\":t\":{\"S\":\"$NOW\"},\":pv\":{\"S\":\"$PROVIDER\"},\":proj\":{\"S\":\"$PROJECT\"},\":pr\":{\"S\":$(printf '%s' "$PROMPT" | head -c 50000 | jq -Rs .)}}"

    # Look up project
    REPO=$(jq -r ".[\"$PROJECT\"].repo // empty" "$CONFIG_FILE")
    BRANCH=$(jq -r ".[\"$PROJECT\"].branch // empty" "$CONFIG_FILE")

    if [ -z "$REPO" ]; then
        log "ERROR: Unknown project '$PROJECT'"
        send_email "[clawd-bot] $PROJECT: unknown project" \
            "Task $TASK_ID failed: project '$PROJECT' not found in projects.json"
        aws sqs delete-message --queue-url "$QUEUE_URL" --receipt-handle "$RECEIPT" --region "$REGION"
        continue
    fi

    PROJECT_DIR="$PROJECTS_DIR/$PROJECT"

    # Clone or update repo
    if [ ! -d "$PROJECT_DIR/.git" ]; then
        log "Cloning $REPO"
        git clone "$REPO" "$PROJECT_DIR"
    fi
    cd "$PROJECT_DIR"
    git fetch origin
    git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH"
    git reset --hard "origin/$BRANCH"
    git clean -fd

    # Run Claude
    EFFORT=$(jq -r ".[\"$PROJECT\"].autonomous.effort // \"medium\"" "$CONFIG_FILE")
    log "Running claude -p (effort=$EFFORT) ..."
    OUTPUT_FILE=$(mktemp /tmp/clawd-XXXXXX)
    EXIT_CODE=0
    timeout 7200 claude -p "$PROMPT" \
        --dangerously-skip-permissions \
        --output-format text \
        --effort "$EFFORT" \
        > "$OUTPUT_FILE" 2>&1 || EXIT_CODE=$?

    CLAUDE_OUTPUT=$(head -c 50000 "$OUTPUT_FILE")
    rm -f "$OUTPUT_FILE"

    if [ "$EXIT_CODE" -eq 0 ]; then
        STATUS="completed"
    elif [ "$EXIT_CODE" -eq 124 ]; then
        STATUS="timed out (2h limit)"
    else
        STATUS="failed (exit $EXIT_CODE)"
    fi
    log "Claude status: $STATUS"

    # Determine DynamoDB status value
    case "$STATUS" in
        "completed") DYNAMO_STATUS="completed" ;;
        "timed out"*) DYNAMO_STATUS="timed_out" ;;
        *) DYNAMO_STATUS="failed" ;;
    esac

    # Push if there are new commits
    PUSH_STATUS="no changes"
    NEW_COMMITS=$(git log "origin/$BRANCH..HEAD" --oneline 2>/dev/null || true)
    if [ -n "$NEW_COMMITS" ]; then
        if git push origin "$BRANCH" 2>&1; then
            PUSH_STATUS="pushed (deploy triggered):\n$NEW_COMMITS"
            log "Pushed commits to $BRANCH"
        else
            PUSH_STATUS="push FAILED"
            log "ERROR: git push failed"
        fi
    else
        log "No new commits"
    fi

    # Record task completion in DynamoDB
    COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    GIT_STATUS_VAL="no_changes"
    COMMITS_VAL=""
    if [ -n "$NEW_COMMITS" ]; then
        if echo -e "$PUSH_STATUS" | grep -q "FAILED"; then
            GIT_STATUS_VAL="push_failed"
        else
            GIT_STATUS_VAL="pushed"
        fi
        COMMITS_VAL="$NEW_COMMITS"
    fi
    OUTPUT_JSON=$(printf '%s' "$CLAUDE_OUTPUT" | head -c 50000 | jq -Rs .)
    COMMITS_JSON=$(printf '%s' "$COMMITS_VAL" | jq -Rs .)
    dynamo_update "$TASK_ID" \
        "SET #s = :s, completed_at = :t, #o = :o, git_status = :g, commits = :c, exit_code = :e" \
        '{"#s":"status","#o":"output"}' \
        "{\":s\":{\"S\":\"$DYNAMO_STATUS\"},\":t\":{\"S\":\"$COMPLETED_AT\"},\":o\":{\"S\":$OUTPUT_JSON},\":g\":{\"S\":\"$GIT_STATUS_VAL\"},\":c\":{\"S\":$COMMITS_JSON},\":e\":{\"N\":\"$EXIT_CODE\"}}"

    # Send notification
    send_email "[clawd-bot] $PROJECT: $STATUS" \
        "Task: $TASK_ID
Project: $PROJECT
Status: $STATUS
Submitted: $(echo "$BODY" | jq -r '.submitted_at // "unknown"')

Prompt:
$PROMPT

Git:
$(echo -e "$PUSH_STATUS")

Output (first 50KB):
$CLAUDE_OUTPUT"

    # Delete from queue
    aws sqs delete-message \
        --queue-url "$QUEUE_URL" \
        --receipt-handle "$RECEIPT" \
        --region "$REGION"

    log "=== Task complete: $TASK_ID ==="

    # Autonomous mode: re-queue follow-up task on success OR failure (with backoff)
    AUTO_ENABLED=$(jq -r ".[\"$PROJECT\"].autonomous.enabled // false" "$CONFIG_FILE")
    FAILURE_FILE="/tmp/clawd-auto-failures-${PROJECT}"
    MAX_CONSECUTIVE_FAILURES=5

    if [ "$AUTO_ENABLED" = "true" ]; then
        AUTO_GOAL=$(jq -r ".[\"$PROJECT\"].autonomous.goal" "$CONFIG_FILE")
        COOLDOWN=$(jq -r ".[\"$PROJECT\"].autonomous.cooldown_minutes // 10" "$CONFIG_FILE")

        if [ "$DYNAMO_STATUS" = "completed" ]; then
            # Success — reset failure counter, use normal cooldown
            echo 0 > "$FAILURE_FILE"
            DELAY_SECONDS=$((COOLDOWN * 60))
            log "Autonomous: task succeeded, resetting failure counter"
        else
            # Failure — increment counter, back off
            FAIL_COUNT=$(cat "$FAILURE_FILE" 2>/dev/null || echo 0)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo "$FAIL_COUNT" > "$FAILURE_FILE"

            if [ "$FAIL_COUNT" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
                log "Autonomous: $FAIL_COUNT consecutive failures for $PROJECT — halting autonomous loop"
                send_email "[clawd-bot] $PROJECT: autonomous loop halted" \
                    "Autonomous mode stopped after $FAIL_COUNT consecutive failures.

Last failure: $STATUS (exit code $EXIT_CODE)
Last task: $TASK_ID

To resume: delete $FAILURE_FILE on EC2 and submit a new task, or fix the underlying issue.

Last output (first 2KB):
$(echo "$CLAUDE_OUTPUT" | head -c 2000)"
                sleep 10
                continue
            fi

            # Exponential backoff: cooldown * 2^(failures-1), capped at 60 min
            BACKOFF_MULTIPLIER=$((1 << (FAIL_COUNT - 1)))
            BACKOFF_MINUTES=$((COOLDOWN * BACKOFF_MULTIPLIER))
            if [ "$BACKOFF_MINUTES" -gt 60 ]; then
                BACKOFF_MINUTES=60
            fi
            DELAY_SECONDS=$((BACKOFF_MINUTES * 60))
            log "Autonomous: failure $FAIL_COUNT/$MAX_CONSECUTIVE_FAILURES, retrying in ${BACKOFF_MINUTES}m"
        fi

        # SQS max delay is 900s (15min) — if longer, sleep the remainder first
        if [ "$DELAY_SECONDS" -gt 900 ]; then
            SLEEP_FIRST=$((DELAY_SECONDS - 900))
            log "Autonomous: sleeping ${SLEEP_FIRST}s before queuing (SQS max delay is 900s)"
            sleep "$SLEEP_FIRST"
            DELAY_SECONDS=900
        fi

        NEXT_TASK_ID="task-$(date +%Y%m%d-%H%M%S)-auto"

        NEXT_PROMPT="You are an autonomous agent working toward this goal: ${AUTO_GOAL}

Read TODO.md to see what has been done and what remains. Pick the single highest-leverage task that moves toward the goal. Do it. Update TODO.md to reflect what you did and what should come next.

Rules:
- One focused task per run. Do it well rather than doing many things poorly.
- Always commit and push your changes.
- Do NOT repeat work already marked done in TODO.md.
- If TODO.md does not exist, create it with a prioritized roadmap for the goal.
- If you believe the goal has been reached, update TODO.md to say so and describe maintenance tasks."

        NEXT_MESSAGE=$(jq -n \
            --arg project "$PROJECT" \
            --arg prompt "$NEXT_PROMPT" \
            --arg task_id "$NEXT_TASK_ID" \
            --arg submitted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{project: $project, prompt: $prompt, task_id: $task_id, submitted_at: $submitted_at}')

        # Record re-queued task in DynamoDB
        REQUEUE_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        aws dynamodb put-item \
            --table-name "$DYNAMO_TABLE" \
            --item "{\"task_id\":{\"S\":\"$NEXT_TASK_ID\"},\"project\":{\"S\":\"$PROJECT\"},\"provider\":{\"S\":\"$PROVIDER\"},\"prompt\":{\"S\":$(printf '%s' "$NEXT_PROMPT" | jq -Rs .)},\"status\":{\"S\":\"pending\"},\"submitted_at\":{\"S\":\"$REQUEUE_TIME\"}}" \
            --region "$REGION" 2>/dev/null || log "WARNING: DynamoDB put failed for $NEXT_TASK_ID"

        SEND_RESULT=$(aws sqs send-message \
            --queue-url "$QUEUE_URL" \
            --message-body "$NEXT_MESSAGE" \
            --delay-seconds "$DELAY_SECONDS" \
            --region "$REGION" 2>&1) || {
            log "ERROR: re-queue failed: $SEND_RESULT"
            # Retry once without delay
            aws sqs send-message \
                --queue-url "$QUEUE_URL" \
                --message-body "$NEXT_MESSAGE" \
                --region "$REGION" > /dev/null 2>&1 || log "ERROR: re-queue retry also failed"
        }

        SEND_MSG_ID=$(echo "$SEND_RESULT" | jq -r '.MessageId // "unknown"' 2>/dev/null)
        FAIL_COUNT_NOW=$(cat "$FAILURE_FILE" 2>/dev/null || echo 0)
        log "Autonomous: queued follow-up $NEXT_TASK_ID for $PROJECT (failures=$FAIL_COUNT_NOW, msgId=$SEND_MSG_ID)"
    else
        # Brief cooldown between manual tasks
        sleep 10
    fi
done
