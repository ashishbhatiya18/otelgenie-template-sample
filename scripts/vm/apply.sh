#!/usr/bin/env bash
# Installs the generated collector configuration as a systemd service.
# Needs root. Safe to run again: it replaces its own files and nothing else.
set -u

ETC=/etc/otelcol-otelgenie
SVC=otelgenie-otelcol
UNIT=/etc/systemd/system/$SVC.service

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here" || exit 1

lines=()
emit() { lines+=("$1"); }
finish() {
  emit "result=$1"
  echo "OTELGENIE-APPLY v1"
  printf '%s\n' "${lines[@]}"
  echo "END OTELGENIE-APPLY lines=${#lines[@]}"
  exit "$2"
}

emit "host=$(uname -n 2>/dev/null || echo unknown)"
emit "time=$(date +%s)"

[ "$(id -u)" = 0 ] || finish need-root 2

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c --quiet MANIFEST.sha256 >/dev/null 2>&1 || finish corrupt-files 2
fi

# shellcheck disable=SC1091
. ./settings.env

BIN="$(command -v otelcol-contrib || true)"
[ -n "$BIN" ] || finish missing-collector 3
emit "collector=$("$BIN" --version 2>/dev/null | awk '{print $NF}')"

# The package ships its own service with a sample configuration. It holds the
# same ports, so it is switched off in favour of the one installed here.
if systemctl is-enabled otelcol-contrib.service >/dev/null 2>&1 || systemctl is-active otelcol-contrib.service >/dev/null 2>&1; then
  systemctl disable --now otelcol-contrib.service >/dev/null 2>&1
  emit "packaged_service=stopped"
fi

install -d -m 0755 "$ETC" "$ETC/conf.d"
rm -f "$ETC"/conf.d/*.yaml
install -m 0644 conf.d/*.yaml "$ETC/conf.d/"
[ -f ca-bundle.pem ] && install -m 0644 ca-bundle.pem "$ETC/ca-bundle.pem"

# Keep secrets already entered on this server; ask for the ones still missing.
tmp="$(mktemp)"
while IFS= read -r line; do
  case "$line" in
    '' | '#'*) printf '%s\n' "$line" >>"$tmp"; continue ;;
  esac
  k="${line%%=*}"
  v="${line#*=}"
  if [ "$v" = CHANGE_ME ] && [ -f "$ETC/otelcol.env" ]; then
    old="$(grep -m1 "^$k=" "$ETC/otelcol.env" | cut -d= -f2-)"
    if [ -n "$old" ] && [ "$old" != CHANGE_ME ]; then v="$old"; fi
  fi
  if [ "$v" = CHANGE_ME ] && { : </dev/tty; } 2>/dev/null; then
    printf 'Enter the value for %s (typing is hidden, press Enter to skip): ' "$k" >/dev/tty
    IFS= read -rs entered </dev/tty
    echo >/dev/tty
    if [ -n "$entered" ]; then v="$entered"; fi
  fi
  printf '%s=%s\n' "$k" "$v" >>"$tmp"
done <otelcol.env
# The collector runs as its own user, not as root. The user has no login and
# no home; it is created here if the server does not have it yet.
if [ "$SERVICE_USER" != root ] && ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi
# systemd reads this file as root before it starts the service, so the
# service user needs no access to it.
install -m 0600 "$tmp" "$ETC/otelcol.env"
rm -f "$tmp"

n=0
while IFS= read -r name; do
  n=$((n + 1))
  emit "placeholder.$n=$name"
done < <(grep '=CHANGE_ME$' "$ETC/otelcol.env" | cut -d= -f1)
emit "placeholders=$n"
[ "$n" = 0 ] || finish placeholders 4

configs=()
for f in "$ETC"/conf.d/*.yaml; do configs+=(--config "$f"); done

validate_out="$(
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    export "${line%%=*}=${line#*=}"
  done <"$ETC/otelcol.env"
  "$BIN" validate "${configs[@]}" 2>&1
)"
if [ $? -ne 0 ]; then
  i=0
  while IFS= read -r l; do
    i=$((i + 1))
    emit "validate.$i=$l"
  done < <(printf '%s\n' "$validate_out" | tail -5)
  finish invalid-config 5
fi

# Without root, reading other services' log files and process details takes
# these two capabilities and nothing more.
CAPS="# runs as root"
if [ "$SERVICE_USER" != root ]; then
  CAPS="AmbientCapabilities=CAP_DAC_READ_SEARCH CAP_SYS_PTRACE
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_SYS_PTRACE"
fi

cat >"$UNIT" <<EOF
[Unit]
Description=OpenTelemetry Collector (managed by otelgenie)
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
$CAPS
EnvironmentFile=$ETC/otelcol.env
Environment=GOMEMLIMIT=${GOMEMLIMIT_MIB}MiB
ExecStart=$BIN ${configs[*]}
Restart=on-failure
RestartSec=10
MemoryMax=${MEMORY_MAX_MB}M
CPUQuota=${CPU_QUOTA_PERCENT}%
NoNewPrivileges=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SVC" >/dev/null 2>&1
systemctl restart "$SVC"
sleep 5
state="$(systemctl is-active "$SVC" 2>/dev/null)"
emit "service=$state"
if [ "$state" != active ]; then
  i=0
  while IFS= read -r l; do
    i=$((i + 1))
    emit "err.$i=$l"
  done < <(journalctl -u "$SVC" -n 8 --no-pager -o cat 2>/dev/null)
  finish service-failed 6
fi
finish ok 0
