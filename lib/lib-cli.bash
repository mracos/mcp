#!/usr/bin/env bash
# Shared CLI helpers for dotfiles scripts.
#
# Three sections:
#   1. Dispatch — subcommand routing, help flags, usage printing
#   2. fzf      — interactive pickers (cli_fzf_pick for args, cli_fzf_multi for stdin)
#   3. Auto-help — source-time setup for --auto-help and --dispatch
#
# Source with --auto-help to get usage()/--help for free:
#   source lib-cli.bash --auto-help "$@"
#   source lib-cli.bash --auto-help --dispatch -- "$@"
#
# Shared across: dotfiles, mracos/launcher, mracos/mcp

# --- Portable helpers ---

# In-place sed that works on both GNU and BSD sed. `sed -i ''` (BSD idiom)
# makes GNU read '' as an empty script and the real script as a filename;
# `sed -i` (GNU idiom) makes BSD eat the next arg as the backup suffix.
# Sidestep both by dropping -i: run sed to a temp file and copy it back.
# The last argument is the file; everything before it is the sed script/flags.
#
# Copy the result back into the original file (truncate + write) rather than
# `mv`-ing the temp over it: `mv` would replace the inode and hand the file the
# temp's 0600 mode, stripping perms like the execute bit. Real `sed -i` (BSD
# and GNU) preserves the file mode, so we do too.
sed_i() {
  local _n=$# _f="${@: -1}" _t
  _t="$(mktemp)"
  if sed "${@:1:$((_n - 1))}" "$_f" > "$_t"; then
    cat "$_t" > "$_f"
  fi
  rm -f "$_t"
}

# Reformat a date string, portable across BSD and GNU date. BSD needs the
# input format (`-j -f`); GNU auto-parses (`-d`). Try BSD first (so macOS
# behavior is unchanged) then fall back to GNU. Input format `%s` means the
# string is an epoch. Returns non-zero if neither can parse (callers keep
# their own `|| default`). Usage: date_reformat <infmt> <str> <outfmt>
date_reformat() {
  case "$1" in
    %s) date -r "$2" "$3" 2>/dev/null || date -d "@$2" "$3" 2>/dev/null ;;
    *)  date -j -f "$1" "$2" "$3" 2>/dev/null || date -d "$2" "$3" 2>/dev/null ;;
  esac
}

# Shift a date by whole days, portable. `base` empty = today. `days` is a
# signed count like -30 or +1. Usage: date_shift <base|""> <signed-days> <outfmt>
date_shift() {
  local _b="$1" _n="$2" _f="$3"
  if [[ -z "$_b" ]]; then
    date -j -v"${_n}d" "$_f" 2>/dev/null || date -d "$_n days" "$_f" 2>/dev/null
  else
    date -j -v"${_n}d" -f "%Y-%m-%d" "$_b" "$_f" 2>/dev/null || date -d "$_b $_n days" "$_f" 2>/dev/null
  fi
}

# --- Dispatch helpers ---

# Return success if token is a standard help flag.
cli_is_help() {
  local token="${1:-}"
  [[ "$token" == "-h" || "$token" == "--help" || "$token" == "help" ]]
}

