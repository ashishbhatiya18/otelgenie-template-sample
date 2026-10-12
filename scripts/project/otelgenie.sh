#!/usr/bin/env bash
# One entry point for the checks around this telemetry setup, and for
# installing the collector on a server.
#
#   bash otelgenie.sh check-requirements     is everything in place to start: tools, kubectl context and access on
#                                            this machine and, on Kubernetes, every container image pullable
#   bash otelgenie.sh check-connectivity     can the destination (or, from a server, the Ingress) be reached
#   bash otelgenie.sh check-prerequisites    Kubernetes: which of kube-state-metrics, the metrics server and
#                                            cert-manager this kind of cluster needs, and which are there
#   bash otelgenie.sh install-prerequisites  Kubernetes: install those that are needed and not already there
#   bash otelgenie.sh install-operator       Kubernetes: install the OpenTelemetry Operator, unless it is there
#   bash otelgenie.sh check-operator         Kubernetes: is the OpenTelemetry Operator installed and running
#   bash otelgenie.sh check-before-install   what is already there, before the collectors are installed
#   bash otelgenie.sh install-collector      install the collector: into the cluster from a jump server; on a
#                                            server (needs root) the collector package too, if it is missing
#   bash otelgenie.sh check-collector        is the collector that was installed present, running and limited
#   bash otelgenie.sh check-ingress          Kubernetes: the Ingress servers send through, and its address
#   bash otelgenie.sh instrument-workload NAMESPACE WORKLOAD LANGUAGE [BINARY]
#                                            Kubernetes: switch auto-instrumentation on for one workload, for
#                                            example: instrument-workload shop deployment/orders java
#   bash otelgenie.sh check-data-flow        is each collector taking data in and sending it on
#   bash otelgenie.sh validate-everything    Kubernetes: every check above, end to end
#   bash otelgenie.sh run-all                every check, in order; on a server it installs as well
#
# Where it runs decides how it works. On a jump server where kubectl points at
# the cluster, it uses kubectl and checks the cluster. Anywhere else it checks
# the server it is running on. Set OTELGENIE_MODE=cluster or OTELGENIE_MODE=server
# to choose yourself.
#
# The check commands change nothing, apart from short-lived pods for the image
# and connectivity checks, which are removed again. The install-* commands and
# instrument-workload change things. Each looks first, does only what is
# missing, and in a cluster asks before it acts (OTELGENIE_YES=1 answers yes).
set -u

what="${1:-}"
arg1="${2:-}"
arg2="${3:-}"
arg3="${4:-}"
arg4="${5:-}"
case "$what" in
  check-requirements | check-connectivity | check-prerequisites | install-prerequisites | install-operator | check-operator) ;;
  check-before-install | install-collector | check-collector | check-ingress | instrument-workload | check-data-flow | validate-everything | run-all) ;;
  *)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit 2
    ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 2
if [ ! -f project.env ]; then
  echo "project.env is missing; run this from the folder the package was unpacked into." >&2
  exit 2
fi
# shellcheck disable=SC1091
. ./project.env

SVC=otelgenie-otelcol
SEL=app.kubernetes.io/managed-by=opentelemetry-operator
K="${KUBECTL:-}"
if [ -z "$K" ]; then
  if command -v kubectl >/dev/null 2>&1; then K=kubectl; elif command -v oc >/dev/null 2>&1; then K=oc; fi
fi

