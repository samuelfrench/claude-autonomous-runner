# daemon/outreach/tests/conftest.py
"""Shared pytest fixtures — mocked AWS services via moto.

Design: a single function-scoped `aws_mock` fixture opens one `mock_aws()`
context. All service fixtures depend on it (no nesting), so a test that
requests multiple services (DynamoDB + SSM, etc.) sees a unified mocked
environment where resources created in any fixture are visible to all.
"""
import os
from typing import Iterator

import boto3
import pytest
from moto import mock_aws


@pytest.fixture(autouse=True)
def aws_env() -> Iterator[None]:
    """Set fake AWS creds so boto3 doesn't try real ones."""
    saved = {k: os.environ.get(k) for k in [
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
        "AWS_DEFAULT_REGION", "AWS_SESSION_TOKEN",
    ]}
    os.environ["AWS_ACCESS_KEY_ID"] = "testing"
    os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
    os.environ["AWS_SESSION_TOKEN"] = "testing"
    os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
    yield
    for k, v in saved.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v


@pytest.fixture
def aws_mock() -> Iterator[None]:
    """Open a single moto mock_aws context shared by all service fixtures.

    Service fixtures (`dynamodb_table`, `ses_client`, etc.) declare this as
    a dependency so resources created in any fixture are visible across all
    of them within the same test.
    """
    with mock_aws():
        yield


@pytest.fixture
def dynamodb_table(aws_mock: None) -> str:
    """Create the clawd-bot-outreach table in moto, return table name."""
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName="clawd-bot-outreach",
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "S"},
            {"AttributeName": "status", "AttributeType": "S"},
        ],
        GlobalSecondaryIndexes=[{
            "IndexName": "status-index",
            "KeySchema": [
                {"AttributeName": "status", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            "Projection": {"ProjectionType": "ALL"},
        }],
        BillingMode="PAY_PER_REQUEST",
    )
    return "clawd-bot-outreach"


@pytest.fixture
def ses_client(aws_mock: None) -> object:
    """Mock SES client with a verified example.com identity."""
    client = boto3.client("ses", region_name="us-east-1")
    client.verify_domain_identity(Domain="example.com")
    return client


@pytest.fixture
def s3_bucket(aws_mock: None) -> str:
    """Create the inbound mail bucket in moto, return bucket name."""
    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket="clawd-bot-outreach-mail")
    return "clawd-bot-outreach-mail"


@pytest.fixture
def ssm_params(aws_mock: None) -> object:
    """Pre-populate SSM with the model-policy parameter."""
    ssm = boto3.client("ssm", region_name="us-east-1")
    ssm.put_parameter(
        Name="/clawd-bot/outreach/model-policy",
        Value="opus-for-high-stakes",
        Type="String",
    )
    return ssm
