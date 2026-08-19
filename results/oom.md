# oom runs

One file, three experiments. Each section is rewritten by its own
script: scripts/oom.sh owns the backlog section, scripts/gc.sh owns
the gc section, scripts/web.sh owns the web section.

<!-- BEGIN backlog -->
## Backlog run (scripts/oom.sh)

2026-08-18 14:15 UTC. context `rancher-desktop`, namespace `cpu-lab`.
Same app, same 1Gi memory limit, same 20 rps of jobs
(40ms CPU each, 2097152 bytes of native memory held
until processed). Demand ~800m. Only delta: `limits.cpu: 500m`.

Note: both pods run `dotnet run app.cs`, which compiles on every
start inside the SDK image. The page cache from that compile counts
against `memory.max` alongside the queue, so part of the capped
pod's headroom before OOMKilled is SDK-image cache, not pure queue
growth; the direction of the result (only the capped pod dies) does
not depend on it, but treat the exact seconds-to-death as specific to
this image, not a universal constant.

| | restarts | last termination | throttle during load |
|---|---|---|---|
| 500m limit | 1 | OOMKilled (exit 137) | 96.01% of CFS periods |
| no limit | 0 | none | - |

OOMKilled after: 29s of load.

Last sample, 500m limit pod: `{"queueDepth":246,"queuedBytes":515899392,"processed":197,"gcHeapBytes":1862000,"workingSetBytes":675426304,"memoryCurrent":"1072259072","memoryMax":"1073741824"}`
Last sample, no-limit pod:   `{"queueDepth":1,"queuedBytes":2097152,"processed":426,"gcHeapBytes":4318792,"workingSetBytes":104464384,"memoryCurrent":"801529856","memoryMax":"1073741824"}`

Drain rates (the capped worker kept processing until the kill, just
slower than the 20/s arrival rate):

```
oom-limit: drained 10.3 jobs/s over the sampled 13s
oom-open: drained 21.6 jobs/s over the sampled 13s
```

```
oom-limit-75cc47b647-gdh8b   1     OOMKilled   137
oom-open-689c68ff7d-p6lwp    0     <none>      <none>
```

Raw samples: `results/oom.jsonl`.
<!-- END backlog -->

<!-- BEGIN gc -->
## GC starvation run (scripts/gc.sh)

2026-08-18 13:51 UTC. context `rancher-desktop`, namespace `cpu-lab`.
Same app, same 512Mi memory limit (384Mi .NET heap hard limit), same
20 rps. Only YAML delta: `limits.cpu: 100m` (both pods request 100m).

Nothing is queued explicitly here. Each request builds a 10000-node
reference-dense object graph (~1.5 MiB) and holds it while burning
40ms of CPU: ~800m of demand against the 100m cap. On the
capped pod, in-flight requests pile up, live object count grows, every GC
cycle gets more expensive, and the collector fights the workload for the
same shrinking quota.

| | pause | gen0 / gen1 / gen2 | managed heap | alloc rate | peak in-flight |
|---|---|---|---|---|---|
| 100m limit | unresponsive: too throttled to answer /gcstats before it died | | | | |
| no limit | 0.16% | 248 / 201 / 0 | 10.7 MiB | 12.2 MiB/s | 1 |

Outcome, 100m limit pod: OOMKilled after 225s (OutOfMemoryException lines: 0), restarts 1.
Outcome, no limit pod: survived, restarts 0, OutOfMemoryException lines: 0.

Caveats: the pod compiles the app in-container at startup, so part of
memory.current is SDK page cache (same caveat as results/oom.md), and a
pod this throttled often cannot answer /gcstats in time, so samples from
the capped pod can be sparse; the kill evidence below is from the
kubelet, not from sampling.

```
gc-limit-6685cc8b5f-8krzm   1     OOMKilled   137
gc-open-7b6776f9cd-zvmqb    0     <none>      <none>
```

Raw samples: `results/gc.jsonl`.
<!-- END gc -->

<!-- BEGIN web -->
## Web API run (scripts/web.sh)

2026-08-19 09:59 UTC. context `minikube`, namespace `cpu-lab`.
Same app, same 512Mi memory limit, same 20 rps of HTTP requests
(40ms CPU and a 200ms awaited downstream call each,
8388608 bytes of working memory allocated and freed inside the
request). Demand ~800m. Only delta: `limits.cpu`.

No queue, no buffer, no background worker: the handler frees every byte it
allocates before it returns. The memory that kills the capped pod belongs
to requests it has not been allowed to finish.

Note: both pods run `dotnet run app.cs`, which compiles on every start
inside the SDK image. That compile inflates `memory.current` with several
hundred MiB of reclaimable page cache, which the kernel evicts under
pressure rather than OOMKilling for - the figures above therefore track
`anon`. What the compile does cost is anon baseline and CPU, both of which
are specific to this image, so treat the exact seconds-to-death as a
property of this setup rather than a universal constant.

| | restarts | last termination | throttle during load |
|---|---|---|---|
| 100m limit | 1 | OOMKilled (exit 137) | 100.00% of CFS periods |
| no limit | 0 | none | - |

OOMKilled after: 24s of load.

```
web-limit: anon memory 241 MiB at t=0s -> peak 339 MiB at t=14s
web-limit: 1 post-restart sample(s) excluded from the curve (container was replaced; raw series in results/web.jsonl)
web-limit: /webstats never answered during load - too starved to serve its own stats endpoint, so every number above came from the cgroup instead
web-open: anon memory 277 MiB at t=0s -> peak 293 MiB at t=14s
web-open: last /webstats at t=14s - in flight 5, peak 11, completed 418, holding 40 MiB, threadPoolThreads 7, queued work items 0
web-open: reclaimable page cache at that sample 174 MiB
```

Last /webstats, 100m limit pod: `never answered during load`
Last /webstats, no-limit pod:   `{"inflight":5,"peakInflight":11,"completed":418,"heldBytes":41943040,"threadPoolThreads":7,"pendingWorkItems":0,"gcHeapBytes":2253680,"workingSetBytes":207376384,"memoryCurrent":"487981056","memoryAnon":"292139008","memoryFile":"182370304","memoryMax":"536870912"}`
Last cgroup read, 100m limit pod: `cur=536203264 anon=355729408`
Last cgroup read, no-limit pod:   `cur=478433280 anon=282615808`

```
web-limit-f84774698-t8jqg   1     OOMKilled   137
web-open-6dd8cd85b7-gsbk4   0     <none>      <none>
```

Raw samples: `results/web.jsonl`.
<!-- END web -->