pass=0
fail=0
warn=0
ok() { pass=$((pass + 1)); printf '  PASS  %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }
note() { warn=$((warn + 1)); printf '  WARN  %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

# --- requirements -----------------------------------------------------------

# What this script, and the installers it sits beside, need from the machine
# they run on. It runs before anything else is assumed, so it also works when
# kubectl is missing or points nowhere.
have() { # have <command> <what it is for> [optional]
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1 is installed"
  elif [ "${3:-}" = optional ]; then
    note "$1 is not installed; $2"
  else
    bad "$1 is not installed; $2"
  fi
}

requirements() {
  section "Does this machine have what the script needs ($(hostname))"
  if [ "${BASH_VERSINFO[0]:-0}" -ge 3 ]; then ok "bash $BASH_VERSION"; else bad "bash 3 or newer is needed"; fi
  for tool in awk sed grep tr mktemp; do have "$tool" "the scripts in this package use it"; done
  if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
    ok "sha256sum or shasum is installed"
  else
    bad "neither sha256sum nor shasum is installed; the installers use one to check the files are complete"
  fi
  have curl "the Ingress and the server checks use it" optional

  # The package itself.
  missing=""
  for f in project.env prerequisites.txt; do [ -f "$f" ] || missing="$missing $f"; done
  for d in $CLUSTER_FOLDERS; do
    for f in apply.sh verify.sh settings.env images.txt; do [ -f "$d/$f" ] || missing="$missing $d/$f"; done
    [ -d "$d/manifests" ] || missing="$missing $d/manifests"
  done
  if [ -n "$SERVER_FOLDER" ]; then
    for f in apply.sh verify.sh; do [ -f "$SERVER_FOLDER/$f" ] || missing="$missing $SERVER_FOLDER/$f"; done
  fi
  if [ -z "$missing" ]; then ok "The package is complete"; else bad "The package is missing:$missing (unpack it again)"; fi

  if [ -z "$CLUSTER_FOLDERS" ]; then
    info "This project has no cluster, so kubectl is not needed."
    have systemctl "the collector runs as a systemd service"
    if [ "$(id -u)" = 0 ] || command -v sudo >/dev/null 2>&1; then ok "root is available (directly or through sudo) for the install"; else bad "installing needs root, and sudo is not installed"; fi
    return
  fi

  # Kubernetes: the tool, the context, the connection, and what the login may do.
  if [ -z "$K" ]; then
    bad "Neither kubectl nor oc is installed; every cluster check and the install need one of them"
    return
  fi
  ok "$K is installed ($($K version --client 2>/dev/null | head -1))"
  ctx="$($K config current-context 2>/dev/null)"
  if [ -z "$ctx" ]; then
    bad "$K has no current context. List them with \"$K config get-contexts\" and choose with \"$K config use-context NAME\""
    return
  fi
  ok "$K has a current context: $ctx"
  info "Cluster address: $($K config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null)"
  info "Namespace of the context: $($K config view --minify -o 'jsonpath={.contexts[0].context.namespace}' 2>/dev/null | grep . || echo default)"
  info "Everything from here on acts on this cluster. If it is not the one you mean, switch context before going further."
  if ! $K get --raw /version --request-timeout=10s >/dev/null 2>&1; then
    bad "The cluster does not answer. Check the network path, a VPN or proxy, and that the login has not expired"
    return
  fi
  ok "The cluster answers (Kubernetes $($K get --raw /version 2>/dev/null | tr -d '\n ' | sed -n 's/.*"gitVersion":"\([^"]*\)".*/\1/p'))"
  if $K get nodes --no-headers >/dev/null 2>&1; then ok "The login can read the cluster's nodes"; else bad "The login cannot read the cluster's nodes"; fi
  if [ "$($K auth can-i create pods 2>/dev/null)" = yes ]; then
    ok "The login can start pods in the context's namespace (the image and connectivity checks use short-lived pods)"
  else
    bad "The login cannot start pods in the context's namespace, so the image and connectivity checks cannot run"
  fi
  if [ "$($K auth can-i get pods/proxy -n "$NAMESPACE" 2>/dev/null)" = yes ]; then
    ok "The login can read the collectors' own counters (pods/proxy in $NAMESPACE)"
  else
    note "The login cannot use pods/proxy in $NAMESPACE, so check-data-flow will not be able to read the collectors' counters"
  fi
  if [ "$($K auth can-i create namespaces 2>/dev/null)" = yes ] && [ "$($K auth can-i create clusterrolebindings 2>/dev/null)" = yes ]; then
    ok "The login can create namespaces and cluster-wide roles, which the install needs"
  else
    bad "The login cannot create namespaces or cluster-wide roles; the install needs a cluster administrator"
  fi
  # shellcheck disable=SC2086
  set -- $CLUSTER_FOLDERS
  if [ $# -gt 1 ] && [ -z "${CLUSTER_FOLDER:-}" ]; then
    note "This project has several kinds of cluster ($CLUSTER_FOLDERS). Say which one this context is on every command, for example: CLUSTER_FOLDER=$1 bash otelgenie.sh check-images"
  fi
}

# check-requirements looks at this machine first and, when that is in order and
# the project has a cluster, goes on to the container images.
if [ "$what" = check-requirements ]; then
  echo "otelgenie: $PROJECT / $ENVIRONMENT"
  requirements
  if [ -z "$CLUSTER_FOLDERS" ] || [ "$fail" -gt 0 ]; then
    if [ -n "$CLUSTER_FOLDERS" ]; then
      section "Container images"
      info "Not tried: fix what failed above first, then run this again."
    fi
    printf '\n%d passed, %d failed, %d warnings\n' "$pass" "$fail" "$warn"
    [ "$fail" -eq 0 ]
    exit
  fi
fi

# --- where are we -----------------------------------------------------------

MODE="${OTELGENIE_MODE:-}"
CONTEXT=""
if [ -n "$K" ]; then CONTEXT="$($K config current-context 2>/dev/null)"; fi
if [ -z "$MODE" ]; then
  if [ -n "$CLUSTER_FOLDERS" ] && [ -n "$CONTEXT" ]; then
    if $K get --raw /version --request-timeout=10s >/dev/null 2>&1; then
      MODE=cluster
    else
      echo "kubectl has the context \"$CONTEXT\" but the cluster does not answer." >&2
      echo "Fix the connection, or run with OTELGENIE_MODE=server to check this machine as a server." >&2
      exit 2
    fi
  else
    MODE=server
  fi
fi

# The folder for the cluster kubectl points at. With several kinds of cluster
# in one project, say which with CLUSTER_FOLDER=cluster-eks.
FOLDER="${CLUSTER_FOLDER:-}"
COLLECTORS=""
if [ "$MODE" = cluster ]; then
  if [ -z "$FOLDER" ]; then
    # shellcheck disable=SC2086
    set -- $CLUSTER_FOLDERS
    if [ $# -ne 1 ]; then
      echo "This project has several kinds of cluster: $CLUSTER_FOLDERS" >&2
      echo "Say which one kubectl points at, for example: CLUSTER_FOLDER=$1 bash otelgenie.sh ..." >&2
      exit 2
    fi
    FOLDER="$1"
  fi
  if [ -f "$FOLDER/settings.env" ]; then
    COLLECTORS="$(grep -m1 '^COLLECTORS=' "$FOLDER/settings.env" | cut -d= -f2- | tr -d '"')"
  fi
fi

# Any HTTP status means the network path is open; 000 means nothing answered.
probe_args() {
  printf '%s' "-sS -m 10 -o /dev/null -w %{http_code} -X POST -H Content-Type:application/json -d {} $1/v1/traces"
}

reached() { # reached <what> <code>
  case "$2" in
    '' | 000) bad "$1 did not answer" ;;
    *) ok "$1 answered (HTTP $2)" ;;
  esac
}

# --- images -----------------------------------------------------------------

# The inventory is images.txt in the cluster folder (where two addresses are
# given, the second is where the cluster pulls from) plus the image used for
# the connectivity check. Each one is tried the only way that proves the
# cluster can pull it: a pod that uses it. The pod does not need to run; it
# only needs to get past the pull.
images_cluster() {
  section "Container images: can the cluster pull them ($CONTEXT)"
  list="$({
    if [ -f "$FOLDER/images.txt" ]; then grep -v '^#' "$FOLDER/images.txt" | awk 'NF {print $NF}'; fi
    echo "$CURL_IMAGE"
  } | sort -u)"
  if [ -n "${APPLICATION_STACKS:-}" ]; then
    info "Application stacks in this project: $APPLICATION_STACKS. Only their auto-instrumentation agents are in the list."
  else
    info "No application stack is instrumented in this project, so the list has no auto-instrumentation agent."
  fi
  info "$(printf '%s\n' "$list" | wc -l | tr -d ' ') images are needed:"
  for img in $list; do info "  $img"; done

  waiting=""
  i=0
  for img in $list; do
    i=$((i + 1))
    pod="otelgenie-image-$$-$i"
    if $K run "$pod" --image="$img" --restart=Never --labels=otelgenie-check=images --command -- true >/dev/null 2>&1; then
      waiting="$waiting $pod|$img"
    else
      bad "$img: the pod to try it with could not be created"
    fi
  done

  tries=0
  while [ -n "$waiting" ] && [ "$tries" -lt 24 ]; do
    tries=$((tries + 1))
    sleep 5
    still=""
    for entry in $waiting; do
      pod="${entry%%|*}"
      img="${entry#*|}"
      state="$($K get pod "$pod" -o 'jsonpath={.status.phase} {.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)"
      phase="${state%% *}"
      reason="${state#* }"
      case "$reason" in
        ErrImagePull | ImagePullBackOff | InvalidImageName | ErrImageNeverPull)
          bad "$img: the cluster cannot pull it ($reason)"
          continue
          ;;
        CreateContainerError | RunContainerError | CrashLoopBackOff)
          ok "$img: the cluster can pull it"
          continue
          ;;
      esac
      case "$phase" in
        Running | Succeeded | Failed) ok "$img: the cluster can pull it" ;;
        *) still="$still $entry" ;;
      esac
    done
    waiting="$still"
  done
  for entry in $waiting; do
    note "${entry#*|}: still not pulled after two minutes; look at: $K describe pod ${entry%%|*}"
  done
  if [ -z "$waiting" ]; then
    $K delete pods -l otelgenie-check=images --wait=false >/dev/null 2>&1
  else
    info "The pods are left in place so you can look. Remove them with: $K delete pods -l otelgenie-check=images"
  fi
}

