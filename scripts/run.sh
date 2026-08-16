#!/usr/bin/env bash
# Deploy both apps, run the benches, write results/.
#
# Env knobs (seconds unless noted):
#   STARTUP_ITERS   default 3
#   BURST_RPS       default 5
#   BURST_SEC       default 45
#   THREADS / BURST_MS   default 4 / 20
#     per request = 80ms of CPU-time > 50ms quota, so the cap must throttle
#     average demand = 5*4*20 = 400m, still under the 500m cap
#   BASE_RPS / BASE_SEC  default 5 / 20
#   SPIKE_RPS / SPIKE_SEC default 40 / 20
#   HOG_RPS / HOG_SEC    default 20 / 30
#   SAT_RPS / SAT_SEC    default 20 / 30
#     saturate leg: scale hog replicas so total hog busy-loops >= node CPUs
#     (node is 8 CPUs, each hog pod runs HOG_LOOPS=4 loops -> 2 replicas)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

STARTUP_ITERS="${STARTUP_ITERS:-3}"
BURST_RPS="${BURST_RPS:-5}"
BURST_SEC="${BURST_SEC:-45}"
THREADS="${THREADS:-4}"
BURST_MS="${BURST_MS:-20}"
BASE_RPS="${BASE_RPS:-5}"
BASE_SEC="${BASE_SEC:-20}"
SPIKE_RPS="${SPIKE_RPS:-40}"
SPIKE_SEC="${SPIKE_SEC:-20}"
HOG_RPS="${HOG_RPS:-20}"
HOG_SEC="${HOG_SEC:-30}"
SAT_RPS="${SAT_RPS:-20}"
SAT_SEC="${SAT_SEC:-30}"
CPU_MS="${CPU_MS:-15}"
IO_MS="${IO_MS:-30}"

guard
ensure_ns
ensure_src

log "applying manifests"
kc apply -f "${ROOT}/k8s/app-limit.yaml"
kc apply -f "${ROOT}/k8s/app-open.yaml"
kc apply -f "${ROOT}/k8s/hog.yaml"
wait_deploy app-limit 600
wait_deploy app-open 600

mkdir -p "$RESULTS"
: > "${RESULTS}/run.jsonl"
INFO_LIMIT="$(http_get "$(pod_of app-limit)" /info || true)"
INFO_OPEN="$(http_get "$(pod_of app-open)" /info || true)"
printf '%s\n' "$INFO_LIMIT" > "${RESULTS}/info-limit.json"
printf '%s\n' "$INFO_OPEN" > "${RESULTS}/info-open.json"
log "info limit: ${INFO_LIMIT}"
log "info open:  ${INFO_OPEN}"

median() {
  printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END { if (NR==0) print ""; else print a[int((NR+1)/2)] }'
}

# --- startup ---------------------------------------------------------------
log "=== startup (${STARTUP_ITERS} restarts each) ==="
LIMIT_S="" OPEN_S=""
for app in app-limit app-open; do
  readings=""
  for i in $(seq 1 "$STARTUP_ITERS"); do
    log "${app} restart ${i}/${STARTUP_ITERS}"
    kc rollout restart "deployment/${app}"
    wait_deploy "$app" 600
    pods="$(kc get pods -l "app=${app}" --sort-by=.status.startTime -o jsonpath='{.items[*].metadata.name}')"
    newest="$(printf '%s\n' "$pods" | awk '{print $NF}')"
    start="$(kc get pod "$newest" -o jsonpath='{.status.startTime}')"
    ready="$(kc get pod "$newest" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')"
    sec=$(( $(iso_epoch "$ready") - $(iso_epoch "$start") ))
    log "${app} #${i} ready in ${sec}s (pod ${newest})"
    readings="${readings} ${sec}"
    append_jsonl "${RESULTS}/run.jsonl" \
      "$(printf '{"kind":"startup","app":"%s","i":%s,"seconds":%s}' "$app" "$i" "$sec")"
  done
  case "$app" in
    app-limit) LIMIT_S="$readings" ;;
    app-open)  OPEN_S="$readings" ;;
  esac
done
# shellcheck disable=SC2086
LIMIT_MED="$(median $LIMIT_S)"
# shellcheck disable=SC2086
OPEN_MED="$(median $OPEN_S)"

