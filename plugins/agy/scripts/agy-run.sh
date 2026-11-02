#!/usr/bin/env bash
# agy-run.sh — Claude Code wrapper around Google Antigravity CLI (`agy`).
# Subcommands: check | ask | review | image | help.
# `--model` (on ask) resolves an alias and passes it to agy's own
# `--model` flag for that call only.

set -euo pipefail

is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

install_hint() {
  if is_windows; then
    echo "irm https://antigravity.google/cli/install.ps1 | iex   (in PowerShell)"
  else
    echo "curl -fsSL https://antigravity.google/cli/install.sh | bash"
  fi
}

find_agy() {
  if command -v agy >/dev/null 2>&1; then
    command -v agy
    return 0
  fi
  # Windows installer puts agy.exe in %LOCALAPPDATA%\agy\bin and only
  # updates the *registry* PATH, so an already-running Claude Code won't see it.
  local win_local=""
  if is_windows && [ -n "${LOCALAPPDATA:-}" ]; then
    win_local="$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || printf '%s' "$LOCALAPPDATA")/agy/bin/agy.exe"
  fi
  for candidate in \
      ${win_local:+"$win_local"} \
      "$HOME/.local/bin/agy" \
      "/opt/antigravity/bin/agy" \
      "/usr/local/bin/agy"; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

auth_status() {
  if [ -n "${ANTIGRAVITY_API_KEY:-}" ]; then
    echo "api-key"
  elif [ -d "$HOME/.config/antigravity" ] || [ -d "$HOME/.gemini/antigravity-cli" ]; then
    echo "oauth"
  else
    echo "missing"
  fi
}

j_esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

cmd_check() {
  if ! path="$(find_agy | head -n1)"; then
    cat <<JSON
{ "installed": false, "path": "", "version": "", "auth": "unknown",
  "error": "agy binary not found; install with: $(j_esc "$(install_hint)")" }
JSON
    return 0
  fi
  version="$("$path" --version 2>/dev/null | head -n1 || echo unknown)"
  auth="$(auth_status)"
  printf '{ "installed": true, "path": "%s", "version": "%s", "auth": "%s", "error": "" }\n' \
    "$(j_esc "$path")" "$(j_esc "$version")" "$(j_esc "$auth")"
}

require_ready() {
  if ! path="$(find_agy)"; then
    echo "error: agy is not installed." >&2
    echo "       install: $(install_hint)" >&2
    exit 127
  fi
  if [ "$(auth_status)" = "missing" ]; then
    echo "error: agy is not authenticated." >&2
    echo "       run \`agy\` once interactively, or export ANTIGRAVITY_API_KEY" >&2
    exit 1
  fi
  echo "$path"
}

# fd arg lets cmd_help reuse the same table on stdout.
print_model_table() {
  local fd="${1:-2}"
  {
    echo "Aliases (case-insensitive):"
    echo "  flash-low                     -> Gemini 3.8 Flash (Low)"
    echo "  flash-medium, flash-med       -> Gemini 3.8 Flash (Medium)"
    echo "  flash, flash-high             -> Gemini 3.8 Flash (High)"
    echo "  pro-low, argon-low            -> Gemini 4 Argon (Low)"
    echo "  pro-medium, argon-medium      -> Gemini 4 Argon (Medium)"
    echo "  pro, pro-high, argon          -> Gemini 4 Argon (High)"
    echo "  sonnet, claude-sonnet         -> Claude Sonnet 5.5 (High)"
    echo "  opus, claude-opus             -> Claude Opus 5.5 (High)"
    echo "  gpt-oss, gpt-oss-120b         -> GPT-OSS 120B (Medium)"
    echo
    echo "Anything else is passed verbatim to \`agy --model\`, which accepts"
    echo "model ids or display names. Run \`agy models\` for the current list."
  } >&"$fd"
}

resolve_model_alias() {
  local input="${1:-}"
  if [ -z "$input" ]; then
    echo "error: --model requires a non-empty value (e.g. --model pro)" >&2
    print_model_table 2
    exit 64
  fi
  # bash 3.2 (macOS /bin/bash) lacks ${var,,}, hence tr.
  local lc; lc="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    flash-low)                     printf '%s' "Gemini 3.8 Flash (Low)" ;;
    flash-medium|flash-med)        printf '%s' "Gemini 3.8 Flash (Medium)" ;;
    flash|flash-high)              printf '%s' "Gemini 3.8 Flash (High)" ;;
    pro-low|argon-low)             printf '%s' "Gemini 4 Argon (Low)" ;;
    pro-medium|pro-med|argon-medium) printf '%s' "Gemini 4 Argon (Medium)" ;;
    pro|pro-high|argon|argon-high) printf '%s' "Gemini 4 Argon (High)" ;;
    sonnet|claude-sonnet)          printf '%s' "Claude Sonnet 5.5 (High)" ;;
    opus|claude-opus)              printf '%s' "Claude Opus 5.5 (High)" ;;
    gpt-oss|gpt-oss-120b)          printf '%s' "GPT-OSS 120B (Medium)" ;;
    # agy validates the name itself and lists valid models on error.
    *)                             printf '%s' "$input" ;;
  esac
}

