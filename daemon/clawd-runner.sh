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

CURRENT_TASK_ID=""
CURRENT_RECEIPT=""
cleanup() {
    log "Shutting down..."
    if [ -n "$CURRENT_TASK_ID" ]; then
        log "Requeuing $CURRENT_TASK_ID: resetting SQS visibility + marking DDB pending"
        # Reset SQS visibility to 0 so the message is immediately available for
        # redelivery. Without this, a mid-flight kill leaves the message invisible
        # for the full 10800s timeout before any runner can pick it up again.
        if [ -n "$CURRENT_RECEIPT" ]; then
            aws sqs change-message-visibility \
                --queue-url "$QUEUE_URL" \
                --receipt-handle "$CURRENT_RECEIPT" \
                --visibility-timeout 0 \
                --region "$REGION" 2>/dev/null || log "WARNING: SQS visibility reset failed"
        fi
        dynamo_update "$CURRENT_TASK_ID" \
            "SET #s = :s, interrupted_at = :t" \
            '{"#s":"status"}' \
            "{\":s\":{\"S\":\"pending\"},\":t\":{\"S\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
    fi
    exit 0
}
trap cleanup SIGTERM SIGINT

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

    CURRENT_TASK_ID="$TASK_ID"
    CURRENT_RECEIPT="$RECEIPT"
    log "=== Task: $TASK_ID | Project: $PROJECT ==="
    log "Prompt: $PROMPT"

    # Extend visibility timeout to 3 hours (matches --timeout below)
    aws sqs change-message-visibility \
        --queue-url "$QUEUE_URL" \
        --receipt-handle "$RECEIPT" \
        --visibility-timeout 10800 \
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
    MODEL=$(jq -r ".[\"$PROJECT\"].autonomous.model // \"sonnet\"" "$CONFIG_FILE")

    # Diagnostic: log which auth is in effect so we can correlate failures with
    # token state later. Long-lived CLAUDE_CODE_OAUTH_TOKEN takes precedence
    # over .credentials.json for Claude CLI; when set, there's no expiry to track.
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        TOKEN_MIN_REMAINING=99999
        log "Auth: long-lived CLAUDE_CODE_OAUTH_TOKEN (no expiry)"
    else
        TOKEN_EXPIRES_MS=$(jq -r '.claudeAiOauth.expiresAt // 0' "$HOME/.claude/.credentials.json" 2>/dev/null || echo 0)
        NOW_MS=$(($(date +%s) * 1000))
        if [ "$TOKEN_EXPIRES_MS" -gt 0 ]; then
            TOKEN_MIN_REMAINING=$(( (TOKEN_EXPIRES_MS - NOW_MS) / 60000 ))
            log "Auth: OAuth access token, expires in ${TOKEN_MIN_REMAINING}m"
            if [ "$TOKEN_MIN_REMAINING" -lt 90 ]; then
                log "WARNING: token has <90m before expiry and task can run up to 180m — may expire mid-task"
            fi
        else
            TOKEN_MIN_REMAINING=0
            log "WARNING: no CLAUDE_CODE_OAUTH_TOKEN and no valid .credentials.json — auth likely broken"
        fi
    fi

    log "Running claude -p (model=$MODEL, effort=$EFFORT, timeout=10800s/3h) ..."
    TASK_START_EPOCH=$(date +%s)
    OUTPUT_FILE=$(mktemp /tmp/clawd-XXXXXX)
    EXIT_CODE=0
    timeout 10800 claude -p "$PROMPT" \
        --dangerously-skip-permissions \
        --output-format text \
        --model "$MODEL" \
        --effort "$EFFORT" \
        --tools "Bash,Edit,Read,Write,Glob,Grep,Task" \
        > "$OUTPUT_FILE" 2>&1 || EXIT_CODE=$?

    TASK_END_EPOCH=$(date +%s)
    DURATION_SEC=$((TASK_END_EPOCH - TASK_START_EPOCH))
    DURATION_MIN=$((DURATION_SEC / 60))
    CLAUDE_OUTPUT=$(head -c 50000 "$OUTPUT_FILE")
    rm -f "$OUTPUT_FILE"

    if [ "$EXIT_CODE" -eq 0 ]; then
        STATUS="completed"
    elif [ "$EXIT_CODE" -eq 124 ]; then
        STATUS="timed out (3h limit)"
    else
        STATUS="failed (exit $EXIT_CODE)"
    fi
    log "Claude status: $STATUS | duration=${DURATION_SEC}s (${DURATION_MIN}m) | model=$MODEL effort=$EFFORT"

    # Diagnostic: warn if task ran >80% of timeout (suggests we may need to bump further)
    if [ "$DURATION_SEC" -gt 8640 ]; then
        log "WARNING: task used ${DURATION_SEC}s (>80% of 10800s timeout) — consider bumping --timeout further"
    fi

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
        "SET #s = :s, completed_at = :t, #o = :o, git_status = :g, commits = :c, exit_code = :e, duration_sec = :d, model = :m, effort = :f, token_min_at_start = :tok" \
        '{"#s":"status","#o":"output"}' \
        "{\":s\":{\"S\":\"$DYNAMO_STATUS\"},\":t\":{\"S\":\"$COMPLETED_AT\"},\":o\":{\"S\":$OUTPUT_JSON},\":g\":{\"S\":\"$GIT_STATUS_VAL\"},\":c\":{\"S\":$COMMITS_JSON},\":e\":{\"N\":\"$EXIT_CODE\"},\":d\":{\"N\":\"$DURATION_SEC\"},\":m\":{\"S\":\"$MODEL\"},\":f\":{\"S\":\"$EFFORT\"},\":tok\":{\"N\":\"${TOKEN_MIN_REMAINING:-0}\"}}"

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

    CURRENT_TASK_ID=""
    CURRENT_RECEIPT=""
    log "=== Task complete: $TASK_ID ==="

    # Detect Claude Max 5-hour quota exhaustion / rate-limiting in the CLI output.
    # These are transient (window rolls over) and should NOT count against the
    # halt-after-N-failures counter — just sleep long enough for the window to
    # reopen and retry, using the existing SQS-delay + in-process-sleep machinery.
    QUOTA_EXHAUSTED=false
    if [ "$DYNAMO_STATUS" != "completed" ]; then
        if echo "$CLAUDE_OUTPUT" | grep -qiE '5-hour limit|usage limit reached|hit your (usage )?limit|rate[_ -]?limit|429|quota (exceeded|exhaust)|please try again in|reset(s|ting)? (at|in|on)|reset(s|ting)? [A-Z][a-z]+ ?[0-9]|try again at'; then
            QUOTA_EXHAUSTED=true
            log "Claude output matched quota/rate-limit pattern — transient, not counted as failure"
        fi
    fi

    # Detect Anthropic Usage Policy / AUP / content-filter refusals. The CLI exits
    # non-zero in seconds with "API Error: ... violate our Usage Policy ...".
    # These are NOT runtime bugs and tend to be persistent until the prompt or
    # model changes — counting them as regular failures halts the loop after 8
    # back-to-back attempts (Apr 27 incident). Treat them as a long-sleep event:
    # don't increment the failure counter, sleep 4h, and email the user once so
    # they can switch model or rephrase.
    POLICY_REFUSAL=false
    if [ "$DYNAMO_STATUS" != "completed" ] && [ "$QUOTA_EXHAUSTED" = "false" ]; then
        if echo "$CLAUDE_OUTPUT" | grep -qiE 'usage policy|violate.*[Uu]sage|API Error.*unable to respond|anthropic\.com/legal/aup'; then
            POLICY_REFUSAL=true
            log "Claude output matched policy-refusal pattern (AUP/content filter) — not counted as failure"
        fi
    fi

    # Autonomous mode: re-queue follow-up task on success OR failure (with backoff)
    AUTO_ENABLED=$(jq -r ".[\"$PROJECT\"].autonomous.enabled // false" "$CONFIG_FILE")
    FAILURE_FILE="/tmp/clawd-auto-failures-${PROJECT}"
    MAX_CONSECUTIVE_FAILURES=8
    QUOTA_SLEEP_MINUTES=60

    if [ "$AUTO_ENABLED" = "true" ]; then
        AUTO_GOAL=$(jq -r ".[\"$PROJECT\"].autonomous.goal" "$CONFIG_FILE")
        COOLDOWN=$(jq -r ".[\"$PROJECT\"].autonomous.cooldown_minutes // 10" "$CONFIG_FILE")

        if [ "$DYNAMO_STATUS" = "completed" ]; then
            # Success — reset failure counter + clear one-shot policy alert flag,
            # use normal cooldown
            echo 0 > "$FAILURE_FILE"
            rm -f "/tmp/clawd-policy-alerted-${PROJECT}"
            DELAY_SECONDS=$((COOLDOWN * 60))
            log "Autonomous: task succeeded, resetting failure counter"
        elif [ "$QUOTA_EXHAUSTED" = "true" ]; then
            # Quota exhausted — long flat sleep, do NOT increment failure counter.
            # Claude Max 5-hour windows are rolling; one hour is usually enough
            # to reopen. If still quota-limited after 1h, next loop will re-detect
            # and sleep again — so the bot rides out the window indefinitely
            # without ever hitting MAX_CONSECUTIVE_FAILURES.
            DELAY_SECONDS=$((QUOTA_SLEEP_MINUTES * 60))
            log "Autonomous: quota exhausted — sleeping ${QUOTA_SLEEP_MINUTES}m before retry (failure counter unchanged)"
        elif [ "$POLICY_REFUSAL" = "true" ]; then
            # AUP / content-filter refusal. Persistent until prompt or model
            # changes, but still treat as transient: long sleep, no halt. Email
            # the user once per project so they can intervene.
            DELAY_SECONDS=$((4 * 60 * 60))
            log "Autonomous: policy refusal — sleeping 4h before retry (failure counter unchanged). Switch autonomous.model in projects.json if persistent."
            POLICY_ALERT_FILE="/tmp/clawd-policy-alerted-${PROJECT}"
            if [ ! -f "$POLICY_ALERT_FILE" ]; then
                send_email "[clawd-bot] $PROJECT: policy refusal (autonomous loop continues)" \
                    "Claude refused the autonomous prompt as a Usage Policy violation. The autonomous loop is continuing with 4-hour retries — it will NOT halt — but real progress requires switching model or rephrasing.

Last task: $TASK_ID
Model: $MODEL
Output (first 1KB):
$(echo "$CLAUDE_OUTPUT" | head -c 1000)

To fix: change autonomous.model in clawd-bot/config/projects.json (Sonnet typically passes where Opus refuses), commit, and pull on EC2."
                touch "$POLICY_ALERT_FILE"
            fi
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