# --- connectivity -----------------------------------------------------------

connectivity_cluster() {
  section "Connectivity from inside the cluster ($CONTEXT)"
  info "Destination: $DESTINATION"
  info "The check runs curl in a short-lived pod from the image $CURL_IMAGE."
  # -k: this checks the network path. The collector checks the certificate itself.
  # shellcheck disable=SC2046
  code="$($K run "otelgenie-check-$$" --rm -i --quiet --restart=Never --image="$CURL_IMAGE" \
    --command -- curl -k $(probe_args "$DESTINATION") 2>/dev/null | tr -dc '0-9' | tail -c 3)"
  reached "The destination (tried from a pod)" "$code"
  if [ -z "$code" ]; then
    info "No answer from the pod at all usually means the image could not be pulled:"
    info "  $K get events --sort-by=.lastTimestamp | tail"
  fi
}

connectivity_server() {
  section "Connectivity from this server ($(hostname))"
  if ! command -v curl >/dev/null 2>&1; then
    bad "curl is not installed, so the check cannot run"
    return
  fi
  ca=()
  if [ -n "$SERVER_FOLDER" ] && [ -f "$SERVER_FOLDER/ca-bundle.pem" ]; then ca=(--cacert "$SERVER_FOLDER/ca-bundle.pem"); fi
  info "This server sends to: $SEND_TO"
  # shellcheck disable=SC2046
  code="$(curl ${ca[@]+"${ca[@]}"} $(probe_args "$SEND_TO") 2>/dev/null)"
  reached "$SEND_TO" "$code"
  if [ "$EXPECT_INGRESS" = yes ] && [ "$code" != 401 ] && [ -n "$code" ] && [ "$code" != 000 ]; then
    note "The cluster's collector should refuse a request without a token with 401; this was $code. Check the Ingress routes /v1 to it."
  fi
}

# --- pre-install ------------------------------------------------------------

# prerequisites.txt has one line for each: name, the command that detects it,
# the file that installs it, where that file comes from, the kinds of cluster
# that do not need it, and the kinds that come with it. Tabs separate the fields.
TAB="$(printf '\t')"
platform() { grep -m1 '^PLATFORM=' "$FOLDER/settings.env" 2>/dev/null | cut -d= -f2- | tr -d '"'; }
detected() { bash -c "${1//kubectl/$K}" >/dev/null 2>&1; }
here() { # here <kinds of cluster, comma separated>: is this cluster one of them
  case ",$1," in *",$(platform),"*) return 0 ;; esac
  return 1
}

# Reports on each prerequisite and changes nothing. What is said about one
# depends on the kind of cluster: not needed, comes with it, or to be installed.
prerequisites() {
  [ -f prerequisites.txt ] || return 0
  while IFS="$TAB" read -r name check file url skip builtin; do
    [ -n "$name" ] || continue
    if here "$skip"; then
      info "$name: not needed on $(platform)."
    elif here "$builtin"; then
      if detected "$check"; then
        ok "$name comes with $(platform) and is there"
      else
        bad "$name should come with $(platform) but was not found (checked with: $check). Ask the cluster's administrators; it is not installed from this package"
      fi
    elif detected "$check"; then
      ok "$name is already installed"
    else
      note "$name is not installed; install it with: bash otelgenie.sh install-prerequisites"
      info "  checked with: $check"
    fi
  done <prerequisites.txt
}

# Installs each prerequisite that is not already there. Every one is looked
# for first, so running this twice installs nothing the second time.
install_prerequisites() {
  section "Prerequisites: install what cluster $CONTEXT is missing"
  if [ ! -s prerequisites.txt ]; then
    info "This package names no prerequisites."
    return
  fi
  # File descriptor 3, so that the question below can still read the keyboard.
  while IFS="$TAB" read -r name check file url skip builtin <&3; do
    [ -n "$name" ] || continue
    if here "$skip"; then
      info "$name: not needed on $(platform), skipped."
      continue
    fi
    if here "$builtin"; then
      if detected "$check"; then
        ok "$name comes with $(platform) and is there; nothing to do"
      else
        bad "$name should come with $(platform) but was not found (checked with: $check). It is not installed from this package; ask the cluster's administrators"
      fi
      continue
    fi
    if detected "$check"; then
      ok "$name is already installed; nothing to do"
      info "  detected with: $check"
      continue
    fi
    info "$name is not installed (nothing found with: $check)"
    if [ "$file" = - ] || { [ ! -f "$file" ] && [ ! -d "$file" ]; }; then
      bad "$name: $file is not in this folder. On a machine with internet access get it from $url, put it next to otelgenie.sh, and run this again"
      continue
    fi
    how=-f
    [ -d "$file" ] && how=-k
    info "Installing it from $file will pull these images:"
    grep -rhoE 'image: *[^ ]+' "$file" 2>/dev/null | sed 's/image: *//; s/"//g' | sort -u | sed 's/^/          /'
    if [ "${OTELGENIE_YES:-}" != 1 ]; then
      if ! { : </dev/tty; } 2>/dev/null; then
        bad "$name: installing needs a yes. Run this in a terminal, or with OTELGENIE_YES=1"
        continue
      fi
      printf '        Install %s into the cluster %s? [y/N] ' "$name" "$CONTEXT" >/dev/tty
      IFS= read -r answer </dev/tty
      case "$answer" in
        y | Y | yes) ;;
        *)
          note "$name: not installed, at your request"
          continue
          ;;
      esac
    fi
    if ! out="$($K apply "$how" "$file" 2>&1)"; then
      bad "$name: $K apply $how $file failed"
      printf '%s\n' "$out" | tail -5 | sed 's/^/          /'
      continue
    fi
    tries=0
    until detected "$check" || [ "$tries" -ge 36 ]; do
      tries=$((tries + 1))
      sleep 5
    done
    if detected "$check"; then
      ok "$name is installed and was detected afterwards"
    else
      note "$name was applied but is still not detected after three minutes; look at its pods (an image that cannot be pulled is the usual cause)"
    fi
  done 3<prerequisites.txt
}

