# oom run

2026-08-18 12:30 UTC. context `rancher-desktop`, namespace `cpu-lab`.
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
| 500m limit | 1 | OOMKilled (exit 137) | 97.31% of CFS periods |
| no limit | 0 | none | - |

OOMKilled after: 26s of load.

Last sample, 500m limit pod: `{"queueDepth":243,"queuedBytes":509607936,"processed":187,"gcHeapBytes":4104280,"workingSetBytes":655503360,"memoryCurrent":"1073078272","memoryMax":"1073741824"}`
Last sample, no-limit pod:   `{"queueDepth":1,"queuedBytes":2097152,"processed":411,"gcHeapBytes":3975120,"workingSetBytes":97677312,"memoryCurrent":"795136000","memoryMax":"1073741824"}`

Drain rates (the capped worker kept processing until the kill, just
slower than the 20/s arrival rate):

```
oom-limit: drained 9.8 jobs/s over the sampled 12s
oom-open: drained 21.8 jobs/s over the sampled 12s
```

```
oom-limit-75cc47b647-c4nv8   1     OOMKilled   137
oom-open-689c68ff7d-4zrpc    0     <none>      <none>
```

Raw samples: `results/oom.jsonl`.
