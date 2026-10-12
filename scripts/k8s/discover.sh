#!/usr/bin/env bash
# Read-only. Prints facts about the cluster kubectl points at, so otelgenie can
# tailor the setup. It changes nothing and prints no secrets.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
items="$here/discover.items"

lines=()
emit() { lines+=("$1"); }
finish() {
  echo "OTELGENIE-DISCOVER v1"
  printf '%s\n' "${lines[@]}"
  echo "END OTELGENIE-DISCOVER lines=${#lines[@]}"
  exit 0
}

K=""
if command -v kubectl >/dev/null 2>&1; then K=kubectl; elif command -v oc >/dev/null 2>&1; then K=oc; fi
emit "time=$(date +%s)"
emit "cli=${K:-none}"
if [ -z "$K" ]; then
  emit "host=unknown"
  emit "cluster=unreachable"
  finish
fi
emit "host=$($K config current-context 2>/dev/null || echo unknown)"

version="$($K get --raw /version 2>/dev/null | tr -d '\n' | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p')"
if [ -z "$version" ]; then
  emit "cluster=unreachable"
  finish
fi
emit "cluster=reachable"
emit "server_version=$version"
emit "nodes=$($K get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
emit "arch=$($K get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}' 2>/dev/null | tr ' ' '\n' | sort -u | paste -sd, -)"

has_crd() { $K get crd "$1" >/dev/null 2>&1; }

if has_crd clusterversions.config.openshift.io; then
  emit "distro=ocp"
else
  case "$version" in
    *-gke.*) emit "distro=gke" ;;
    *-eks-*) emit "distro=eks" ;;
    *) emit "distro=unknown" ;;
  esac
fi

if [ "$($K auth can-i create clusterrolebindings 2>/dev/null)" = yes ]; then emit "admin=yes"; else emit "admin=no"; fi
if has_crd opentelemetrycollectors.opentelemetry.io; then emit "operator=installed"; else emit "operator=none"; fi
if has_crd certificates.cert-manager.io; then emit "cert_manager=yes"; else emit "cert_manager=no"; fi

if [ -r "$items" ]; then
  while read -r kind a _; do
    case "$kind" in
      svc)
        # The first Service with that name in any namespace, as namespace:port.
        found="$($K get svc -A --field-selector "metadata.name=$a" \
          -o jsonpath='{.items[0].metadata.namespace}:{.items[0].spec.ports[0].port}' 2>/dev/null)"
        case "$found" in
          ?*:?*) emit "svc.$a=$found" ;;
          *) emit "svc.$a=none" ;;
        esac
        ;;
    esac
  done <"$items"
else
  emit "items=missing"
fi

finish
