#!/usr/bin/env bash
# Read-only. Prints facts about this server so otelgenie can tailor the setup.
# It changes nothing and prints no passwords or file contents.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
items="$here/discover.items"

lines=()
emit() { lines+=("$1"); }

emit "host=$(uname -n 2>/dev/null || echo unknown)"
emit "time=$(date +%s)"
if [ -r /etc/os-release ]; then
  emit "os_id=$( (. /etc/os-release; echo "${ID:-unknown}") )"
  emit "os_like=$( (. /etc/os-release; echo "${ID_LIKE:-}") )"
  emit "os_version=$( (. /etc/os-release; echo "${VERSION_ID:-unknown}") )"
else
  emit "os_id=$(uname -s | tr '[:upper:]' '[:lower:]')"
  emit "os_like="
  emit "os_version=unknown"
fi
emit "arch=$(uname -m)"
if [ -r /proc/meminfo ]; then
  emit "mem_total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
else
  emit "mem_total_kb=unknown"
fi
emit "cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
if [ -d /run/systemd/system ]; then emit "systemd=yes"; else emit "systemd=no"; fi

if command -v otelcol-contrib >/dev/null 2>&1; then
  emit "collector=$(otelcol-contrib --version 2>/dev/null | awk '{print $NF}')"
else
  emit "collector=none"
fi

if ! command -v journalctl >/dev/null 2>&1; then
  emit "journal=missing"
elif journalctl -n 0 >/dev/null 2>&1; then
  emit "journal=ok"
else
  emit "journal=denied"
fi

listening=""
ports_source=none
if command -v ss >/dev/null 2>&1; then
  listening="$(ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -u)"
  ports_source=ss
elif command -v netstat >/dev/null 2>&1; then
  listening="$(netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}' | sed 's/.*://' | sort -u)"
  ports_source=netstat
fi
emit "ports_source=$ports_source"

if [ -r "$items" ]; then
  while read -r kind a b; do
    case "$kind" in
      port)
        if [ "$ports_source" = none ]; then
          emit "port.$a=unknown"
        elif printf '%s\n' "$listening" | grep -qx "$a"; then
          emit "port.$a=open"
        else
          emit "port.$a=closed"
        fi
        ;;
      unit)
        if ! command -v systemctl >/dev/null 2>&1; then
          emit "unit.$a=unknown"
        elif ! systemctl cat "$a.service" >/dev/null 2>&1; then
          emit "unit.$a=missing"
        else
          emit "unit.$a=$(systemctl is-active "$a.service" 2>/dev/null)"
        fi
        ;;
      glob)
        count="$(compgen -G "$a" | wc -l | tr -d ' ')"
        parent="$(dirname "$a")"
        if [ "$count" = 0 ] && [ -d "$parent" ] && [ ! -r "$parent" ]; then
          emit "glob.$a=denied"
        else
          emit "glob.$a=$count"
        fi
        ;;
      tcp)
        if command -v timeout >/dev/null 2>&1 && timeout 5 bash -c "exec 3<>/dev/tcp/$a/$b" 2>/dev/null; then
          emit "tcp.$a:$b=ok"
        else
          emit "tcp.$a:$b=fail"
        fi
        ;;
    esac
  done <"$items"
else
  emit "items=missing"
fi

echo "OTELGENIE-DISCOVER v1"
printf '%s\n' "${lines[@]}"
echo "END OTELGENIE-DISCOVER lines=${#lines[@]}"
