# Build a Custom Claude Code Statusline

## What This Is

Claude Code supports a customizable status bar at the bottom of the CLI. It works by running a shell script you write, piping JSON session data to it via stdin, and displaying whatever your script outputs to stdout. It updates after every assistant message (~300ms debounce).

## Prerequisites

- Claude Code CLI installed
- `jq` installed (`brew install jq` on macOS, `apt install jq` on Linux)
- A text editor

## Step 1: Create the Script

Create `~/.claude/statusline.sh`:

```bash
#!/bin/bash
# Claude Code Statusline - Context Monitor + Service Status + Session Info
# Output: 2 lines
#   Line 1: [Model] project-dir | branch  service-status
#   Line 2: ████████░░░░ 42% context (84,000 / 200,000) | 12m 34s

input=$(cat)

# --- Colors (ANSI escape codes) ---
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
DIM='\033[90m'
RESET='\033[0m'

# --- Claude Code Service Status (cached 60s to avoid hammering the API) ---
STATUS_CACHE="/tmp/claude_code_status_cache"
STATUS_TTL=60
CLAUDE_CODE_COMPONENT_ID="yyzkbfz2thpt"

get_service_status() {
    local now=$(date +%s)
    local cache_time=0

    if [ -f "$STATUS_CACHE" ]; then
        # macOS uses -f %m, Linux uses -c %Y for file mtime
        cache_time=$(stat -f %m "$STATUS_CACHE" 2>/dev/null || stat -c %Y "$STATUS_CACHE" 2>/dev/null || echo 0)
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
        operational)          printf "${GREEN}✓${RESET}" ;;
        degraded_performance) printf "${YELLOW}◐${RESET}" ;;
        partial_outage)       printf "${YELLOW}⚠${RESET}" ;;
        major_outage)         printf "${RED}✗${RESET}" ;;
        *)                    printf "${DIM}?${RESET}" ;;
    esac
}

# --- Git branch (cached 5s to avoid running git on every update) ---
GIT_CACHE="/tmp/statusline-git-cache"
GIT_CACHE_TTL=5

get_git_branch() {
    local dir="$1"
    [ -z "$dir" ] || [ "$dir" = "null" ] && return

    local now=$(date +%s)
    local cache_time=0

    if [ -f "$GIT_CACHE" ]; then
        cache_time=$(stat -f %m "$GIT_CACHE" 2>/dev/null || stat -c %Y "$GIT_CACHE" 2>/dev/null || echo 0)
    fi

    if [ $((now - cache_time)) -lt $GIT_CACHE_TTL ] && [ -f "$GIT_CACHE" ]; then
        cat "$GIT_CACHE"
        return
    fi

    local branch=$(git -C "$dir" branch --show-current 2>/dev/null)
    echo "$branch" > "$GIT_CACHE"
    echo "$branch"
}

# --- Extract data from Claude Code's JSON ---
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
pct=$(echo "$input" | jq -r '.context_window.used_percentage // ""' | cut -d. -f1)
dir=$(echo "$input" | jq -r '.workspace.current_dir // ""')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# Handle null/empty percentage (happens before first API response)
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

# --- Context bar color thresholds ---
if [ "$pct" -ge 90 ]; then
    BAR_COLOR="$RED"
elif [ "$pct" -ge 70 ]; then
    BAR_COLOR="$YELLOW"
else
    BAR_COLOR="$GREEN"
fi

# --- Build 20-char progress bar ---
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

# --- Token counts (derived from percentage for display) ---
used_tokens=$((pct * context_size / 100))
fmt_used=$(printf "%'d" $used_tokens)
fmt_size=$(printf "%'d" $context_size)

# --- Directory + git branch ---
dir_name=""
git_info=""
if [ -n "$dir" ] && [ "$dir" != "null" ]; then
    dir_name="${dir##*/}"
    branch=$(get_git_branch "$dir")
    [ -n "$branch" ] && git_info=" | ${DIM}🌿 ${branch}${RESET}"
fi

# --- Output (2 lines) ---
echo -e "${CYAN}[$model]${RESET} 📁 ${dir_name}${git_info} $status_indicator"
echo -e "${BAR_COLOR}${BAR}${RESET} ${BAR_COLOR}${pct}%${RESET} context ${DIM}($fmt_used / $fmt_size)${RESET} | ⏱️  ${mins}m ${secs}s"
```