cmd_ask() {
  local model_alias=""
  local model_flag_seen=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)
        model_flag_seen=1
        # `shift 2` on a one-arg list would `set -e`-exit silently; handle
        # the empty case so resolve_model_alias prints the real error.
        if [ $# -ge 2 ]; then
          model_alias="$2"; shift 2
        else
          shift
        fi ;;
      --model=*)
        model_flag_seen=1
        model_alias="${1#--model=}"
        shift ;;
      --)        shift; break ;;
      *)         break ;;
    esac
  done
  # Resolve model before prompt check so empty --model gets the right error.
  local canonical=""
  if [ "$model_flag_seen" -eq 1 ]; then
    canonical="$(resolve_model_alias "$model_alias")"
  fi
  local prompt="${1:-}"
  shift || true
  if [ -z "$prompt" ]; then
    echo "error: ask requires a prompt argument" >&2
    exit 64
  fi
  local path
  path="$(require_ready)"
  if [ -n "$canonical" ]; then
    "$path" --model "$canonical" -p "$prompt" "$@"
  else
    "$path" -p "$prompt" "$@"
  fi
}

cmd_review() {
  local focus="${1:-Please review the following diff for correctness, edge cases, security issues, and style.}"
  local path
  path="$(require_ready)"
  local repo_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  local diff
  diff="$(git -C "$repo_dir" diff HEAD 2>/dev/null || true)"
  if [ -z "$diff" ]; then
    diff="$(git -C "$repo_dir" diff 2>/dev/null || true)"
  fi
  if [ -z "$diff" ]; then
    echo "error: no git diff found in $repo_dir. Stage or make changes first." >&2
    exit 1
  fi
  # Windows caps a command line at ~32K chars (Linux: 128K per argument) and
  # `agy -p` ignores stdin, so large diffs go through a file agy can read.
  local max_inline="${AGY_REVIEW_INLINE_MAX:-24000}"
  if [ "${#diff}" -le "$max_inline" ]; then
    local full
    full=$(printf '%s\n\nDiff:\n```diff\n%s\n```\n' "$focus" "$diff")
    "$path" -p "$full"
    return
  fi
  local tmpdir; tmpdir="$(mktemp -d)"
  trap "rm -rf $(printf '%q' "$tmpdir")" EXIT
  printf '%s\n' "$diff" > "$tmpdir/review.diff"
  local diff_file="$tmpdir/review.diff" add_dir="$tmpdir"
  if is_windows && command -v cygpath >/dev/null 2>&1; then
    diff_file="$(cygpath -w "$diff_file")"
    add_dir="$(cygpath -w "$add_dir")"
  fi
  "$path" --add-dir "$add_dir" \
    -p "$(printf '%s\n\nThe diff is too large to inline. Read it from this file (unified diff of %s): %s' \
           "$focus" "$repo_dir" "$diff_file")"
}

