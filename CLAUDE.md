# mcp

Bash CLI for managing MCP servers across AI coding clients. Extracted from [dotfiles](https://github.com/mracos/dotfiles).

## Structure

- `bin/` - Entry point (`mcp` dispatcher)
- `lib/` - Subcommands (`mcp-*`) and shared libs (`lib-*.bash`)
- `test/` - Bats tests
- `lib/lib-cli.bash` - Shared CLI helpers (dispatch, usage, symlink resolution)

## Commands

```sh
npm test                    # Run all tests
```

## Conventions

- Subcommands source `lib-cli.bash` with `--auto "$@"` for help detection
- Tests use bats + bats-assert + bats-support
- Test structure: AAA (arrange/act/assert), `PROJECT_ROOT` env var for paths
- Commits: present tense imperative, `<scope>: <what>`

## Architecture

Thin dispatcher (`bin/mcp`) resolves symlinks to find `lib/` relative to itself. Subcommands in `lib/mcp-*` source shared libs from the same directory. `lib-mcp.bash` holds all shared state and helpers (config paths, jq wrappers, codex sync, daemon management).

## Shared libs

`lib-cli.bash` is shared with [dotfiles/notes](https://github.com/mracos/dotfiles) and [mracos/launcher](https://github.com/mracos/launcher). Changes here should be synced back.
