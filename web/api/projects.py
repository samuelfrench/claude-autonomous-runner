import json
import os

API_KEY = os.environ["API_KEY"]
PROJECTS = json.loads(os.environ.get("PROJECTS", "[]"))


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

    return {
        "statusCode": 200,
        "headers": cors_headers(),
        "body": json.dumps({"projects": PROJECTS}),
    }


def cors_headers():
    return {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type,x-api-key",
        "Access-Control-Allow-Methods": "GET,OPTIONS",
    }
