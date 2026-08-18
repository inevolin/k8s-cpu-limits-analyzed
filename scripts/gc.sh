#!/usr/bin/env bash
# Starve the garbage collector with a CPU limit, and measure it.
#
# scripts/oom.sh proves the backlog mechanism with an explicit queue in
# native memory. This script removes the explicit queue and lets the GC
# itself be what the CPU limit starves. /gcwork builds a reference-dense
# graph of small objects per request and holds it while burning real
# CPU. Work arrives open-loop from outside, so on the capped pod
# in-flight requests pile up, live object count grows with them, every
# GC cycle gets more expensive (mark cost scales with object count, not
# bytes), and the collector and the workload fight over the same
# shrinking quota. The death spiral ends in OOMKilled, in-process
# OutOfMemoryException, or both. The uncapped pod holds a handful of
# requests in flight and never notices.
#
# Two design constraints that are easy to get wrong:
# - The load generator must be outside the pod. If the pod drove its own
#   allocation loop, throttling would slow allocation and collection in
#   the same proportion and the effect would cancel out. (.NET allocation
#   is closed-loop: an allocating thread blocks while the GC runs. The
#   /churn endpoint exists to see that effect on its own: at gentler
#   caps it produces measurable GC lag, not death.)
# - The gc pods have no readinessProbe (see k8s/gc-*.yaml): a drowning
#   pod would fail it, the Service would stop routing, and the open-loop
#   load would quietly become closed-loop. The startupProbe still gates
#   the initial in-container compile.
#
# Sized to fail fast: 100m cap (limit < request is invalid, so both pods
# request 100m; the only YAML delta stays limits.cpu), 512Mi memory
# limit = 384Mi .NET heap hard limit, so the runway is short.
#
# Env knobs:
#   GC_RPS 20, GC_SEC 120, GC_NODES 10000, GC_CPU_MS 40
#   (~800m of demand vs the 100m cap, ~1.5 MiB of live graph per
#    in-flight request)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

GC_RPS="${GC_RPS:-20}"
GC_SEC="${GC_SEC:-120}"
GC_NODES="${GC_NODES:-10000}"
GC_CPU_MS="${GC_CPU_MS:-40}"

guard
ensure_ns
ensure_src

log "applying manifests"
kc apply -f "${ROOT}/k8s/gc-limit.yaml"
kc apply -f "${ROOT}/k8s/gc-open.yaml"
kc apply -f "${ROOT}/k8s/probe.yaml"
# the capped pod compiles the app under its own 100m cap; give it time
wait_deploy gc-limit 900
wait_deploy gc-open 900
wait_deploy probe 300

# fresh pods are required for the death check below: lastState.terminated
# persists across restarts, so a reused pod would report a previous kill
for app in gc-limit gc-open; do
  R="$(kc get pods -l "app=${app}" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)"
  [ "${R:-0}" = "0" ] || die "${app} already restarted (${R}); run scripts/cleanup.sh first"
done

mkdir -p "$RESULTS"
: > "${RESULTS}/gc.jsonl"

pod_restarts()   { kc get pods -l "app=$1" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo ""; }
pod_last_reason(){ kc get pods -l "app=$1" -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo ""; }
pod_last_exit()  { kc get pods -l "app=$1" -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || echo ""; }
oomex_count()    { kc logs -l "app=$1" --tail=2000 2>/dev/null | grep -c 'OutOfMemoryException' || true; }

# Scrape /gcstats through the Service from the idle probe pod. Never exec
# into the pod under test: that spends its CPU budget on the measurement
# and, once the pod is busy enough, the exec fails outright and writes
# kubectl's error into the sample stream.
gcsample() {
  local app="$1" out
  out="$(kc exec deploy/probe -- python3 -c "
import urllib.request
print(urllib.request.urlopen('http://${app}/gcstats', timeout=45).read().decode())
" 2>/dev/null || true)"
  case "$out" in
    '{'*'}') printf '%s' "$out" ;;
    *)       printf '' ;;
  esac
}

DEMAND_M=$(( GC_RPS * GC_CPU_MS ))
URL_PATH="/gcwork?nodes=${GC_NODES}&cpuMs=${GC_CPU_MS}"
log "=== gc spiral  ${GC_NODES}-node graphs held in flight, ~${DEMAND_M}m demand vs 100m cap, ${GC_RPS} rps, up to ${GC_SEC}s ==="
apply_load gc-work-limit "http://gc-limit${URL_PATH}" "$GC_RPS" "$GC_SEC" 20
apply_load gc-work-open  "http://gc-open${URL_PATH}"  "$GC_RPS" "$GC_SEC" 20

