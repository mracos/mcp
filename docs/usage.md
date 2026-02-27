# MCP Server Management

Use the local `mcp` CLI as the source of truth for MCP servers.

Do not manage servers directly with `claude mcp ...` or `codex mcp ...` if you want dotfiles-managed state.

`mcp` manages `~/.mcp-servers.json` (tracked in dotfiles) and syncs to both clients:

```bash
mcp list                          # List all configured servers
mcp add notion https://...        # Add HTTP server
mcp add tool -- npx -y @pkg/mcp   # Add stdio server
mcp remove <name>                 # Remove a server
mcp edit                          # Open in $EDITOR
mcp apply                         # Merge into ~/.claude.json
mcp show <name>                   # Show server config
```

After changes, restart Claude Code for new servers to take effect.

**How it works:**
- `~/.mcp-servers.json` is tracked in dotfiles
- `mcp apply` (or `./link.sh ai`) updates:
  - `~/.claude.json` (`mcpServers` for Claude Code)
  - `~/.codex/config.toml` (`[mcp_servers.*]` for Codex)
- Existing non-MCP keys in both files are preserved

**Adding env vars:** Edit the file directly with `mcp edit`:
```json
{
  "myserver": {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "@example/mcp"],
    "env": { "API_KEY": "${MY_API_KEY}" }
  }
}
```

## Server Types

**Always use `stdio-http-proxy` instead of plain `stdio`** - stdio spawns a new MCP server instance for every Claude Code session. With http-proxy, the server runs persistently and Claude connects via HTTP. All stdio servers should be proxied.

```json
{
  "myserver": {
    "type": "stdio-http-proxy",
    "command": "npx",
    "args": ["-y", "@example/mcp"],
    "env": { "API_KEY": "${MY_API_KEY}" },
    "port": 8081
  }
}
```

Use unique ports per server (8081, 8082, etc). The proxy handles the stdio↔HTTP translation.

### Why SSE instead of HTTP?

The `mcp` CLI outputs `sse` type (not `http`) for stdio-http-proxy servers. This is intentional:

- Claude Code assumes `http` endpoints support OAuth and tries discovery
- Local mcp-proxy doesn't implement OAuth, causing 404/auth errors
- `sse` transport skips OAuth discovery and connects directly
- SSE is deprecated in MCP spec but still works in Claude Code

To use `http` type, options are:
1. Implement mock OAuth endpoints in mcp-proxy (always accept)
2. Wait for Claude Code to add per-server OAuth disable flag

For Codex, proxied servers are written as streamable HTTP URLs (`http://localhost:<port>/mcp`) in `~/.codex/config.toml`.

## Slack MCP Server

Slack MCP uses browser tokens (xoxc + xoxd) instead of OAuth - stealth mode, no app install needed.

**Token types:**
- `xoxc-...` - session token from localStorage (API calls)
- `xoxd-...` - cookie `d` from `.slack.com` (authentication)

Tokens are stored in 1Password and loaded via `op://` refs in `env.tpl`.

**Add the server** (first time, via `mcp edit`):

```json
{
  "slack": {
    "type": "stdio-http-proxy",
    "command": "npx",
    "args": ["-y", "@anthropic/slack-mcp-server@latest", "--transport", "stdio"],
    "env": {
      "SLACK_TOKEN": "${SLACK_MCP_XOXC_TOKEN}",
      "SLACK_COOKIE": "${SLACK_MCP_XOXD_TOKEN}"
    },
    "port": 8082
  }
}
```

Then `mcp apply` to start the daemon. The `${...}` env vars are resolved via `envsubst` from the op cache.

**Refresh tokens** (they expire periodically):

```bash
slack-chrome-tokens refresh
```

Extracts fresh tokens from Chrome, saves to 1Password, refreshes op cache. Restart the daemon with `mcp daemon stop slack && mcp daemon start slack` to pick up new env vars.

If 1Password is unavailable, falls back to printing tokens for manual use.
