#!/usr/bin/env bash
# launchd backend implementation: shells out to the `launcher` CLI from
# https://github.com/mracos/launcher.

if ! command -v launcher >/dev/null 2>&1; then
  echo "Error: MCP_BACKEND=launchd requires the 'launcher' CLI to be in PATH" >&2
  echo "       Install from https://github.com/mracos/launcher" >&2
  exit 1
fi

# Scope launcher operations to mcp's domain. These exports are inherited by
# every launcher subprocess we spawn but do not leak outside this bash process.
export LAUNCHER_PREFIX="${MCP_LAUNCHD_PREFIX:-mcp}"
export LAUNCHER_DIR="${MCP_LAUNCHD_DIR:-$DAEMON_DIR}"
export LAUNCHER_INSTALL_DIR="${MCP_LAUNCHD_INSTALL_DIR:-$HOME/Library/LaunchAgents}"

_launchd_log_dir() {
  echo "$DAEMON_DIR/logs"
}

_launchd_plist_path() {
  echo "$LAUNCHER_DIR/${LAUNCHER_PREFIX}.${1}.plist"
}

# Build the command string passed to `launcher new`. Wraps the invocation with
# `/usr/bin/env PATH=...` so child spawns resolve tools without depending on
# the launchd inherited environment.
_launchd_command_for() {
  local server="$1"
  local port cmd cmd_abs args_str npx_abs daemon_path

  port=$(jq -r ".\"$server\".port" "$MCP_FILE")
  cmd=$(jq -r ".\"$server\".command" "$MCP_FILE")
  cmd_abs=$(resolve_command "$cmd") || true
  args_str=$(jq -r ".\"$server\".args | join(\" \")" "$MCP_FILE")
  npx_abs=$(resolve_command "npx") || true
  daemon_path=$(backend_env_path)

  printf "/usr/bin/env PATH=%s %s mcp-proxy --port %s -- %s %s" \
    "$daemon_path" "$npx_abs" "$port" "$cmd_abs" "$args_str"
}

# launcher new doesn't write StandardOut/ErrorPath into the plist; add them
# so `launcher logs <name>` and `mcp daemon logs <name>` work out of the box.
_launchd_set_log_paths() {
  local server="$1"
  local plist log_dir
  plist=$(_launchd_plist_path "$server")
  [[ -f "$plist" ]] || return 0
  log_dir=$(_launchd_log_dir)
  mkdir -p "$log_dir"

  /usr/libexec/PlistBuddy -c "Add :StandardOutPath string $log_dir/$server.out.log" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :StandardOutPath $log_dir/$server.out.log" "$plist" 2>/dev/null \
    || true
  /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $log_dir/$server.err.log" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :StandardErrorPath $log_dir/$server.err.log" "$plist" 2>/dev/null \
    || true
}

backend_apply() {
  cli_require_jq
  ensure_file
  mkdir -p "$LAUNCHER_DIR"

  while IFS= read -r server; do
    [[ -z "$server" ]] && continue
    local type
    type=$(jq -r ".\"$server\".type" "$MCP_FILE")
    [[ "$type" != "stdio-http-proxy" ]] && continue

    local cmd
    cmd=$(_launchd_command_for "$server")
    launcher new -d "$LAUNCHER_DIR" "$server" "$cmd" >/dev/null
    _launchd_set_log_paths "$server"
  done < <(jq -r 'keys[]' "$MCP_FILE")

  launcher link --all >/dev/null 2>&1 || true
}

backend_start() {
  local name="${1:-}"
  backend_apply
  if [[ -n "$name" ]]; then
    launcher load "$name"
  else
    launcher load --all
  fi
}

backend_stop() {
  local name="${1:-}"
  if [[ -n "$name" ]]; then
    launcher unload "$name" 2>/dev/null || true
  else
    launcher unload --all 2>/dev/null || true
  fi
}

backend_delete() {
  local name="$1"
  launcher unload "$name" 2>/dev/null || true
  launcher unlink "$name" 2>/dev/null || true
  launcher rm "$name" 2>/dev/null || true
}

backend_status() {
  launcher ls
}

backend_logs() {
  local name="${1:-}"
  if [[ -n "$name" ]]; then
    launcher logs "$name" -f
  else
    echo "launchd backend: specify a server name to tail logs."
    launcher ls
  fi
}

backend_server_status() {
  local name="$1"
  local plist state
  plist=$(_launchd_plist_path "$name")
  [[ -f "$plist" ]] || { echo ""; return 0; }

  state=$(launcher info "$name" 2>/dev/null | awk -F': ' '/^Status:/ {print $2; exit}')

  case "$state" in
    running) echo "online" ;;
    stopped) echo "stopped" ;;
    "") echo "" ;;
    *) echo "$state" ;;
  esac
}