Make it executable:

```bash
chmod +x ~/.claude/statusline.sh
```

## Step 2: Configure Claude Code

Add the `statusLine` key to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

If `settings.json` doesn't exist yet, create it with just that content. If it already exists, add the `statusLine` key alongside your existing config.

**Configuration options:**
- `type` (required): Must be `"command"`
- `command` (required): Path to script or inline shell command. `~` expands to home directory.
- `padding` (optional): Extra horizontal spacing in characters. Defaults to `0`.

**Inline alternative** (no separate script file):
```json
{
  "statusLine": {
    "type": "command",
    "command": "jq -r '\"[\\(.model.display_name)] \\(.context_window.used_percentage // 0)% context\"'"
  }
}
```

## Step 3: Verify

Start a new Claude Code session. You should see the statusline appear after your first message.

Test manually outside Claude Code:

```bash
# Green bar (25%)
echo '{"model":{"display_name":"Claude Opus 4.6"},"workspace":{"current_dir":"/tmp/test"},"context_window":{"context_window_size":200000,"used_percentage":25},"cost":{"total_duration_ms":345000}}' | ~/.claude/statusline.sh

# Yellow bar (78%)
echo '{"model":{"display_name":"Claude Opus 4.6"},"workspace":{"current_dir":"/tmp/test"},"context_window":{"context_window_size":200000,"used_percentage":78},"cost":{"total_duration_ms":1234000}}' | ~/.claude/statusline.sh

# Red bar (94%)
echo '{"model":{"display_name":"Claude Opus 4.6"},"workspace":{"current_dir":"/tmp/test"},"context_window":{"context_window_size":200000,"used_percentage":94},"cost":{"total_duration_ms":2700000}}' | ~/.claude/statusline.sh

# Waiting state (before first response)
echo '{"model":{"display_name":"Claude Opus 4.6"},"workspace":{"current_dir":"/tmp/test"},"context_window":{"context_window_size":200000},"cost":{"total_duration_ms":0}}' | ~/.claude/statusline.sh
```

---

## How It Works

1. Claude Code invokes your script after every assistant message (~300ms debounce)
2. It pipes JSON to stdin with model info, context usage, costs, workspace, etc.
3. Your script parses the JSON (with `jq`), formats it, and prints to stdout
4. Each line of output becomes a row in the status bar
5. ANSI color codes are fully supported

### Data Flow

```
Claude Code runtime
    |
    v
Serializes session state to JSON
    |
    v (pipes to stdin)
~/.claude/statusline.sh
    |
    v (reads JSON, parses with jq)
Formats output with colors, progress bar, etc.
    |
    v (prints to stdout)
Claude Code renders in status bar area
```

---

## JSON Input Reference

Claude Code pipes this JSON structure to your script's stdin. All fields are available for you to use.

### Core Fields (Always Present)

| Field | Type | Description |
|-------|------|-------------|
| `model.display_name` | string | Model name (e.g., "Opus") |
| `model.id` | string | Model ID (e.g., "claude-opus-4-6") |
| `workspace.current_dir` | string | Current working directory |
| `workspace.project_dir` | string | Directory where Claude Code was launched |
| `cost.total_cost_usd` | float | Session cost in USD |
| `cost.total_duration_ms` | number | Wall-clock session time (ms) |
| `cost.total_api_duration_ms` | number | Time waiting for API responses (ms) |
| `cost.total_lines_added` | number | Lines of code added this session |
| `cost.total_lines_removed` | number | Lines of code removed this session |
| `context_window.used_percentage` | float | Context usage 0-100 (pre-calculated, most accurate) |
| `context_window.remaining_percentage` | float | Context remaining 0-100 |
| `context_window.context_window_size` | number | Max tokens (200,000 default, 1,000,000 extended) |
| `context_window.total_input_tokens` | number | Cumulative input tokens (entire session) |
| `context_window.total_output_tokens` | number | Cumulative output tokens (entire session) |
| `session_id` | string | Unique session ID |
| `version` | string | Claude Code version |
| `cwd` | string | Current working directory (same as `workspace.current_dir`) |
| `output_style.name` | string | Current output style |
| `exceeds_200k_tokens` | boolean | Whether total tokens exceed 200k |

