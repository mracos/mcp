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
