# 0002: mcp back into dotfiles as source, published to mracos/mcp via GitHub Action

**Date:** 2026-08-07
**Status:** Accepted
**Deciders:** Marcos

## Context

`mcp` (the MCP-server manager CLI) was extracted out of dotfiles in June 2026 (dotfiles commit `558394d3 bin/mcp: extract to standalone repo mracos/mcp`) under [tools/0001](../tools/0001-tools-multirepo.md), which chose multi-repo with manual `lib-cli.bash` sync. Since then `mcp` grew a pluggable daemon backend (pm2 + launchd via the `launcher` CLI, ADR [mcp/0001](0001-mcp-backend-abstraction.md)) in its own repo.

Two problems surfaced, the same ones [nbx/0011](../nbx/0011-nbx-extraction-mirror.md) called out:

1. **`lib-cli.bash` drifted badly.** dotfiles is 285 lines; the `mcp` copy is 92 and uses the old `--auto` API instead of `--auto-help`. "Sync by hand" (CLAUDE.md) did not hold. `mcp` is running an old CLI helper.
2. **Development split from the monorepo.** Changes to `mcp` land in a second repo, out of the daily dotfiles flow, with no shared test/lint/verify path.

nbx proved the fix ([nbx/0011](../nbx/0011-nbx-extraction-mirror.md)): keep the tool in dotfiles as the single source of truth, and generate a read-only standalone mirror via an append-only publish Action. That ADR explicitly invited replication once the pattern proved cheap: *"If it proves cheap and reliable, we replicate it to launcher/mcp and generalize."* mcp is the first replication.

## Decision

**Bring `mcp` source back into dotfiles as canonical, and publish `mracos/mcp` as a generated, read-only mirror** using the nbx/0011 append-only mechanism. This **supersedes [tools/0001](../tools/0001-tools-multirepo.md) for mcp** (as nbx/0011 did for nbx). `mracos/mcp` keeps its existing history but gains only synthetic `sync dotfiles@<sha>` commits going forward; never edit it directly again.

### Layout in dotfiles

Standard dispatcher -> lib -> shared `lib-cli` shape, matching `notes`/`nbx`:

| Standalone (old) | dotfiles (canonical) |
|---|---|
| `bin/mcp` | `files/shell/bin/mcp` |
| `lib/mcp-*`, `lib/lib-mcp.bash`, `lib/lib-backend*.bash` | `lib/shell/mcp/` |
| `lib/lib-cli.bash` (vendored, drifted) | dropped; uses `lib/shell/shared/lib-cli.bash` |
| `test/mcp.bats` | `test/files/shell/bin/mcp.bats` |
| `docs/adrs/`, `docs/usage.md`, `examples/` | `docs/adrs/mcp/`, `lib/shell/mcp/usage.md`, `lib/shell/mcp/examples/` |

Bringing it back meant re-homing it on the current shared `lib-cli.bash`: subcommands now source `$LIB_ROOT/shared/lib-cli.bash --auto-help` (was `$SCRIPT_DIR/lib-cli.bash --auto`), and the `cd -P "$(dirname ...)" && pwd` path-discovery blocks became parameter expansion (`${BASH_SOURCE[0]%/*}`) per the shell-perf rules. The drift is now impossible: the mirror always vendors a fresh copy of the one source.

### Mechanism (identical shape to nbx/0011)

- **`scripts/extract-mcp.sh <build-dir>`** (later folded into the generic `scripts/extract.sh mcp`, ADR [tools/0003](../tools/0003-generic-extraction-engine.md)): pure offline assembler. Gathers mcp's files into the standalone `bin/` + `lib/` layout, **vendors `lib-cli.bash` from `lib/shell/shared/`**, and applies two path rewrites:
  - dispatcher: `${SCRIPT_DIR%/files/shell/bin}` -> `${SCRIPT_DIR%/bin}`, `$REPO_ROOT/lib/shell/mcp` -> `$REPO_ROOT/lib`, shared `lib-cli` -> `lib/lib-cli.bash`.
  - subcommands: `$LIB_ROOT/shared/lib-cli.bash` -> `$SCRIPT_DIR/lib-cli.bash` (flat layout), dropping the now-unused `LIB_ROOT` line.
  - `lib-mcp.bash` / `lib-backend*.bash` copy verbatim (they resolve siblings via `${BASH_SOURCE[0]%/*}`, which is layout-agnostic).
  - emits `README.md`, `docs/usage.md`, `examples/`, `mcp.plugin.zsh`, `package.json`, `.gitignore`, `LICENSE`, `.github/workflows/ci.yml`.
- **`.github/workflows/publish-mcp.yml`**: on push touching mcp paths (or manual dispatch), assemble, smoke-test `mcp --help`, clone the mirror, overlay the tree, and add **one commit per publish** (`sync dotfiles@<sha>` + the dotfiles message). Plain push, no force. Reuses the shared `DOTFILES_PUBLISH_REPOS` PAT.

### Why the mirror CI is macOS-only

The launchd backend and its tests exercise `/usr/libexec/PlistBuddy` and macOS launch agents, so the generated `ci.yml` runs `macos-latest` only (matching the original mcp repo). nbx runs both OSes; mcp cannot until the launchd paths are guarded for Linux.

### `launcher` stays external

The launchd backend shells out to the `launcher` CLI (`command -v launcher`), which is still its own repo. That is a runtime dependency, not a source dependency: mcp degrades cleanly when `launcher` is absent (pm2 is the default backend). Bringing `launcher` back is a separate decision, not blocked by this one.

## Consequences

**Positive:**

- One source of truth again; `lib-cli.bash` drift is structurally impossible for mcp (the mirror vendors a fresh copy every publish).
- mcp development rejoins the dotfiles flow (shared tests, lint, verify, commit conventions). All 46 bats pass in dotfiles and against the assembled standalone tree.
- Second data point for the extraction pattern. With nbx + mcp sharing the same assembler shape, the generic engine hinted at in nbx/0011 is now in view.

**Negative:**

- `mracos/mcp` becomes generated: no PRs/issues-as-source, and its history turns into a publish log (`sync dotfiles@<sha>`) from here on. Its real prior history is preserved but frozen.
- The assembler must track two path rewrites (dispatcher + subcommand) plus the shared-lib vendoring. Kept minimal and covered by the offline extraction test.

## Setup required (one-time, by the operator)

1. `mracos/mcp` already exists; nothing to create.
2. Ensure the `DOTFILES_PUBLISH_REPOS` secret's PAT scope includes `mracos/mcp` (contents:write). It was created for nbx; add mcp to its repo set.
3. First publish overwrites the mirror's working tree with the generated layout (append commit, no force). After that, treat `mracos/mcp` as read-only.

## Related Decisions

- [nbx/0011](../nbx/0011-nbx-extraction-mirror.md): the POC this replicates. This ADR is the first replication it invited.
- [tools/0001](../tools/0001-tools-multirepo.md): the multi-repo + manual-sync decision this supersedes for mcp.
- [mcp/0001](0001-mcp-backend-abstraction.md): the pluggable backend design that grew in the standalone repo and now lives in dotfiles.
- CLAUDE.md "Shared Code Across Repos": the manual-sync rule this supersedes for mcp.
