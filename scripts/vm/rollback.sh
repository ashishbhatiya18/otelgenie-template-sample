#!/usr/bin/env bash
# Removes everything apply.sh installed. Needs root.
# It does not remove the otelcol-contrib package itself.
set -u

ETC=/etc/otelcol-otelgenie
SVC=otelgenie-otelcol
UNIT=/etc/systemd/system/$SVC.service

lines=()
emit() { lines+=("$1"); }
finish() {
  emit "result=$1"
  echo "OTELGENIE-ROLLBACK v1"
  printf '%s\n' "${lines[@]}"
  echo "END OTELGENIE-ROLLBACK lines=${#lines[@]}"
  exit "$2"
}

emit "host=$(uname -n 2>/dev/null || echo unknown)"
emit "time=$(date +%s)"
[ "$(id -u)" = 0 ] || finish need-root 2

systemctl stop "$SVC" >/dev/null 2>&1
systemctl disable "$SVC" >/dev/null 2>&1
rm -f "$UNIT"
rm -rf "$ETC"
systemctl daemon-reload
finish ok 0
