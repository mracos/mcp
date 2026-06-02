# ADR mcp - 0001: Backend-agnostic process management

> Date: 2026/06/01
>
> Authors: `Marcos Ferreira`

> Status: Proposed

## Context

`mcp` manages MCP servers and exposes a `daemon` subcommand to run `stdio-http-proxy` servers as long-lived processes. Today `mcp-daemon` and `lib-mcp.bash` invoke `npx pm2` directly in six places. This couples `mcp` to a single process manager and causes two concrete failures:

1. **Hardcoded backend.** Adding launchd (the natural mac primitive, and what `mracos/launcher` already wraps) means rewriting `mcp-daemon` end-to-end and re-implementing per-server status checks.
2. **Daemon environment is not self-contained.** The pm2 ecosystem is generated with `script: 'npx'` and `args: 'mcp-proxy --port N -- bunx --bun ...'`. Both `npx` and `bunx` are mise shims. When pm2's daemon process doesn't inherit a mise-shimmed PATH (e.g., started outside an interactive shell), spawns fail with `ENOENT`. The granola MCP server is currently broken for this reason.

The fix is structural: introduce a backend abstraction inside `mcp`, then implement two backends (pm2 fixed, launchd new). Backend selection is global. Public CLI surface stays the same.

## Decision

**1. Backend abstraction (`lib/lib-backend.bash`):**

A new file defines the function vocabulary every backend must provide and resolves which implementation to source based on a single config value.

- Selection mechanism: `MCP_BACKEND` env var, default `pm2`. Future-proof: top-level `"backend"` field in `~/.mcp-servers.json` overrides the env var.
- Resolution happens once at source time. `lib-backend.bash` sources exactly one of `lib-backend-pm2.bash` or `lib-backend-launchd.bash` and aliases its private functions to the public vocabulary.

Public vocabulary:

| Function | Purpose |
|---|---|
| `backend_apply` | Sync registry with `~/.mcp-servers.json` (write ecosystem.config.js or plists) |
| `backend_start [name]` | Start all or one |
| `backend_stop [name]` | Stop all or one |
| `backend_status` | Human-friendly list |
| `backend_logs [name]` | Tail logs |
| `backend_server_status <name>` | Returns `online\|errored\|stopped\|""` — used by `get_expected_config` |

**2. Self-contained tool resolution:**

`generate_ecosystem` (renamed `_pm2_apply`) and the new `_launchd_apply` both resolve top-level commands to absolute paths at generation time and inject a sane PATH for child spawns.

- For each `stdio-http-proxy` server, run `command -v <tool>` for `command` and for the first arg if it looks like a tool name (`bunx`, `npx`, `uvx`, `pnpm`, `yarn`). Inline the absolute path.
- Inject `env.PATH` that always contains: the current shell's PATH at generation time, with mise shims and homebrew paths prepended explicitly so a hand-edit can't drop them.
- The resolution lives in a shared helper in `lib-backend.bash` so both backends use the same logic.

**3. pm2 backend (`lib/lib-backend-pm2.bash`):**

Existing pm2 logic moves here, refactored to the new vocabulary. No behavior change beyond the self-containment fix.

- `_pm2_apply` writes `~/.local/share/mcp/ecosystem.config.js` with absolute paths and PATH env.
- `_pm2_start/stop/logs` wrap `npx pm2 ...` exactly as today.
- `_pm2_server_status` parses `npx pm2 jlist`.

**4. launchd backend (`lib/lib-backend-launchd.bash`):**

Shells out to the `launcher` CLI from `mracos/launcher`. mcp does not write plists itself or call `launchctl` directly.