# Print a comment block from a script file and exit.
# Usage: cli_usage_range <script-file> <start-line> <end-line> [exit-code]
cli_usage_range() {
  local file="$1"
  local start_line="$2"
  local end_line="$3"
  local code="${4:-1}"

  awk -v start="$start_line" -v end="$end_line" '
    NR >= start && NR <= end {
      sub(/^# /, "")
      sub(/^#/, "")
      print
    }
  ' "$file"
  exit "$code"
}

# Print initial comment block until first blank comment separator and exit.
# Usage: cli_usage_until_blank <script-file> [exit-code]
cli_usage_until_blank() {
  local file="$1"
  local code="${2:-1}"

  awk 'NR>1 && /^$/{exit} NR>1{sub(/^# /, ""); sub(/^#/, ""); print}' "$file"
  exit "$code"
}

# Find a subcommand file across a colon-separated dir list. First match wins.
# Usage: _cli_find_subcmd <dirs> <filename>
_cli_find_subcmd() {
  local dirs="$1" name="$2" dir
  local IFS=:
  for dir in $dirs; do
    [[ -n "$dir" && -x "$dir/$name" ]] && { printf '%s/%s\n' "$dir" "$name"; return 0; }
  done
  return 1
}

# Exec subcommand script if it exists/executable.
# Callers pass raw "$@" (unshifted) - the function safely consumes the cmd.
# <base-dirs> may be a single dir or a colon-separated list (first match wins).
# Usage: cli_exec_subcommand <base-dirs> <prefix> <cmd> "$@"
# Example: cli_exec_subcommand "$SCRIPT_DIR" "notes-daily-" "$cmd" "$@"
cli_exec_subcommand() {
  local base_dirs="$1"
  local prefix="$2"
  local cmd="$3"
  shift 3
  [[ $# -gt 0 ]] && shift

  local subcmd
  if subcmd="$(_cli_find_subcmd "$base_dirs" "${prefix}${cmd}")"; then
    export _CLI_CMD_PATH="${_CLI_CMD_PATH:-$(basename "$0")} $cmd"
    exec "$subcmd" "$@"
  fi
  return 1
}

# List subcommands by scanning executable scripts with a given prefix.
# Extracts name (sans prefix) and description (line 2 comment) from each.
# Skips nested subcommands when a parent dispatcher exists
# (e.g. notes-people-add is hidden because notes-people handles it).
# <base-dirs> may be a single dir or a colon-separated list: entries are
# aggregated sorted by name, duplicates resolve to the first dir (matching
# cli_exec_subcommand), and the parent lookup spans the whole list.
# Usage: cli_list_subcommands <base-dirs> <prefix>
cli_list_subcommands() {
  local base_dirs="$1" prefix="$2"
  local dir cmd name desc suffix parent parent_file
  local seen=" " lines=""
  local IFS=:
  for dir in $base_dirs; do
    [[ -n "$dir" ]] || continue
    for cmd in "$dir/${prefix}"*; do
      [[ -x "$cmd" ]] || continue
      name="${cmd##*/}"
      name="${name#$prefix}"
      [[ "$seen" == *" $name "* ]] && continue
      seen="$seen$name "
      # Skip nested: notes-people-add is nested if notes-people is a dispatcher.
      # Only skip when the parent uses --dispatch (is a real dispatcher, not a leaf command).
      if [[ "$name" == *-* ]]; then
        parent="${name%%-*}"
        if parent_file="$(_cli_find_subcmd "$base_dirs" "${prefix}${parent}")"; then
          grep -q -- '--dispatch' "$parent_file" && continue
        fi
      fi
      desc=$(sed -n '2s/^# *//p' "$cmd")
      # Show + suffix when the command is itself a dispatcher (has subcommands)
      suffix=""
      grep -q -- '--dispatch' "$cmd" && suffix="+"
      lines="${lines}${name}${suffix}"$'\t'"${desc}"$'\n'
    done
  done
  [[ -n "$lines" ]] || return 0
  printf '%s' "$lines" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 |
    while IFS=$'\t' read -r name desc; do
      printf "  %-20s %s\n" "$name" "$desc"
    done
}

# Resolve script path, following symlinks.
# Accepts basenames, relative paths, and absolute paths.
# Usage: path=$(cli_resolve_script_path)
cli_resolve_script_path() {
  local source="${1:-${BASH_SOURCE[1]}}"
  local target=""

  [[ "$source" == */* ]] || source="$(command -v -- "$source")"
  [[ "$source" == /* ]] || source="$PWD/$source"

  while [[ -L "$source" ]]; do
    target="$(readlink "$source")"
    if [[ "$target" == /* ]]; then
      source="$target"
    else
      source="${source%/*}/$target"
    fi
  done

  printf '%s\n' "$source"
}

# Resolve script directory, following symlinks.
# Usage: dir=$(cli_resolve_script_dir)
cli_resolve_script_dir() {
  local source
  source="$(cli_resolve_script_path "${1:-${BASH_SOURCE[1]}}")" || return 1
  printf '%s\n' "${source%/*}"
}

# Return success when arg matches YYYY-MM-DD.
cli_is_date() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

# --- fzf helpers ---
#
# Two pickers for different use cases:
#
#   cli_fzf_pick   Simple lists passed as args. For short, known option sets
#                  (categories, actions, sections). Supports --new for creation.
#                  Example: cli_fzf_pick "Move to?" "${categories[@]}"
#
#   cli_fzf_multi  Entity pickers from stdin. For dynamic, tab-delimited data
#                  (people, meetings, todos) with metadata and preview support.
#                  Works for single-select too — --multi enables but doesn't require.
#                  Example: printf '%s\n' "${entries[@]}" | cli_fzf_multi "Pick" --preview "cat {2}"

# Require fzf or exit with error.
cli_require_fzf() {
  command -v fzf &>/dev/null || { echo "Error: fzf is required for interactive mode" >&2; exit 1; }
}

# Require jq or exit with error.
cli_require_jq() {
  command -v jq &>/dev/null || { echo "Error: jq is required" >&2; exit 1; }
}

# Pick from a short list of known options (args, not stdin).
# Appends "+ New..." option when --new is passed; returns literal "+ New..." if chosen.
# Usage: cli_fzf_pick [--new] <header> <item1> <item2> ...
# Returns: selected item on stdout, exits 0. Empty/cancel exits 1.
cli_fzf_pick() {
  cli_require_fzf
  local allow_new=false
  if [[ "${1:-}" == "--new" ]]; then
    allow_new=true; shift
  fi
  local header="$1"; shift
  local items=()
  [[ $# -gt 0 ]] && items=("$@")

  $allow_new && items+=("+ New...")
  [[ ${#items[@]} -eq 0 ]] && return 1

  local selected
  selected=$(printf '%s\n' "${items[@]}" | fzf --header="$header") || return 1
  [[ -z "$selected" ]] && return 1
  echo "$selected"
}

# Prompt user for a new name (used after cli_fzf_pick returns "+ New...").
# Usage: cli_fzf_new_input <prompt>
cli_fzf_new_input() {
  local prompt="${1:-Name}"
  local value
  printf '%s: ' "$prompt" >&2
  read -r value
  [[ -z "$value" ]] && return 1
  echo "$value"
}

# Pick from dynamic, tab-delimited entries via fzf (reads from stdin).
# Format: "display_text\tmetadata1\tmetadata2..."
# Shows only the first field (--with-nth=1), returns full selected lines.
# Works for single-select too — TAB enables multi, ENTER confirms.
# Usage: printf '%s\n' "${entries[@]}" | cli_fzf_multi <header> [--preview <cmd>] [--prompt <label>]
# Returns: selected lines on stdout (tab-delimited), exits 0. Cancel exits 1.
cli_fzf_multi() {
  cli_require_fzf
  local header="$1"; shift
  local extra_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preview) shift; extra_args+=(--preview "$1" --preview-window "right:40%:wrap"); shift ;;
      --prompt) shift; extra_args+=(--prompt "$1"); shift ;;
      *) shift ;;
    esac
  done

  local selected
  selected=$(fzf --multi \
      --delimiter=$'\t' \
      --with-nth=1 \
      --header="$header" \
      ${extra_args[@]+"${extra_args[@]}"}) || return 1  # bash 3.2 + set -u: guard empty array
  [[ -z "$selected" ]] && return 1
  echo "$selected"
}

# --- Auto-help (source-time) ---
# Capture caller and define usage(). Flags parsed before "$@":
#
#   source lib-cli.bash --auto-help "$@"
#     → defines usage(), checks --help
#
#   source lib-cli.bash --auto-help --dispatch -- "$@"
#     → same + usage() auto-appends COMMANDS from discovered subcommands
#     → prefix defaults to "basename-" (e.g. notes-people → notes-people-)
#     → dispatchers may override _CLI_SUBCMD_DIR after sourcing; it accepts a
#       colon-separated dir list (searched in order, like PATH)
#
#   source lib-cli.bash --auto-help --dispatch "custom-prefix-" -- "$@"
#     → same but with explicit prefix override
#
#   source lib-cli.bash --auto-help --deferred "$@"
#     → defines usage() but does NOT check --help at source time
#     → script handles --help itself after setup (e.g. pipeline scripts
#       that need STEPS defined before showing help)
#
# Scripts can override usage() after sourcing if they need custom behavior.
_CLI_SCRIPT="${BASH_SOURCE[1]}"
_CLI_SUBCMD_DIR=""
_CLI_SUBCMD_PREFIX=""

# Print the comment-header block from the caller script to stdout.
# Auto-prepends _CLI_CMD_PATH to USAGE lines. Skips COMPLETE: blocks (they
# drive zsh completions, not humans). Does NOT exit.
cli_print_usage_header() {
  local cmd_path="${_CLI_CMD_PATH:-}"
  awk -v cmd="$cmd_path" '
    NR>1 && /^$/{exit}
    NR>1 {
      sub(/^# /, ""); sub(/^#/, "")
      if ($0 == "COMPLETE:") { skip = 1; next }
      if (skip) {
        if ($0 ~ /^  /) next
        skip = 0
        if ($0 == "") next
      }
      # Auto-prepend command path to USAGE line when args start with non-alpha
      # (e.g. "[options]", "<command>"). Skips lines with hardcoded names for compat.
      if (cmd != "" && /^USAGE:/) {
        rest = $0; sub(/^USAGE: */, "", rest)
        if (rest == "" || rest ~ /^[^a-zA-Z]/) {
          sub(/^USAGE: */, "USAGE: " cmd " ")
        }
      }
      print
    }
  ' "$_CLI_SCRIPT"
}

usage() {
  cli_print_usage_header
  if [[ -n "$_CLI_SUBCMD_DIR" && -n "$_CLI_SUBCMD_PREFIX" ]]; then
    echo ""
    echo "COMMANDS:"
    cli_list_subcommands "$_CLI_SUBCMD_DIR" "$_CLI_SUBCMD_PREFIX"
  fi
  exit "${1:-1}"
}

if [[ "${1:-}" == "--auto-help" ]]; then
  shift
  export _CLI_CMD_PATH="${_CLI_CMD_PATH:-$(basename "$_CLI_SCRIPT")}"
  _cli_deferred=false
  if [[ "${1:-}" == "--dispatch" ]]; then
    shift
    _CLI_SUBCMD_DIR="$(cli_resolve_script_dir "$_CLI_SCRIPT")"
    if [[ "${1:-}" != "--" && "${1:-}" != --* && -n "${1:-}" ]]; then
      _CLI_SUBCMD_PREFIX="$1"; shift
    else
      _CLI_SUBCMD_PREFIX="$(basename "$_CLI_SCRIPT")-"
    fi
  fi
  [[ "${1:-}" == "--deferred" ]] && { _cli_deferred=true; shift; }
  [[ "${1:-}" == "--" ]] && shift || true
  if [[ "$_cli_deferred" == false ]]; then
    cli_is_help "${1:-}" && usage 0 || true
  fi
fi
