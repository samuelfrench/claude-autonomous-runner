#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install clawd-runner (Claude) systemd service
sudo cp "$SCRIPT_DIR/clawd-runner.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/codex-runner.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable clawd-runner
sudo systemctl enable codex-runner

echo "Services installed and enabled:"
echo "  clawd-runner (Claude):  sudo systemctl start clawd-runner"
echo "  codex-runner (Codex):   sudo systemctl start codex-runner"
echo "  Logs: journalctl -u clawd-runner -f"
echo "  Logs: journalctl -u codex-runner -f"

# Install hourly status report cron
chmod +x "$SCRIPT_DIR/hourly-report.sh"
CRON_LINE="0 * * * * $SCRIPT_DIR/hourly-report.sh >> /tmp/clawd-hourly-report.log 2>&1"
(crontab -l 2>/dev/null | grep -v 'hourly-report.sh' || true; echo "$CRON_LINE") | crontab -
echo "Hourly report cron installed."
