#!/usr/bin/env bash
# Installs the generated collectors into the cluster kubectl points at.
# Needs a cluster administrator. Safe to run again.
set -u

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
# Records up to eight lines of a command's output under a prefix.
detail() {
  local prefix="$1" i=0 l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    i=$((i + 1))
    emit "$prefix.$i=$(printf '%s' "$l" | cut -c1-600)"
  done < <(tail -8)
}

K=""
if command -v kubectl >/dev/null 2>&1; then K=kubectl; elif command -v oc >/dev/null 2>&1; then K=oc; fi
emit "time=$(date +%s)"
[ -n "$K" ] || { emit "host=unknown"; finish unreachable 2; }
emit "host=$($K config current-context 2>/dev/null || echo unknown)"
$K get --raw /version >/dev/null 2>&1 || finish unreachable 2
[ "$($K auth can-i create clusterrolebindings 2>/dev/null)" = yes ] || finish need-admin 2

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c --quiet MANIFEST.sha256 >/dev/null 2>&1 || finish corrupt-files 2
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>&1 || finish corrupt-files 2
fi

# shellcheck disable=SC1091
. ./settings.env
NS="$NAMESPACE"
has_crd() { $K get crd "$1" >/dev/null 2>&1; }

if ! has_crd opentelemetrycollectors.opentelemetry.io; then
  # The operator's manifest is carried in by hand, like a package would be.
  if [ "$PLATFORM" = ocp ] || [ -z "$OPERATOR_FILE" ] || [ ! -f "$OPERATOR_FILE" ]; then
    finish missing-operator 3
  fi
  has_crd certificates.cert-manager.io || finish missing-cert-manager 3
  # Point image addresses at the internal registry where images.txt says so.
  rewrite=()
  while read -r src dst; do
    case "$src" in '' | '#'*) continue ;; esac
    [ -n "$dst" ] && rewrite+=(-e "s|$src|$dst|g")
  done <images.txt
  [ "${#rewrite[@]}" -gt 0 ] || rewrite=(-e 's|^||')
  if ! out="$(sed "${rewrite[@]}" "$OPERATOR_FILE" | $K apply --server-side -f - 2>&1)"; then
    printf '%s\n' "$out" | detail validate
    finish operator-failed 3
  fi
  if ! $K -n opentelemetry-operator-system rollout status deployment/opentelemetry-operator-controller-manager --timeout=180s >/dev/null 2>&1; then
    $K -n opentelemetry-operator-system get events --field-selector type=Warning -o custom-columns=M:.message --no-headers 2>/dev/null | detail err
    finish operator-failed 3
  fi
  emit "operator=installed-now"
else
  emit "operator=present"
fi

$K get namespace "$NS" >/dev/null 2>&1 || $K create namespace "$NS" >/dev/null 2>&1

# Keep secrets already stored in the cluster; ask for the ones still missing.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
while IFS= read -r line; do
  case "$line" in
    '' | '#'*) continue ;;
  esac
  k="${line%%=*}"
  v="${line#*=}"
  if [ "$v" = CHANGE_ME ]; then
    old="$($K -n "$NS" get secret otelgenie-env -o "jsonpath={.data.$k}" 2>/dev/null | base64 -d 2>/dev/null)"
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

n=0
while IFS= read -r name; do
  n=$((n + 1))
  emit "placeholder.$n=$name"
done < <(grep '=CHANGE_ME$' "$tmp" | cut -d= -f1)
emit "placeholders=$n"
[ "$n" = 0 ] || finish placeholders 4

if ! $K -n "$NS" create secret generic otelgenie-env "--from-env-file=$tmp" --dry-run=client -o yaml | $K apply -f - >/dev/null 2>&1; then
  emit "validate.1=could not store the Secret otelgenie-env in the namespace $NS"
  finish rejected 5
fi
if [ -f ca-bundle.pem ]; then
  $K -n "$NS" create configmap otelgenie-ca --from-file=ca-bundle.pem --dry-run=client -o yaml | $K apply -f - >/dev/null 2>&1
fi

# A collector left over from an earlier run that is no longer wanted.
for c in node cluster; do
  case " $COLLECTORS " in
    *" $c "*) ;;
    *) $K -n "$NS" delete opentelemetrycollector "otelgenie-$c" --ignore-not-found >/dev/null 2>&1 ;;
  esac
done

for f in manifests/*.yaml; do
  ok=no
  # Right after the operator starts, its admission webhook can take a moment.
  for _ in 1 2 3 4 5 6; do
    if out="$($K apply -f "$f" 2>&1)"; then ok=yes; break; fi
    case "$out" in *webhook* | *"connection refused"* | *"no endpoints"*) sleep 10 ;; *) break ;; esac
  done
  if [ "$ok" != yes ]; then
    emit "validate.0=$f"
    printf '%s\n' "$out" | detail validate
    finish rejected 5
  fi
done
$K -n "$NS" create configmap otelgenie-applied --from-file=MANIFEST.sha256 --dry-run=client -o yaml | $K apply -f - >/dev/null 2>&1

workload() {
  if [ "$1" = node ]; then echo "daemonset/otelgenie-node-collector"; else echo "deployment/otelgenie-cluster-collector"; fi
}
failed=no
for c in $COLLECTORS; do
  w="$(workload "$c")"
  for _ in $(seq 1 30); do
    $K -n "$NS" get "$w" >/dev/null 2>&1 && break
    sleep 2
  done
  # Pods read the Secret only when they start.
  $K -n "$NS" rollout restart "$w" >/dev/null 2>&1
  $K -n "$NS" rollout status "$w" --timeout=180s >/dev/null 2>&1 || failed=yes
done

if [ "$failed" = yes ]; then
  {
    $K -n "$NS" get events --field-selector type=Warning -o custom-columns=M:.message --no-headers 2>/dev/null | tail -4
    $K -n "$NS" logs -l app.kubernetes.io/managed-by=opentelemetry-operator --tail=40 --prefix=false 2>/dev/null | grep -iE 'error|invalid|failed' | tail -4
  } | detail err
  finish not-ready 6
fi

emit "service=active"
finish ok 0
