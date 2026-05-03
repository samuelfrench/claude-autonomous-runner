"""Unit tests for the SES inbound parser Lambda's opt-out handling.

Run from repo root: `python -m pytest infrastructure/lambda/outreach-mail-parser/`.
"""
import importlib.util
import os
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location(
    "lambda_function", HERE / "lambda_function.py"
)
lf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lf)


@pytest.mark.parametrize("subject,body,expected", [
    ("STOP", "", True),
    ("re: pitch", "STOP", True),
    ("re: pitch", "stop", True),
    ("re: pitch", "Please unsubscribe me", True),
    ("re: pitch", "Do not contact me again", True),
    ("re: pitch", "do-not-contact", True),
    ("re: pitch", "Remove me from your list", True),
    ("re: pitch", "I had to stop by the apiary yesterday — fascinating piece, send draft", False),
    ("re: pitch", "Thanks, send the draft.", False),
    ("re: pitch", "", False),
])
def test_is_opt_out(subject, body, expected):
    assert lf.is_opt_out(subject, body) is expected


def test_is_opt_out_only_inspects_first_500_body_chars():
    body = "Thanks, send the draft.\n\n" + ("filler " * 100) + " STOP"
    assert lf.is_opt_out("re: pitch", body) is False


@pytest.mark.parametrize("raw,expected", [
    ("alice@example.com", "alice@example.com"),
    ("Alice Smith <alice@example.com>", "alice@example.com"),
    ("ALICE@EXAMPLE.COM", "alice@example.com"),
    ("  Bob  <bob@x.io>  ", "bob@x.io"),
    ("", ""),
])
def test_normalize_email(raw, expected):
    assert lf.normalize_email(raw) == expected


