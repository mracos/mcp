#!/usr/bin/env bats

load "$PROJECT_ROOT/test/test_helper.bash"

MCP_CLI="$PROJECT_ROOT/bin/mcp"

setup() {
  TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export MCP_FILE="$TEST_HOME/mcp-servers.json"
  export DAEMON_DIR="$TEST_HOME/.local/share/mcp"
  export CODEX_CONFIG="$TEST_HOME/.codex/config.toml"
  export MCP_DAEMON_WAIT=0

  mkdir -p "$TEST_HOME/.claude"
  mkdir -p "$DAEMON_DIR"

  # Create mock bin directory
  MOCK_BIN="$TEST_HOME/mock-bin"
  mkdir -p "$MOCK_BIN"

  # Mock npx to handle pm2 commands without side effects
  cat > "$MOCK_BIN/npx" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "pm2" ]]; then
  shift
  case "$1" in
    jlist)
      if [[ -f "$HOME/.mock-pm2-state" ]]; then
        cat "$HOME/.mock-pm2-state"
      else
        echo '[]'
      fi
      ;;
    start)
      echo "mock: pm2 start $*" >> "$HOME/.mock-pm2-log"
      ;;
    stop|delete)
      echo "mock: pm2 $*" >> "$HOME/.mock-pm2-log"
      ;;
    list)
      echo "mock: pm2 list"
      ;;
    logs)
      shift
      echo "mock: pm2 logs $*"
      ;;
    *)
      echo "mock: pm2 $*" >> "$HOME/.mock-pm2-log"
      ;;
  esac
  exit 0
fi
echo "mock: npx $*" # non-pm2 npx calls (shouldn't happen in mcp)
MOCK
  chmod +x "$MOCK_BIN/npx"

  export PATH="$MOCK_BIN:$PATH"
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
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" list
  assert_success
}

