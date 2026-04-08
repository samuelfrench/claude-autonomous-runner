import json
import os

import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMO_TABLE"])
API_KEY = os.environ["API_KEY"]


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

    path = event.get("rawPath", "")
    params = event.get("queryStringParameters") or {}

    # GET /tasks/{task_id} — single task detail
    if path.startswith("/tasks/") and len(path.split("/")) == 3:
        task_id = path.split("/")[2]
        result = table.get_item(Key={"task_id": task_id})
        item = result.get("Item")
        if not item:
            return response(404, {"error": "Task not found"})
        return response(200, serialize_item(item))

    # GET /tasks — list tasks
    limit = min(int(params.get("limit", "50")), 200)
    provider_filter = params.get("provider")

    if provider_filter and provider_filter in ("claude", "codex"):
        # Query GSI by provider
        result = table.query(
            IndexName="provider-submitted-index",
            KeyConditionExpression=Key("provider").eq(provider_filter),
            ScanIndexForward=False,
            Limit=limit,
        )
    else:
        # Scan for all tasks, sorted client-side
        result = table.scan(Limit=limit)
        result["Items"].sort(key=lambda x: x.get("submitted_at", ""), reverse=True)

    items = [serialize_item(item) for item in result.get("Items", [])]

    # Optional status filter (applied post-query)
    status_filter = params.get("status")
    if status_filter:
        items = [i for i in items if i.get("status") == status_filter]

    return response(200, {"tasks": items, "count": len(items)})


def serialize_item(item):
    """Convert DynamoDB item to JSON-serializable dict."""
    result = {}
    for key, value in item.items():
        if isinstance(value, (int, float)):
            result[key] = value
        else:
            result[key] = str(value)
    return result


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
        "Access-Control-Allow-Methods": "GET,OPTIONS",
    }
