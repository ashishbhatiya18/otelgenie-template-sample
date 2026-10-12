#!/usr/bin/env bash
# Read-only. Reports whether the collectors are running and data is flowing.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here" || exit 1

lines=()
emit() { lines+=("$1"); }
finish() {
  echo "OTELGENIE-VERIFY v1"
  printf '%s\n' "${lines[@]}"
  echo "END OTELGENIE-VERIFY lines=${#lines[@]}"
  exit 0
}

K=""
if command -v kubectl >/dev/null 2>&1; then K=kubectl; elif command -v oc >/dev/null 2>&1; then K=oc; fi
emit "time=$(date +%s)"
if [ -z "$K" ] || ! $K get --raw /version >/dev/null 2>&1; then
  emit "host=unknown"
  emit "service=unreachable"
  finish
fi
emit "host=$($K config current-context 2>/dev/null || echo unknown)"

# shellcheck disable=SC1091
. ./settings.env
NS="$NAMESPACE"
SEL=app.kubernetes.io/managed-by=opentelemetry-operator

state=""
all=yes
for c in $COLLECTORS; do
  if [ "$c" = node ]; then
    want="$($K -n "$NS" get daemonset otelgenie-node-collector -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
    ready="$($K -n "$NS" get daemonset otelgenie-node-collector -o jsonpath='{.status.numberReady}' 2>/dev/null)"
  else
    want="$($K -n "$NS" get deployment otelgenie-cluster-collector -o jsonpath='{.spec.replicas}' 2>/dev/null)"
    ready="$($K -n "$NS" get deployment otelgenie-cluster-collector -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  fi
  want="${want:-0}"
  ready="${ready:-0}"
  state="$state$c $ready of $want ready; "
  if [ "$want" = 0 ] || [ "$want" != "$ready" ]; then all=no; fi
done
if [ "$all" = yes ] && [ -n "$state" ]; then emit "service=active"; else emit "service=${state:-nothing installed}"; fi

restarts=0
for r in $($K -n "$NS" get pods -l "$SEL" -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' 2>/dev/null); do
  [ "$r" -gt "$restarts" ] 2>/dev/null && restarts="$r"
done
emit "restarts=$restarts"

# Counts values still set to the placeholder, without printing any value.
if data="$($K -n "$NS" get secret otelgenie-env -o jsonpath='{.data}' 2>/dev/null)"; then
  emit "placeholders=$(printf '%s' "$data" | grep -o '"Q0hBTkdFX01F"' | wc -l | tr -d ' ')"
else
  emit "placeholders=unknown"
fi

# Which generated files the cluster was last given.
while read -r sum path; do
  case "$path" in manifests/*) emit "file.$path=$sum" ;; esac
done < <($K -n "$NS" get configmap otelgenie-applied -o 'jsonpath={.data.MANIFEST\.sha256}' 2>/dev/null)

pods="$($K -n "$NS" get pods -l "$SEL" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
raw=""
for p in $pods; do
  # Each collector's own status page, read through the API server.
  raw="$raw
$($K get --raw "/api/v1/namespaces/$NS/pods/$p:8888/proxy/metrics" 2>/dev/null)"
done
if [ -z "$(printf '%s' "$raw" | tr -d '\n')" ]; then
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

i=0
while IFS= read -r l; do
  i=$((i + 1))
  emit "err.$i=$l"
done < <(for p in $pods; do $K -n "$NS" logs "$p" --since=15m 2>/dev/null; done |
  grep -E "$(printf '\t')(warn|error)$(printf '\t')|Exporting failed" | cut -c1-600 | sort -u | tail -12)

finish