@test "mcp list shows configured servers with sync status" {
  echo '{"test-server": {"type": "http", "url": "https://example.com"}}' > "$MCP_FILE"
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" list
  assert_success
  assert_output --partial "test-server"
  assert_output --partial "http"
  # Not synced yet, should show ~ and prompt to apply
  assert_output --partial "~"
  assert_output --partial "applied: none"
  assert_output --partial "mcp apply"
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

@test "mcp add --help shows usage instead of creating server" {
  echo '{}' > "$MCP_FILE"
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" add --help
  assert_success
  assert_output --partial "USAGE"
  refute_output --partial "Added"
}

@test "mcp add creates stdio server with env vars" {
  echo '{}' > "$MCP_FILE"
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" add --no-apply slack --env SLACK_TOKEN=xoxc-123 --env SLACK_COOKIE=xoxd-456 -- npx -y slack-mcp-server@latest --transport stdio
  assert_success

  run jq -e '.slack.type' "$MCP_FILE"
  assert_success
  assert_output '"stdio"'

  run jq -e '.slack.env.SLACK_TOKEN' "$MCP_FILE"
  assert_success
  assert_output '"xoxc-123"'

  run jq -e '.slack.env.SLACK_COOKIE' "$MCP_FILE"
  assert_success
  assert_output '"xoxd-456"'

  run jq -e '.slack.command' "$MCP_FILE"
  assert_success
  assert_output '"npx"'

  run jq -e '.slack.args[0]' "$MCP_FILE"
  assert_success
  assert_output '"-y"'
}

@test "mcp add creates stdio server without env when not provided" {
  echo '{}' > "$MCP_FILE"
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" add --no-apply mytool -- npx -y @example/mcp
  assert_success

  run jq -e '.mytool.env' "$MCP_FILE"
  assert_failure
}

@test "mcp remove --help shows usage instead of failing" {
  run "$MCP_CLI" remove --help
  assert_success
  assert_output --partial "USAGE"
  refute_output --partial "not found"
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

@test "mcp add --no-apply skips apply" {
  echo '{}' > "$MCP_FILE"
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" add --no-apply myserver https://example.com/mcp
  assert_success
  assert_output --partial "Added"
  refute_output --partial "Merged"

  # Server should not be in claude.json
  run jq -e '.mcpServers.myserver' "$HOME/.claude.json"
  assert_failure
}

@test "mcp remove --no-apply skips apply" {
  echo '{"myserver": {"type": "http", "url": "https://example.com"}}' > "$MCP_FILE"
  echo '{"mcpServers": {"myserver": {"type": "http", "url": "https://example.com"}}}' > "$HOME/.claude.json"

  run "$MCP_CLI" remove --no-apply myserver
  assert_success
  assert_output --partial "Removed"
  refute_output --partial "Merged"

  # Server should still be in claude.json (orphan)
  run jq -e '.mcpServers.myserver' "$HOME/.claude.json"
  assert_success
}

@test "mcp remove stops daemon for stdio-http-proxy server" {
  cat > "$MCP_FILE" << 'EOF'
{
  "myproxy": {
    "type": "stdio-http-proxy",
    "command": "npx",
    "args": ["-y", "@example/mcp"],
    "port": 8081
  }
}
EOF
  echo '{}' > "$HOME/.claude.json"

  # Mock daemon as online
  echo '[{"name": "mcp-myproxy", "pm2_env": {"status": "online"}}]' > "$HOME/.mock-pm2-state"

  run "$MCP_CLI" remove --no-apply myproxy
  assert_success
  assert_output --partial "Stopping daemon"
  assert_output --partial "Removed"

  # Verify pm2 delete was called
  run cat "$HOME/.mock-pm2-log"
  assert_output --partial "pm2 delete mcp-myproxy"
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
  # Use a simple test config instead of the real one (which has stdio-http-proxy)
  cat > "$MCP_FILE" << 'EOF'
{
  "notion": {
    "type": "http",
    "url": "https://mcp.notion.com/mcp"
  }
}
EOF
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" apply
  assert_success
  assert_output --partial "Merged"

  run jq -e '.mcpServers.notion' "$HOME/.claude.json"
  assert_success

  run grep -n "^\[mcp_servers\.notion\]$" "$CODEX_CONFIG"
  assert_success
  run grep -n '^url = "https://mcp\.notion\.com/mcp"$' "$CODEX_CONFIG"
  assert_success
}

@test "unknown command shows error" {
  run "$MCP_CLI" invalidcmd
  assert_failure
  assert_output --partial "Unknown command"
}

# Daemon command tests

@test "mcp daemon without subcommand shows pm2 list" {
  echo '{}' > "$MCP_FILE"

  run "$MCP_CLI" daemon
  assert_success
  assert_output --partial "mock: pm2 list"
}

@test "mcp daemon unknown subcommand shows error" {
  run "$MCP_CLI" daemon invalid
  assert_failure
  assert_output --partial "Unknown daemon subcommand"
}

@test "mcp logs invokes pm2 logs" {
  run "$MCP_CLI" logs
  assert_success
  assert_output --partial "mock: pm2 logs"
}

@test "mcp logs with name invokes pm2 logs for that server" {
  run "$MCP_CLI" logs myserver
  assert_success
  assert_output --partial "mock: pm2 logs mcp-myserver"
}

# stdio-http-proxy type tests

@test "mcp list shows stdio-http-proxy servers with daemon status" {
  cat > "$MCP_FILE" << 'EOF'
{
  "myproxy": {
    "type": "stdio-http-proxy",
    "command": "npx",
    "args": ["-y", "@example/mcp"],
    "port": 8081
  }
}
EOF
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" list
  assert_success
  assert_output --partial "myproxy"
  assert_output --partial "stdio-http-proxy"
  assert_output --partial "daemon not started"
}

@test "mcp list shows synced status after apply" {
  cat > "$MCP_FILE" << 'EOF'
{
  "myhttp": {
    "type": "http",
    "url": "https://example.com/mcp"
  }
}
EOF
  echo '{}' > "$HOME/.claude.json"

  "$MCP_CLI" apply

  run "$MCP_CLI" list
  assert_success
  assert_output --partial "✓"
  assert_output --partial "applied: claude,codex"
  refute_output --partial "mcp apply"
}

@test "mcp list shows orphan servers in claude.json" {
  echo '{}' > "$MCP_FILE"
  cat > "$HOME/.claude.json" << 'EOF'
{
  "mcpServers": {
    "orphan": {
      "type": "http",
      "url": "https://example.com/mcp"
    }
  }
}
EOF

  run "$MCP_CLI" list
  assert_success
  assert_output --partial "orphan"
  assert_output --partial "orphan in claude.json"
}

@test "mcp apply attempts to start daemon for stdio-http-proxy" {
  cat > "$MCP_FILE" << 'EOF'
{
  "myproxy": {
    "type": "stdio-http-proxy",
    "command": "npx",
    "args": ["-y", "@example/mcp"],
    "port": 8081
  }
}
EOF
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" apply
  assert_success
  assert_output --partial "Starting daemon for 'myproxy'"
  assert_output --partial "Merged"

  # Verify pm2 start was called
  run cat "$HOME/.mock-pm2-log"
  assert_output --partial "pm2 start"
  assert_output --partial "mcp-myproxy"
}

@test "mcp apply uses sse when daemon is online" {
  cat > "$MCP_FILE" << 'EOF'
{
  "myproxy": {
    "type": "stdio-http-proxy",
    "command": "npx",
    "args": ["-y", "@example/mcp"],
    "port": 8081
  }
}
EOF
  echo '{}' > "$HOME/.claude.json"

  # Mock daemon as online
  echo '[{"name": "mcp-myproxy", "pm2_env": {"status": "online"}}]' > "$HOME/.mock-pm2-state"

  run "$MCP_CLI" apply
  assert_success
  assert_output --partial "myproxy → http://localhost:8081/sse (daemon online)"

  # Should be sse type in claude.json
  run jq -e '.mcpServers.myproxy.type' "$HOME/.claude.json"
  assert_success
  assert_output '"sse"'
}

@test "mcp apply always uses sse for stdio-http-proxy even when daemon stopped" {
  cat > "$MCP_FILE" << 'EOF'
{
  "myproxy": {
    "type": "stdio-http-proxy",
    "command": "npx",
    "args": ["-y", "@example/mcp"],
    "port": 8081
  }
}
EOF
  echo '{}' > "$HOME/.claude.json"

  # Mock daemon as stopped
  echo '[{"name": "mcp-myproxy", "pm2_env": {"status": "stopped"}}]' > "$HOME/.mock-pm2-state"

  run "$MCP_CLI" apply
  assert_success
  assert_output --partial "myproxy → http://localhost:8081/sse (daemon stopped)"

  # Should still be sse type (no fallback)
  run jq -e '.mcpServers.myproxy.type' "$HOME/.claude.json"
  assert_success
  assert_output '"sse"'

  run grep -n '^url = "http://localhost:8081/mcp"$' "$CODEX_CONFIG"
  assert_success
}

@test "mcp apply passes through http type unchanged" {
  cat > "$MCP_FILE" << 'EOF'
{
  "myhttp": {
    "type": "http",
    "url": "https://example.com/mcp"
  }
}
EOF
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" apply
  assert_success

  run jq -e '.mcpServers.myhttp.type' "$HOME/.claude.json"
  assert_success
  assert_output '"http"'

  run jq -e '.mcpServers.myhttp.url' "$HOME/.claude.json"
  assert_success
  assert_output '"https://example.com/mcp"'
}

@test "mcp apply writes stdio servers to codex config" {
  cat > "$MCP_FILE" << 'EOF'
{
  "mytool": {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "@example/mcp"],
    "env": {
      "API_KEY": "${MY_API_KEY}"
    }
  }
}
EOF
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" apply
  assert_success

  run grep -n "^\[mcp_servers\.mytool\]$" "$CODEX_CONFIG"
  assert_success
  run grep -n '^command = "npx"$' "$CODEX_CONFIG"
  assert_success
  run grep -nF 'args = ["-y","@example/mcp"]' "$CODEX_CONFIG"
  assert_success
  run grep -n "^\[mcp_servers\.mytool\.env\]$" "$CODEX_CONFIG"
  assert_success
  run grep -nF 'API_KEY = "${MY_API_KEY}"' "$CODEX_CONFIG"
  assert_success
}

@test "mcp apply does not write env table for stdio-http-proxy codex entries" {
  cat > "$MCP_FILE" << 'EOF'
{
  "readwise": {
    "type": "stdio-http-proxy",
    "command": "npx",
    "args": ["-y", "@iflow-mcp/readwise-mcp-enhanced"],
    "env": {
      "READWISE_TOKEN": "${READWISE_ACCESS_TOKEN}"
    },
    "port": 8081
  }
}
EOF
  echo '{}' > "$HOME/.claude.json"

  run "$MCP_CLI" apply
  assert_success

  run grep -n "^\[mcp_servers\.readwise\]$" "$CODEX_CONFIG"
  assert_success
  run grep -n '^url = "http://localhost:8081/mcp"$' "$CODEX_CONFIG"
  assert_success
  run grep -n "^\[mcp_servers\.readwise\.env\]$" "$CODEX_CONFIG"
  assert_failure
}

# Ecosystem file generation tests

@test "mcp daemon start generates ecosystem.config.js" {
  cat > "$MCP_FILE" << 'EOF'
{
  "test": {
    "type": "stdio-http-proxy",
    "command": "npx",
    "args": ["-y", "@test/mcp"],
    "port": 8081
  }
}
EOF

  run "$MCP_CLI" daemon start
  assert_success

  # Check file was created
  assert [ -f "$DAEMON_DIR/ecosystem.config.js" ]

  # Check content
  run cat "$DAEMON_DIR/ecosystem.config.js"
  assert_output --partial "module.exports"
  assert_output --partial "mcp-test"
  assert_output --partial "mcp-proxy"
  assert_output --partial "8081"
}