operator_state() { # prints "namespace/name available" for each operator deployment
  $K get deployments -A -l app.kubernetes.io/name=opentelemetry-operator \
    -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {.status.availableReplicas}{"\n"}{end}' 2>/dev/null
}

# --- the operator -----------------------------------------------------------

OPERATOR_CRDS="opentelemetrycollectors.opentelemetry.io instrumentations.opentelemetry.io"

operator_running() { operator_state | awk '$2 >= 1 {f=1} END {exit !f}'; }
operator_crds() {
  for crd in $OPERATOR_CRDS; do $K get crd "$crd" >/dev/null 2>&1 || return 1; done
}

check_operator() {
  section "The OpenTelemetry Operator on cluster $CONTEXT"
  op="$(operator_state)"
  if operator_running; then
    ok "The operator is running ($(printf '%s' "$op" | head -1 | cut -d' ' -f1))"
  elif [ -n "$op" ]; then
    bad "The operator is installed but not ready ($(printf '%s' "$op" | head -1 | cut -d' ' -f1)). Look at its pods and their events"
  else
    bad "The operator is not installed; install it with: bash otelgenie.sh install-operator"
  fi
  for crd in $OPERATOR_CRDS; do
    if $K get crd "$crd" >/dev/null 2>&1; then ok "Resource type $crd exists"; else bad "Resource type $crd is missing"; fi
  done
}

install_operator() {
  section "The OpenTelemetry Operator: install it on cluster $CONTEXT if it is missing"
  if operator_running && operator_crds; then
    ok "The operator is already installed and running ($(operator_state | head -1 | cut -d' ' -f1)); nothing to do"
    return
  fi
  if [ -n "$(operator_state)" ]; then
    bad "The operator is installed but not ready. Nothing was changed; look at its pods and their events before installing over it"
    return
  fi
  info "The operator is not installed."
  if [ "$(platform)" = ocp ]; then
    bad "On OpenShift the operator is not installed from this package. A cluster administrator installs \"Red Hat build of OpenTelemetry\" from OperatorHub, for all namespaces; then run: bash otelgenie.sh check-operator"
    return
  fi
  if ! $K get crd certificates.cert-manager.io >/dev/null 2>&1; then
    bad "cert-manager is not installed and the operator needs it. Run first: bash otelgenie.sh install-prerequisites"
    return
  fi
  ok "cert-manager is there"
  file="$(grep -m1 '^OPERATOR_FILE=' "$FOLDER/settings.env" 2>/dev/null | cut -d= -f2- | tr -d '"')"
  src=""
  for candidate in "$FOLDER/$file" "$file"; do
    if [ -n "$file" ] && [ -f "$candidate" ]; then
      src="$candidate"
      break
    fi
  done
  if [ -z "$src" ]; then
    bad "${file:-The operator's file} is not here. On a machine with internet access get it from ${OPERATOR_URL:-the operator's releases}, put it in $FOLDER, and run this again"
    return
  fi
  # Point image addresses at the internal registry where images.txt says so.
  rewrite=()
  while read -r from to; do
    case "$from" in '' | '#'*) continue ;; esac
    [ -n "$to" ] && rewrite+=(-e "s|$from|$to|g")
  done <"$FOLDER/images.txt"
  [ "${#rewrite[@]}" -gt 0 ] || rewrite=(-e 's|^||')
  info "Installing it from $src will pull these images:"
  sed "${rewrite[@]}" "$src" | grep -oE 'image: *[^ ]+' | sed 's/image: *//; s/"//g' | sort -u | sed 's/^/          /'
  if [ "${OTELGENIE_YES:-}" != 1 ]; then
    if ! { : </dev/tty; } 2>/dev/null; then
      bad "Installing needs a yes. Run this in a terminal, or with OTELGENIE_YES=1"
      return
    fi
    printf '        Install the OpenTelemetry Operator into the cluster %s? [y/N] ' "$CONTEXT" >/dev/tty
    IFS= read -r answer </dev/tty
    case "$answer" in
      y | Y | yes) ;;
      *)
        note "The operator was not installed, at your request"
        return
        ;;
    esac
  fi
  if ! out="$(sed "${rewrite[@]}" "$src" | $K apply --server-side -f - 2>&1)"; then
    bad "Applying $src failed"
    printf '%s\n' "$out" | tail -5 | sed 's/^/          /'
    return
  fi
  tries=0
  until { operator_running && operator_crds; } || [ "$tries" -ge 36 ]; do
    tries=$((tries + 1))
    sleep 5
  done
  if operator_running && operator_crds; then
    ok "The operator is installed and running ($(operator_state | head -1 | cut -d' ' -f1))"
  else
    bad "The operator was applied but is not running after three minutes; an image that cannot be pulled is the usual cause"
    $K get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | grep -i opentelemetry | tail -5 | sed 's/^/          /'
  fi
}

preinstall_cluster() {
  section "Before installing: cluster $CONTEXT"
  ready="$($K get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ {n++} END {print n+0}')"
  total="$($K get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$total" -gt 0 ] && [ "$ready" = "$total" ]; then ok "All $total nodes are Ready"; else note "$ready of $total nodes are Ready"; fi
  if [ "$($K auth can-i create clusterrolebindings 2>/dev/null)" = yes ]; then
    ok "This kubectl login can create cluster-wide resources"
  else
    bad "This kubectl login cannot create cluster-wide resources; the install needs an administrator"
  fi
  prerequisites
  if $K get crd opentelemetrycollectors.opentelemetry.io >/dev/null 2>&1; then
    ok "The OpenTelemetry Operator's resource types are already there"
  else
    info "The OpenTelemetry Operator is not installed yet."
  fi
  if $K get namespace "$NAMESPACE" >/dev/null 2>&1; then
    info "The namespace $NAMESPACE already exists:"
    $K -n "$NAMESPACE" get opentelemetrycollectors,pods 2>/dev/null | sed 's/^/        /'
  else
    info "The namespace $NAMESPACE does not exist yet; apply.sh creates it."
  fi
}