### Current API Call Details (null before first API response)

| Field | Type | Description |
|-------|------|-------------|
| `context_window.current_usage.input_tokens` | number | Input tokens in current context |
| `context_window.current_usage.output_tokens` | number | Output tokens generated |
| `context_window.current_usage.cache_creation_input_tokens` | number | Tokens written to cache |
| `context_window.current_usage.cache_read_input_tokens` | number | Tokens read from cache |

### Rate Limits (Pro/Max subscribers only, after first API response)

| Field | Type | Description |
|-------|------|-------------|
| `rate_limits.five_hour.used_percentage` | float | 5-hour rate limit usage (0-100) |
| `rate_limits.five_hour.resets_at` | number | Unix epoch when 5-hour window resets |
| `rate_limits.seven_day.used_percentage` | float | 7-day rate limit usage (0-100) |
| `rate_limits.seven_day.resets_at` | number | Unix epoch when 7-day window resets |

### Conditional Fields (Only present in specific modes)

| Field | Type | When Present |
|-------|------|-------------|
| `vim.mode` | string ("NORMAL"/"INSERT") | Only when vim mode is enabled |
| `agent.name` | string | Only when running with `--agent` flag |
| `worktree.name` | string | Only during `--worktree` sessions |
| `worktree.path` | string | Only during `--worktree` sessions |
| `worktree.branch` | string | Only during `--worktree` sessions |
| `worktree.original_cwd` | string | Only during `--worktree` sessions |
| `worktree.original_branch` | string | Only during `--worktree` sessions |

### Full Example JSON

```json
{
  "cwd": "/Users/you/project",
  "session_id": "abc123",
  "transcript_path": "/path/to/transcript.jsonl",
  "model": {
    "id": "claude-opus-4-6",
    "display_name": "Opus"
  },
  "workspace": {
    "current_dir": "/Users/you/project",
    "project_dir": "/Users/you/project"
  },
  "version": "1.0.80",
  "output_style": { "name": "default" },
  "cost": {
    "total_cost_usd": 0.01234,
    "total_duration_ms": 45000,
    "total_api_duration_ms": 2300,
    "total_lines_added": 156,
    "total_lines_removed": 23
  },
  "context_window": {
    "total_input_tokens": 15234,
    "total_output_tokens": 4521,
    "context_window_size": 200000,
    "used_percentage": 8,
    "remaining_percentage": 92,
    "current_usage": {
      "input_tokens": 8500,
      "output_tokens": 1200,
      "cache_creation_input_tokens": 5000,
      "cache_read_input_tokens": 2000
    }
  },
  "exceeds_200k_tokens": false,
  "rate_limits": {
    "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
  }
}
```

---

## Script Walkthrough

Here's what each section of the script does:

### 1. Read JSON Input
```bash
input=$(cat)
```
Claude Code pipes JSON to stdin. `cat` captures the entire input into a variable for repeated parsing.

### 2. ANSI Color Definitions
Standard escape codes for terminal coloring. These work in most modern terminals.

### 3. Service Status Check (with caching)
Queries Anthropic's public status page API to show whether Claude Code is operational. The result is cached to `/tmp/claude_code_status_cache` for 60 seconds to avoid a network call on every update. The `curl` timeout is 1 second — if the API is down, it falls back to the stale cache or shows `?`.

The component ID `yyzkbfz2thpt` is specifically the "Claude Code" component on status.claude.com.

### 4. Git Branch (with caching)
Runs `git branch --show-current` in the working directory, cached for 5 seconds. Without caching, this would run git on every single statusline update.

### 5. Data Extraction
Uses `jq` to pull specific fields from the JSON. The `// "default"` syntax provides fallback values for missing fields.

### 6. Waiting State
Before the first API response, `used_percentage` and `duration_ms` are both 0. The script shows a "Waiting..." message instead of a meaningless empty bar.

### 7. Progress Bar Construction
Builds a 20-character bar using Unicode block characters:
- `█` (U+2588) for filled portions
- `░` (U+2591) for empty portions

