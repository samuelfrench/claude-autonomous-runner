#!/bin/bash
set -euo pipefail

PROJECTS_DIR="$HOME/projects"
CONFIG_FILE="$HOME/claude-workspace/clawd-bot/config/projects.json"
REGION="us-east-1"
EMAIL="${NOTIFICATION_EMAIL:-your-email@example.com}"
DYNAMO_TABLE="clawd-bot-tasks"
PROVIDER="ollama"
COMFYUI_URL="http://127.0.0.1:8188"
DEFAULT_MODEL="codestral:22b"
# Model choice (Apr 20 2026): codestral:22b is Mistral's code-specialised model,
# aider-compatible, emits clean SEARCH/REPLACE blocks with the filename on its
# own line before the fence — which is what aider's parser requires.
#
# Prior attempts and why they were rejected:
# - qwen3.5:35b-a3b              — 600 s litellm timeouts under VRAM saturation
# - qwen2.5-coder:32b(+ctx64k)   — emits prose tutorials, never the edit format
# - deepseek-coder-v2:16b+whole  — leaks format header into file content
# - deepseek-coder-v2:16b+diff   — malformed headers ("File Path: `foo`"),
#                                   aider creates literally-named garbage files
#
# Context cap: set via ollama-model-settings.yml (extra_params.num_ctx: 16384).
# Without the cap ollama allocates KV cache + compute buffers for the model's
# full training context and panics with "graph_reserve: failed to allocate
# compute buffers" on a 24 GB GPU. At 16 k ctx codestral fits in ~16 GB VRAM
# with ~8 GB headroom — verified via `nvidia-smi` and `ollama ps`.
DEFAULT_EDIT_FORMAT="diff"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# If your GitHub account has "block pushes that expose your private email"
# enabled, any commit whose author OR committer email is your real address
# is rejected with GH007. Aider invokes git subprocesses which inherit
# these env vars, so setting them here transparently routes every
# runner-triggered commit through the noreply address without touching
# any global git config. Replace with your own GH numeric id + username.
export GIT_AUTHOR_NAME="${BOT_GIT_NAME:-clawd-bot}"
export GIT_AUTHOR_EMAIL="${BOT_GIT_EMAIL:-bot@example.com}"
export GIT_COMMITTER_NAME="${BOT_GIT_NAME:-clawd-bot}"
export GIT_COMMITTER_EMAIL="${BOT_GIT_EMAIL:-bot@example.com}"

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

# Discover queue URL — retry on clock-skew errors which can occur if systemd
# starts us before NTP has synced. Without this, a boot-time SignatureDoesNotMatch
# exits the script; systemd's StartLimitBurst then trips and the runner sits
# silently dead for hours. Observed Apr 20 2026: 28h outage after a boot-race.
QUEUE_URL=""
for attempt in $(seq 1 12); do
    if QUEUE_URL=$(aws sqs get-queue-url --queue-name clawd-bot-tasks-ollama --region "$REGION" --query 'QueueUrl' --output text 2>/dev/null) && [ -n "$QUEUE_URL" ]; then
        break
    fi
    QUEUE_URL=""
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Startup: aws sqs get-queue-url failed (attempt $attempt/12) — sleeping 10s (likely clock skew from boot)"
    sleep 10
done
if [ -z "$QUEUE_URL" ]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FATAL: unable to reach SQS after 2 minutes of retries"
    exit 1