preinstall_server() {
  section "Before installing: server $(hostname)"
  if [ -r /etc/os-release ]; then info "$(. /etc/os-release && echo "$PRETTY_NAME"), $(uname -m)"; fi
  if command -v systemctl >/dev/null 2>&1; then ok "systemd is here"; else bad "systemd is not here; the collector runs as a systemd service"; fi
  if command -v otelcol-contrib >/dev/null 2>&1; then
    ok "The collector package is installed ($(otelcol-contrib --version 2>/dev/null | head -1))"
  else
    info "The collector package (otelcol-contrib) is not installed; install-collector installs it."
    package_source
    case "$PKG_HOW" in
      file) ok "Its package file is here: $PKG_PATH" ;;
      repo) info "It will come from your package repository${PACKAGE_REPO_URL:+ ($PACKAGE_REPO_URL)}." ;;
      *) bad "$PKG_WHY" ;;
    esac
  fi
  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    info "The user $SERVICE_USER already exists."
  else
    info "The user $SERVICE_USER does not exist yet; the install creates it."
  fi
  state="$(systemctl is-active "$SVC" 2>/dev/null)"
  info "The service $SVC is currently: ${state:-not installed}"
  if [ -z "$SERVER_FOLDER" ] || [ ! -d "$SERVER_FOLDER" ]; then
    bad "This package has no server folder. If servers send through the cluster's Ingress, give its address in otelgenie and download the package again."
  fi
}

# --- install (servers only) -------------------------------------------------

# Where the collector package for this server comes from. Sets PKG_HOW to
# "file" (with PKG_PATH), "repo", or "none" (with PKG_WHY saying what to do).
package_source() {
  PKG_HOW=none
  PKG_PATH=""
  PKG_FAMILY=""
  like=""
  if [ -r /etc/os-release ]; then like="$(. /etc/os-release && echo "${ID:-} ${ID_LIKE:-}")"; fi
  case " $like " in
    *" rhel "* | *" fedora "* | *" centos "*) PKG_FAMILY=rhel ;;
    *" debian "* | *" ubuntu "*) PKG_FAMILY=debian ;;
  esac
  arch="$(uname -m)"
  [ "$arch" = arm64 ] && arch=aarch64
  [ "$arch" = amd64 ] && arch=x86_64
  if [ -z "$PKG_FAMILY" ]; then
    PKG_WHY="This is neither a Red Hat nor a Debian family system, so the collector package cannot be installed for you. Install otelcol-contrib ${COLLECTOR_VERSION:-} by hand"
    return
  fi
  want=""
  from=""
  if [ -f packages.txt ]; then
    while IFS="$(printf '\t')" read -r os a file url; do
      if [ "$os" = "$PKG_FAMILY" ] && [ "$a" = "$arch" ]; then
        want="$file"
        from="$url"
      fi
    done <packages.txt
  fi
  for candidate in "$want" "$SERVER_FOLDER/$want"; do
    if [ -n "$want" ] && [ -f "$candidate" ]; then
      PKG_HOW=file
      PKG_PATH="$candidate"
      return
    fi
  done
  if [ "${PACKAGE_METHOD:-}" = repo ]; then
    PKG_HOW=repo
    return
  fi
  if [ -n "$want" ]; then
    PKG_WHY="The collector package $want is not here. On a machine with internet access get it from $from, put it next to otelgenie.sh on this server, and run this again"
  else
    PKG_WHY="The template lists no collector package for this server ($PKG_FAMILY, $arch). Ask the owner of the template to add one, or install otelcol-contrib ${COLLECTOR_VERSION:-} by hand"
  fi
}

# Installs the collector package, unless the server already has it.
install_package() {
  if command -v otelcol-contrib >/dev/null 2>&1; then
    ok "The collector package is already installed ($(otelcol-contrib --version 2>/dev/null | head -1)); it is left as it is"
  else
    info "The collector package (otelcol-contrib) is not installed."
    package_source
    case "$PKG_HOW:$PKG_FAMILY" in
      file:rhel)
        info "Installing $PKG_PATH"
        out="$(rpm -Uvh "$PKG_PATH" 2>&1)"
        ;;
      file:debian)
        info "Installing $PKG_PATH"
        out="$(dpkg -i "$PKG_PATH" 2>&1)"
        ;;
      repo:rhel)
        info "Installing otelcol-contrib from your package repository"
        if command -v dnf >/dev/null 2>&1; then out="$(dnf install -y otelcol-contrib 2>&1)"; else out="$(yum install -y otelcol-contrib 2>&1)"; fi
        ;;
      repo:debian)
        info "Installing otelcol-contrib from your package repository"
        out="$(apt-get install -y otelcol-contrib 2>&1)"
        ;;
      *)
        bad "$PKG_WHY"
        return 1
        ;;
    esac
    if ! command -v otelcol-contrib >/dev/null 2>&1; then
      bad "The collector package could not be installed"
      printf '%s\n' "$out" | tail -5 | sed 's/^/          /'
      return 1
    fi
    ok "The collector package is installed ($(otelcol-contrib --version 2>/dev/null | head -1))"
  fi
  if [ -n "${COLLECTOR_VERSION:-}" ] && ! otelcol-contrib --version 2>/dev/null | grep -q "$COLLECTOR_VERSION"; then
    note "This setup was written for version $COLLECTOR_VERSION of the collector; the one installed is different"
  fi
  return 0
}

install_server() {
  section "Installing the collector on $(hostname)"
  if [ -z "$SERVER_FOLDER" ] || [ ! -d "$SERVER_FOLDER" ]; then
    bad "This package has no server folder to install from"
    return
  fi
  if [ "$(id -u)" != 0 ]; then
    bad "Installing needs root: sudo bash otelgenie.sh install-collector"
    return
  fi
  install_package || return
  info "Running $SERVER_FOLDER/apply.sh. It asks for the access token; typing is hidden."
  if (cd "$SERVER_FOLDER" && bash apply.sh); then ok "apply.sh finished"; else bad "apply.sh reported a problem (see its output above)"; fi
}

# --- install the collectors in the cluster ----------------------------------

