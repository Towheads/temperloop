#!/bin/bash
# Display: current folder path | model | context remaining progress bar

input=$(cat)

# Persist the live rate-limit snapshot for out-of-band consumers — the build
# / sweep 5-hour-quota gate reads it (foundation #447). The statusline
# is the ONLY surface Claude Code hands `.rate_limits`, and it renders constantly
# during an active run, so this file stays near-real-time at zero token cost.
# Cheap, atomic (tmp + mv), and non-fatal: only writes when `.rate_limits` is
# present, and any failure is swallowed so the prompt never breaks or stalls.
if printf '%s' "$input" | jq -e '.rate_limits' >/dev/null 2>&1; then
  _rl_out="$HOME/.claude/rate-limits.json"
  _rl_tmp="$_rl_out.$$.tmp"
  if printf '%s' "$input" \
    | jq -c '{five_hour: .rate_limits.five_hour, seven_day: .rate_limits.seven_day, captured_at: (now | floor)}' \
      > "$_rl_tmp" 2>/dev/null; then
    mv -f "$_rl_tmp" "$_rl_out" 2>/dev/null || rm -f "$_rl_tmp" 2>/dev/null
  else
    rm -f "$_rl_tmp" 2>/dev/null
  fi
fi

# ANSI color codes
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

# Get full current folder path from JSON input
FOLDER=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // empty')
[ -z "$FOLDER" ] && FOLDER=$(pwd)

# Append current git branch (or short SHA if detached) when FOLDER is a git repo
BRANCH=$(git -C "$FOLDER" branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && BRANCH=$(git -C "$FOLDER" rev-parse --short HEAD 2>/dev/null)
[ -n "$BRANCH" ] && FOLDER="$FOLDER ($BRANCH)"

# Get model display name from JSON input
MODEL=$(echo "$input" | jq -r '.model.display_name // empty')
[ -z "$MODEL" ] && MODEL=$(echo "$input" | jq -r '.model.id // empty')
[ -z "$MODEL" ] && MODEL="unknown"

# Format a quota: "5h: 93%" colored by remaining
format_quota() {
  local label="$1" used_pct="$2"
  [ -z "$used_pct" ] || [ "$used_pct" = "null" ] && { echo "${label}: --"; return; }
  local left
  left=$(awk -v u="$used_pct" 'BEGIN { printf "%.0f", 100 - u }')
  local color="$GREEN"
  [ "$left" -le 50 ] && color="$YELLOW"
  [ "$left" -le 20 ] && color="$RED"
  printf "${label}: ${color}%s%%${RESET}" "$left"
}

build_quota_part() {
  local h5 d7 resets_at mins_left mins_part=""
  h5=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
  d7=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
  resets_at=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
  if [ -n "$resets_at" ] && [ "$resets_at" != "null" ]; then
    mins_left=$(( (resets_at - $(date +%s)) / 60 ))
    [ "$mins_left" -lt 0 ] && mins_left=0
    mins_part=" ${mins_left}m"
  fi
  printf "Quota [%b%s  %b]" "$(format_quota 5h "$h5")" "$mins_part" "$(format_quota 7d "$d7")"
}

# Format raw token count: 850, 12k, 1.2M
format_tokens() {
  local n="$1"
  awk -v n="$n" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n/1000000
    else if (n >= 1000) printf "%.0fk", n/1000
    else printf "%d", n
  }'
}

build_tokens_part() {
  local transcript total
  transcript=$(echo "$input" | jq -r '.transcript_path // empty')
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    total=$(jq -s 'map(.message.usage // {} | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.output_tokens // 0)) | add // 0' "$transcript" 2>/dev/null)
  fi
  [ -z "$total" ] || [ "$total" = "null" ] && total=0
  printf "Tokens: %s" "$(format_tokens "$total")"
}

# Build context remaining progress bar
REMAINING_PCT=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
WINDOW_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
if [ -n "$REMAINING_PCT" ] && [ -n "$WINDOW_SIZE" ]; then
  REMAINING_TOKENS=$(awk -v p="$REMAINING_PCT" -v s="$WINDOW_SIZE" 'BEGIN { printf "%.0f", s * p / 100 }')
else
  REMAINING_TOKENS=""
fi

if [ -n "$REMAINING_PCT" ]; then
  PCT=$(printf '%.0f' "$REMAINING_PCT")

  if [ "$PCT" -gt 50 ]; then
    COLOR="$GREEN"
  elif [ "$PCT" -gt 25 ]; then
    COLOR="$YELLOW"
  else
    COLOR="$RED"
  fi

  if [ -n "$REMAINING_TOKENS" ] && [ "$REMAINING_TOKENS" != "null" ]; then
    TOKENS_K=$(awk -v t="$REMAINING_TOKENS" 'BEGIN { printf "%.0fk", t/1000 }')
    CONTEXT_PART="Context: $(printf "${COLOR}${PCT}%% (${TOKENS_K})${RESET}")"
  else
    CONTEXT_PART="Context: $(printf "${COLOR}${PCT}%%${RESET}")"
  fi
  QUOTA_PART=$(build_quota_part)
  TOKENS_PART=$(build_tokens_part)
  printf "%s | %s | %b | %s | %s\n" "$FOLDER" "$MODEL" "$CONTEXT_PART" "$QUOTA_PART" "$TOKENS_PART"
else
  QUOTA_PART=$(build_quota_part)
  TOKENS_PART=$(build_tokens_part)
  printf "%s | %s | Context: -- | %s | %s\n" "$FOLDER" "$MODEL" "$QUOTA_PART" "$TOKENS_PART"
fi
