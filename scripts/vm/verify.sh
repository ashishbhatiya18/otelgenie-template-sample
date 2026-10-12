#!/usr/bin/env bash
# Read-only. Reports whether the collector is running and data is flowing.
# Run with sudo if you can; without it some checks are reported as unknown.
set -u

ETC=/etc/otelcol-otelgenie
SVC=otelgenie-otelcol
METRICS_HOST=127.0.0.1
METRICS_PORT=8888

lines=()
emit() { lines+=("$1"); }

emit "host=$(uname -n 2>/dev/null || echo unknown)"
emit "time=$(date +%s)"

if command -v systemctl >/dev/null 2>&1; then
  emit "service=$(systemctl is-active "$SVC" 2>/dev/null)"
  emit "restarts=$(systemctl show "$SVC" -p NRestarts --value 2>/dev/null)"
  emit "memory_max=$(systemctl show "$SVC" -p MemoryMax --value 2>/dev/null)"
  emit "memory_current=$(systemctl show "$SVC" -p MemoryCurrent --value 2>/dev/null)"
else
  emit "service=unknown"
fi

if [ -r "$ETC/otelcol.env" ]; then
  emit "placeholders=$(grep -c '=CHANGE_ME$' "$ETC/otelcol.env")"
else
  emit "placeholders=unknown"
fi

sum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
for f in "$ETC"/conf.d/*.yaml; do
  [ -r "$f" ] && emit "file.conf.d/$(basename "$f")=$(sum "$f")"
done

fetch_metrics() {
  # OTELGENIE_METRICS_FILE lets the template's tests feed a saved status page.
  if [ -n "${OTELGENIE_METRICS_FILE:-}" ]; then
    cat "$OTELGENIE_METRICS_FILE"
  elif command -v curl >/dev/null 2>&1; then
    curl -s -m 5 "http://$METRICS_HOST:$METRICS_PORT/metrics"
  else
    exec 3<>"/dev/tcp/$METRICS_HOST/$METRICS_PORT" || return 1
    printf 'GET /metrics HTTP/1.0\r\nHost: %s\r\n\r\n' "$METRICS_HOST" >&3
    cat <&3
    exec 3<&-
  fi
}

raw="$(fetch_metrics 2>/dev/null)"
if [ -z "$raw" ]; then
  emit "metrics=unreachable"
else
  emit "metrics=ok"
  while IFS= read -r l; do
    [ -n "$l" ] && emit "$l"
  done < <(printf '%s\n' "$raw" | awk '
    /^otelcol_(receiver_accepted|receiver_refused|receiver_failed|scraper_scraped|scraper_errored|exporter_sent|exporter_send_failed|exporter_enqueue_failed)_/ {
      name = $1; sub(/\{.*/, "", name)
      who = "-"
      if (match($0, /(receiver|exporter)="[^"]*"/)) {
        who = substr($0, RSTART, RLENGTH); sub(/^[a-z]*="/, "", who); sub(/"$/, "", who)
      }
      total[name "|" who] += $NF
    }
    END { for (k in total) printf "m.%s=%d\n", k, total[k] }' | sort)
fi

if command -v journalctl >/dev/null 2>&1; then
  i=0
  while IFS= read -r l; do
    i=$((i + 1))
    emit "err.$i=$l"
  done < <(journalctl -u "$SVC" --since "-15min" --no-pager -o cat 2>/dev/null |
    grep -E "$(printf '\t')(warn|error)$(printf '\t')|Exporting failed" | cut -c1-600 | tail -12)
fi

echo "OTELGENIE-VERIFY v1"
printf '%s\n' "${lines[@]}"
echo "END OTELGENIE-VERIFY lines=${#lines[@]}"