fi
log "ollama-runner started. Queue: $QUEUE_URL"
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
        # for the full 14400s timeout before any runner can pick it up again.
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

    # Extend visibility timeout to 4 hours
    aws sqs change-message-visibility \
        --queue-url "$QUEUE_URL" \
        --receipt-handle "$RECEIPT" \
        --visibility-timeout 14400 \
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
        send_email "[clawd-bot/ollama] $PROJECT: unknown project" \
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
    # Always reset push URL to the real repo at task start in case a prior
    # sandboxed run left it pointing at no-push.
    git remote set-url --push origin "$REPO" 2>/dev/null || true
    git fetch origin
    git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH"
    git reset --hard "origin/$BRANCH"
    git clean -fd

    # Model selection
    MODEL=$(jq -r ".[\"$PROJECT\"].ollama_model // \"$DEFAULT_MODEL\"" "$CONFIG_FILE")

    # Check for image generation requests in prompt
    if echo "$PROMPT" | grep -qiE '\[IMAGE:.*\]|generate.*(image|photo|illustration)|create.*(image|photo|illustration)'; then
        if curl -sf "$COMFYUI_URL/system_stats" > /dev/null 2>&1; then
            log "ComfyUI detected, generating images..."
            IMAGE_DESCRIPTIONS=$(echo "$PROMPT" | grep -oP '\[IMAGE:\s*\K[^\]]+' || true)
            if [ -n "$IMAGE_DESCRIPTIONS" ]; then
                echo "$IMAGE_DESCRIPTIONS" | while IFS= read -r img_desc; do
                    log "Generating image: $img_desc"
                    "$SCRIPT_DIR/generate-image.sh" "$img_desc" "$PROJECT_DIR" 2>&1 || log "WARNING: Image generation failed for: $img_desc"
                done
            fi
        else
            log "WARNING: ComfyUI not running at $COMFYUI_URL — skipping image generation"
        fi
    fi

    # Sandbox mode: disable push credentials before running LLM
    SANDBOX_ENABLED=$(jq -r ".[\"$PROJECT\"].autonomous.sandbox.enabled // false" "$CONFIG_FILE")
    if [ "$SANDBOX_ENABLED" = "true" ]; then
        log "Sandbox: disabling push (untrusted data protection)"
        git remote set-url --push origin no-push
    fi

    # Write a .aiderignore to keep aider from auto-adding huge files.
    # .aiderignore is gitignored via --aiderignore-file at invocation below, so
    # it doesn't need to be tracked in the project repo. Files >1MB and known
    # large-data directories are excluded — aider otherwise auto-adds any file
    # mentioned by name in the prompt, even 11MB JSON exports.
    AIDERIGNORE_FILE="$PROJECT_DIR/.aiderignore.clawd"
    {
        echo "# Auto-generated by clawd ollama-runner — DO NOT COMMIT"
        # Exclude all binary/image files (these are never useful in LLM context and
        # cause aider's repomap scanner to enumerate thousands of files, making startup
        # take many minutes and producing an enormous prompt that times out ollama)
        find . -type f \( -name '*.webp' -o -name '*.jpg' -o -name '*.jpeg' \
            -o -name '*.png' -o -name '*.gif' -o -name '*.svg' -o -name '*.ico' \
            -o -name '*.mp4' -o -name '*.mp3' -o -name '*.woff' -o -name '*.woff2' \
            -o -name '*.ttf' -o -name '*.eot' \) 2>/dev/null | sed 's|^\./||'
        # Exclude data files >30KB. 30KB is chosen to keep normal configs
        # (package.json, tsconfig.json) while blocking data exports that
        # waste context. Without this, aider auto-adds large data files
        # whenever the prompt mentions the filename — even when the prompt
        # explicitly says "do not touch", because auto-add doesn't read
        # negations.
        find . -type f \( -name '*.json' -o -name '*.csv' -o -name '*.ndjson' -o -name '*.sql' \) -size +30k 2>/dev/null | sed 's|^\./||'
        # Exclude any markdown/text file >40KB. Large TODO/LOG/DOC files blow
        # past codestral's 32k context and aider silently truncates them, so
        # the model ends up hallucinating content that isn't actually there
        # (it makes up plausible-sounding lines as search content).
        find . -type f \( -name '*.md' -o -name '*.txt' -o -name '*.log' -o -name '*.rst' \) -size +40k 2>/dev/null | sed 's|^\./||'
    } > "$AIDERIGNORE_FILE"

    # Run aider
    # --map-tokens 0: disable repomap entirely — repos with 20k+ files (e.g. image-heavy)
    # make repomap generation take minutes and produce a prompt that times out ollama.
    # Autonomous tasks are goal-directed enough not to need a full repo map.
    # --timeout 1800: override litellm's 600s default. A 36B-param MoE at 64k
    # context on a near-saturated 24GB GPU can take well over 10 min per reply;
    # the 600s default caused every request to time out and retry 9x, wasting
    # ~90 min per task with zero commits. 30 min gives real responses room to
    # finish while still bailing on actually-hung requests.
    EDIT_FORMAT=$(jq -r ".[\"$PROJECT\"].ollama_edit_format // \"$DEFAULT_EDIT_FORMAT\"" "$CONFIG_FILE")
    # --model-settings-file sets per-model `extra_params: num_ctx: N` so aider
    # forces ollama to allocate only N tokens of KV cache. Without this,
    # aider/litellm picks num_ctx based on the model's training max (deepseek-
    # coder-v2 = 163k) → ollama tries to allocate >20 GB KV cache on a 24 GB
    # GPU and panics with `graph_reserve: failed to allocate compute buffers`.
    # (The AIDER_MODEL_METADATA_FILE env var — which sets litellm's max_input_tokens
    # — does NOT control num_ctx in the ollama API call, only aider's internal
    # token accounting. Only model-settings-file's extra_params propagates to
    # the API request. Verified Apr 20 2026.)
    log "Running aider (model=ollama_chat/$MODEL, edit-format=$EDIT_FORMAT, timeout=1800s/req) ..."
    OUTPUT_FILE=$(mktemp /tmp/ollama-XXXXXX)
    EXIT_CODE=0
    timeout 14400 aider \
        --model "ollama_chat/$MODEL" \
        --edit-format "$EDIT_FORMAT" \
        --model-settings-file "$SCRIPT_DIR/ollama-model-settings.yml" \
        --aiderignore "$AIDERIGNORE_FILE" \
        --map-tokens 0 \
        --timeout 1800 \
        --yes-always \
        --no-auto-lint \
        --no-stream \
        --no-show-model-warnings \
        --message "$PROMPT" \
        > "$OUTPUT_FILE" 2>&1 || EXIT_CODE=$?

    rm -f "$AIDERIGNORE_FILE"

    AIDER_OUTPUT=$(head -c 50000 "$OUTPUT_FILE")
    rm -f "$OUTPUT_FILE"

    # ALWAYS restore push URL after aider runs, even on failure, to prevent
    # sandbox leaking into the next task.
    if [ "$SANDBOX_ENABLED" = "true" ]; then
        git remote set-url --push origin "$REPO"
    fi

    # Detect aider pseudo-success: aider exits 0 even when every LLM call
    # timed out. Grep the output for repeated connection errors and treat
    # that as a failure so the autonomous loop backs off instead of churning.
    AIDER_CONN_ERRORS=$(printf '%s' "$AIDER_OUTPUT" | grep -cE 'litellm\.(APIConnectionError|Timeout)|Connection timed out' || true)
    if [ "$EXIT_CODE" -eq 0 ] && [ "$AIDER_CONN_ERRORS" -ge 3 ]; then
        log "Aider exited 0 but output has $AIDER_CONN_ERRORS connection errors — treating as failed"
        EXIT_CODE=97
    fi

    # Detect aider silent no-op: exits 0 with no errors but produced nothing.
    # Seen with models that can't reliably emit aider's edit format (qwen2.5-coder:32b
    # emits prose tutorials instead of SEARCH/REPLACE blocks). Without this guard
    # the autonomous loop churns at zero progress while reporting success.
    if [ "$EXIT_CODE" -eq 0 ]; then
        NEW_COMMITS_CHECK=$(git log "origin/$BRANCH..HEAD" --oneline 2>/dev/null || true)
        WORKING_TREE_DIRTY=$(git status --porcelain 2>/dev/null | head -1)
        if [ -z "$NEW_COMMITS_CHECK" ] && [ -z "$WORKING_TREE_DIRTY" ]; then
            log "Aider exited 0 but produced no commits and no working-tree changes — model likely not emitting edit format, treating as failed"
            EXIT_CODE=96
        fi
    fi

    # Detect aider edit-format rejection: model emits SEARCH/REPLACE-like blocks
    # but with bad filenames/fences, aider prints "did not conform to the edit format"
    # and may still commit garbage-named files. If we see this, the commits (if any)
    # are garbage — treat as failed regardless of aider's exit code.
    AIDER_FORMAT_REJECTS=$(printf '%s' "$AIDER_OUTPUT" | grep -cE 'did not conform to the edit format|Bad/missing filename|Only [0-9]+ reflections allowed, stopping' || true)
    if [ "$EXIT_CODE" -eq 0 ] && [ "$AIDER_FORMAT_REJECTS" -ge 2 ]; then
        log "Aider reported $AIDER_FORMAT_REJECTS edit-format rejections — model is emitting malformed diffs, treating as failed"
        EXIT_CODE=95
    fi

    # Run project-specific verify_cmd if defined. Aider's diff format only
    # validates that SEARCH blocks match source text — it does NOT validate
    # that the resulting file is syntactically or semantically correct. Codestral
    # has happily produced commits with ESM `import` statements in a CommonJS
    # file, duplicate `const` declarations, and references to uninstalled
    # packages. A verify_cmd ("node audit/run-audit.js", "npm test", etc.) that
    # exits non-zero on broken code catches this before it ever reaches the
    # remote. Without it, broken commits pile up faster than humans notice.
    if [ "$EXIT_CODE" -eq 0 ]; then
        VERIFY_CMD=$(jq -r ".[\"$PROJECT\"].autonomous.verify_cmd // \"\"" "$CONFIG_FILE")
        if [ -n "$VERIFY_CMD" ] && [ "$VERIFY_CMD" != "null" ]; then
            log "Running verify_cmd: $VERIFY_CMD"
            VERIFY_OUT=$(mktemp /tmp/ollama-verify-XXXXXX)
            if timeout 300 bash -c "$VERIFY_CMD" > "$VERIFY_OUT" 2>&1; then
                log "verify_cmd passed"
            else
                V_EXIT=$?
                log "verify_cmd failed (exit $V_EXIT) — aider-produced code is broken, reverting"
                tail -c 2000 "$VERIFY_OUT" | while IFS= read -r line; do log "  verify> $line"; done
                git reset --hard "origin/$BRANCH" 2>&1 | while IFS= read -r line; do log "  $line"; done
                git clean -fd 2>&1 | while IFS= read -r line; do log "  $line"; done
                EXIT_CODE=93
                # Append verify output to AIDER_OUTPUT so the failure email has context
                AIDER_OUTPUT="$AIDER_OUTPUT

