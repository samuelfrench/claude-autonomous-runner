#!/bin/bash
set -euxo pipefail

# Runs as root on EC2 first boot

REGION="us-east-1"
BOT_USER="ec2-user"
BOT_HOME="/home/$BOT_USER"

exec > /var/log/clawd-bot-setup.log 2>&1

echo "=== clawd-bot bootstrap starting ==="

# Install system packages
dnf install -y git jq

# Retrieve GitHub SSH key from SSM
mkdir -p "$BOT_HOME/.ssh"
aws ssm get-parameter \
    --name "/clawd-bot/github-ssh-key" \
    --with-decryption \
    --query 'Parameter.Value' --output text \
    --region "$REGION" > "$BOT_HOME/.ssh/id_ed25519"
chmod 600 "$BOT_HOME/.ssh/id_ed25519"

# GitHub known hosts
ssh-keyscan github.com >> "$BOT_HOME/.ssh/known_hosts" 2>/dev/null
chown -R "$BOT_USER:$BOT_USER" "$BOT_HOME/.ssh"

# Git config
su - "$BOT_USER" -c 'git config --global user.name "clawd-bot"'
su - "$BOT_USER" -c 'git config --global user.email "bot@example.com"'

# Install Claude CLI
su - "$BOT_USER" -c 'curl -fsSL https://claude.ai/install.sh | sh'

# Install Node.js and Codex CLI
dnf install -y nodejs
npm install -g @openai/codex

# Retrieve OpenAI API key from SSM and write env file for codex-runner service
OPENAI_KEY=$(aws ssm get-parameter \
    --name "/clawd-bot/openai-api-key" \
    --with-decryption \
    --query 'Parameter.Value' --output text \
    --region "$REGION" 2>/dev/null || echo "")
if [ -n "$OPENAI_KEY" ]; then
    echo "OPENAI_API_KEY=$OPENAI_KEY" > "$BOT_HOME/.codex-env"
    chmod 600 "$BOT_HOME/.codex-env"
    chown "$BOT_USER:$BOT_USER" "$BOT_HOME/.codex-env"
    su - "$BOT_USER" -c "export OPENAI_API_KEY='$OPENAI_KEY' && printenv OPENAI_API_KEY | codex login --with-api-key" 2>/dev/null || true
fi

# Clone your fork of this repo
su - "$BOT_USER" -c 'git clone git@github.com:YOUR_USERNAME/claude-autonomous-runner.git "$HOME/clawd-bot"'

# Create projects directory
su - "$BOT_USER" -c 'mkdir -p "$HOME/projects"'

# Install systemd services
cp "$BOT_HOME/clawd-bot/daemon/clawd-runner.service" /etc/systemd/system/
cp "$BOT_HOME/clawd-bot/daemon/codex-runner.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable clawd-runner
systemctl enable codex-runner
# Do NOT start clawd-runner — user must run `claude auth login` first
# Start codex-runner if API key was configured (no interactive login needed)
if [ -f "$BOT_HOME/.codex-env" ]; then
    systemctl start codex-runner
fi

echo "=== clawd-bot bootstrap complete ==="
echo "Next: SSH in, run 'claude auth login', then 'sudo systemctl start clawd-runner'"
