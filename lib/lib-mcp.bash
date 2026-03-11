#!/usr/bin/env bash
# Shared helpers for mcp subcommands

MCP_FILE="${MCP_FILE:-$HOME/.mcp-servers.json}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
CODEX_CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
DAEMON_DIR="${DAEMON_DIR:-$HOME/.local/share/mcp}"
CODEX_MCP_BEGIN="# BEGIN managed by mcp"
CODEX_MCP_END="# END managed by mcp"

require_jq() {
  command -v jq &>/dev/null || { echo "Error: jq is required"; exit 1; }
}

ensure_file() {
  [[ -f "$MCP_FILE" ]] || echo '{}' > "$MCP_FILE"
}

extract_codex_managed_block() {
  [[ -f "$CODEX_CONFIG" ]] || return 0
  awk -v begin="$CODEX_MCP_BEGIN" -v end="$CODEX_MCP_END" '
    $0 == begin {print; in_block=1; next}
    in_block == 1 {print}
    $0 == end {exit}
  ' "$CODEX_CONFIG"
}

is_codex_server_applied() {
  local name="$1"
  [[ -f "$CODEX_CONFIG" ]] || return 1
  awk -v begin="$CODEX_MCP_BEGIN" -v end="$CODEX_MCP_END" -v section="[mcp_servers.$name]" '
    $0 == begin {in_block=1; next}
    $0 == end {in_block=0}
    in_block == 1 && $0 == section {found=1; exit}
    END {exit found ? 0 : 1}
  ' "$CODEX_CONFIG"
}

# Get daemon status: online, errored, stopped, or empty if not registered
get_daemon_status() {
  local name="$1"
  npx pm2 jlist 2>/dev/null | jq -r ".[] | select(.name == \"mcp-$name\") | .pm2_env.status" 2>/dev/null || echo ""
}

# Get the expected config for a server (applying transformations like mcp-apply does)
get_expected_config() {
  local name="$1"
  local type
  type=$(jq -r ".\"$name\".type" "$MCP_FILE")

  if [[ "$type" == "stdio-http-proxy" ]]; then
    local port daemon_status
    port=$(jq -r ".\"$name\".port" "$MCP_FILE")
    daemon_status=$(get_daemon_status "$name")

    if [[ "$daemon_status" == "online" ]]; then
      jq -n --arg url "http://localhost:$port/sse" '{type: "sse", url: $url}'
    else
      jq ".\"$name\" | {type: \"stdio\", command, args, env}" "$MCP_FILE"
    fi
  else
    jq ".\"$name\"" "$MCP_FILE"
  fi
}

build_codex_mcp_block() {
  require_jq
  ensure_file

  jq -r '
    def common_lines:
      [
        (if has("startup_timeout_sec") then "startup_timeout_sec = \(.startup_timeout_sec | tojson)" else empty end),
        (if has("tool_timeout_sec") then "tool_timeout_sec = \(.tool_timeout_sec | tojson)" else empty end),
        (if has("enabled") then "enabled = \(.enabled | tojson)" else empty end),
        (if has("required") then "required = \(.required | tojson)" else empty end),
        (if has("enabled_tools") then "enabled_tools = \(.enabled_tools | tojson)" else empty end),
        (if has("disabled_tools") then "disabled_tools = \(.disabled_tools | tojson)" else empty end),
        (if has("env_vars") then "env_vars = \(.env_vars | tojson)" else empty end),
        (if has("bearer_token_env_var") then "bearer_token_env_var = \(.bearer_token_env_var | tojson)" else empty end)
      ];
    def dict_lines($table):
      to_entries[] | "[\($table)]", "\(.key) = \(.value | tojson)";
    def server_lines($name):
      . as $cfg
      | (if ($cfg.type // "http") == "stdio-http-proxy" then
          "[mcp_servers.\($name)]",
          "url = \("http://localhost:\($cfg.port)/mcp" | tojson)"
        elif ($cfg.type // "http") == "stdio" then
          "[mcp_servers.\($name)]",
          "command = \($cfg.command | tojson)",
          (if has("args") then "args = \($cfg.args | tojson)" else empty end)
        else
          "[mcp_servers.\($name)]",
          "url = \($cfg.url | tojson)"
        end),
        (. | common_lines[]),
        (if (($cfg.type // "http") == "stdio") and has("env") then .env | dict_lines("mcp_servers.\($name).env") else empty end),
        (if has("http_headers") then .http_headers | dict_lines("mcp_servers.\($name).http_headers") else empty end),
        (if has("env_http_headers") then .env_http_headers | dict_lines("mcp_servers.\($name).env_http_headers") else empty end);
    [
      "'"$CODEX_MCP_BEGIN"'",
      (
        to_entries
        | sort_by(.key)
        | map(. as $entry | [$entry.value | server_lines($entry.key)] | join("\n"))
        | join("\n\n")
      ),
      "'"$CODEX_MCP_END"'"
    ] | join("\n")
  ' "$MCP_FILE"
}

sync_codex_config() {
  ensure_file

  local codex_dir
  codex_dir=$(dirname "$CODEX_CONFIG")
  mkdir -p "$codex_dir"
  [[ -f "$CODEX_CONFIG" ]] || touch "$CODEX_CONFIG"

  local tmp existing managed
  tmp="${CODEX_CONFIG}.tmp"
  existing="${CODEX_CONFIG}.clean"
  managed="${CODEX_CONFIG}.managed"

  awk -v begin="$CODEX_MCP_BEGIN" -v end="$CODEX_MCP_END" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    skip == 0 {print}
  ' "$CODEX_CONFIG" > "$existing"

  build_codex_mcp_block > "$managed"

  {
    cat "$existing"
    [[ -s "$existing" ]] && echo
    echo
    cat "$managed"
    echo
  } > "$tmp"

  mv "$tmp" "$CODEX_CONFIG"
  rm -f "$existing" "$managed"
}

# Generate ecosystem.config.js from mcp-servers.json
generate_ecosystem() {
  require_jq
  ensure_file
  mkdir -p "$DAEMON_DIR"

  local ecosystem="$DAEMON_DIR/ecosystem.config.js"

  echo "module.exports = {" > "$ecosystem"
  echo "  apps: [" >> "$ecosystem"

  local first=true
  while IFS= read -r server; do
    [[ -z "$server" ]] && continue

    local type port cmd args_json env_json
    type=$(jq -r ".\"$server\".type" "$MCP_FILE")

    [[ "$type" != "stdio-http-proxy" ]] && continue

    port=$(jq -r ".\"$server\".port" "$MCP_FILE")
    cmd=$(jq -r ".\"$server\".command" "$MCP_FILE")
    args_json=$(jq -r ".\"$server\".args | join(\" \")" "$MCP_FILE")

    local proxy_args="mcp-proxy --port $port -- $cmd $args_json"

    env_json=$(jq -c ".\"$server\".env // {}" "$MCP_FILE" | envsubst)

    $first || echo "," >> "$ecosystem"
    first=false

    cat >> "$ecosystem" << EOF
    {
      name: 'mcp-$server',
      script: 'npx',
      args: '$proxy_args',
      env: $env_json,
      max_restarts: 10,
      min_uptime: 5000,
      restart_delay: 1000,
      exp_backoff_restart_delay: 500
    }
EOF
  done < <(jq -r 'keys[]' "$MCP_FILE")

  echo "  ]" >> "$ecosystem"
  echo "}" >> "$ecosystem"

  echo "$ecosystem"
}
