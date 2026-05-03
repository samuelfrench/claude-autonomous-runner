# daemon/outreach/tests/test_config.py
"""Verify config module exports the expected constants."""
from outreach import config


def test_table_name() -> None:
    assert config.DDB_TABLE == "clawd-bot-outreach"


def test_dryrun_table_name() -> None:
    assert config.DDB_TABLE_DRYRUN == "clawd-bot-outreach-dryrun"


def test_region() -> None:
    assert config.AWS_REGION == "us-east-1"


def test_email_addresses() -> None:
    assert config.EMAIL_FROM == "hello@example.com"
    assert config.EMAIL_REPLY_TO == "replies@example.com"
    assert config.EMAIL_SIGNUPS == "signups@example.com"


def test_ssm_paths() -> None:
    assert config.SSM_MODEL_POLICY == "/clawd-bot/outreach/model-policy"
    assert config.SSM_PREFIX == "/clawd-bot/outreach/"


def test_s3_bucket() -> None:
    assert config.S3_INBOUND_BUCKET == "clawd-bot-outreach-mail"


def test_alert_email() -> None:
    assert config.ALERT_EMAIL == "admin@example.com"
