#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

KEY_FILE="$SCRIPT_DIR/../clawd-bot.pem"
CREDS="$HOME/.claude/.credentials.json"
REMOTE_USER="ec2-user"
REMOTE_HOST="$CLAWD_PUBLIC_IP"
REMOTE_CREDS="/home/ec2-user/.claude/.credentials.json"
SSH_OPTS="-i $KEY_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# Check local credentials exist
if [ ! -f "$CREDS" ]; then
    log "SKIP: No local credentials at $CREDS"
    exit 0
fi

# Check local credentials are valid (not expired)
LOCAL_EXPIRES=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CREDS" 2>/dev/null)
NOW_MS=$(($(date +%s) * 1000))

if [ "$LOCAL_EXPIRES" -le "$NOW_MS" ] 2>/dev/null; then
    log "SKIP: Local credentials expired (expiresAt: $LOCAL_EXPIRES, now: $NOW_MS)"
    exit 0
fi

EXPIRES_IN_MIN=$(( (LOCAL_EXPIRES - NOW_MS) / 60000 ))
log "Local credentials valid (expires in ${EXPIRES_IN_MIN}m)"

# Check EC2 is reachable
if ! ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "true" 2>/dev/null; then
    log "SKIP: EC2 instance unreachable at $REMOTE_HOST"
    exit 0
fi

# Get remote credentials expiry (if they exist)
REMOTE_EXPIRES=$(ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" \
    "jq -r '.claudeAiOauth.expiresAt // 0' $REMOTE_CREDS 2>/dev/null" 2>/dev/null || echo "0")

if [ "$LOCAL_EXPIRES" -le "$REMOTE_EXPIRES" ] 2>/dev/null; then
    log "SKIP: Remote credentials already up-to-date (remote expires: $REMOTE_EXPIRES, local: $LOCAL_EXPIRES)"
    exit 0
fi

# Copy credentials
scp $SSH_OPTS "$CREDS" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_CREDS" 2>/dev/null

log "SYNCED: Credentials copied to $REMOTE_HOST (expires in ${EXPIRES_IN_MIN}m)"
