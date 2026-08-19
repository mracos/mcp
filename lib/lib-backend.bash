#!/usr/bin/env bash
# Process-management backend dispatcher.
#
# Sources lib-backend-${MCP_BACKEND}.bash, which defines the backend vocabulary
# every backend must provide:
#
#   backend_apply                  Write registry artifact (ecosystem / plists)
#   backend_start [name]           Start all or one (auto-applies first)
#   backend_stop [name]            Stop all or one (keeps registration)
#   backend_delete <name>          Remove a server's registration entirely
#   backend_status                 Human-friendly process list
#   backend_logs [name]            Tail logs
#   backend_server_status <name>   online|errored|stopped|"" (for get_expected_config)

MCP_BACKEND="${MCP_BACKEND:-pm2}"

_backend_dir="${BASH_SOURCE[0]%/*}"
_backend_lib="$_backend_dir/lib-backend-${MCP_BACKEND}.bash"

if [[ ! -f "$_backend_lib" ]]; then
  echo "Error: unknown MCP_BACKEND='$MCP_BACKEND' (no $_backend_lib)" >&2
  exit 1
fi

# Resolve a command name to an absolute path. Falls back to known shim/bin
# locations (mise shims, ~/.bun/bin, homebrew). Echoes the input unchanged
# if no resolution is found, returning non-zero so callers can decide.
resolve_command() {
  local cmd="$1"

  if [[ "$cmd" == /* ]]; then
    echo "$cmd"
    return 0
  fi

  local resolved
  resolved=$(command -v "$cmd" 2>/dev/null || true)
  if [[ -n "$resolved" && "$resolved" == /* ]]; then
    echo "$resolved"
    return 0
  fi

  local dir
  for dir in \
    "$HOME/.local/share/mise/shims" \
    "$HOME/.bun/bin" \
    "$HOME/bin" \
    "$HOME/.local/bin" \
    "/opt/homebrew/bin" \
    "/usr/local/bin" \
    "/usr/bin"; do
    if [[ -x "$dir/$cmd" ]]; then
      echo "$dir/$cmd"
      return 0
    fi
  done

  echo "$cmd"
  return 1
}

# Build a known-good PATH for daemon child processes. Captures the current
# shell PATH and prepends shim/bin directories so spawned tools resolve even
# when the daemon process inherits a minimal environment.
backend_env_path() {
  local extras=(
    "$HOME/.local/share/mise/shims"
    "$HOME/.bun/bin"
    "$HOME/bin"
    "$HOME/.local/bin"
    "/opt/homebrew/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  )

  local joined
  joined="$(IFS=:; echo "${extras[*]}"):${PATH:-}"
  echo "$joined" | awk -v RS=: -v ORS=: '$0 != "" && !seen[$0]++ { print }' | sed 's/:$//'
}

# shellcheck source=/dev/null
source "$_backend_lib"