T0=$SECONDS
DEADLINE=$(( SECONDS + GC_SEC + 120 ))
DIED="" OOMEX=0
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  T=$(( SECONDS - T0 ))

  REASON="$(pod_last_reason gc-limit)"
  EXIT_CODE="$(pod_last_exit gc-limit)"
  if [ -n "$REASON" ] || [ "${EXIT_CODE:-}" = "137" ]; then
    DIED="${REASON:-exit ${EXIT_CODE}} after ${T}s"
    log "gc-limit terminated: ${DIED}"
    break
  fi
  OPEN_REASON="$(pod_last_reason gc-open)"
  [ -n "$OPEN_REASON" ] && die "gc-open terminated (${OPEN_REASON}) - test invalid"

  OOMEX="$(oomex_count gc-limit)"
  if [ "${OOMEX:-0}" -gt 0 ]; then
    log "gc-limit threw OutOfMemoryException after ${T}s"
    break
  fi

  for app in gc-limit gc-open; do
    s="$(gcsample "$app")"
    [ -n "$s" ] && append_jsonl "${RESULTS}/gc.jsonl" \
      "$(printf '{"kind":"gcsample","t":%s,"app":"%s",%s' "$T" "$app" "${s#\{}")"
  done
  sleep 5
done

kc delete job gc-work-limit gc-work-open --ignore-not-found >/dev/null 2>&1 || true

EVIDENCE="$(kc get pods -l 'app in (gc-limit,gc-open)' \
  -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST_REASON:.status.containerStatuses[0].lastState.terminated.reason,EXIT:.status.containerStatuses[0].lastState.terminated.exitCode --no-headers || true)"
log "evidence:"$'\n'"${EVIDENCE}"

SUMMARY="$(python3 - "${RESULTS}/gc.jsonl" <<'PY'
import json, sys
rows = []
for l in open(sys.argv[1]):
    try:
        rows.append(json.loads(l))
    except ValueError:
        pass
for app, label in (("gc-limit", "100m limit"), ("gc-open", "no limit")):
    r = [d for d in rows if d.get("app") == app]
    if len(r) < 2:
        print(f"| {label} | unresponsive: too throttled to answer /gcstats before it died | | | | |")
        continue
    a, b = r[0], r[-1]
    dt = (b["t"] - a["t"]) or 1
    heap = b["managedHeapBytes"] / 1048576
    alloc = (b["totalAllocatedBytes"] - a["totalAllocatedBytes"]) / 1048576 / dt
    peak_inflight = max(d.get("inflight", 0) for d in r)
    print(f"| {label} | {b['pauseTimePercentage']}% | "
          f"{b['gen0']-a['gen0']} / {b['gen1']-a['gen1']} / {b['gen2']-a['gen2']} | "
          f"{heap:.1f} MiB | {alloc:.1f} MiB/s | {peak_inflight} |")
PY
)"

WHEN="$(date -u '+%Y-%m-%d %H:%M UTC')"
write_section "${RESULTS}/oom.md" gc <<EOF
## GC starvation run (scripts/gc.sh)

${WHEN}. context \`${KCTX}\`, namespace \`${NS}\`.
Same app, same 512Mi memory limit (384Mi .NET heap hard limit), same
${GC_RPS} rps. Only YAML delta: \`limits.cpu: 100m\` (both pods request 100m).

Nothing is queued explicitly here. Each request builds a ${GC_NODES}-node
reference-dense object graph (~1.5 MiB) and holds it while burning
${GC_CPU_MS}ms of CPU: ~${DEMAND_M}m of demand against the 100m cap. On the
capped pod, in-flight requests pile up, live object count grows, every GC
cycle gets more expensive, and the collector fights the workload for the
same shrinking quota.

| | pause | gen0 / gen1 / gen2 | managed heap | alloc rate | peak in-flight |
|---|---|---|---|---|---|
${SUMMARY}

Outcome, 100m limit pod: ${DIED:-survived} (OutOfMemoryException lines: ${OOMEX:-0}), restarts $(pod_restarts gc-limit).
Outcome, no limit pod: survived, restarts $(pod_restarts gc-open), OutOfMemoryException lines: $(oomex_count gc-open).

Caveats: the pod compiles the app in-container at startup, so part of
memory.current is SDK page cache (same caveat as the backlog section above), and a
pod this throttled often cannot answer /gcstats in time, so samples from
the capped pod can be sparse; the kill evidence below is from the
kubelet, not from sampling.

\`\`\`
${EVIDENCE}
\`\`\`

Raw samples: \`results/gc.jsonl\`.
EOF
log "wrote the gc section of ${RESULTS}/oom.md"

OPEN_RESTARTS="$(pod_restarts gc-open)"
[ "${OPEN_RESTARTS:-0}" = "0" ] || die "gc-open restarted - test invalid, the uncapped pod must survive"
[ -n "$DIED" ] || [ "${OOMEX:-0}" -gt 0 ] || die "expected the capped pod to die or throw OutOfMemoryException"
log "PROVEN: identical pods, identical load; the CPU-limited pod's GC lost the fight (${DIED:-OutOfMemoryException}), the uncapped pod never noticed."
