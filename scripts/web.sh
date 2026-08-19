#!/usr/bin/env bash
# Prove that a CPU limit alone can OOMKill a plain HTTP API that has no
# queue, no buffer and no background worker anywhere in it.
#
# Two pods run the same app with the same 512Mi memory limit; the only YAML
# delta is limits.cpu (100m vs none). Requests arrive open-loop at WEB_RPS.
# Each request allocates WEB_BYTES of working memory, awaits a WEB_IO_MS
# downstream dependency, spends WEB_CPU_MS of CPU-time on it, and frees it
# before returning. Nothing is retained: no request's memory outlives the
# request, and both pods run byte-identical handler code with an identical
# per-request footprint. The await is what makes this shape: it releases the
# thread while the buffer stays allocated, so the backlog is not silently
# bounded by ThreadPool size the way a synchronous handler's backlog would
# be.
#
# What differs is how many requests exist at once. Little's Law:
#   in flight = arrival rate x service time
# The CPU limit cannot change the arrival rate (that is the client's) and
# cannot change the footprint (that is the code's), so it changes service
# time, and in-flight count rises to match. Memory is in-flight count x
# footprint. Demand is WEB_RPS * WEB_CPU_MS = 800m against a 100m cap, so
# the capped pod's in-flight count grows without bound until the kernel
# ends it. The uncapped pod holds a handful of requests and stays flat.
#
# This is shape 3. Shape 1 (scripts/oom.sh) is an app-level queue holding
# memory; shape 2 (scripts/gc.sh) is garbage the collector cannot reclaim;
# here the memory is live and belongs to requests the pod has not been
# allowed to finish.
#
# Three design constraints that are easy to get wrong:
# - The handler must allocate *before* its first await. Allocating after it
#   puts the backlog in the ThreadPool queue at a few hundred bytes per
#   entry, the in-flight count tracks ThreadPool thread growth (order of
#   a thread per second) instead of the arrival deficit, and memory plateaus at
#   threads x footprint instead of running away. That is a real and useful
#   result - it is what an app that streams instead of buffering gets - but
#   it is not the shape under test here.
# - The web pods have no readinessProbe (see k8s/web-*.yaml): a drowning
#   pod would fail it, the Service would stop routing, and the open-loop
#   load would quietly become closed-loop. Symptom when you get this wrong
#   is a sawtooth - memory climbs, the pod drops out of the Service,
#   drains, rejoins - instead of a climb to the limit.
# - Watch `anon` in memory.stat, not memory.current. Both pods carry ~500
#   MiB of reclaimable page cache from the in-pod `dotnet run` compile,
#   which the kernel evicts under pressure rather than OOMKilling for.
#
# Sized to fail fast, like the gc lab: 100m cap (limit < request is
# invalid, so both pods request 100m; the only YAML delta stays limits.cpu)
# and a 512Mi memory limit, which leaves roughly 300 MiB of anon headroom
# above the runtime's own footprint.
#
# The knob that sets time-to-death is WEB_BYTES, not the cap. This system
# self-throttles: as the ThreadPool queue grows, Kestrel's accept loop gets
# less of the same shrinking quota, so the rate at which new requests reach
# a handler collapses along with the drain rate. Tightening limits.cpu
# therefore slows accumulation about as much as it slows draining and buys
# little. Per-request footprint costs the pod no CPU at all, so it is the
# lever that actually shortens the run: with ~250 MiB of anon headroom
# above the runtime's own footprint, 8 MiB per request puts the ceiling at
# roughly 30 in flight, which the arrival deficit reaches in seconds.
# (The measured arrival rate is also below WEB_RPS - the load pod has its
# own 500m limit and one thread per in-flight request, so it degrades once
# responses start hanging. That makes time-to-death conservative.)
#
# Env knobs:
#   WEB_RPS       default 20 (requests per second, open loop)
#   WEB_CPU_MS    default 40 (CPU-time per request -> demand 20*40 = 800m)
#   WEB_BYTES     default 8388608 (8MiB held for the life of the request)
#   WEB_IO_MS     default 200 (awaited downstream dependency per request)
#   WEB_SEC       default 90 (max load duration; stops at first OOMKill)
#   WEB_TIMEOUT   default 10 (client timeout; does not stop a running handler)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

