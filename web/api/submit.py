import json
import os
import uuid
from datetime import datetime, timezone

import boto3

dynamodb = boto3.resource("dynamodb")
sqs = boto3.client("sqs")
table = dynamodb.Table(os.environ["DYNAMO_TABLE"])

CLAUDE_QUEUE_URL = os.environ["CLAUDE_QUEUE_URL"]
CODEX_QUEUE_URL = os.environ["CODEX_QUEUE_URL"]
API_KEY = os.environ["API_KEY"]
VALID_PROJECTS = json.loads(os.environ.get("PROJECTS", "[]"))


def handler(event, context):
    # Auth check
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if headers.get("x-api-key") != API_KEY:
        return {"statusCode": 401, "body": json.dumps({"error": "Unauthorized"})}

    # CORS preflight
    if event.get("requestContext", {}).get("http", {}).get("method") == "OPTIONS":
        return {
            "statusCode": 200,
            "headers": cors_headers(),
            "body": "",
        }

    try:
        body = json.loads(event.get("body", "{}"))
    except json.JSONDecodeError:
        return response(400, {"error": "Invalid JSON"})

    project = body.get("project", "")
    provider = body.get("provider", "claude")
    prompt = body.get("prompt", "")

    if not project or not prompt:
        return response(400, {"error": "project and prompt are required"})
    if provider not in ("claude", "codex"):
        return response(400, {"error": "provider must be 'claude' or 'codex'"})
    if VALID_PROJECTS and project not in VALID_PROJECTS:
        return response(400, {"error": f"Unknown project: {project}"})

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    task_id = f"task-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}"

    # Write to DynamoDB
    table.put_item(
        Item={
            "task_id": task_id,
            "project": project,
            "provider": provider,
            "prompt": prompt,
            "status": "pending",
            "submitted_at": now,
        }
    )

    # Send to SQS
    queue_url = CODEX_QUEUE_URL if provider == "codex" else CLAUDE_QUEUE_URL
    sqs.send_message(
        QueueUrl=queue_url,
        MessageBody=json.dumps(
            {
                "project": project,
                "prompt": prompt,
                "task_id": task_id,
                "provider": provider,
                "submitted_at": now,
            }
        ),
    )

    return response(200, {"task_id": task_id, "status": "pending"})


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": cors_headers(),
        "body": json.dumps(body),
    }


def cors_headers():
    return {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type,x-api-key",
        "Access-Control-Allow-Methods": "POST,OPTIONS",
    }
