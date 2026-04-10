# Claude Autonomous Runner

Self-hosted autonomous coding agent that runs [Claude Code](https://claude.ai/download), [OpenAI Codex](https://openai.com/index/introducing-codex/), and [Ollama](https://ollama.com/) (via [aider](https://aider.chat/)) headless, polling SQS for tasks.

## What it does

- Runs `claude -p`, `codex exec`, or `aider` headless against your project repos
- Pushes changes to GitHub (triggering CI/CD auto-deploy)
- Emails results via SES
- Tracks all task state in DynamoDB (pending/running/completed/failed)
- **Autonomous mode**: projects self-re-queue follow-up tasks toward a goal, with exponential backoff on failure
- **Sandbox mode**: prompt injection defense for projects processing untrusted data
- Web dashboard for submitting tasks and monitoring progress
- Daily effectiveness reports with failure analysis and actionable suggestions
- Local image generation via ComfyUI (SDXL) for Ollama runner tasks

## Architecture

```
                    ┌─────────────────────────────────────────────────────┐
                    │                   EC2 Instance                      │
You (CLI/Web) ──►  │  SQS ──► clawd-runner  ──► claude -p (Sonnet)      │
                    │  SQS ──► codex-runner  ──► codex exec              │
                    └─────────────────────────────────────────────────────┘
                    ┌─────────────────────────────────────────────────────┐
                    │                  Local Machine                      │
                    │  SQS ──► ollama-runner ──► aider + ollama (local)  │
                    │                           + ComfyUI (image gen)    │
                    └─────────────────────────────────────────────────────┘
                                        │
                                        ├──► git push (triggers deploy)
                                        ├──► SES email (results)
                                        ├──► DynamoDB (task tracking)
                                        └──► SQS re-queue (autonomous mode)
```

**Three providers:**
- **Claude** (EC2): `claude -p` with Sonnet model, restricted tool set for token efficiency
- **Codex** (EC2): `codex exec` with full-auto mode
- **Ollama** (local): `aider` with any Ollama model — zero inference cost, runs on your GPU

Each provider has its own SQS queue and systemd daemon.

## Setup

### Prerequisites

- AWS CLI configured with appropriate permissions
- A Claude Code subscription (for `claude` CLI)
- An OpenAI API key (for Codex, optional)
- Ollama installed locally (for local runner, optional)

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

### 3. Set up Ollama runner (optional, local machine)

```bash
# Install ollama and pull a model
ollama pull qwen3.5:35b-a3b

# Install aider
pip install aider-chat

# Install the systemd user service
cp daemon/ollama-runner.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now ollama-runner
```

### 4. Add projects

Edit `config/projects.json`:

```json
{
  "my-project": {
    "repo": "git@github.com:you/my-project.git",
    "branch": "main",
    "autonomous": {
      "enabled": true,
      "goal": "Your autonomous goal here",
      "codex_goal": "Optional separate goal for Codex runs",
      "cooldown_minutes": 10,
      "effort": "medium",
      "sandbox": {
        "enabled": false,
        "allowed_paths": ["safe-dir/", "RESULTS.md"]
      }
    }
  }
}
```

### 5. Submit tasks

```bash
# Via CLI
./client/clawd my-project "Fix the login bug"
./client/clawd my-project "Add unit tests" --provider codex
./client/clawd my-project "Audit data quality" --provider ollama

# Use the autonomous goal from config
./client/clawd my-project --auto

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

**Per-provider goals**: Set `codex_goal` in config to give the Codex provider a different goal than Claude (e.g., Claude does visual polish while Codex does code cleanup).

## Sandbox Mode (Prompt Injection Defense)

When processing untrusted data (e.g., user-submitted content, scraped data), enable sandbox mode to prevent prompt injection from leading to unauthorized changes:

```json
"sandbox": {
  "enabled": true,
  "allowed_paths": ["audit/", "RESULTS.md", "TODO.md"]
}
```

When sandbox is enabled:
1. **Before the LLM runs**: push credentials are removed (`git remote set-url --push origin no-push`)
2. **After the LLM finishes**: all changed files are validated against `allowed_paths`
3. **If any file outside allowed paths was modified**: push is blocked, repo is reset, alert email is sent
4. **If clean**: push credentials are restored and changes are pushed normally

This provides two layers of defense — the LLM cannot push during execution, and the runner validates the diff before pushing.

## Token Optimization

The Claude runner is configured for token efficiency:

```bash
claude -p "$PROMPT" \
    --model sonnet \
    --effort "$EFFORT" \
    --tools "Bash,Edit,Read,Write,Glob,Grep"
```

- **`--model sonnet`**: Uses Sonnet instead of Opus for autonomous tasks
- **`--tools`**: Restricts to core tools only, excluding MCP, browser, agent delegation tools from the system prompt
- **`--effort medium`**: Reduces thinking budget for well-scoped tasks

## Credential Auth Sync

Claude Code uses OAuth tokens that expire. A local cron job syncs credentials to EC2:

```bash
# Add to your local crontab
0 */4 * * * /path/to/infrastructure/sync-auth.sh >> /tmp/clawd-sync-auth.log 2>&1
```

## Monitoring

- **Hourly reports**: SES email with daemon health, queue depth, auth status
- **Daily effectiveness reports**: Task success rate, failure analysis, actionable suggestions, auth health, autonomous loop status
- **Web dashboard**: Real-time task list with filtering by status/provider
- **Logs**: `journalctl -u clawd-runner -f` (EC2) or `journalctl --user -u ollama-runner -f` (local)

## Image Generation

The Ollama runner supports local image generation via ComfyUI. Include `[IMAGE: description]` in your prompt and the runner will generate SDXL images before passing the task to aider.

Requires ComfyUI running locally at `http://127.0.0.1:8188`.

## Cost

- EC2 t3a.medium: ~$20/month (on-demand)
- Claude Code: uses your existing subscription (no API costs)
- Codex: OpenAI API usage costs
- Ollama: **zero inference cost** (runs on your local GPU)
- SQS/DynamoDB/Lambda/S3: free tier eligible
- SES: pennies

## Teardown

```bash
./infrastructure/teardown.sh
```

## License

MIT