--- verify_cmd ($VERIFY_CMD) failed with exit $V_EXIT ---
$(cat "$VERIFY_OUT")"
            fi
            rm -f "$VERIFY_OUT"
        fi
    fi

    if [ "$EXIT_CODE" -eq 0 ]; then
        STATUS="completed"
    elif [ "$EXIT_CODE" -eq 93 ]; then
        STATUS="failed (verify_cmd rejected — aider produced broken code, reverted)"
    elif [ "$EXIT_CODE" -eq 95 ]; then
        STATUS="failed (aider edit-format rejected — malformed SEARCH/REPLACE from model)"
    elif [ "$EXIT_CODE" -eq 96 ]; then
        STATUS="failed (no edits — model may not emit aider edit format)"
    elif [ "$EXIT_CODE" -eq 97 ]; then
        STATUS="failed (ollama connection errors)"
    elif [ "$EXIT_CODE" -eq 124 ]; then
        STATUS="timed out (4h limit)"
    else
        STATUS="failed (exit $EXIT_CODE)"
    fi
    log "Aider status: $STATUS"

    # Determine DynamoDB status value
    case "$STATUS" in
        "completed") DYNAMO_STATUS="completed" ;;
        "timed out"*) DYNAMO_STATUS="timed_out" ;;
        *) DYNAMO_STATUS="failed" ;;
    esac

    # Discard local commits on any non-zero exit. The 93/95/96/97 guards detect
    # cases where the model misbehaved but aider may have still produced a
    # partial commit before exiting. Without this, the sandbox block below
    # happily pushes those commits as long as paths are allowed — which
    # bypasses the guard entirely. Observed Apr 20 2026 task-20260420-223613-auto:
    # exit 95 (edit-format rejected) yet two duplicate-function commits
    # (96ec5bd8, 782fd73c) reached master because the push gate only checked
    # NEW_COMMITS + sandbox, not EXIT_CODE.
    if [ "$EXIT_CODE" -ne 0 ]; then
        LOCAL_COMMITS=$(git log "origin/$BRANCH..HEAD" --oneline 2>/dev/null || true)
        if [ -n "$LOCAL_COMMITS" ]; then
            LOCAL_COUNT=$(printf '%s\n' "$LOCAL_COMMITS" | wc -l)
            log "Exit $EXIT_CODE — discarding $LOCAL_COUNT local commits (not pushing):"
            printf '%s\n' "$LOCAL_COMMITS" | while IFS= read -r l; do log "  discarded: $l"; done
            git reset --hard "origin/$BRANCH" 2>&1 | while IFS= read -r line; do log "  $line"; done
            git clean -fd 2>&1 | while IFS= read -r line; do log "  $line"; done
        fi
    fi

    # Sandbox validation: check changed files against allowed paths before pushing
    PUSH_STATUS="no changes"
    NEW_COMMITS=$(git log "origin/$BRANCH..HEAD" --oneline 2>/dev/null || true)

    if [ -n "$NEW_COMMITS" ] && [ "$SANDBOX_ENABLED" = "true" ]; then
        # Validate all changed files are in allowed paths
        CHANGED_FILES=$(git diff --name-only "origin/$BRANCH..HEAD" 2>/dev/null || true)
        SANDBOX_VIOLATION=false
        VIOLATION_FILES=""
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            ALLOWED=false
            while IFS= read -r pattern; do
                [ -z "$pattern" ] && continue
                if [[ "$file" == "$pattern"* ]]; then
                    ALLOWED=true
                    break
                fi
            done < <(jq -r ".[\"$PROJECT\"].autonomous.sandbox.allowed_paths[]" "$CONFIG_FILE")
            if [ "$ALLOWED" = "false" ]; then
                SANDBOX_VIOLATION=true
                VIOLATION_FILES="$VIOLATION_FILES  - $file\n"
                log "SANDBOX VIOLATION: $file is outside allowed paths"
            fi
        done <<< "$CHANGED_FILES"

        if [ "$SANDBOX_VIOLATION" = "true" ]; then
            log "Sandbox: BLOCKED push — files outside allowed paths"
            PUSH_STATUS="BLOCKED by sandbox"
            send_email "[clawd-bot/ollama] $PROJECT: SANDBOX VIOLATION" \
                "Push blocked — LLM modified files outside allowed paths.
