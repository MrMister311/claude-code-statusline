#!/bin/bash
# Claude Code Statusline - Context Monitor + Service Status + Session Info
# Multi-line: Line 1 = project info, Line 2 = context bar + duration

input=$(cat)

# --- Colors ---
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
DIM='\033[90m'
RESET='\033[0m'

# --- Claude Code Service Status (cached for 60 seconds) ---
STATUS_CACHE="/tmp/claude_code_status_cache"
STATUS_TTL=60
CLAUDE_CODE_COMPONENT_ID="yyzkbfz2thpt"

get_service_status() {
    local now=$(date +%s)
    local cache_time=0

    if [ -f "$STATUS_CACHE" ]; then
        cache_time=$(stat -f %m "$STATUS_CACHE" 2>/dev/null || echo 0)
    fi

    if [ $((now - cache_time)) -lt $STATUS_TTL ] && [ -f "$STATUS_CACHE" ]; then
        cat "$STATUS_CACHE"
        return
    fi

    local status=$(curl -s --max-time 1 "https://status.claude.com/api/v2/components.json" 2>/dev/null | \
        jq -r ".components[] | select(.id == \"$CLAUDE_CODE_COMPONENT_ID\") | .status" 2>/dev/null)

    if [ -n "$status" ]; then
        echo "$status" > "$STATUS_CACHE"
        echo "$status"
    elif [ -f "$STATUS_CACHE" ]; then
        cat "$STATUS_CACHE"
    else
        echo "unknown"
    fi
}

format_status() {
    case "$1" in
        operational)         printf "${GREEN}✓${RESET}" ;;
        degraded_performance) printf "${YELLOW}◐${RESET}" ;;
        partial_outage)      printf "${YELLOW}⚠${RESET}" ;;
        major_outage)        printf "${RED}✗${RESET}" ;;
        *)                   printf "${DIM}?${RESET}" ;;
    esac
}

# --- Git branch (cached for 5 seconds) ---
GIT_CACHE="/tmp/statusline-git-cache"
GIT_CACHE_TTL=5

get_git_branch() {
    local dir="$1"
    [ -z "$dir" ] || [ "$dir" = "null" ] && return

    local now=$(date +%s)
    local cache_time=0

    if [ -f "$GIT_CACHE" ]; then
        cache_time=$(stat -f %m "$GIT_CACHE" 2>/dev/null || echo 0)
    fi

    if [ $((now - cache_time)) -lt $GIT_CACHE_TTL ] && [ -f "$GIT_CACHE" ]; then
        cat "$GIT_CACHE"
        return
    fi

    local branch=$(git -C "$dir" branch --show-current 2>/dev/null)
    echo "$branch" > "$GIT_CACHE"
    echo "$branch"
}

# --- Extract data ---
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
pct=$(echo "$input" | jq -r '.context_window.used_percentage // ""' | cut -d. -f1)
dir=$(echo "$input" | jq -r '.workspace.current_dir // ""')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# Handle null/empty percentage
if [ -z "$pct" ] || [ "$pct" = "null" ]; then
    pct=0
fi

# --- Service status ---
service_status=$(get_service_status)
status_indicator=$(format_status "$service_status")

# --- Waiting state (before first API response) ---
if [ "$pct" -eq 0 ] && [ "$duration_ms" -eq 0 ]; then
    echo -e "${CYAN}[$model]${RESET} Waiting for first response... $status_indicator"
    exit 0
fi

# --- Context bar color ---
if [ "$pct" -ge 90 ]; then
    BAR_COLOR="$RED"
elif [ "$pct" -ge 70 ]; then
    BAR_COLOR="$YELLOW"
else
    BAR_COLOR="$GREEN"
fi

# --- Build progress bar (20 chars wide) ---
BAR_WIDTH=20
FILLED=$((pct * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))
BAR=""
[ "$FILLED" -gt 0 ] && BAR=$(printf "%${FILLED}s" | tr ' ' '█')
[ "$EMPTY" -gt 0 ] && BAR="${BAR}$(printf "%${EMPTY}s" | tr ' ' '░')"

# --- Session duration ---
duration_sec=$((duration_ms / 1000))
mins=$((duration_sec / 60))
secs=$((duration_sec % 60))

# --- Derive used tokens from percentage for display ---
used_tokens=$((pct * context_size / 100))
fmt_used=$(printf "%'d" $used_tokens)
fmt_size=$(printf "%'d" $context_size)

# --- Directory + git ---
dir_name=""
git_info=""
if [ -n "$dir" ] && [ "$dir" != "null" ]; then
    dir_name="${dir##*/}"
    branch=$(get_git_branch "$dir")
    [ -n "$branch" ] && git_info=" | ${DIM}🌿 ${branch}${RESET}"
fi

# --- Output (2 lines) ---
# Line 1: Model, directory, git branch, service status
echo -e "${CYAN}[$model]${RESET} 📁 ${dir_name}${git_info} $status_indicator"
# Line 2: Context progress bar, percentage, token counts, session duration
echo -e "${BAR_COLOR}${BAR}${RESET} ${BAR_COLOR}${pct}%${RESET} context ${DIM}($fmt_used / $fmt_size)${RESET} | ⏱️  ${mins}m ${secs}s"
