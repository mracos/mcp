#!/usr/bin/env bats

load "$PROJECT_ROOT/test/test_helper.bash"

MCP_CLI="$PROJECT_ROOT/files/shell/bin/mcp"

setup() {
  TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export MCP_FILE="$TEST_HOME/.claude/mcp-servers.json"
  export HOOK_FILE="$PROJECT_ROOT/hooks/post-link/ai.sh"
  mkdir -p "$TEST_HOME/.claude"
}

teardown() {
  rm -rf "$TEST_HOME"
}

@test "mcp CLI exists" {
  assert [ -f "$MCP_CLI" ]
}

@test "mcp CLI is executable" {
  assert [ -x "$MCP_CLI" ]
}

@test "mcp --help shows usage" {
  run "$MCP_CLI" --help
  assert_success
  assert_output --partial "USAGE"
  assert_output --partial "mcp list"
  assert_output --partial "mcp add"
}

@test "mcp without args shows usage" {
  run "$MCP_CLI"
  assert_success
  assert_output --partial "USAGE"
}

@test "mcp list works with empty file" {
  echo '{}' > "$MCP_FILE"

  run "$MCP_CLI" list
  assert_success
  assert_output --partial "MCP Servers"
}

@test "mcp list shows configured servers" {
  echo '{"test-server": {"type": "http", "url": "https://example.com"}}' > "$MCP_FILE"

  run "$MCP_CLI" list
  assert_success
  assert_output --partial "test-server"
  assert_output --partial "http"
}

@test "mcp add creates HTTP server" {
  echo '{}' > "$MCP_FILE"
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" add myserver https://example.com/mcp
  assert_success

  run jq -e '.myserver.type' "$MCP_FILE"
  assert_success
  assert_output '"http"'

  run jq -e '.myserver.url' "$MCP_FILE"
  assert_success
  assert_output '"https://example.com/mcp"'
}

@test "mcp add creates stdio server" {
  echo '{}' > "$MCP_FILE"
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" add mytool -- npx -y @example/mcp
  assert_success

  run jq -e '.mytool.type' "$MCP_FILE"
  assert_success
  assert_output '"stdio"'

  run jq -e '.mytool.command' "$MCP_FILE"
  assert_success
  assert_output '"npx"'
}

@test "mcp remove deletes server" {
  echo '{"myserver": {"type": "http", "url": "https://example.com"}}' > "$MCP_FILE"
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" remove myserver
  assert_success

  run jq -e '.myserver' "$MCP_FILE"
  assert_failure
}

@test "mcp remove fails for non-existent server" {
  echo '{}' > "$MCP_FILE"

  run "$MCP_CLI" remove nonexistent
  assert_failure
  assert_output --partial "not found"
}

@test "mcp show displays server config" {
  echo '{"myserver": {"type": "http", "url": "https://example.com"}}' > "$MCP_FILE"

  run "$MCP_CLI" show myserver
  assert_success
  assert_output --partial "http"
  assert_output --partial "https://example.com"
}

@test "mcp show fails for non-existent server" {
  echo '{}' > "$MCP_FILE"

  run "$MCP_CLI" show nonexistent
  assert_failure
  assert_output --partial "not found"
}

@test "mcp apply merges into claude.json" {
  cp "$PROJECT_ROOT/files/ai/.claude/mcp-servers.json" "$MCP_FILE"
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" apply
  assert_success
  assert_output --partial "Merged"

  run jq -e '.mcpServers.notion' "$HOME/.claude.json"
  assert_success
}

@test "unknown command shows error" {
  run "$MCP_CLI" invalidcmd
  assert_failure
  assert_output --partial "Unknown command"
}
