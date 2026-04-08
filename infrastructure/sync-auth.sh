#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

KEY_FILE="$SCRIPT_DIR/../clawd-bot.pem"
CREDS="$HOME/.claude/.credentials.json"

if [ ! -f "$CREDS" ]; then
    echo "No local credentials found"
    exit 1
fi

scp -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "$CREDS" "ec2-user@${CLAWD_PUBLIC_IP}:/home/ec2-user/.claude/.credentials.json" 2>/dev/null

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Synced credentials to $CLAWD_PUBLIC_IP"