# A question before anything is changed in the cluster. Returns 1 for no.
confirm() { # confirm <what>
  [ "${OTELGENIE_YES:-}" = 1 ] && return 0
  if ! { : </dev/tty; } 2>/dev/null; then
    bad "$1 needs a yes. Run this in a terminal, or with OTELGENIE_YES=1"
    return 1
  fi
  printf '        %s on the cluster %s? [y/N] ' "$1" "$CONTEXT" >/dev/tty
  IFS= read -r answer </dev/tty
  case "$answer" in y | Y | yes) return 0 ;; esac
  note "$1: not done, at your request"
  return 1
}

install_collectors_cluster() {
  section "The collectors: install them on cluster $CONTEXT"
  if ! { operator_running && operator_crds; }; then
    bad "The OpenTelemetry Operator is not running, and it is what runs the collectors. Run first: bash otelgenie.sh install-operator"
    return
  fi
  ok "The operator is running"
  if [ ! -f "$FOLDER/apply.sh" ]; then
    bad "$FOLDER/apply.sh is missing; unpack the package again"
    return
  fi
  info "This applies everything in $FOLDER/manifests to the namespace $NAMESPACE: the collectors, their"
  info "permissions and, where the project has them, the Instrumentation resource and the Ingress."
  info "Applying again is safe: what is already there is updated in place."
  confirm "Install the collectors" || return
  info "Running $FOLDER/apply.sh. It asks for the access token; typing is hidden."
  if (cd "$FOLDER" && bash apply.sh); then
    ok "apply.sh finished; see its report above, then run: bash otelgenie.sh check-collector"
  else
    bad "apply.sh reported a problem (see its output above)"
  fi
}

# --- the Ingress ------------------------------------------------------------

check_ingress() {
  section "The Ingress for servers outside cluster $CONTEXT"
  if [ "$EXPECT_INGRESS" != yes ]; then
    info "Nothing in this project runs on servers outside the cluster, so there is no Ingress."
    return
  fi
  if ! $K -n "$NAMESPACE" get ingress otelgenie-gateway >/dev/null 2>&1; then
    bad "The Ingress otelgenie-gateway does not exist in $NAMESPACE. It is created with the collectors: bash otelgenie.sh install-collector"
    return
  fi
  ok "The Ingress otelgenie-gateway exists in $NAMESPACE"
  class="$($K -n "$NAMESPACE" get ingress otelgenie-gateway -o 'jsonpath={.spec.ingressClassName}' 2>/dev/null)"
  [ -n "$class" ] || class="the default one of the cluster"
  info "Ingress class: $class"
  addr="$($K -n "$NAMESPACE" get ingress otelgenie-gateway -o 'jsonpath={.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  if [ -z "$addr" ]; then
    note "It has no address yet. An ingress controller usually gives one within a few minutes; run this again. If it never does, the cluster has no default ingress class: add ingressClassName to $FOLDER/manifests/*ingress.yaml and install the collectors again"
    return
  fi
  ok "Its address is $addr"
  if [ -n "$INGRESS" ]; then
    info "otelgenie has been given: $INGRESS"
    try="$INGRESS"
  else
    info "Give otelgenie this address, as servers will use it: http://$addr"
    info "(or https://A-NAME if you put a host name and a certificate on it)."
    try="http://$addr"
  fi
  if command -v curl >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    code="$(curl -k $(probe_args "$try") 2>/dev/null)"
    case "$code" in
      401) ok "$try reaches the collector, which refuses a request without a token (401), as it should" ;;
      '' | 000) note "$try did not answer from this machine; servers may still reach it" ;;
      *) bad "$try answered $code where the collector should answer 401; check it routes /v1 to otelgenie-cluster-collector:4318" ;;
    esac
  else
    info "curl is not on this machine, so $try was not tried from here."
  fi
}

# --- instrument one workload ------------------------------------------------