- `_launchd_apply` iterates `stdio-http-proxy` servers and calls `launcher new -d "$DAEMON_DIR" mcp-<name> "<resolved-command>"` for each. The command string includes resolved absolute paths and is prefixed by an inline `env PATH=...` so the launch agent has the right PATH without depending on the plist's `EnvironmentVariables` keys.
- `_launchd_start [name]` → `launcher load mcp-<name>` (one or all).
- `_launchd_stop [name]` → `launcher unload mcp-<name>`.
- `_launchd_logs [name]` → `launcher logs mcp-<name> -f`.
- `_launchd_server_status` → parses `launcher info mcp-<name>` for the `state=` line, maps `running`→`online`, `stopped` with non-zero last_exit→`errored`, otherwise `stopped`. Empty when not registered.
- Hard requirement: `command -v launcher` must succeed. If it doesn't, fail fast with a clear error pointing at the install instructions.

**5. `mcp-daemon` becomes a thin dispatcher:**

- Sources `lib-backend.bash` after `lib-mcp.bash`.
- Each subcommand (`start|stop|status|logs`) maps 1:1 to a `backend_*` call.
- `start` now runs `backend_apply` first (today this is implicit via `generate_ecosystem`), so launchd users don't have to remember a separate "register" step.

**6. `get_expected_config` decoupling:**

`lib-mcp.bash::get_daemon_status` becomes a one-line forwarder to `backend_server_status`. The "online → return sse url" logic in `get_expected_config` is unchanged.

## Consequences

**Positive:**

- Granola unblocks: absolute-path resolution fixes the `bunx ENOENT` failure mode for both backends.
- Backend swap is a one-env-var change. Same `mcp daemon ...` muscle memory regardless of backend.
- launchd backend reuses `launcher` instead of reimplementing launchctl + plist generation. Launcher improvements (logs, info) accrete to mcp for free.
- `lib-backend.bash` becomes the single chokepoint for adding a third backend later (systemd, runit, supervisord) without touching `mcp-daemon` or `lib-mcp.bash`.

**Negative:**

- launchd backend requires `launcher` in PATH. Documented; failure mode is a clear error, not a silent break.
- Two backend files instead of one inlined pm2 path. Net +~150 LOC for the abstraction. Acceptable for the swap-ability it buys.
- Tool resolution at generation time means `mcp daemon start` must be re-run after `mise use -g bun@<new>`. Today users would also need to restart pm2; not a regression. Will be called out in `docs/usage.md`.

## Implementation Notes

Phased delivery (each phase ships independently and leaves the repo in a working state):

1. **Phase 1 — backend abstraction skeleton.**
   - Add `lib-backend.bash` with vocabulary + dispatch.
   - Add `lib-backend-pm2.bash` containing the current logic, moved verbatim from `lib-mcp.bash` and `mcp-daemon`, then renamed to `_pm2_*`.
   - `mcp-daemon` rewritten to call `backend_*`.
   - `get_daemon_status` forwards to `backend_server_status`.
   - Tests: existing bats tests pass unchanged; add one covering `backend_*` dispatching to pm2 by default.

2. **Phase 2 — self-contained pm2.**
   - Add `resolve_command` helper in `lib-backend.bash` (returns absolute path via `command -v` with a fallback search of mise shims + homebrew bin).
   - Update `_pm2_apply` to use it and to inject `env.PATH`.
   - Manually verify granola starts after `mise install bun` is done. Add a unit test for `resolve_command`.

3. **Phase 3 — launchd backend.**
   - Add `lib-backend-launchd.bash`.
   - Add `MCP_BACKEND` selection logic in `lib-backend.bash`.
   - Tests: bats coverage for `_launchd_apply` arg construction (don't execute `launcher` in tests; mock via `PATH=mocks:$PATH`).
   - Manual verification: switch one server (granola) to launchd, confirm `mcp daemon status` shows it and `mcp apply` rewrites the SSE URL.

4. **Phase 4 — docs.**
   - Update `README.md` and `docs/usage.md`.
   - Note the `mise install bun` prerequisite for granola specifically.

No phase exceeds ~5 files. Each commits separately. Phase 1 is the only one that touches existing behavior; phases 2-4 are additive.

## Related Decisions

- `mracos/launcher` ADRs (if/when added) — this ADR formalizes mcp's dependency on launcher's CLI surface.
