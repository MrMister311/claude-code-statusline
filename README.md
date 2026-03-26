# Claude Code Statusline — Service Status Add-on

Claude Code already lets you build a custom statusline with one command — just type `/statusline` and describe what you want. It'll generate a script, save it, and configure it for you. No repo needed.

**This project adds one thing you can't get from `/statusline`:** a live indicator that checks whether Claude Code's servers are actually up.

![Claude Code Statusline](statusline.jpg)

The green check mark in the screenshot — that's the service status indicator. It pings Anthropic's public status page and shows you at a glance:

- **Green ✓** — servers are working normally
- **Yellow ◐** — servers are up but slower than usual
- **Yellow ⚠** — partial outage
- **Red ✗** — major outage
- **Gray ?** — couldn't reach the status page (retries every 60 seconds)

> For the official statusline docs, see [code.claude.com/docs/en/statusline](https://code.claude.com/docs/en/statusline).

---

## Adding the Service Status to Your Statusline

If you already have a statusline script (from `/statusline` or your own), you can drop this into it.

### What you need

- `jq` installed (`brew install jq` on macOS, `apt install jq` on Linux)
- `curl` (almost certainly already installed)

### The code

Paste this into your existing `~/.claude/statusline.sh`:

```bash
# --- Claude Code Service Status (cached 60s) ---
STATUS_CACHE="/tmp/claude_code_status_cache"
STATUS_TTL=60
CLAUDE_CODE_COMPONENT_ID="yyzkbfz2thpt"

get_service_status() {
    local now=$(date +%s)
    local cache_time=0

    if [ -f "$STATUS_CACHE" ]; then
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
    local GREEN='\033[32m' YELLOW='\033[33m' RED='\033[31m' DIM='\033[90m' RESET='\033[0m'
    case "$1" in
        operational)          printf "${GREEN}✓${RESET}" ;;
        degraded_performance) printf "${YELLOW}◐${RESET}" ;;
        partial_outage)       printf "${YELLOW}⚠${RESET}" ;;
        major_outage)         printf "${RED}✗${RESET}" ;;
        *)                    printf "${DIM}?${RESET}" ;;
    esac
}
```

Then wherever you build your output line, add the indicator:

```bash
status_indicator=$(format_status "$(get_service_status)")
echo -e "your existing output here $status_indicator"
```

### How it works

- Calls Anthropic's public status page API (`status.claude.com`)
- Looks up the Claude Code component specifically (ID: `yyzkbfz2thpt`)
- Caches the result for 60 seconds so it's not hitting the API on every message
- The `curl` timeout is 1 second — if the API is slow, it falls back to the cached result
- Works on both macOS and Linux (handles the `stat` difference)

---

## Full Example Script

If you're starting from scratch and want a complete statusline with the service status baked in, there's a full working script in this repo: [`statusline.sh`](statusline.sh)

It includes a context progress bar, git branch, session timer, and the service status indicator. But honestly, you'll probably get a better starting point by running `/statusline` in Claude Code and then just pasting in the service status code from above.

---

## Don't Have a Statusline Yet?

1. Open Claude Code
2. Type `/statusline`
3. Describe what you want (e.g., "show context percentage with a progress bar and session timer")
4. Claude generates and configures it for you
5. Come back here and add the service status snippet if you want it

---

## License

MIT