The color changes based on context usage thresholds.

### 8. Token Display
Since `used_percentage` is a percentage, tokens are derived: `pct * context_size / 100`. This is approximate but useful for display. The `printf "%'d"` adds comma separators for readability.

---

## Design Decisions & Gotchas

1. **Always use `used_percentage`** for context tracking. Don't manually calculate from token counts. Cumulative `total_input_tokens`/`total_output_tokens` can exceed `context_window_size` (they're session totals, not current window size). `used_percentage` reflects actual context state.

2. **Cache expensive operations.** The script runs after every assistant message. Git lookups (5s cache) and HTTP requests (60s cache) prevent performance issues.

3. **Handle nulls everywhere.** Many fields are null/empty before the first API response. Use jq defaults: `jq -r '.field // "fallback"'`

4. **`stat` differs on macOS vs Linux.** macOS uses `stat -f %m` for file mtime, Linux uses `stat -c %Y`. The script handles both with a fallback chain.

5. **`printf "%'d"` for number formatting** adds comma separators (e.g., 200,000). Requires locale support — works on macOS and most Linux distros.

6. **Keep it fast.** If your script takes >300ms, it'll be cancelled by the next update cycle. Avoid unbounded network calls without timeouts.

7. **The script must be executable.** `chmod +x` is required or the statusline silently fails.

8. **Changes take effect on next message.** Editing the script or settings.json won't visually update until Claude produces another response.

9. **Initial context is non-zero.** The statusline may show ~10-15% at session start — this is accurate (system prompt + CLAUDE.md are already in context).

10. **jq must be installed.** The statusline fails silently without it. Verify with `which jq`.

11. **Status line is disabled** if `disableAllHooks` is `true` in settings.

---

## Customization Ideas

### Add Rate Limit Tracking (Pro/Max)
```bash
rate_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // ""' | cut -d. -f1)
if [ -n "$rate_5h" ] && [ "$rate_5h" != "null" ]; then
    echo -e "${DIM}Rate: ${rate_5h}% (5h)${RESET}"
fi
```

### Add Cost Display (API Key Users)
```bash
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
echo -e "${DIM}Cost: \$${cost}${RESET}"
```

### Add Lines Changed
```bash
added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
echo -e "${GREEN}+${added}${RESET} ${RED}-${removed}${RESET} lines"
```

### Add Vim Mode Indicator
```bash
vim_mode=$(echo "$input" | jq -r '.vim.mode // ""')
if [ -n "$vim_mode" ] && [ "$vim_mode" != "null" ]; then
    echo -e "${CYAN}[${vim_mode}]${RESET}"
fi
```

### Late-Night Warning
```bash
hour=$(date +%H)
if [ "$hour" -ge 0 ] && [ "$hour" -lt 6 ]; then
    echo -e "${RED}🌙 It's late — consider wrapping up${RESET}"
fi
```

### Write in Python Instead
```python
#!/usr/bin/env python3
import json, sys

data = json.load(sys.stdin)
model = data.get("model", {}).get("display_name", "Claude")
pct = int(data.get("context_window", {}).get("used_percentage", 0) or 0)
bar_width = 20
filled = pct * bar_width // 100
bar = "█" * filled + "░" * (bar_width - filled)
print(f"[{model}] {bar} {pct}%")
```

### Minimal One-Liner (No Script File)
```json
{
  "statusLine": {
    "type": "command",
    "command": "jq -r '\"[\\(.model.display_name)] \\(.context_window.used_percentage // 0 | floor)% context\"'"
  }
}
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Statusline doesn't appear | Check `settings.json` has `statusLine` key, script is `chmod +x` |
| Empty or broken output | Verify `jq` is installed: `which jq` |
| Status shows `?` | Normal — means status API timed out, will retry in 60s |
| Numbers show without commas | Locale issue — `printf "%'d"` needs grouping support |
| Git branch is stale | 5-second cache — switches within 5s of branch change |
| Script seems to not update | Changes apply on next assistant message, not immediately |
| Statusline disappeared | Check if `disableAllHooks: true` is set in settings |

---

## License

MIT