@mock_aws
def test_mark_do_not_contact_writes_authoritative_row_and_updates_existing_target():
    os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
    ddb = boto3.resource("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName="t",
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    table = ddb.Table("t")
    table.put_item(Item={
        "pk": "cold-target#bob@x.io", "sk": "metadata",
        "email": "bob@x.io", "status": "unsent", "name": "Bob",
    })

    lf.mark_do_not_contact(table, "bob@x.io", "stop-reply", "2026-04-30T12:00:00Z#abc")

    dnc = table.get_item(Key={"pk": "do-not-contact#bob@x.io", "sk": "metadata"})["Item"]
    assert dnc["email"] == "bob@x.io"
    assert dnc["reason"] == "stop-reply"
    assert dnc["source_inbound_sk"] == "2026-04-30T12:00:00Z#abc"

    target = table.get_item(Key={"pk": "cold-target#bob@x.io", "sk": "metadata"})["Item"]
    assert target["do_not_contact"] is True
    assert target["status"] == "do-not-contact"
    assert target["do_not_contact_reason"] == "stop-reply"


# ─── Bounce / DSN tests ────────────────────────────────────────────────


@pytest.mark.parametrize("from_addr,expected", [
    ("MAILER-DAEMON@amazonses.com", True),
    ("mailer-daemon@example.com", True),
    ("postmaster@gmail.com", True),
    ("Mail Delivery Subsystem <MAILER-DAEMON@example.com>", True),
    ("editor@example.com", False),
    ("sam@example.com", False),
    ("", False),
])
def test_is_dsn(from_addr, expected):
    assert lf.is_dsn(from_addr) is expected


def test_parse_dsn_gmail_5_1_1():
    """Gmail-style DSN for unknown user (5.1.1)."""
    raw = (
        b"From: MAILER-DAEMON@amazonses.com\r\n"
        b"To: hello@example.com\r\n"
        b"Subject: Delivery Status Notification (Failure)\r\n"
        b"Content-Type: multipart/report; report-type=delivery-status; "
        b'boundary="----=_Part_1"\r\n\r\n'
        b"------=_Part_1\r\n"
        b"Content-Type: text/plain\r\n\r\n"
        b"An error occurred.\r\n\r\n"
        b"------=_Part_1\r\n"
        b"Content-Type: message/delivery-status\r\n\r\n"
        b"Reporting-MTA: dns; amazonses.com\r\n\r\n"
        b"Action: failed\r\n"
        b"Final-Recipient: rfc822; pitches@example.com\r\n"
        b"Diagnostic-Code: smtp; 550-5.1.1 The email account that you tried to reach\r\n"
        b" 550-5.1.1 does not exist.\r\n"
        b"Status: 5.1.1\r\n\r\n"
        b"------=_Part_1--\r\n"
    )
    bounces = lf.parse_dsn(raw)
    assert len(bounces) == 1
    b = bounces[0]
    assert b["recipient"] == "pitches@example.com"
    assert b["status"] == "5.1.1"
    assert b["bounce_type"] == "hard"
    assert "550-5.1.1" in b["diagnostic_code"]


def test_parse_dsn_outlook_5_4_1():
    """Outlook/O365 DSN with access-denied 5.4.1."""
    raw = (
        b"From: postmaster@outlook.com\r\n"
        b"To: hello@example.com\r\n"
        b"Content-Type: multipart/report; report-type=delivery-status; "
        b'boundary="==XYZ"\r\n\r\n'
        b"--==XYZ\r\n"
        b"Content-Type: text/plain\r\n\r\n"
        b"failed\r\n\r\n"
        b"--==XYZ\r\n"
        b"Content-Type: message/delivery-status\r\n\r\n"
        b"Action: failed\r\n"
        b"Final-Recipient: rfc822; editor@example.com\r\n"
        b"Diagnostic-Code: smtp; 550 5.4.1 Recipient address rejected: Access denied.\r\n"
        b"Status: 5.4.1\r\n\r\n"
        b"--==XYZ--\r\n"
    )
    bounces = lf.parse_dsn(raw)
    assert len(bounces) == 1
    assert bounces[0]["recipient"] == "editor@example.com"
    assert bounces[0]["bounce_type"] == "hard"
    assert bounces[0]["status"] == "5.4.1"


def test_parse_dsn_soft_bounce_4_2_2():
    raw = (
        b"From: MAILER-DAEMON@example.com\r\n"
        b"Content-Type: multipart/report; report-type=delivery-status; "
        b'boundary="b1"\r\n\r\n'
        b"--b1\r\n"
        b"Content-Type: message/delivery-status\r\n\r\n"
        b"Action: delayed\r\n"
        b"Final-Recipient: rfc822; busy@example.com\r\n"
        b"Status: 4.2.2\r\n"
        b"Diagnostic-Code: smtp; 452 mailbox full\r\n\r\n"
        b"--b1--\r\n"
    )
    bounces = lf.parse_dsn(raw)
    assert len(bounces) == 1
    assert bounces[0]["bounce_type"] == "soft"
    assert bounces[0]["status"] == "4.2.2"


def test_parse_dsn_no_recipient_returns_empty():
    raw = b"From: MAILER-DAEMON@x\r\n\r\nSomething went wrong but no recipient.\r\n"
    assert lf.parse_dsn(raw) == []


def _make_table():
    """Helper: create a moto DDB table with the table-of-record schema."""
    ddb = boto3.resource("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName="t",
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    return ddb.Table("t")


@mock_aws
def test_mark_bounced_hard_writes_dnc_immediately():
    os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
    table = _make_table()
    lf.mark_bounced(
        table, "x@example.com", "hard", "5.1.1",
        "smtp; 550 no such user", "2026-05-01T00:00:00Z#sk1",
    )
    dnc = table.get_item(
        Key={"pk": "do-not-contact#x@example.com", "sk": "metadata"}
    ).get("Item")
    assert dnc is not None
    assert dnc["reason"] == "hard-bounce-5.1.1"
    bounces = table.query(
        KeyConditionExpression="pk = :pk",
        ExpressionAttributeValues={":pk": "bounce#x@example.com"},
    ).get("Items", [])
    assert len(bounces) == 1
    assert bounces[0]["bounce_type"] == "hard"


@mock_aws
def test_mark_bounced_soft_does_not_dnc_below_threshold():
    os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
    table = _make_table()
    # 2 soft bounces — under the threshold of 3
    for i in range(2):
        lf.mark_bounced(
            table, "y@example.com", "soft", "4.2.2",
            "smtp; mailbox full", f"sk{i}",
        )
    dnc = table.get_item(
        Key={"pk": "do-not-contact#y@example.com", "sk": "metadata"}
    ).get("Item")
    assert dnc is None
    bounces = table.query(
        KeyConditionExpression="pk = :pk",
        ExpressionAttributeValues={":pk": "bounce#y@example.com"},
    ).get("Items", [])
    assert len(bounces) == 2


@mock_aws
def test_mark_bounced_soft_promotes_to_dnc_at_threshold():
    os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
    table = _make_table()
    for i in range(3):
        lf.mark_bounced(
            table, "z@example.com", "soft", "4.2.2",
            "smtp; mailbox full", f"sk{i}",
        )
    dnc = table.get_item(
        Key={"pk": "do-not-contact#z@example.com", "sk": "metadata"}
    ).get("Item")
    assert dnc is not None
    assert "soft-bounce-threshold" in dnc["reason"]
    assert "3-in-7d" in dnc["reason"]


@mock_aws
def test_mark_bounced_handles_empty_recipient():
    os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
    table = _make_table()
    # Should not raise; should not write anything
    lf.mark_bounced(table, "", "hard", "5.1.1", "x", "sk")
    lf.mark_bounced(table, None, "hard", "5.1.1", "x", "sk")
    items = table.scan().get("Items", [])
    assert items == []


@mock_aws
def test_mark_do_not_contact_does_not_create_placeholder_target_row():
    """If someone proactively emails STOP without ever being targeted, we still
    write the authoritative do-not-contact# row but must NOT fabricate a
    cold-target# row for them.
    """
    os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
    ddb = boto3.resource("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName="t",
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    table = ddb.Table("t")

    lf.mark_do_not_contact(table, "stranger@x.io", "stop-reply", "sk")

    assert "Item" in table.get_item(Key={"pk": "do-not-contact#stranger@x.io", "sk": "metadata"})
    assert "Item" not in table.get_item(Key={"pk": "cold-target#stranger@x.io", "sk": "metadata"})
