#!/usr/bin/env bash
# Tear down everything this repo created.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
guard

log "deleting labeled resources"
kc delete deployments,services,jobs,configmaps \
  -l app.kubernetes.io/part-of=cpu-lab --ignore-not-found

owner="$(kubectl --context "$KCTX" get ns "$NS" \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' --request-timeout=15s 2>/dev/null || true)"
if [ "$owner" = "cpu-lab" ]; then
  log "deleting namespace ${NS}"
  kubectl --context "$KCTX" delete ns "$NS" --ignore-not-found --request-timeout=60s >&2
else
  log "leaving namespace ${NS} (we did not create it)"
fi