cmd_image() {
  local description=""
  local name=""
  local output=""
  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)
        if [ $# -ge 2 ]; then
          name="$2"; shift 2
        else
          echo "error: --name requires a value (e.g. --name coffee_cup)" >&2
          exit 64
        fi ;;
      --name=*)
        name="${1#--name=}"
        if [ -z "$name" ]; then
          echo "error: --name= requires a non-empty value" >&2
          exit 64
        fi
        shift ;;
      --output)
        if [ $# -ge 2 ]; then
          output="$2"; shift 2
        else
          echo "error: --output requires a path (e.g. --output /tmp/out.png)" >&2
          exit 64
        fi ;;
      --output=*)
        output="${1#--output=}"
        if [ -z "$output" ]; then
          echo "error: --output= requires a non-empty path" >&2
          exit 64
        fi
        shift ;;
      --)        shift; positional+=("$@"); break ;;
      *)         positional+=("$1"); shift ;;
    esac
  done
  description="${positional[*]}"
  if [ -z "$description" ]; then
    echo "error: image requires a description" >&2
    exit 64
  fi
  local agy_path
  agy_path="$(require_ready)"

  local name_clause=""
  if [ -n "$name" ]; then
    name_clause=" Save the image with name \"${name}\"."
  fi
  local prompt
  prompt="Use your built-in generate_image tool to create the following image. Description: ${description}.${name_clause}

After the tool returns, you MUST end your reply with a single line in this exact format (no quotes, no markdown, nothing after it):
IMAGE_PATH: <absolute filesystem path to the saved image>

The IMAGE_PATH line is required — the calling wrapper parses it to locate the file."

  local response rc
  response="$("$agy_path" -p "$prompt" 2>&1)" || rc=$?
  rc="${rc:-0}"
  printf '%s\n' "$response"

  local src
  src="$(printf '%s' "$response" \
    | sed -n 's/^[[:space:]]*IMAGE_PATH:[[:space:]]*//p' \
    | tail -n1)"

  # Fallback when the model skips the marker line.
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    src="$(printf '%s' "$response" \
      | grep -oE '/[^[:space:]]+\.(png|jpg|jpeg|webp)' \
      | head -n1)"
  fi

  if [ -n "$src" ] && [ -f "$src" ]; then
    echo
    echo "[wrapper] generated: $src"
    if [ -n "$output" ]; then
      cp "$src" "$output"
      echo "[wrapper] copied to: $output"
    fi
  else
    echo
    echo "[wrapper] warning: agy did not include an IMAGE_PATH line and no image path was found in its reply." >&2
    echo "[wrapper]          if --output was requested, the copy was skipped." >&2
  fi
  return "$rc"
}

cmd_help() {
  cat <<'HELP'
/agy:* commands (Claude Code plugin for the Antigravity CLI)

Slash commands
  /agy:setup                            Verify agy install + auth. Offers install if missing.
  /agy:ask [--model A] <prompt>         One-shot prompt; returns agy's response verbatim.
  /agy:delegate [--background] [--model A] <task>
                                        Hand a task to the agy:runner subagent.
  /agy:research [--background] [--model A] <topic>
                                        Deep-research investigation via agy:runner.
  /agy:review [focus]                   Send current `git diff` to agy for review.
  /agy:image [--name S] [--output P] <description>
                                        Generate an image via agy's built-in tool.
  /agy:help                             This help.

Model selection (--model)
HELP
  print_model_table 1
  cat <<'HELP'

How --model works
  The wrapper resolves the alias and passes it to agy's own --model flag for
  that call only; your default model and any open TUI are left untouched.
  Unknown names are forwarded as-is and agy rejects invalid ones with the
  list of available models.

Underlying CLI
  Run `agy --help` for agy's own flags: --add-dir, -c/--continue,
  --conversation, --dangerously-skip-permissions, -i/--prompt-interactive,
  --log-file, --model, -p/--print, --print-timeout, --sandbox.

  Subcommands: changelog, help, install, models, plugin/plugins, update.
HELP
}

main() {
  case "${1:-}" in
    check)              cmd_check ;;
    ask)     shift;     cmd_ask "$@" ;;
    review)  shift;     cmd_review "$@" ;;
    image)   shift;     cmd_image "$@" ;;
    help|-h|--help|"")  cmd_help ;;
    *)                  echo "error: unknown subcommand '$1'" >&2; cmd_help >&2; exit 64 ;;
  esac
}

# Skip dispatch when sourced (lets unit tests call functions directly).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  main "$@"
fi
