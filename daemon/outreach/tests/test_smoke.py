# daemon/outreach/tests/test_smoke.py
"""Verify pytest + moto plumbing works."""
import boto3


def test_dynamodb_fixture_works(dynamodb_table: str) -> None:
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    resp = ddb.describe_table(TableName=dynamodb_table)
    assert resp["Table"]["TableStatus"] == "ACTIVE"


def test_ses_fixture_works(ses_client: object) -> None:
    resp = ses_client.list_identities()
    assert "example.com" in resp["Identities"]


def test_ssm_fixture_works(ssm_params: object) -> None:
    resp = ssm_params.get_parameter(Name="/clawd-bot/outreach/model-policy")
    assert resp["Parameter"]["Value"] == "opus-for-high-stakes"
