# gc run

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