WEB_RPS="${WEB_RPS:-20}"
WEB_CPU_MS="${WEB_CPU_MS:-40}"
WEB_BYTES="${WEB_BYTES:-8388608}"
WEB_IO_MS="${WEB_IO_MS:-200}"
WEB_SEC="${WEB_SEC:-90}"
WEB_TIMEOUT="${WEB_TIMEOUT:-10}"

guard
ensure_ns
ensure_src

log "applying manifests"
kc apply -f "${ROOT}/k8s/web-limit.yaml"
kc apply -f "${ROOT}/k8s/web-open.yaml"
# The pods copy /src/app.cs out of the configmap at container start, so an
# already-running pod keeps executing the source it started with. Without
# this restart, editing app.cs and re-running would silently measure the
# old code. (scripts/oom.sh and scripts/gc.sh have the same latent trap.)
kc rollout restart deployment/web-limit deployment/web-open >/dev/null
wait_deploy web-limit 600
wait_deploy web-open 600

mkdir -p "$RESULTS"
: > "${RESULTS}/web.jsonl"

INFO_LIMIT="$(http_get "$(pod_of web-limit)" /info || true)"
INFO_OPEN="$(http_get "$(pod_of web-open)" /info || true)"
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
running_pod() {
  kc get pods -l "app=$1" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
# Short-timeout exec. A pod this starved can take longer to schedule a
# forked `cat` than the default 20s request timeout, and a blocking sample
# costs more evidence than a missing one: fail fast, record null, keep the
# curve dense. Without this the loop lands ~2 samples across the whole run.
kcq() {
  kubectl --context "$KCTX" -n "$NS" --request-timeout="${SAMPLE_TIMEOUT}s" "$@"
}
SAMPLE_TIMEOUT="${SAMPLE_TIMEOUT:-4}"
# how often to probe /webstats, in seconds of wall clock
WS_EVERY="${WS_EVERY:-5}"
# cpu.stat gets its own, longer budget on a slower cadence: a fully
# throttled pod can take far longer than SAMPLE_TIMEOUT to schedule a
# forked `cat`, and losing this read costs the throttle evidence outright
CG_TIMEOUT="${CG_TIMEOUT:-20}"
CG_EVERY="${CG_EVERY:-10}"

webstat() {
  # /webstats via the pod, tolerant of the pod being mid-OOM
  local pod; pod="$(running_pod "$1")"
  [ -n "$pod" ] || { echo ""; return 0; }
  # curl-with-fallback, same reason lib.sh's http_get has one: the SDK
  # image is not guaranteed to ship curl forever
  kcq exec "pod/${pod}" -- bash -lc "
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --max-time ${SAMPLE_TIMEOUT} http://127.0.0.1:8080/webstats
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- -T ${SAMPLE_TIMEOUT} http://127.0.0.1:8080/webstats
    else
      exec 3<>/dev/tcp/127.0.0.1/8080
      printf 'GET /webstats HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3
      awk 'BEGIN{h=1} h && \$0==\"\" {h=0; next} !h {print}' <&3
    fi
  " 2>/dev/null || echo ""
}
# cpu.stat via the short-timeout exec. lib.sh's cgstats() is unusable in
# this loop for two reasons: it goes through `kc` (20s), which alone thins
# the sample curve to a handful of points across the run, and it echoes
# `nr_periods=0 nr_throttled=0 ...` on failure instead of returning empty,
# so a timed-out read looks like a successful one and silently zeroes the
# throttle evidence. Return empty on any failure and let the caller keep
# the last good read.
cgcpu() {
  local pod raw np nt
  pod="$(running_pod "$1")"
  [ -n "$pod" ] || { echo ""; return 0; }
  raw="$(kubectl --context "$KCTX" -n "$NS" --request-timeout="${CG_TIMEOUT}s" \
    exec "pod/${pod}" -- cat /sys/fs/cgroup/cpu.stat 2>/dev/null || true)"
  np="$(printf '%s\n' "$raw" | awk '/^nr_periods /{print $2; exit}')"
  nt="$(printf '%s\n' "$raw" | awk '/^nr_throttled /{print $2; exit}')"
  # a read that did not yield both counters is a failed read, not a zero one
  [ -n "$np" ] && [ -n "$nt" ] || { echo ""; return 0; }
  echo "nr_periods=${np} nr_throttled=${nt}"
}

cgmem() {
  # memory.current and memory.stat's `anon` straight from the cgroup. A
  # saturated pod may be too starved to answer its own /webstats (that is
  # itself a finding, see shape 2), so the memory evidence must not depend
  # on the app running at all. `anon` is the number that matters: both pods
  # carry ~500 MiB of reclaimable page cache from the in-pod compile, which
  # pins memory.current near the limit from the first sample and which the
  # kernel evicts under pressure rather than OOMKilling for.
  local pod; pod="$(running_pod "$1")"
  [ -n "$pod" ] || { echo ""; return 0; }
  kcq exec "pod/${pod}" -- sh -c \
    'cat /sys/fs/cgroup/memory.current; awk "/^anon /{print \$2}" /sys/fs/cgroup/memory.stat' \
    2>/dev/null | tr '\n' ' ' || echo ""
}

# baseline cpu.stat right before load starts, so the reported throttle %
# is load-phase only and does not include the in-pod dotnet compile at
# startup (which is itself throttled under the 100m cap and would
# otherwise inflate the number)
BASE_CG_LIMIT="$(cgcpu web-limit)"
BASE_NP=0 BASE_NT=0
if [ -n "$BASE_CG_LIMIT" ]; then
  BASE_NP="$(cg_field "$BASE_CG_LIMIT" nr_periods)"; BASE_NP="${BASE_NP:-0}"
  BASE_NT="$(cg_field "$BASE_CG_LIMIT" nr_throttled)"; BASE_NT="${BASE_NT:-0}"
fi

DEMAND_M=$(( WEB_RPS * WEB_CPU_MS ))
URL_PATH="/render?bytes=${WEB_BYTES}&cpuMs=${WEB_CPU_MS}&ioMs=${WEB_IO_MS}"
log "=== web  demand ~${DEMAND_M}m vs 100m cap, ${WEB_BYTES}B held per in-flight request, ${WEB_RPS} rps, up to ${WEB_SEC}s ==="
apply_load web-load-limit "http://web-limit${URL_PATH}" "$WEB_RPS" "$WEB_SEC" "$WEB_TIMEOUT"
apply_load web-load-open  "http://web-open${URL_PATH}"  "$WEB_RPS" "$WEB_SEC" "$WEB_TIMEOUT"

T0=$SECONDS
DEADLINE=$(( SECONDS + WEB_SEC + 120 ))
OOM_AT="" LAST_CG_LIMIT="$BASE_CG_LIMIT"
LAST_WEB_LIMIT="" LAST_WEB_OPEN="" LAST_MEM_LIMIT="" LAST_MEM_OPEN=""
# A pod too starved to serve its own /webstats is a real finding (see
# shape 2), but polling a dark endpoint costs a full SAMPLE_TIMEOUT every
# iteration and thins out the memory curve that matters. Give up on it
# after two misses in a row and record when that happened.
DARK_LIMIT=0 DARK_OPEN=0
WS_NEXT_LIMIT=0 WS_NEXT_OPEN=0
CG_NEXT=0 CG_READS=0
PEAK_ANON_LIMIT=0 PEAK_ANON_OPEN=0
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  T=$(( SECONDS - T0 ))

  # check termination *before* sampling: kubelet can restart a killed
  # container within seconds, and a sample taken after that restart would
  # read the fresh container's near-zero counters, silently deflating the
  # evidence instead of reflecting the pod that actually died.
  REASON="$(pod_last_reason web-limit)"
  EXIT_CODE="$(pod_last_exit web-limit)"
  # some runtimes surface a killed non-init process as reason=Error
  # rather than OOMKilled; exit 137 (128+SIGKILL) catches that too
  if [ "$REASON" = "OOMKilled" ] || [ "${EXIT_CODE:-}" = "137" ]; then
    OOM_AT="$T"
    log "web-limit killed after ${T}s (reason=${REASON:-?} exit=${EXIT_CODE:-?})"
    break
  fi
  OPEN_REASON="$(pod_last_reason web-open)"
  # the uncapped pod must never die; fail fast if it does
  [ -n "$OPEN_REASON" ] && die "web-open terminated (${OPEN_REASON}) - test invalid"

  for app in web-limit web-open; do
    r="$(pod_restarts "$app")"
    # a restart mid-iteration means this sample would belong to a fresh
    # container, not the one under test - skip it rather than record it
    [ "${r:-0}" = "0" ] || continue
    mem="$(cgmem "$app")"
    cur="$(printf '%s' "$mem" | awk '{print $1}')"
    anon="$(printf '%s' "$mem" | awk '{print $2}')"
    case "$app" in
      web-limit) dark="$DARK_LIMIT"; ws_next="$WS_NEXT_LIMIT"; peak="$PEAK_ANON_LIMIT" ;;
      web-open)  dark="$DARK_OPEN";  ws_next="$WS_NEXT_OPEN";  peak="$PEAK_ANON_OPEN" ;;
    esac
    ws=""
    # every exec costs up to SAMPLE_TIMEOUT against a starved pod, and the
    # memory curve is the evidence that matters; sample memory every pass
    # and /webstats on a wall-clock cadence. Gating on iteration count
    # instead would collapse to one probe per run as soon as a starved
    # pod stretches each iteration out to several seconds.
    if [ "$dark" -lt 2 ] && [ "$SECONDS" -ge "$ws_next" ]; then
      ws="$(webstat "$app")"
      if [ -n "$ws" ]; then dark=0; else dark=$(( dark + 1 )); fi
      ws_next=$(( SECONDS + WS_EVERY ))
    fi
    # A sample whose anon has collapsed to a fraction of the running peak
    # is the replacement container, not the pod under test: the kubelet
    # publishes restartCount only after the new container is serving, so
    # the restart guard above cannot catch it. Keep it out of the LAST_*
    # values the report publishes; the raw line still goes to the JSONL.
    live=1
    if [ -n "$anon" ]; then
      if [ "$anon" -lt $(( peak / 2 )) ]; then live=0; else peak="$anon"; fi
    fi
    case "$app" in
      web-limit)
        DARK_LIMIT="$dark"; WS_NEXT_LIMIT="$ws_next"; PEAK_ANON_LIMIT="$peak"
        [ -n "$anon" ] && [ "$live" = "1" ] && LAST_MEM_LIMIT="cur=${cur} anon=${anon}"
        [ -n "$ws" ] && [ "$live" = "1" ] && LAST_WEB_LIMIT="$ws" ;;
      web-open)
        DARK_OPEN="$dark"; WS_NEXT_OPEN="$ws_next"; PEAK_ANON_OPEN="$peak"
        [ -n "$anon" ] && [ "$live" = "1" ] && LAST_MEM_OPEN="cur=${cur} anon=${anon}"
        [ -n "$ws" ] && [ "$live" = "1" ] && LAST_WEB_OPEN="$ws" ;;
    esac
    # Raw samples go in raw, including any taken after the kill. The kubelet
    # publishes restartCount and lastState *after* the replacement container
    # is already serving, so a post-mortem sample cannot be recognised at
    # collection time; it is filtered in the summary below, where the reset
    # to near-zero memory is unambiguous.
    # record even when /webstats went dark, so the memory curve survives
    append_jsonl "${RESULTS}/web.jsonl" \
      "$(printf '{"kind":"websample","t":%s,"app":"%s","restarts":%s,"memoryCurrent":%s,"memoryAnon":%s,"stats":%s}' \
        "$T" "$app" "${r:-0}" "${cur:-null}" "${anon:-null}" "${ws:-null}")"
  done
  # restart-guard cpu.stat too: after the kill, cgstats would read the
  # fresh container's counters (dominated by its startup compile) and
  # poison the load-phase throttle number
  if [ "$SECONDS" -ge "$CG_NEXT" ] && [ "$(pod_restarts web-limit)" = "0" ]; then
    cg="$(cgcpu web-limit)"
    [ -n "$cg" ] && LAST_CG_LIMIT="$cg" && CG_READS=$(( CG_READS + 1 ))
    CG_NEXT=$(( SECONDS + CG_EVERY ))
  fi

  sleep 1
