#!/usr/bin/env bash
# Saves the statusline's rate_limits so Leeway sees Claude usage as it happens.
# Call it from a Claude Code statusline script, after reading stdin into $input:
#   printf '%s' "$input" | "/path/to/leeway/scripts/claude-statusline-snapshot.sh" &
set -uo pipefail

out="$HOME/Library/Application Support/Leeway/claude-snapshots"
mkdir -p "$out"

if ! command -v jq >/dev/null 2>&1; then
  # Say it once, where the user can find it, instead of failing in silence on each update.
  [[ -f "$out/README-jq-missing.txt" ]] || echo "claude-statusline-snapshot.sh needs jq: brew install jq" > "$out/README-jq-missing.txt"
  exit 0
fi
rm -f "$out/README-jq-missing.txt"

dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
dir="${dir/#\~/$HOME}"
# Resolve symbolic links and remove a trailing slash, as Leeway does, so both compute the same name.
dir=$(cd "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir")
hash=$(printf '%s' "$dir" | shasum -a 256 | cut -c1-8)

tmp="$out/$hash.json.$$"
jq -c --arg dir "$dir" '
  select(.rate_limits.five_hour != null or .rate_limits.seven_day != null)
  | {config_dir: $dir, captured_at: now, five_hour: .rate_limits.five_hour, seven_day: .rate_limits.seven_day}
' > "$tmp" 2>/dev/null

if [[ -s "$tmp" ]]; then mv "$tmp" "$out/$hash.json"; else rm -f "$tmp"; fi
