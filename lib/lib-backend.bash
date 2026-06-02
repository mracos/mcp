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

_backend_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_backend_lib="$_backend_dir/lib-backend-${MCP_BACKEND}.bash"

if [[ ! -f "$_backend_lib" ]]; then
  echo "Error: unknown MCP_BACKEND='$MCP_BACKEND' (no $_backend_lib)" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$_backend_lib"
