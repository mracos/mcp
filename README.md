# mcp

Manage MCP servers from a single config file (`~/.mcp-servers.json`) and sync to multiple AI coding clients.

Supported targets:
- **Claude Code** - `~/.claude.json` (`mcpServers`)
- **Codex** - `~/.codex/config.toml` (`[mcp_servers.*]`)

## Install

```zsh
# zinit
zinit ice as"command" pick"bin/mcp"
zinit light mracos/mcp

# sheldon (plugins.toml)
[plugins.mcp]
github = "mracos/mcp"

# manual
git clone https://github.com/mracos/mcp ~/.mcp
export PATH="$HOME/.mcp/bin:$PATH"
```

## Requirements

- **bash** 3.2+ (macOS stock bash works)
- **[jq](https://jqlang.github.io/jq/)** - JSON processing (all commands)
- **Node.js / npx** - daemon management only (`mcp daemon`, `stdio-http-proxy` servers)
- **[mcp-proxy](https://github.com/nicholasgasior/mcp-proxy)** - stdio-to-HTTP proxy (`npx mcp-proxy`)
- **envsubst** (gettext) - env var expansion in daemon configs

## Usage

```bash
mcp list                          # List all configured servers
mcp add notion https://...        # Add HTTP server
mcp add tool -- npx -y @pkg/mcp   # Add stdio server
mcp remove <name>                 # Remove a server
mcp edit                          # Open in $EDITOR
mcp apply                         # Sync into clients
mcp show <name>                   # Show server config
mcp daemon [start|stop|status]    # Manage proxy daemons
mcp logs [name]                   # Tail daemon logs
```

## Server Types

### HTTP

Direct connection to a remote MCP server:

```bash
mcp add notion https://mcp.notion.com/mcp
```

### stdio

Spawns a new process per session:

```bash
mcp add mytool -- npx -y @example/mcp
```

### stdio-http-proxy

Runs the stdio server as a persistent daemon via `mcp-proxy`, connects via HTTP. Prefer this over plain `stdio` to avoid spawning a new process per session:

```json
{
  "myserver": {
    "type": "stdio-http-proxy",
    "command": "npx",
    "args": ["-y", "@example/mcp"],
    "env": { "API_KEY": "${MY_API_KEY}" },
    "port": 8081
  }
```

Use unique ports per server. `mcp apply` starts daemons automatically and writes SSE endpoints to Claude Code config.

### Why SSE instead of HTTP?

Claude Code assumes `http` endpoints support OAuth and tries discovery. Local `mcp-proxy` doesn't implement OAuth, causing 404 errors. `sse` transport skips OAuth discovery and connects directly.

For Codex, proxied servers are written as streamable HTTP URLs (`http://localhost:<port>/mcp`).

## Env Vars

Add env vars with `--env` on `mcp add`:

```bash
mcp add --env API_KEY=sk-123 mytool -- npx -y @example/mcp
```

Or edit directly with `mcp edit`:

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

`${VAR}` references in env values are expanded via `envsubst` when generating daemon configs.

## How It Works

`~/.mcp-servers.json` is the source of truth. `mcp apply` reads it and:

1. Starts daemons for `stdio-http-proxy` servers (via PM2)
2. Merges server configs into `~/.claude.json`
3. Syncs server configs into `~/.codex/config.toml`

Existing non-MCP keys in both target files are preserved.

## Testing

```bash
npm install
npm test
```