This may indicate prompt injection from untrusted data, OR the model is emitting
malformed edit-format blocks that aider parses into garbage filenames.

Violated files:
$(echo -e "$VIOLATION_FILES")
Allowed paths: $(jq -r ".[\"$PROJECT\"].autonomous.sandbox.allowed_paths | join(\", \")" "$CONFIG_FILE")

Task: $TASK_ID
Commits:
$NEW_COMMITS

Review the changes manually: cd $PROJECT_DIR && git diff origin/$BRANCH..HEAD"
            # Reset to clean state
            git reset --hard "origin/$BRANCH"
            git clean -fd
            # Downgrade status: sandbox block must count as failure so the
            # autonomous loop backs off instead of churning on a broken model.
            STATUS="failed (sandbox blocked — files outside allowed paths)"
            DYNAMO_STATUS="failed"
            EXIT_CODE=95
            NEW_COMMITS=""
        else
            log "Sandbox: all changes in allowed paths, pushing"
            if git push origin "$BRANCH" 2>&1; then
                PUSH_STATUS="pushed (sandbox validated):\n$NEW_COMMITS"
                log "Pushed commits to $BRANCH"
            else
                PUSH_STATUS="push FAILED"
                log "ERROR: git push failed"
                STATUS="failed (git push rejected)"
                DYNAMO_STATUS="failed"
                EXIT_CODE=94
            fi
        fi
    elif [ -n "$NEW_COMMITS" ]; then
        # No sandbox — push directly
        if git push origin "$BRANCH" 2>&1; then
            PUSH_STATUS="pushed (deploy triggered):\n$NEW_COMMITS"
            log "Pushed commits to $BRANCH"
        else
            PUSH_STATUS="push FAILED"
            log "ERROR: git push failed"
            STATUS="failed (git push rejected)"
            DYNAMO_STATUS="failed"
            EXIT_CODE=94
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
    OUTPUT_JSON=$(printf '%s' "$AIDER_OUTPUT" | head -c 50000 | jq -Rs .)
    COMMITS_JSON=$(printf '%s' "$COMMITS_VAL" | jq -Rs .)
    dynamo_update "$TASK_ID" \
        "SET #s = :s, completed_at = :t, #o = :o, git_status = :g, commits = :c, exit_code = :e" \
        '{"#s":"status","#o":"output"}' \
        "{\":s\":{\"S\":\"$DYNAMO_STATUS\"},\":t\":{\"S\":\"$COMPLETED_AT\"},\":o\":{\"S\":$OUTPUT_JSON},\":g\":{\"S\":\"$GIT_STATUS_VAL\"},\":c\":{\"S\":$COMMITS_JSON},\":e\":{\"N\":\"$EXIT_CODE\"}}"

    # Send notification
    send_email "[clawd-bot/ollama] $PROJECT: $STATUS" \
        "Task: $TASK_ID
