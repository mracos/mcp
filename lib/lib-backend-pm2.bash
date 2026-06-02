#!/usr/bin/env bash
# pm2 backend implementation.
#
# Generates an ecosystem.config.js from ~/.mcp-servers.json and proxies the
# backend vocabulary to `npx pm2 ...`.

_pm2_ecosystem_path() {
  echo "$DAEMON_DIR/ecosystem.config.js"
}

_pm2_generate_ecosystem() {
  require_jq
  ensure_file
  mkdir -p "$DAEMON_DIR"

  local ecosystem
  ecosystem=$(_pm2_ecosystem_path)

  local daemon_path npx_abs
  daemon_path=$(backend_env_path)
  npx_abs=$(resolve_command "npx") || true

  echo "module.exports = {" > "$ecosystem"
  echo "  apps: [" >> "$ecosystem"

  local first=true
  while IFS= read -r server; do
    [[ -z "$server" ]] && continue

    local type port cmd cmd_abs args_str env_json
    type=$(jq -r ".\"$server\".type" "$MCP_FILE")

    [[ "$type" != "stdio-http-proxy" ]] && continue

    port=$(jq -r ".\"$server\".port" "$MCP_FILE")
    cmd=$(jq -r ".\"$server\".command" "$MCP_FILE")
    cmd_abs=$(resolve_command "$cmd") || true
    args_str=$(jq -r ".\"$server\".args | join(\" \")" "$MCP_FILE")

    local proxy_args="mcp-proxy --port $port -- $cmd_abs $args_str"

    env_json=$(jq -c ".\"$server\".env // {}" "$MCP_FILE" | envsubst)
    env_json=$(echo "$env_json" | jq -c --arg p "$daemon_path" '. + {PATH: $p}')

    $first || echo "," >> "$ecosystem"
    first=false

    cat >> "$ecosystem" << EOF
    {
      name: 'mcp-$server',
      script: '$npx_abs',
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

backend_apply() {
  _pm2_generate_ecosystem >/dev/null
}

backend_start() {
  local name="${1:-}"
  local ecosystem
  ecosystem=$(_pm2_generate_ecosystem)
  echo "Generated $ecosystem"

  if [[ -n "$name" ]]; then
    npx pm2 start "$ecosystem" --only "mcp-$name"
  else
    npx pm2 start "$ecosystem"
  fi
}

backend_stop() {
  local name="${1:-}"
  if [[ -n "$name" ]]; then
    npx pm2 stop "mcp-$name"
  else
    npx pm2 stop all
  fi
}

backend_delete() {
  local name="$1"
  npx pm2 delete "mcp-$name" 2>/dev/null || true
}

backend_status() {
  npx pm2 list
}

backend_logs() {
  local name="${1:-}"
  if [[ -n "$name" ]]; then
    npx pm2 logs "mcp-$name"
  else
    npx pm2 logs
  fi
}

backend_server_status() {
  local name="$1"
  npx pm2 jlist 2>/dev/null \
    | jq -r ".[] | select(.name == \"mcp-$name\") | .pm2_env.status" 2>/dev/null \
    || echo ""
}
