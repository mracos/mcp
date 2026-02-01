# MCP Server Management

**Do NOT use `claude mcp add`** - it stores servers in `~/.claude.json` mixed with session state.

Instead, use the `mcp` CLI which manages `~/.claude/mcp-servers.json` (tracked in dotfiles):

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
- `~/.claude/mcp-servers.json` is tracked in dotfiles
- `mcp apply` (or `./link.sh ai`) merges it into `~/.claude.json`
- Existing keys in `~/.claude.json` (sessions, state) are preserved

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

**Prefer `stdio-http-proxy` over plain `stdio`** - stdio spawns a new MCP server instance for every Claude Code session. With http-proxy, the server runs persistently and Claude connects via HTTP.

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
