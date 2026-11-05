#!/usr/bin/env bash
# cursor / seen_ids の読み書き。fetch-comments.sh が書いた pending を確定させる。
set -euo pipefail

DATA="${REVIEW_INSIGHTS_HOME:-$HOME/.claude/review-insights}"
CONF="$DATA/config.json"

usage() {
  cat >&2 <<'USAGE'
usage:
  state.sh get <repo>              現在の state.json を表示（無ければ初期化）
  state.sh cursor <repo> [since]   有効な since を ISO8601 で表示（since 指定は "14d" / ISO 形式）
  state.sh commit <repo>           pending を seen_ids に取り込み cursor を進める
  state.sh reset <repo>            state を初期化する（全件取り直しになる）
USAGE
  exit 2
}

iso_from_spec() { # "14d" / "36h" / ISO8601 → ISO8601(UTC)
  local spec="$1"
  case "$spec" in
    *d) date -u -v-"${spec%d}"d +%Y-%m-%dT%H:%M:%SZ ;;
    *h) date -u -v-"${spec%h}"H +%Y-%m-%dT%H:%M:%SZ ;;
    *)  echo "$spec" ;;
  esac
}

state_file() { echo "$DATA/$1/state.json"; }

ensure_state() {
  local f; f="$(state_file "$1")"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || echo '{"cursor":null,"seen_ids":[],"last_run":null,"stats":{"fetched":0,"runs":0}}' > "$f"
  echo "$f"
}

cmd="${1:-}"; repo="${2:-}"
[ -n "$cmd" ] && [ -n "$repo" ] || usage
jq -e --arg r "$repo" '.repos[$r]' "$CONF" >/dev/null || { echo "unknown repo: $repo" >&2; exit 1; }

case "$cmd" in
  get) cat "$(ensure_state "$repo")" ;;
  cursor)
    f="$(ensure_state "$repo")"
    if [ -n "${3:-}" ]; then iso_from_spec "$3"
    else
      cur="$(jq -r '.cursor // empty' "$f")"
      [ -n "$cur" ] && echo "$cur" || iso_from_spec "$(jq -r '.default_since' "$CONF")"
    fi
    ;;
  commit)
    f="$(ensure_state "$repo")"
    p="$DATA/$repo/.pending_state.json"
    [ -f "$p" ] || { echo "no pending state for $repo (fetch-comments.sh を先に実行する)" >&2; exit 1; }
    max="$(jq -r '.seen_ids_max' "$CONF")"
    tmp="$(mktemp)"
    jq --slurpfile p "$p" --argjson max "$max" '
      .cursor = $p[0].next_cursor
      | .seen_ids = ((.seen_ids + $p[0].pending_ids) | unique_by(.) | .[-$max:])
      | .last_run = $p[0].run_started
      | .stats.fetched += ($p[0].pending_ids | length)
      | .stats.runs += 1
    ' "$f" > "$tmp" && mv "$tmp" "$f"
    rm -f "$p"
    jq -c '{cursor,last_run,seen:(.seen_ids|length),stats}' "$f"
    ;;
  reset)
    f="$(state_file "$repo")"; rm -f "$f" "$DATA/$repo/.pending_state.json"; ensure_state "$repo" >/dev/null
    echo "reset: $repo"
    ;;
  *) usage ;;
esac
