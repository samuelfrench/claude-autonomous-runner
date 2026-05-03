# daemon/outreach/tests/test_tools_registry.py
"""Tests for the self-built tool registry."""
from outreach.tools_registry import ToolsRegistry, ToolStatus


def test_register_tool(dynamodb_table: str) -> None:
    reg = ToolsRegistry(table_name=dynamodb_table)
    reg.register(name="bluesky-post", purpose="post to Bluesky",
                 source_path="dynamic-tools/bluesky-post.py")
    tool = reg.get("bluesky-post")
    assert tool is not None
    assert tool["status"] == ToolStatus.EXPERIMENTAL.value
    assert tool["run_count"] == 0


def test_record_run_success(dynamodb_table: str) -> None:
    reg = ToolsRegistry(table_name=dynamodb_table)
    reg.register(name="bluesky-post", purpose="post", source_path="x")
    reg.record_run("bluesky-post", success=True)
    tool = reg.get("bluesky-post")
    assert tool["run_count"] == 1
    assert tool["success_count"] == 1


def test_promotes_after_5_successes(dynamodb_table: str) -> None:
    reg = ToolsRegistry(table_name=dynamodb_table)
    reg.register(name="bluesky-post", purpose="post", source_path="x")
    for _ in range(5):
        reg.record_run("bluesky-post", success=True)
    tool = reg.get("bluesky-post")
    assert tool["status"] == ToolStatus.STABLE.value


def test_no_promote_with_failures(dynamodb_table: str) -> None:
    reg = ToolsRegistry(table_name=dynamodb_table)
    reg.register(name="bluesky-post", purpose="post", source_path="x")
    for _ in range(4):
        reg.record_run("bluesky-post", success=True)
    reg.record_run("bluesky-post", success=False)
    tool = reg.get("bluesky-post")
    assert tool["status"] == ToolStatus.EXPERIMENTAL.value


def test_quarantine_after_3_consecutive_failures(dynamodb_table: str) -> None:
    reg = ToolsRegistry(table_name=dynamodb_table)
    reg.register(name="buggy-tool", purpose="x", source_path="y")
    for _ in range(3):
        reg.record_run("buggy-tool", success=False)
    tool = reg.get("buggy-tool")
    assert tool["status"] == ToolStatus.QUARANTINED.value


def test_list_stable_tools_only(dynamodb_table: str) -> None:
    reg = ToolsRegistry(table_name=dynamodb_table)
    reg.register(name="exp1", purpose="x", source_path="y")
    reg.register(name="stable1", purpose="x", source_path="y")
    for _ in range(5):
        reg.record_run("stable1", success=True)
    stable = list(reg.list_stable())
    names = {t["name"] for t in stable}
    assert names == {"stable1"}