leg() {
  # $1=job $2=url $3=rps $4=sec $5=app-label -> sets LEG_JSON, LEG_P99, LEG_P95, LEG_THR, ...
  local job="$1" url="$2" rps="$3" sec="$4" app="$5"
  local before after
  apply_load "$job" "$url" "$rps" "$sec" 5
  before="$(cgstats "$app")"
  LEG_JSON="$(wait_load "$job" "$sec")"
  after="$(cgstats "$app")"
  local bp bt ap at
  bp="$(cg_field "$before" nr_periods)"; bt="$(cg_field "$before" nr_throttled)"
  ap="$(cg_field "$after" nr_periods)";  at="$(cg_field "$after" nr_throttled)"
  LEG_D_P=$(( ap - bp ))
  LEG_D_T=$(( at - bt ))
  LEG_THR="$(ratio_pct "$LEG_D_T" "$LEG_D_P")"
  LEG_P99="$(json_num "$LEG_JSON" p99)"
  LEG_P95="$(json_num "$LEG_JSON" p95)"
  LEG_P50="$(json_num "$LEG_JSON" p50)"
  LEG_ERR="$(json_num "$LEG_JSON" errors)"
  LEG_TO="$(json_num "$LEG_JSON" timeouts)"
  append_jsonl "${RESULTS}/run.jsonl" \
    "$(printf '{"kind":"leg","job":"%s","app":"%s","throttlePct":%s,"cgPeriods":%s,"cgThrottled":%s,%s' \
      "$job" "$app" "$LEG_THR" "$LEG_D_P" "$LEG_D_T" "${LEG_JSON#\{}")"
}

# --- burst (avg demand under the 500m cap) --------------------------------
AVG_M=$(( BURST_RPS * THREADS * BURST_MS ))
BURST_PATH="/burst?threads=${THREADS}&ms=${BURST_MS}"
log "=== burst  ~${AVG_M}m average, ${BURST_RPS} rps, ${BURST_SEC}s ==="
leg burst-limit "http://app-limit${BURST_PATH}" "$BURST_RPS" "$BURST_SEC" app-limit
BL_P99="$LEG_P99"; BL_P95="$LEG_P95"; BL_P50="$LEG_P50"; BL_THR="$LEG_THR"; BL_ERR="$LEG_ERR"; BL_TO="$LEG_TO"
leg burst-open  "http://app-open${BURST_PATH}"  "$BURST_RPS" "$BURST_SEC" app-open
BO_P99="$LEG_P99"; BO_P95="$LEG_P95"; BO_P50="$LEG_P50"; BO_THR="$LEG_THR"; BO_ERR="$LEG_ERR"; BO_TO="$LEG_TO"

# --- spike ----------------------------------------------------------------
MIX_PATH="/mixed?cpuMs=${CPU_MS}&ioMs=${IO_MS}"
log "=== spike  ${BASE_RPS} rps ${BASE_SEC}s then ${SPIKE_RPS} rps ${SPIKE_SEC}s ==="
leg spike-base-limit "http://app-limit${MIX_PATH}" "$BASE_RPS" "$BASE_SEC" app-limit
SBL_P99="$LEG_P99"; SBL_THR="$LEG_THR"
leg spike-limit      "http://app-limit${MIX_PATH}" "$SPIKE_RPS" "$SPIKE_SEC" app-limit
SL_P99="$LEG_P99"; SL_P95="$LEG_P95"; SL_THR="$LEG_THR"; SL_ERR="$LEG_ERR"; SL_TO="$LEG_TO"
leg spike-base-open  "http://app-open${MIX_PATH}"  "$BASE_RPS" "$BASE_SEC" app-open
SBO_P99="$LEG_P99"; SBO_THR="$LEG_THR"
leg spike-open       "http://app-open${MIX_PATH}"  "$SPIKE_RPS" "$SPIKE_SEC" app-open
SO_P99="$LEG_P99"; SO_P95="$LEG_P95"; SO_THR="$LEG_THR"; SO_ERR="$LEG_ERR"; SO_TO="$LEG_TO"

# --- noisy neighbor -------------------------------------------------------
cleanup_hog() { kc scale deployment/hog --replicas=0 >/dev/null 2>&1 || true; }
trap cleanup_hog EXIT

log "=== hog  victim=app-open, ${HOG_RPS} rps ${HOG_SEC}s ==="
kc scale deployment/hog --replicas=0 >/dev/null
leg hog-off "http://app-open${MIX_PATH}" "$HOG_RPS" "$HOG_SEC" app-open
HO_P99="$LEG_P99"; HO_THR="$LEG_THR"

kc scale deployment/hog --replicas=1 >/dev/null
kc rollout status deployment/hog --timeout=90s --request-timeout=120s >&2
PLACEMENT="$(kc get pods -l 'app in (app-limit,app-open,hog)' \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName --no-headers || true)"
log "placement:"$'\n'"${PLACEMENT}"
leg hog-on "http://app-open${MIX_PATH}" "$HOG_RPS" "$HOG_SEC" app-open
HN_P99="$LEG_P99"; HN_THR="$LEG_THR"

# --- saturate (node actually full, not just a noisy neighbor) -------------
# gentle hog above is 4 busy loops on 1 replica: enough to be a neighbor,
# not enough to fill an 8-CPU node. Scale hog replicas so total loops (each
# pod runs HOG_LOOPS=4, set in k8s/hog.yaml) meet/exceed node CPUs, so the
# node is actually saturated and the "request protects you" claim gets a
# real test.
NODE_CPUS_NUM="$(kubectl --context "$KCTX" get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null | sed 's/[^0-9]*//g')"
NODE_CPUS_NUM="${NODE_CPUS_NUM:-8}"
HOG_LOOPS_PER_POD=4
SAT_REPLICAS=$(( (NODE_CPUS_NUM + HOG_LOOPS_PER_POD - 1) / HOG_LOOPS_PER_POD ))
[ "$SAT_REPLICAS" -ge 1 ] || SAT_REPLICAS=1
log "=== saturate  victim=app-open, ${SAT_RPS} rps ${SAT_SEC}s, hog replicas=${SAT_REPLICAS} (~$((SAT_REPLICAS * HOG_LOOPS_PER_POD)) busy loops on an ${NODE_CPUS_NUM}-CPU node) ==="
kc scale deployment/hog --replicas="$SAT_REPLICAS" >/dev/null
kc rollout status deployment/hog --timeout=90s --request-timeout=120s >&2
PLACEMENT_SAT="$(kc get pods -l 'app in (app-limit,app-open,hog)' \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName --no-headers || true)"
log "placement (saturate):"$'\n'"${PLACEMENT_SAT}"
leg saturate "http://app-open${MIX_PATH}" "$SAT_RPS" "$SAT_SEC" app-open
SAT_P99="$LEG_P99"; SAT_THR="$LEG_THR"
kc scale deployment/hog --replicas=0 >/dev/null
log "scaled hog back down"

# --- report ---------------------------------------------------------------
NODE_CPU="$(kubectl --context "$KCTX" get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null || echo '?')"
NODE_NAME="$(kubectl --context "$KCTX" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '?')"
WHEN="$(date '+%Y-%m-%d %H:%M %Z')"

cat > "${RESULTS}/run.md" <<EOF
# numbers from this run

${WHEN}. context \`${KCTX}\`, namespace \`${NS}\`, node \`${NODE_NAME}\` (${NODE_CPU} allocatable CPU).
Startup is 3 restarts, median. Everything else is one pass.

## what .NET saw

| pod | ProcessorCount | cpu.max |
|---|---|---|
| app-limit (500m cap) | $(printf '%s' "$INFO_LIMIT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("processorCount","?"))' 2>/dev/null || echo '?') | \`$(printf '%s' "$INFO_LIMIT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("cpuMax","?"))' 2>/dev/null || echo '?')\` |
| app-open (no cap) | $(printf '%s' "$INFO_OPEN" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("processorCount","?"))' 2>/dev/null || echo '?') | \`$(printf '%s' "$INFO_OPEN" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("cpuMax","?"))' 2>/dev/null || echo '?')\` |

## startup

\`dotnet run\` compiles on every start, so this is CPU-heavy on purpose.

| | runs (s) | median |
|---|---|---|
| 500m limit | ${LIMIT_S} | ${LIMIT_MED} |
| no limit | ${OPEN_S} | ${OPEN_MED} |

## burst

\`/burst?threads=${THREADS}&ms=${BURST_MS}\` at ${BURST_RPS} rps for ${BURST_SEC}s.
Average CPU demand is about ${AVG_M}m, under the 500m cap.

| | p50 | p95 | p99 | throttle | errors / timeouts |
|---|---|---|---|---|---|
| 500m limit | ${BL_P50} | ${BL_P95} | ${BL_P99} | ${BL_THR}% | ${BL_ERR} / ${BL_TO} |
| no limit | ${BO_P50} | ${BO_P95} | ${BO_P99} | ${BO_THR}% | ${BO_ERR} / ${BO_TO} |

## spike

\`/mixed?cpuMs=${CPU_MS}&ioMs=${IO_MS}\`. Quiet at ${BASE_RPS} rps (${BASE_SEC}s), then ${SPIKE_RPS} rps for ${SPIKE_SEC}s.

| | quiet p99 | spike p99 | spike throttle |
|---|---|---|---|
| 500m limit | ${SBL_P99} | ${SL_P99} | ${SL_THR}% |
| no limit | ${SBO_P99} | ${SO_P99} | ${SO_THR}% |

## hog

Same mixed URL, ${HOG_RPS} rps, ${HOG_SEC}s. Victim is app-open (no CPU limit). Hog is 4 busy loops, 100m request, no CPU limit.

| | p99 | throttle |
|---|---|---|
| no hog | ${HO_P99} | ${HO_THR}% |
| hog on the node | ${HN_P99} | ${HN_THR}% |

\`\`\`
${PLACEMENT}
\`\`\`

Raw lines: \`results/run.jsonl\`.
EOF

log "wrote ${RESULTS}/run.md"

log "regenerating charts"
python3 "${ROOT}/scripts/plot.py"

log "done. scripts/cleanup.sh when you want the namespace gone."