done

kc delete job web-load-limit web-load-open --ignore-not-found >/dev/null 2>&1 || true

LIMIT_RESTARTS="$(pod_restarts web-limit)"
OPEN_RESTARTS="$(pod_restarts web-open)"
LIMIT_EXIT="$(pod_last_exit web-limit)"
EVIDENCE="$(kc get pods -l 'app in (web-limit,web-open)' \
  -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST_REASON:.status.containerStatuses[0].lastState.terminated.reason,EXIT:.status.containerStatuses[0].lastState.terminated.exitCode --no-headers || true)"
log "evidence:"$'\n'"${EVIDENCE}"

THR_PCT="?" THR_NOTE=""
if [ -n "$LAST_CG_LIMIT" ]; then
  NP="$(cg_field "$LAST_CG_LIMIT" nr_periods)"; NP="${NP:-0}"
  NT="$(cg_field "$LAST_CG_LIMIT" nr_throttled)"; NT="${NT:-0}"
  # delta since just-before-load, so compile-time throttling at pod
  # startup doesn't get folded into the load-phase throttle percentage
  D_NP=$(( NP - BASE_NP )); D_NT=$(( NT - BASE_NT ))
  if [ "$D_NP" -gt 0 ] && [ "$D_NT" -ge 0 ]; then
    THR_PCT="$(ratio_pct "$D_NT" "$D_NP")"
  elif [ "$CG_READS" -eq 0 ]; then
    # no cpu.stat read survived after the baseline: the pod was too
    # throttled to schedule the exec at all, which is itself the finding.
    # Report the since-start ratio and name what actually failed.
    THR_PCT="$(ratio_pct "$NT" "${NP:-1}")"
    THR_NOTE=" (cumulative since container start; every load-phase read timed out - the pod could not schedule a forked \`cat\`)"
  else
    THR_PCT="$(ratio_pct "$NT" "${NP:-1}")"
    THR_NOTE=" (cumulative since container start; the pre-load baseline was lost)"
  fi
