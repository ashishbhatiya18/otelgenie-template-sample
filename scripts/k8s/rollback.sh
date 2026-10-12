#!/usr/bin/env bash
# Removes what apply.sh created in the cluster. The OpenTelemetry Operator
# itself is left in place, since other teams may be using it.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here" || exit 1
# shellcheck disable=SC1091
. ./settings.env

K=kubectl
command -v kubectl >/dev/null 2>&1 || K=oc

for f in $(ls manifests/*.yaml | sort -r); do
  $K delete -f "$f" --ignore-not-found
done
$K -n "$NAMESPACE" delete secret otelgenie-env --ignore-not-found
$K -n "$NAMESPACE" delete configmap otelgenie-ca otelgenie-applied --ignore-not-found
$K delete namespace "$NAMESPACE" --ignore-not-found
echo "Removed. The OpenTelemetry Operator was left installed."
