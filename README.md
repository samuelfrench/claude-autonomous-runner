# Claude Autonomous Runner

Self-hosted autonomous coding agent that runs [Claude Code](https://claude.ai/download) and [OpenAI Codex](https://openai.com/index/introducing-codex/) headless on an EC2 instance, polling SQS for tasks.

## What it does

- Runs `claude -p` or `codex exec` headless against your project repos
- Pushes changes to GitHub (triggering CI/CD auto-deploy)
- Emails results via SES
- Tracks all task state in DynamoDB (pending/running/completed/failed)
- **Autonomous mode**: projects can self-re-queue follow-up tasks toward a goal, with exponential backoff on failure
- Web dashboard for submitting tasks and monitoring progress

## Architecture

```
You (CLI/Web) --> SQS Queue --> EC2 Daemon --> claude -p / codex exec
                                    |
                                    +--> git push (triggers deploy)
                                    +--> SES email (results)
                                    +--> DynamoDB (task tracking)
                                    +--> SQS re-queue (autonomous mode)
```

- **EC2 instance** runs two systemd daemons: `clawd-runner` (Claude) and `codex-runner` (Codex)
- Each daemon long-polls its own SQS queue
- **Web dashboard**: S3 + CloudFront static site, API Gateway + Lambda backend

## Setup

### Prerequisites

- AWS CLI configured with appropriate permissions
- A Claude Code subscription (for `claude` CLI)
- An OpenAI API key (for Codex, optional)

### 1. Deploy infrastructure

```bash
# Creates: SQS queues, DynamoDB table, IAM role, security group, EC2 instance
./infrastructure/setup.sh

# Creates: Lambda functions, API Gateway, S3 bucket, CloudFront distribution
./infrastructure/setup-web.sh
```

### 2. Configure Claude auth on EC2

```bash
ssh -i clawd-bot.pem ec2-user@<instance-ip>
claude auth login
sudo systemctl start clawd-runner
```

### 3. Add projects

Edit `config/projects.json`:

```json
{
  "my-project": {
    "repo": "git@github.com:you/my-project.git",
    "branch": "main",
    "autonomous": {
      "enabled": true,
      "goal": "Your autonomous goal here",
      "cooldown_minutes": 30,
      "effort": "high"
    }
  }
}
```

### 4. Submit tasks

```bash
# Via CLI
./client/clawd my-project "Fix the login bug"
./client/clawd my-project "Add unit tests" --provider codex

# Check status
./client/clawd-status
```

Or use the web dashboard at your CloudFront URL.

## Autonomous Mode

Projects with `autonomous.enabled: true` will automatically re-queue follow-up tasks after each completion. The agent:

1. Reads `TODO.md` in the project repo
2. Picks the highest-leverage task toward the goal
3. Does it, commits, pushes
4. Updates `TODO.md` and re-queues itself

**Failure handling**: On failure, retries with exponential backoff (cooldown x 2^failures, capped at 60 min). After 5 consecutive failures, halts and sends an alert email. Success resets the counter.

## Credential auth sync

Claude Code uses OAuth tokens that expire. A local cron job syncs credentials to EC2 every 4 hours:

```bash
# Add to your local crontab
0 */4 * * * /path/to/infrastructure/sync-auth.sh >> /tmp/clawd-sync-auth.log 2>&1
```

## Monitoring

- **Hourly reports**: SES email with daemon health, queue depth, auth status, recent activity
- **Web dashboard**: Real-time task list with filtering by status/provider
- **Logs**: `journalctl -u clawd-runner -f` on the EC2 instance

## Cost

- EC2 t3a.medium: ~$20/month (on-demand)
- Claude Code: uses your existing subscription (no API costs)
- Codex: OpenAI API usage costs
- SQS/DynamoDB/Lambda/S3: free tier eligible
- SES: pennies

## Teardown

```bash
./infrastructure/teardown.sh
```

## License

MIT