instrument_workload() { # <namespace> <workload> <language> [binary, for Go]
  ns="$1"
  workload="$2"
  lang="$3"
  exe="$4"
  section "Auto-instrumentation for one workload on cluster $CONTEXT"
  if [ -z "$ns" ] || [ -z "$workload" ] || [ -z "$lang" ]; then
    bad "Say which: bash otelgenie.sh instrument-workload NAMESPACE WORKLOAD LANGUAGE, for example: instrument-workload shop deployment/orders java"
    return
  fi
  case "$workload" in */*) ;; *) workload="deployment/$workload" ;; esac
  case "$lang" in
    java | python) ;;
    go)
      if [ -z "$exe" ]; then
        bad "A Go workload also needs the path of its binary inside the container: instrument-workload $ns $workload go /path/to/binary"
        return
      fi
      ;;
    *)
      bad "The language must be java, python or go"
      return
      ;;
  esac
  if ! $K -n "$NAMESPACE" get instrumentation otelgenie >/dev/null 2>&1; then
    bad "The Instrumentation resource otelgenie is not in $NAMESPACE. Run first: bash otelgenie.sh install-collector"
    return
  fi
  if ! $K -n "$ns" get "$workload" >/dev/null 2>&1; then
    bad "$workload was not found in the namespace $ns"
    return
  fi
  key="instrumentation.opentelemetry.io/inject-$lang"
  now="$($K -n "$ns" get "$workload" -o 'jsonpath={.spec.template.metadata.annotations}' 2>/dev/null)"
  case "$now" in
    *"$key"*)
      ok "$workload in $ns already carries $key; nothing to do"
      return
      ;;
  esac
  patch="\"$key\":\"$NAMESPACE/otelgenie\""
  [ "$lang" = go ] && patch="$patch,\"instrumentation.opentelemetry.io/otel-go-auto-target-exe\":\"$exe\""
  info "This adds the annotation $key to the pod template of $workload in $ns, which restarts its pods."
  info "If the workload is installed from a Helm chart, a later helm upgrade removes the annotation again"
  info "unless the chart sets it too; the values file in the package's services folder does that."
  confirm "Instrument $workload in $ns" || return
  if ! out="$($K -n "$ns" patch "$workload" --type merge -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{$patch}}}}}" 2>&1)"; then
    bad "The annotation could not be added: $out"
    return
  fi
  ok "The annotation was added"
  if $K -n "$ns" rollout status "$workload" --timeout=180s >/dev/null 2>&1; then
    ok "$workload has restarted"
  else
    note "$workload has not finished restarting after three minutes: $K -n $ns rollout status $workload"
  fi
}

# --- post-install -----------------------------------------------------------

rollout() { # rollout <kind> <name> <jsonpath wanted> <jsonpath ready>
  want="$($K -n "$NAMESPACE" get "$1" "$2" -o "jsonpath={$3}" 2>/dev/null)"
  have="$($K -n "$NAMESPACE" get "$1" "$2" -o "jsonpath={$4}" 2>/dev/null)"
  if [ -z "$want" ]; then
    bad "The $1 $2 does not exist in $NAMESPACE"
  elif [ "${have:-0}" = "$want" ] && [ "$want" != 0 ]; then
    ok "$1 $2: $have of $want ready"
  else
    bad "$1 $2: ${have:-0} of $want ready"
  fi
}

postinstall_cluster() {
  section "After installing: cluster $CONTEXT"
  prerequisites
  op="$(operator_state)"
  if printf '%s\n' "$op" | awk '$2 >= 1 {f=1} END {exit !f}'; then
    ok "The OpenTelemetry Operator is running ($(printf '%s' "$op" | head -1 | cut -d' ' -f1))"
  else
    bad "No running OpenTelemetry Operator was found"
  fi
  for crd in opentelemetrycollectors.opentelemetry.io instrumentations.opentelemetry.io; do
    if $K get crd "$crd" >/dev/null 2>&1; then ok "Resource type $crd exists"; else bad "Resource type $crd is missing"; fi
  done
  if ! $K get namespace "$NAMESPACE" >/dev/null 2>&1; then
    bad "The namespace $NAMESPACE does not exist; the collectors are not installed"
    return
  fi
  ok "The namespace $NAMESPACE exists"
  if $K -n "$NAMESPACE" get secret otelgenie-env >/dev/null 2>&1; then ok "The Secret otelgenie-env exists"; else bad "The Secret otelgenie-env is missing"; fi
  for c in $COLLECTORS; do
    if [ "$c" = node ]; then
      rollout daemonset otelgenie-node-collector .status.desiredNumberScheduled .status.numberReady
    else
      rollout deployment otelgenie-cluster-collector .spec.replicas .status.readyReplicas
    fi
  done
  if [ "$EXPECT_INSTRUMENTATION" = yes ]; then
    if $K -n "$NAMESPACE" get instrumentation otelgenie >/dev/null 2>&1; then
      ok "The Instrumentation resource otelgenie exists"
    else
      bad "The Instrumentation resource otelgenie is missing, so no application will be instrumented"
    fi
  fi
  if [ "$EXPECT_INGRESS" = yes ]; then
    addr="$($K -n "$NAMESPACE" get ingress otelgenie-gateway -o 'jsonpath={.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
    if ! $K -n "$NAMESPACE" get ingress otelgenie-gateway >/dev/null 2>&1; then
      bad "The Ingress otelgenie-gateway is missing, so servers outside the cluster cannot send"
    elif [ -n "$addr" ]; then
      ok "The Ingress otelgenie-gateway has the address $addr"
    else
      note "The Ingress otelgenie-gateway has no address yet"
    fi
  fi
}

postinstall_server() {
  section "After installing: server $(hostname)"
  state="$(systemctl is-active "$SVC" 2>/dev/null)"
  if [ "$state" = active ]; then ok "The service $SVC is active"; else bad "The service $SVC is ${state:-not installed}"; fi
  user="$(systemctl show "$SVC" -p User --value 2>/dev/null)"
  if [ "$user" = "$SERVICE_USER" ]; then ok "It runs as the user $user"; else bad "It runs as \"${user:-root}\", not as $SERVICE_USER"; fi
  mem="$(systemctl show "$SVC" -p MemoryMax --value 2>/dev/null)"
  cpu="$(systemctl show "$SVC" -p CPUQuotaPerSecUSec --value 2>/dev/null)"
  case "$mem" in '' | infinity) bad "It has no memory limit" ;; *) ok "Memory is limited to $((mem / 1048576)) MB" ;; esac
  case "$cpu" in '' | infinity) bad "It has no CPU limit" ;; *) ok "CPU is limited ($cpu of every second)" ;; esac
  restarts="$(systemctl show "$SVC" -p NRestarts --value 2>/dev/null)"
  if [ "${restarts:-0}" -gt 2 ]; then note "It has restarted $restarts times: journalctl -u $SVC -n 50"; fi
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS -m 5 http://127.0.0.1:13133/ >/dev/null 2>&1; then ok "The collector's health check answers"; else bad "The collector's health check does not answer"; fi
  fi
}

# --- validation: is data flowing -------------------------------------------

# counters <metrics text> <prefix>: the sum of every counter starting with it.
counters() {
  printf '%s\n' "$1" | awk -v p="$2" 'index($0, p) == 1 {s += $NF} END {printf "%d", s}'
}

flow() { # flow <who> <metrics text>
  if [ -z "$2" ]; then
    bad "$1: its own counters could not be read"
    return
  fi
  took="$(counters "$2" otelcol_receiver_accepted_)"
  sent="$(counters "$2" otelcol_exporter_sent_)"
  lost="$(counters "$2" otelcol_exporter_send_failed_)"
  if [ "$sent" -gt 0 ]; then ok "$1: took in $took, sent on $sent"; else bad "$1: took in $took but has sent nothing on"; fi
  if [ "$lost" -gt 0 ]; then bad "$1: $lost items could not be sent on"; fi
}

collector_pods() { $K -n "$NAMESPACE" get pods -l "$SEL" -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null; }

validate_cluster() {
  section "Is data flowing: cluster $CONTEXT"
  pods="$(collector_pods)"
  if [ -z "$pods" ]; then
    bad "No collector pods were found in $NAMESPACE"
    return
  fi
  for p in $pods; do
    flow "$p" "$($K get --raw "/api/v1/namespaces/$NAMESPACE/pods/$p:8888/proxy/metrics" 2>/dev/null)"
  done
  info "A collector that was installed less than a minute ago may not have sent anything yet."
}

validate_server() {
  section "Is data flowing: server $(hostname)"
  if ! command -v curl >/dev/null 2>&1; then
    bad "curl is not installed, so the collector's counters cannot be read"
    return
  fi
  flow "$SVC" "$(curl -fsS -m 5 http://127.0.0.1:8888/metrics 2>/dev/null)"
  errs="$(journalctl -u "$SVC" --since -10min --no-pager -o cat 2>/dev/null | grep -cE "$(printf '\t')error$(printf '\t')|Exporting failed")"
  if [ "${errs:-0}" -gt 0 ]; then note "$errs error lines in the last 10 minutes: journalctl -u $SVC --since -10min"; else ok "No errors in its log in the last 10 minutes"; fi
}

# --- final validation, Kubernetes ------------------------------------------

final_cluster() {
  connectivity_cluster
  postinstall_cluster
  validate_cluster

  section "Final checks: cluster $CONTEXT"
  # Pods that keep restarting, or are not running.
  while read -r name phase restarts; do
    [ -n "$name" ] || continue
    if [ "$phase" != Running ]; then
      bad "Pod $name is $phase"
    elif [ "${restarts:-0}" -gt 2 ]; then
      note "Pod $name has restarted $restarts times: $K -n $NAMESPACE logs $name --previous"
    else
      ok "Pod $name is Running"
    fi
  done < <($K -n "$NAMESPACE" get pods -o 'jsonpath={range .items[*]}{.metadata.name} {.status.phase} {.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null)

  # What the operator itself says about each collector.
  while read -r name mode image; do
    [ -n "$name" ] || continue
    info "Collector $name: mode $mode, image ${image:-not reported}"
  done < <($K -n "$NAMESPACE" get opentelemetrycollectors -o 'jsonpath={range .items[*]}{.metadata.name} {.spec.mode} {.status.image}{"\n"}{end}' 2>/dev/null)

  for p in $(collector_pods); do
    errs="$($K -n "$NAMESPACE" logs "$p" --since=10m 2>/dev/null | grep -cE "$(printf '\t')error$(printf '\t')|Exporting failed")"
    if [ "${errs:-0}" -gt 0 ]; then
      note "$p logged $errs errors in the last 10 minutes: $K -n $NAMESPACE logs $p --since=10m"
    else
      ok "$p logged no errors in the last 10 minutes"
    fi
  done

  # The node collectors hand over to the cluster's collector; its Service must have endpoints.
  eps="$($K -n "$NAMESPACE" get endpoints otelgenie-cluster-collector -o 'jsonpath={.subsets[*].addresses[*].ip}' 2>/dev/null)"
  if [ -n "$eps" ]; then ok "The Service otelgenie-cluster-collector has endpoints, so node collectors and the Ingress can reach it"; else bad "The Service otelgenie-cluster-collector has no endpoints"; fi

  if [ "$EXPECT_INGRESS" = yes ] && [ -n "$INGRESS" ]; then
    if command -v curl >/dev/null 2>&1; then
      # shellcheck disable=SC2046
      code="$(curl -k $(probe_args "$INGRESS") 2>/dev/null)"
      case "$code" in
        401) ok "The Ingress at $INGRESS reaches the collector, which refuses a request without a token (401)" ;;
        '' | 000) note "The Ingress at $INGRESS did not answer from this machine; servers may still reach it" ;;
        *) bad "The Ingress at $INGRESS answered $code where the collector should answer 401; check it routes /v1 to otelgenie-cluster-collector:4318" ;;
      esac
    else
      info "curl is not on this machine, so the Ingress at $INGRESS was not tried from here."
    fi
  elif [ "$EXPECT_INGRESS" = yes ]; then
    note "The Ingress address has not been given in otelgenie yet, so servers outside the cluster have nothing to send to"
  fi

  if [ "$EXPECT_INSTRUMENTATION" = yes ]; then
    marked="$($K get pods -A -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.annotations}{"\n"}{end}' 2>/dev/null | grep -c 'instrumentation.opentelemetry.io/inject-')"
    injected="$($K get pods -A -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.initContainers[*].name}{"\n"}{end}' 2>/dev/null | grep -c 'opentelemetry-auto-instrumentation')"
    if [ "${marked:-0}" -eq 0 ]; then
      note "No pod carries an inject annotation yet, so no application is instrumented"
    elif [ "${injected:-0}" -lt "$marked" ]; then
      note "$marked pods carry an inject annotation but only $injected got the agent; pods annotated before the operator was ready need a restart"
    else
      ok "$injected application pods carry the agent"
    fi
  fi
}

# --- run --------------------------------------------------------------------

run() {
  case "$1:$MODE" in
    check-images:cluster) images_cluster ;;
    check-images:server)
      section "Container images"
      info "Images are only used on Kubernetes. Run this where kubectl points at the cluster."
      ;;
    check-prerequisites:cluster)
      section "Prerequisites: what cluster $CONTEXT ($(platform)) needs and has"
      prerequisites
      ;;
    install-prerequisites:cluster) install_prerequisites ;;
    check-prerequisites:server | install-prerequisites:server)
      section "Prerequisites"
      info "These belong to a cluster. Run this where kubectl points at it."
      ;;
    install-operator:cluster) install_operator ;;
    check-operator:cluster) check_operator ;;
    install-operator:server | check-operator:server)
      section "The OpenTelemetry Operator"
      info "The operator belongs to a cluster. Run this where kubectl points at it."
      ;;
    check-connectivity:cluster) connectivity_cluster ;;
    check-connectivity:server) connectivity_server ;;
    check-before-install:cluster) preinstall_cluster ;;
    check-before-install:server) preinstall_server ;;
    install-collector:server) install_server ;;
    install-collector:cluster) install_collectors_cluster ;;
    check-ingress:cluster) check_ingress ;;
    instrument-workload:cluster) instrument_workload "$arg1" "$arg2" "$arg3" "$arg4" ;;
    check-ingress:server | instrument-workload:server)
      section "Kubernetes only"
      info "This belongs to a cluster. Run it where kubectl points at it."
      ;;
    check-collector:cluster) postinstall_cluster ;;
    check-collector:server) postinstall_server ;;
    check-data-flow:cluster) validate_cluster ;;
    check-data-flow:server) validate_server ;;
    validate-everything:cluster) final_cluster ;;
    validate-everything:server)
      info "The final validation is for Kubernetes. On a server, these are the checks:"
      connectivity_server
      postinstall_server
      validate_server
      ;;
  esac
}

[ "$what" = check-requirements ] || echo "otelgenie: $PROJECT / $ENVIRONMENT, checking as a $MODE"
if [ "$what" = run-all ]; then
  requirements
  if [ "$MODE" = server ]; then
    run check-connectivity
    run check-before-install
    run install-collector
    run check-collector
    run check-data-flow
  else
    # final covers connectivity, the post-install checks and the data flow.
    run check-images
    run check-before-install
    run validate-everything
  fi
elif [ "$what" = check-requirements ]; then
  run check-images
else
  run "$what"
fi

printf '\n%d passed, %d failed, %d warnings\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ]
