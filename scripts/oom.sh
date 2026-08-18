#!/usr/bin/env bash
# Prove that a CPU limit alone can end in OOMKilled.
#
# Two pods run the same app with the same 1Gi memory limit; the only
# YAML delta is limits.cpu (500m vs none). Work arrives at OOM_RPS,
# every job costs OOM_CPU_MS of CPU-time and holds OOM_BYTES of native
# memory until a worker has processed it. Demand is
# OOM_RPS * OOM_CPU_MS = 800m of CPU. The uncapped pod drains at that
# speed and its memory stays flat. The capped pod can only drain 500m
# worth, the backlog holds more and more memory, and the kernel
# OOMKills it. Nothing leaks; the pod just isn't allowed to do the
# work that would free the memory. Same mechanism as a GC that can't
# keep up, a Kafka consumer falling behind, or any in-memory queue.
#
# Env knobs:
#   OOM_RPS      default 20 (jobs per second)
#   OOM_CPU_MS   default 40 (CPU-time per job -> demand 20*40 = 800m)
#   OOM_BYTES    default 2097152 (2MiB held per queued job)
#   OOM_SEC      default 240 (max load duration; stops at first OOMKill)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

OOM_RPS="${OOM_RPS:-20}"
OOM_CPU_MS="${OOM_CPU_MS:-40}"
OOM_BYTES="${OOM_BYTES:-2097152}"
OOM_SEC="${OOM_SEC:-240}"

guard
ensure_ns
ensure_src

log "applying manifests"
kc apply -f "${ROOT}/k8s/oom-limit.yaml"
kc apply -f "${ROOT}/k8s/oom-open.yaml"
wait_deploy oom-limit 600
wait_deploy oom-open 600

mkdir -p "$RESULTS"
: > "${RESULTS}/oom.jsonl"

INFO_LIMIT="$(http_get "$(pod_of oom-limit)" /info || true)"
INFO_OPEN="$(http_get "$(pod_of oom-open)" /info || true)"
log "info limit: ${INFO_LIMIT}"
log "info open:  ${INFO_OPEN}"

pod_restarts() {
  kc get pods -l "app=$1" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo ""
}
pod_last_reason() {
  kc get pods -l "app=$1" -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo ""
}
pod_last_exit() {
  kc get pods -l "app=$1" -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || echo ""
}
memsample() {
  # /memstats via the pod, tolerant of the pod being mid-OOM
  local app="$1" pod
  pod="$(kc get pods -l "app=${app}" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || { echo ""; return 0; }
  http_get "$pod" /memstats 2>/dev/null || echo ""
}

# baseline cpu.stat right before load starts, so the reported throttle %
# is load-phase only and does not include the in-pod dotnet compile at
# startup (which is itself throttled under the 500m cap and would
# otherwise inflate the number)
BASE_CG_LIMIT="$(cgstats oom-limit 2>/dev/null || true)"
BASE_NP=0 BASE_NT=0
if [ -n "$BASE_CG_LIMIT" ]; then
  BASE_NP="$(cg_field "$BASE_CG_LIMIT" nr_periods)"; BASE_NP="${BASE_NP:-0}"
  BASE_NT="$(cg_field "$BASE_CG_LIMIT" nr_throttled)"; BASE_NT="${BASE_NT:-0}"
fi

DEMAND_M=$(( OOM_RPS * OOM_CPU_MS ))
URL_PATH="/enqueue?bytes=${OOM_BYTES}&cpuMs=${OOM_CPU_MS}"
log "=== oom  demand ~${DEMAND_M}m vs 500m cap, ${OOM_BYTES}B held per job, ${OOM_RPS} rps, up to ${OOM_SEC}s ==="
apply_load oom-load-limit "http://oom-limit${URL_PATH}" "$OOM_RPS" "$OOM_SEC" 5
apply_load oom-load-open  "http://oom-open${URL_PATH}"  "$OOM_RPS" "$OOM_SEC" 5