Project: $PROJECT
Provider: ollama
Status: $STATUS
Submitted: $(echo "$BODY" | jq -r '.submitted_at // "unknown"')

Prompt:
$PROMPT

Git:
$(echo -e "$PUSH_STATUS")

Output (first 50KB):
$AIDER_OUTPUT"

    # Delete from queue
    aws sqs delete-message \
        --queue-url "$QUEUE_URL" \
        --receipt-handle "$RECEIPT" \
        --region "$REGION"

    CURRENT_TASK_ID=""
    CURRENT_RECEIPT=""
    log "=== Task complete: $TASK_ID ==="

    # Autonomous mode: re-queue follow-up task on success OR failure (with backoff)
    AUTO_ENABLED=$(jq -r ".[\"$PROJECT\"].autonomous.enabled // false" "$CONFIG_FILE")
    FAILURE_FILE="/tmp/clawd-auto-failures-ollama-${PROJECT}"
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
                send_email "[clawd-bot/ollama] $PROJECT: autonomous loop halted" \
                    "Autonomous mode stopped after $FAIL_COUNT consecutive failures.

Last failure: $STATUS (exit code $EXIT_CODE)
Last task: $TASK_ID

To resume: delete $FAILURE_FILE and submit a new task, or fix the underlying issue.

Last output (first 2KB):
$(echo "$AIDER_OUTPUT" | head -c 2000)"
                sleep 5
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
        sleep 5
    fi
done