fi

# throughput and in-flight growth per pod: proves the capped pod kept
# serving right up to the kill (just slower than 20/s arriving) and that
# the memory it held was in-flight requests, not retention
SUMMARY="$(python3 - "${RESULTS}/web.jsonl" <<'PY'
import json, sys

rows = []
malformed = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except ValueError:
        # a sample truncated mid-body by the exec timeout. Losing one
        # sample is survivable; losing the whole report to a traceback
        # after the run has already happened is not.
        malformed += 1

if malformed:
    print(f"note: {malformed} malformed sample line(s) skipped (exec timeout mid-read)")

def mib(v):
    try:
        return int(v) / 2**20
    except (TypeError, ValueError):
        return None

for app in ("web-limit", "web-open"):
    r = [d for d in rows if d.get("app") == app]
    if not r:
        continue

    # A container restart resets the cgroup to near-zero. That is the only
    # thing that makes anon fall off a cliff here, and it is exactly what a
    # sample taken in the gap between the kill and the kubelet publishing
    # restartCount looks like. Cut the series there, so the published curve
    # describes the container under test and not its replacement.
    series = [(d["t"], mib(d.get("memoryAnon"))) for d in r]
    series = [(t, v) for t, v in series if v is not None]
    kept, dropped = [], 0
    for t, v in series:
        if kept and v < kept[-1][1] * 0.5:
            dropped = len(series) - len(kept)
            break
        kept.append((t, v))

    if len(kept) >= 2:
        pt, peak = max(kept, key=lambda kv: kv[1])
        # headline the peak, not the last sample. The replacement container
        # starts its own compile immediately, so a post-restart reading can
        # land above half the peak and survive the drop filter; the climb
        # to the peak is what the kernel acted on and is artifact-free.
        print(f"{app}: anon memory {kept[0][1]:.0f} MiB at t={kept[0][0]}s "
              f"-> peak {peak:.0f} MiB at t={pt}s")
    elif kept:
        print(f"{app}: anon memory {kept[0][1]:.0f} MiB at t={kept[0][0]}s (single usable sample)")
    if dropped:
        print(f"{app}: {dropped} post-restart sample(s) excluded from the curve "
              f"(container was replaced; raw series in results/web.jsonl)")

    # /webstats is the app answering about itself; the cgroup reads above do
    # not need the app at all. When only one of them works, that gap is the
    # point: a pod too throttled to serve its own stats is a pod whose
    # dashboards and probes are already lying.
    with_stats = [d for d in r if isinstance(d.get("stats"), dict)]
    if with_stats:
        last = with_stats[-1]["stats"]
        print(f"{app}: last /webstats at t={with_stats[-1]['t']}s - in flight {last['inflight']}, "
              f"peak {last['peakInflight']}, completed {last['completed']}, "
              f"holding {last['heldBytes']/2**20:.0f} MiB, "
              f"threadPoolThreads {last['threadPoolThreads']}, "
              f"queued work items {last['pendingWorkItems']}")
        f = mib(last.get("memoryFile"))
        if f is not None:
            print(f"{app}: reclaimable page cache at that sample {f:.0f} MiB")
    else:
        print(f"{app}: /webstats never answered during load - too starved to serve its own "
              f"stats endpoint, so every number above came from the cgroup instead")