T0=$SECONDS
DEADLINE=$(( SECONDS + OOM_SEC + 120 ))
OOM_AT="" LAST_CG_LIMIT="$BASE_CG_LIMIT" LAST_MEM_LIMIT="" LAST_MEM_OPEN=""
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  T=$(( SECONDS - T0 ))

  # check termination BEFORE sampling: kubelet can restart a killed
  # container within seconds, and a sample taken after that restart
  # would read the fresh container's near-zero counters, silently
  # deflating the evidence (drain rate, throttle %, memory) instead of
  # reflecting the pod that actually died.
  REASON="$(pod_last_reason oom-limit)"
  EXIT_CODE="$(pod_last_exit oom-limit)"
  # some runtimes surface a killed non-init process as reason=Error
  # rather than OOMKilled; exit 137 (128+SIGKILL) catches that too
  if [ "$REASON" = "OOMKilled" ] || [ "${EXIT_CODE:-}" = "137" ]; then
    OOM_AT="$T"
    log "oom-limit killed after ${T}s (reason=${REASON:-?} exit=${EXIT_CODE:-?})"
    break
  fi
  OPEN_REASON="$(pod_last_reason oom-open)"
  # the uncapped pod must never die; fail fast if it does
  [ -n "$OPEN_REASON" ] && die "oom-open terminated (${OPEN_REASON}) - test invalid"

  for app in oom-limit oom-open; do
    r="$(pod_restarts "$app")"
    # a restart mid-iteration means this sample would belong to a fresh
    # container, not the one under test - skip it rather than record it
    [ "${r:-0}" = "0" ] || continue
    ms="$(memsample "$app")"
    if [ -n "$ms" ]; then
      case "$app" in
        oom-limit) LAST_MEM_LIMIT="$ms" ;;
        oom-open)  LAST_MEM_OPEN="$ms" ;;
      esac
      append_jsonl "${RESULTS}/oom.jsonl" \
        "$(printf '{"kind":"oomsample","t":%s,"app":"%s","restarts":%s,%s' \
          "$T" "$app" "${r:-0}" "${ms#\{}")"
    fi
  done
  cg="$(cgstats oom-limit 2>/dev/null || true)"
  [ -n "$cg" ] && LAST_CG_LIMIT="$cg"

  sleep 3
done

kc delete job oom-load-limit oom-load-open --ignore-not-found >/dev/null 2>&1 || true

LIMIT_RESTARTS="$(pod_restarts oom-limit)"
OPEN_RESTARTS="$(pod_restarts oom-open)"
LIMIT_EXIT="$(pod_last_exit oom-limit)"
EVIDENCE="$(kc get pods -l 'app in (oom-limit,oom-open)' \
  -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST_REASON:.status.containerStatuses[0].lastState.terminated.reason,EXIT:.status.containerStatuses[0].lastState.terminated.exitCode --no-headers || true)"
log "evidence:"$'\n'"${EVIDENCE}"

THR_PCT="?"
if [ -n "$LAST_CG_LIMIT" ]; then
  NP="$(cg_field "$LAST_CG_LIMIT" nr_periods)"; NP="${NP:-0}"
  NT="$(cg_field "$LAST_CG_LIMIT" nr_throttled)"; NT="${NT:-0}"
  # delta since just-before-load, so compile-time throttling at pod
  # startup doesn't get folded into the load-phase throttle percentage
  D_NP=$(( NP - BASE_NP )); D_NT=$(( NT - BASE_NT ))
  if [ "$D_NP" -gt 0 ] && [ "$D_NT" -ge 0 ]; then
    THR_PCT="$(ratio_pct "$D_NT" "$D_NP")"
  else
    # baseline sample raced with the pod's own startup and landed after
    # the load-phase snapshot; fall back to the cumulative since-start
    # ratio rather than print nonsense
    THR_PCT="$(ratio_pct "$NT" "${NP:-1}") (cumulative since start, baseline sample was inconsistent)"
  fi
fi

# drain rate per pod from the samples: proves the capped worker was still
# processing (just too slowly) right up to the kill, not silently stalled
DRAIN="$(python3 - "${RESULTS}/oom.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
for app in ("oom-limit", "oom-open"):
    r = [d for d in rows if d.get("app") == app]
    if len(r) >= 2 and r[-1]["t"] > r[0]["t"]:
        dt = r[-1]["t"] - r[0]["t"]
        dp = r[-1]["processed"] - r[0]["processed"]
        print(f"{app}: drained {dp/dt:.1f} jobs/s over the sampled {dt}s")
PY
)"

WHEN="$(date -u '+%Y-%m-%d %H:%M UTC')"
cat > "${RESULTS}/oom.md" <<EOF
# oom run

${WHEN}. context \`${KCTX}\`, namespace \`${NS}\`.
Same app, same 1Gi memory limit, same ${OOM_RPS} rps of jobs
(${OOM_CPU_MS}ms CPU each, ${OOM_BYTES} bytes of native memory held
until processed). Demand ~${DEMAND_M}m. Only delta: \`limits.cpu: 500m\`.

Note: both pods run \`dotnet run app.cs\`, which compiles on every
start inside the SDK image. The page cache from that compile counts
against \`memory.max\` alongside the queue, so part of the capped
pod's headroom before OOMKilled is SDK-image cache, not pure queue
growth; the direction of the result (only the capped pod dies) does
not depend on it, but treat the exact seconds-to-death as specific to
this image, not a universal constant.

| | restarts | last termination | throttle during load |
|---|---|---|---|
| 500m limit | ${LIMIT_RESTARTS:-?} | ${REASON:-none} (exit ${LIMIT_EXIT:-n/a}) | ${THR_PCT}% of CFS periods |
| no limit | ${OPEN_RESTARTS:-0} | none | - |

OOMKilled after: ${OOM_AT:-not observed}s of load.

Last sample, 500m limit pod: \`${LAST_MEM_LIMIT:-n/a}\`
Last sample, no-limit pod:   \`${LAST_MEM_OPEN:-n/a}\`

Drain rates (the capped worker kept processing until the kill, just
slower than the 20/s arrival rate):

\`\`\`
${DRAIN:-n/a}
\`\`\`

\`\`\`
${EVIDENCE}
\`\`\`

Raw samples: \`results/oom.jsonl\`.
EOF
log "wrote ${RESULTS}/oom.md"

[ -n "$OOM_AT" ] || die "expected oom-limit to be OOMKilled, it wasn't"
[ "${OPEN_RESTARTS:-0}" = "0" ] || die "oom-open restarted, test invalid"
log "PROVEN: identical pods, identical load; the CPU-limited one was OOMKilled, the other never restarted."
