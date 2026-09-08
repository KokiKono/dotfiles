#!/usr/bin/env bash

input=$(cat)

# Parse JSON with python3 (no jq dependency)
result=$(STATUSLINE_INPUT="$input" python3 - <<'PYEOF'
import json, os

try:
    data = json.loads(os.environ.get("STATUSLINE_INPUT", "{}"))
except Exception:
    data = {}

model = (data.get("model") or {}).get("display_name") or "Claude"
cw = data.get("context_window") or {}
pct = int(cw.get("used_percentage") or 0)
cost_usd = (data.get("cost") or {}).get("total_cost_usd") or 0
duration_ms = int((data.get("cost") or {}).get("total_duration_ms") or 0)
cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or os.getcwd()
dirname = os.path.basename(cwd)
mins = duration_ms // 60000
secs = (duration_ms % 60000) // 1000

print(f"{model}\t{pct}\t{cost_usd:.2f}\t{mins}\t{secs}\t{dirname}")
PYEOF
)

if [[ -z "$result" ]]; then
  printf "\033[36m[Claude]\033[0m 📁 ...\n"
  exit 0
fi

model=$(echo "$result" | cut -f1)
pct=$(echo "$result" | cut -f2)
cost=$(echo "$result" | cut -f3)
mins=$(echo "$result" | cut -f4)
secs=$(echo "$result" | cut -f5)
dirname=$(echo "$result" | cut -f6)

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'

# Bar color based on context usage
if (( pct >= 90 )); then BAR_COLOR="$RED"
elif (( pct >= 70 )); then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILLED=$((pct / 10))
EMPTY=$((10 - FILLED))
BAR=""
[ "$FILLED" -gt 0 ] && BAR=$(printf "%${FILLED}s" | tr ' ' '█')
[ "$EMPTY" -gt 0 ] && BAR="${BAR}$(printf "%${EMPTY}s" | tr ' ' '░')"

# Git branch
BRANCH=""
git rev-parse --git-dir > /dev/null 2>&1 && BRANCH=" | 🌿 $(git branch --show-current 2>/dev/null)"

printf "${CYAN}[%s]${RESET} 📁 %s%s\n" "$model" "$dirname" "$BRANCH"
printf "${BAR_COLOR}%s${RESET} %d%% | ${YELLOW}\$%s${RESET} | ⏱️  %dm %ds\n" "$BAR" "$pct" "$cost" "$mins" "$secs"
