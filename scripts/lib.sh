#!/usr/bin/env bash
# Shared helpers. Source this, don't run it.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT="$(cd "${LIB_DIR}/.." >/dev/null 2>&1 && pwd)"
RESULTS="${ROOT}/results"
KCTX="${KCTX:-$(kubectl config current-context 2>/dev/null || true)}"
NS="${NS:-cpu-lab}"
export LC_ALL=C

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

kc() {
  kubectl --context "$KCTX" -n "$NS" --request-timeout=20s "$@"
}

guard() {
  [ -n "$KCTX" ] || die "no kubectl context. set KCTX=..."
  if printf '%s %s' "$KCTX" "$NS" | grep -qiE 'prod|production|live'; then
    [ "${FORCE:-0}" = "1" ] || die "refusing context/ns that looks like prod (FORCE=1 to override)"
  fi
  log "target context=${KCTX} ns=${NS}"
}

ensure_ns() {
  if ! kubectl --context "$KCTX" get ns "$NS" --request-timeout=15s >/dev/null 2>&1; then
    kubectl --context "$KCTX" create namespace "$NS" --request-timeout=15s >&2
    kubectl --context "$KCTX" label ns "$NS" app.kubernetes.io/part-of=cpu-lab --overwrite --request-timeout=15s >&2
  fi
}

ensure_src() {
  kubectl create configmap src \
    --from-file="${ROOT}/app/app.cs" \
    --from-file="${ROOT}/app/load.py" \
    --dry-run=client -o yaml \
    | kubectl label -f - --local --dry-run=client -o yaml \
        app.kubernetes.io/part-of=cpu-lab \
    | kc apply -f - >/dev/null
}

wait_deploy() {
  local name="$1" timeout_s="${2:-300}"
  log "waiting for ${name}"
  kc rollout status "deployment/${name}" --timeout="${timeout_s}s" --request-timeout="$((timeout_s + 30))s"
}

pod_of() {
  local app="$1" pod
  pod="$(kc get pods -l "app=${app}" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || die "no running pod for app=${app}"
  printf '%s\n' "$pod"
}

# RFC3339 -> unix seconds. Works with macOS date (no GNU date needed).
iso_epoch() {
  python3 -c 'import sys; from datetime import datetime
s=sys.argv[1].replace("Z","+00:00")
print(int(datetime.fromisoformat(s).timestamp()))' "$1"
}

cgstats() {
  local app="$1" pod raw
  pod="$(pod_of "$app")"
  raw="$(kc exec "pod/${pod}" -- sh -c \
    'cat /sys/fs/cgroup/cpu.stat 2>/dev/null; echo ---; cat /sys/fs/cgroup/cpu.max 2>/dev/null' \
    2>/dev/null || true)"
  local np nt tu cm
  np="$(printf '%s\n' "$raw" | awk '/^nr_periods /{print $2; exit}')"
  nt="$(printf '%s\n' "$raw" | awk '/^nr_throttled /{print $2; exit}')"
  tu="$(printf '%s\n' "$raw" | awk '/^throttled_usec /{print $2; exit}')"
  cm="$(printf '%s\n' "$raw" | awk '/^---$/{f=1; next} f{print; exit}')"
  echo "nr_periods=${np:-0} nr_throttled=${nt:-0} throttled_usec=${tu:-0} cpu_max='${cm:-n/a}'"
}

cg_field() {
  local line="$1" field="$2"
  case "$field" in
    cpu_max) printf '%s\n' "$line" | sed -n "s/.*cpu_max='\([^']*\)'.*/\1/p" ;;
    *)       printf '%s\n' "$line" | sed -n "s/.*${field}=\([0-9]*\).*/\1/p" ;;
  esac
}

ratio_pct() {
  LC_ALL=C awk -v n="$1" -v d="$2" 'BEGIN { if (d==0) print "0.00"; else printf "%.2f", (n/d)*100 }'
}

json_num() {
  printf '%s' "$1" | python3 -c 'import json,sys; k=sys.argv[1]; print(json.load(sys.stdin).get(k,""))' "$2"
}

esc() { printf '%s' "$1" | sed 's/[&\#]/\\&/g'; }

# apply_load then wait_load. Split so the caller can snapshot cpu.stat
# after the load pod is Running (image pull is not part of the window).
apply_load() {
  local job="$1" url="$2" rps="$3" duration="$4" timeout="${5:-5}"
  local rendered="${RESULTS}/.tmp/${job}.yaml"
  mkdir -p "${RESULTS}/.tmp"
  sed \
    -e "s#\${JOB_NAME}#$(esc "$job")#g" \
    -e "s#\${TARGET_URL}#$(esc "$url")#g" \
    -e "s#\${RPS}#$(esc "$rps")#g" \
    -e "s#\${DURATION}#$(esc "$duration")#g" \
    -e "s#\${TIMEOUT}#$(esc "$timeout")#g" \
    "${ROOT}/k8s/load.yaml" > "$rendered"

  log "load job=${job} rps=${rps} ${duration}s -> ${url}"
  kc delete job "$job" --ignore-not-found >/dev/null
  kc apply -f "$rendered" >/dev/null

  local deadline=$((SECONDS + 180)) phase=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    phase="$(kc get pods -l "job-name=${job}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    [ "$phase" = "Running" ] && break
    sleep 1
  done
  [ "$phase" = "Running" ] || die "load pod for ${job} never reached Running (last phase='${phase}')"
}

wait_load() {
  local job="$1" duration="$2"
  local wait=$(( duration + 180 ))
  if ! kc wait "job/${job}" --for=condition=complete \
      --timeout="${wait}s" --request-timeout="$((wait + 30))s" >&2; then
    echo "job ${job} failed. last logs:" >&2
    kc logs "job/${job}" --tail=40 >&2 || true
    return 1
  fi

  local logs line
  logs="$(kc logs "job/${job}" --tail=80)"
  line="$(printf '%s\n' "$logs" | grep -m1 '^RESULT_JSON: ' || true)"
  [ -n "$line" ] || { echo "$logs" >&2; die "no RESULT_JSON from ${job}"; }
  printf '%s\n' "${line#RESULT_JSON: }"
}

append_jsonl() {
  local file="$1" json="$2"
  mkdir -p "$RESULTS"
  printf '%s\n' "$json" >> "$file"
}

# GET a path on the app inside its pod. sdk image may not ship curl/wget.
http_get() {
  local pod="$1" path="$2"
  kc exec "pod/${pod}" -- bash -lc "
    if command -v curl >/dev/null 2>&1; then
      curl -fsS http://127.0.0.1:8080${path}
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- http://127.0.0.1:8080${path}
    else
      exec 3<>/dev/tcp/127.0.0.1/8080
      printf 'GET ${path} HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3
      # drop headers
      awk 'BEGIN{h=1} h && \$0==\"\" {h=0; next} !h {print}' <&3
    fi
  "
}