PY
)"

CAP="$(kc get deploy web-limit \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || true)"

WHEN="$(date -u '+%Y-%m-%d %H:%M UTC')"
write_section "${RESULTS}/oom.md" web <<EOF
## Web API run (scripts/web.sh)

${WHEN}. context \`${KCTX}\`, namespace \`${NS}\`.
Same app, same 512Mi memory limit, same ${WEB_RPS} rps of HTTP requests
(${WEB_CPU_MS}ms CPU and a ${WEB_IO_MS}ms awaited downstream call each,
${WEB_BYTES} bytes of working memory allocated and freed inside the
request). Demand ~${DEMAND_M}m. Only delta: \`limits.cpu\`.

No queue, no buffer, no background worker: the handler frees every byte it
allocates before it returns. The memory that kills the capped pod belongs
to requests it has not been allowed to finish.

Note: both pods run \`dotnet run app.cs\`, which compiles on every start
inside the SDK image. That compile inflates \`memory.current\` with several
hundred MiB of reclaimable page cache, which the kernel evicts under
pressure rather than OOMKilling for - the figures above therefore track
\`anon\`. What the compile does cost is anon baseline and CPU, both of which
are specific to this image, so treat the exact seconds-to-death as a
property of this setup rather than a universal constant.

| | restarts | last termination | throttle during load |
|---|---|---|---|
| ${CAP:-capped} limit | ${LIMIT_RESTARTS:-?} | ${REASON:-none} (exit ${LIMIT_EXIT:-n/a}) | ${THR_PCT}% of CFS periods${THR_NOTE} |
| no limit | ${OPEN_RESTARTS:-0} | none | - |

OOMKilled after: ${OOM_AT:-not observed}s of load.

\`\`\`
${SUMMARY:-n/a}
\`\`\`

Last /webstats, ${CAP:-capped} limit pod: \`${LAST_WEB_LIMIT:-never answered during load}\`
Last /webstats, no-limit pod:   \`${LAST_WEB_OPEN:-n/a}\`
Last cgroup read, ${CAP:-capped} limit pod: \`${LAST_MEM_LIMIT:-n/a}\`
Last cgroup read, no-limit pod:   \`${LAST_MEM_OPEN:-n/a}\`

\`\`\`
${EVIDENCE}
\`\`\`

Raw samples: \`results/web.jsonl\`.
EOF
log "wrote ${RESULTS}/oom.md"

[ -n "$OOM_AT" ] || die "expected web-limit to be OOMKilled, it wasn't"
[ "${OPEN_RESTARTS:-0}" = "0" ] || die "web-open restarted, test invalid"
log "PROVEN: identical pods, identical load, no queue anywhere in the app; the CPU-limited one was OOMKilled, the other never restarted."
